## Please note that the use of unbuffered streams comes with a number
## of restrictions:
##
## * Delayed writes are not supported.
## * Output consuming operations such as `getOutput`, `consumeOutputs` and
##   `consumeContiguousOutput` should not be used with them.
## * They cannot participate as intermediate steps in pipelines.

import
  deques, typetraits,
  stew/[ptrops, strings, ranges/ptr_arith],
  buffers, async_backend

export
  CloseBehavior

type
  OutputStream* = ref object of RootObj
    vtable*: ptr OutputStreamVTable   # This is nil for any memory output
    buffers*: PageBuffers              # This is nil for unsafe memory outputs
    span: PageSpan
    spanEndPos: Natural
    extCursorsCount: int
    closeFut: Future[void]

  WriteCursor* = object
    span: PageSpan
    stream: OutputStream

  LayeredOutputStream* = ref object of OutputStream
    subStream*: OutputStream

  OutputStreamHandle* = object
    s*: OutputStream

  AsyncOutputStream* {.borrow: `.`.} = distinct OutputStream

  WriteSyncProc* = proc (s: OutputStream, buf: pointer, bufLen: Natural)
                        {.nimcall, gcsafe, raises: [IOError, Defect].}

  WriteAsyncProc* = proc (s: OutputStream, buf: pointer, bufLen: Natural): Future[void]
                         {.nimcall, gcsafe, raises: [IOError, Defect].}

  FlushSyncProc* = proc (s: OutputStream)
                        {.nimcall, gcsafe, raises: [IOError, Defect].}

  FlushAsyncProc* = proc (s: OutputStream): Future[void]
                         {.nimcall, gcsafe, raises: [IOError, Defect].}

  CloseSyncProc* = proc (s: OutputStream)
                        {.nimcall, gcsafe, raises: [IOError, Defect].}

  CloseAsyncProc* = proc (s: OutputStream): Future[void]
                         {.nimcall, gcsafe, raises: [IOError, Defect].}

  OutputStreamVTable* = object
    writeSync*: WriteSyncProc
    writeAsync*: WriteAsyncProc
    flushSync*: FlushSyncProc
    flushAsync*: FlushAsyncProc
    closeSync*: CloseSyncProc
    closeAsync*: CloseAsyncProc

  VarSizeWriteCursor* = distinct WriteCursor

  FileOutputStream = ref object of OutputStream
    file: File

const
  nimAllocatorMetadataSize* = 0
    # TODO: Get this from Nim's allocator.
    # The goal is to make perfect page-aligned allocations

proc disconnectOutputDevice(s: OutputStream) =
  if s.vtable != nil:
    if s.vtable.closeAsync != nil:
      s.closeFut = s.vtable.closeAsync(s)
    elif s.vtable.closeSync != nil:
      s.vtable.closeSync(s)
    s.vtable = nil

template disconnectOutputDevice(s: AsyncOutputStream) =
  disconnectOutputDevice OutputStream(s)

proc close*(s: OutputStream,
            behavior = dontWaitAsyncClose)
           {.raises: [IOError, Defect].} =
  disconnectOutputDevice(s)
  if s.closeFut != nil:
    fsTranslateErrors "Stream closing failed":
      if behavior == waitAsyncClose:
        waitFor s.closeFut
      else:
        asyncCheck s.closeFut

proc close*(s: AsyncOutputStream): Future[void]
           {.raises: [IOError, Defect].} =
  disconnectOutputDevice(s)
  result = OutputStream(s).closeFut
  doAssert result != nil

template closeNoWait*(sp: AsyncOutputStream|OutputStream) =
  ## Close the stream without waiting even if's async.
  ## This operation will use `asyncCheck` internally to detect unhandled
  ## errors from the closing operation.
  close(InputStream(s), dontWaitAsyncClose)

# TODO
# The destructors are currently disabled because they seem to cause
# mysterious segmentation faults related to corrupted GC internal
# data structures.
#[
proc `=destroy`*(h: var OutputStreamHandle) {.raises: [Defect].} =
  if h.s != nil:
    if h.s.vtable != nil and h.s.vtable.closeSync != nil:
      try:
        h.s.vtable.closeSync(h.s)
      except IOError:
        # Since this is a destructor, there is not much we can do here.
        # If the user wanted to handle the error, they would have called
        # `close` manually.
        discard # TODO
    # h.s = nil
]#

converter implicitDeref*(h: OutputStreamHandle): OutputStream =
  h.s

template canExtendOutput(s: OutputStream): bool =
  # Streams writing to pre-allocated existing buffers cannot be grown
  s != nil and s.buffers != nil

template isExternalCursor(c: var WriteCursor): bool =
  # Is this the original stream cursor or is it one created by a "delayed write"
  addr(c) != addr(c.stream.cursor)

proc addPage(s: OutputStream) =
  s.span = s.buffers.addWritablePage().writableSpan
  s.spanEndPos += s.span.len

template makeHandle*(sp: OutputStream): OutputStreamHandle =
  let s = sp
  OutputStreamHandle(s: s)

proc memoryOutput*(pageSize = defaultPageSize): OutputStreamHandle =
  doAssert pageSize > 0
  makeHandle OutputStream(buffers: initPageBuffers(pageSize))

proc unsafeMemoryOutput*(buffer: pointer, len: Natural): OutputStreamHandle =
  let buffer = cast[ptr byte](buffer)

  makeHandle OutputStream(
    span: PageSpan(startAddr: buffer, endAddr: offset(buffer, len)),
    spanEndPos: len)

proc ensureRunway*(s: OutputStream, neededRunway: Natural) =
  ## The hint provided in `ensureRunway` overrides any previous
  ## hint specified at stream creation with `pageSize`.
  let runway = s.span.len

  # This is a temporary requirement.
  # ensureRunway should be called immediately after creating the OutputStream
  # In the future, we'll relax this by implementing more logic in buffers.nim
  doAssert runway == 0, "call ensureRunway immediately after stream creation"

  if neededRunway > runway:
    # If you use an unsafe memory output, you must ensure that
    # it will have a large enough size to hold the data you are
    # feeding to it.
    doAssert s.buffers != nil, "Unsafe memory output of insufficient size"
    s.span = s.buffers.ensureRunway(neededRunway - runway)

template ensureRunway*(s: AsyncOutputStream, neededRunway: Natural) =
  ensureRunway OutputStream(s, neededRunway)

let FileOutputVTable = OutputStreamVTable(
  writeSync: proc (s: OutputStream, buf: pointer, bufLen: Natural)
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =
    var file = FileOutputStream(s).file

    template fail =
      raise newException(IOError, "Failed to write OutputStream page.")

    if s.buffers != nil:
      s.buffers.consumeAllPages(pageAddr, pageLen):
        let written = file.writeBuffer(pageAddr, pageLen)
        if written != pageLen: fail()

    if bufLen > 0:
      doAssert buf != nil
      var written = file.writeBuffer(buf, bufLen)
      if written != bufLen: fail()
  ,
  flushSync: proc (s: OutputStream)
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =
    flushFile FileOutputStream(s).file
  ,
  closeSync: proc (s: OutputStream)
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =
    close FileOutputStream(s).file
)

template vtableAddr*(vtable: OutputStreamVTable): ptr OutputStreamVTable =
  ## This is a simple work-around for the somewhat broken side
  ## effects analysis of Nim - reading from global let variables
  ## is considered a side-effect.
  {.noSideEffect.}:
    unsafeAddr vtable

proc fileOutput*(filename: string,
                 fileMode: FileMode = fmWrite,
                 pageSize = defaultPageSize): OutputStreamHandle
                {.raises: [IOError, Defect].} =
  let f = open(filename, fileMode)

  makeHandle FileOutputStream(
    vtable: vtableAddr FileOutputVTable,
    buffers: initPageBuffers(pageSize),
    file: f)

proc pos*(s: OutputStream): int =
  s.spanEndPos - s.span.len

template pos*(s: AsyncOutputStream): int =
  pos OutputStream(s)

#
# Pre-conditions for `drainAllBuffers(Sync/Async)`
#  * The cursor has reached the current span end
#  * We are working with a vtable-enabled stream
#
# Post-conditions:
#  * All completed pages are written
#  * There is a fresh page ready for writing at the top
#    (we can reuse a previously existing page for this)
#  * The stream cursor is re-initialized at the start of the top page
#
proc drainAllBuffersSync(s: OutputStream, buf: pointer, bufSize: Natural) =
  s.vtable.writeSync(s, buf, bufSize)
  if s.buffers != nil:
    s.span = s.buffers.getWritableSpan()
    s.spanEndPos += s.span.len

proc drainAllBuffersAsync(s: OutputStream, buf: pointer, bufSize: Natural) {.async.} =
  await s.vtable.writeAsync(s, buf, bufSize)
  s.span = s.buffers.getWritableSpan()
  s.spanEndPos += s.span.len

proc createCursor(s: OutputStream, size: int): WriteCursor =
  inc s.extCursorsCount

  let
    # The start address matches the current stream main cursor location
    startAddr = s.span.startAddr
    endAddr = offset(startAddr, size)

  result = WriteCursor(
    stream: s,
    span: PageSpan(startAddr: startAddr, endAddr: endAddr))

  # Adjust the stream main cursor to point past the end
  # of the newly created cursor:
  s.span.startAddr = endAddr

proc delayFixedSizeWrite*(s: OutputStream, size: Natural): WriteCursor =
  let runway = s.span.len
  if size <= runway:
    result = createCursor(s, size)
  else:
    result = createCursor(s, runway)

    let
      runwayDeficit = size - runway
      nextPageSize = nextAlignedSize(runwayDeficit, s.buffers.pageSize)
      nextPage = s.buffers.addWritablePage(nextPageSize)
      nextPageSpan = nextPage.writableSpan

    s.span = PageSpan(startAddr: offset(nextPageSpan.startAddr, runwayDeficit),
                      endAddr: nextPageSpan.endAddr)

    # See the explanation about split cursors above
    nextPage.startOffset = -runwayDeficit

    s.spanEndPos += nextPageSize

proc delayVarSizeWrite*(s: OutputStream, maxSize: Natural): VarSizeWriteCursor =
  ## Please note that using variable sized writes are not supported
  ## for unbuffered streams and unsafe memory inputs.
  doAssert s.buffers != nil

  let runway = s.span.len
  if maxSize <= runway:
    let
      startAddr = s.span.startAddr
      endAddr = offset(startAddr, maxSize)

    result = VarSizeWriteCursor WriteCursor(
      stream: s,
      span: PageSpan(startAddr: startAddr, endAddr: endAddr))

    s.buffers.splitLastPageAt(endAddr)
    s.span.startAddr = endAddr

  else:
    s.buffers.endLastPageAt(s.span.startAddr)
    let
      nextPageSize = nextAlignedSize(maxSize, s.buffers.pageSize)
      nextPageSpan = s.buffers.addWritablePage(nextPageSize).writableSpan
      cursorEndAddr = offset(nextPageSpan.startAddr, maxSize)

    result = VarSizeWriteCursor WriteCursor(
      stream: s,
      span: PageSpan(startAddr: nextPageSpan.startAddr,
                     endAddr: cursorEndAddr))

    s.span = PageSpan(startAddr: cursorEndAddr,
                      endAddr: nextPageSpan.endAddr)
    s.spanEndPos += nextPageSize

proc finalize*(cursor: var WriteCursor) =
  doAssert cursor.stream.extCursorsCount > 0
  dec cursor.stream.extCursorsCount

proc finalWrite*(cursor: var WriteCursor, data: openArray[byte]) =
  doAssert data.len == cursor.span.len
  copyMem(cursor.span.startAddr, unsafeAddr data[0], data.len)
  finalize cursor

proc finalWrite*(c: var VarSizeWriteCursor, data: openArray[byte]) =
  template cursor: auto = WriteCursor(c)

  let overestimatedBytes = cursor.span.len - data.len
  doAssert overestimatedBytes >= 0

  for page in items(cursor.stream.buffers.queue):
    let baseAddr = page.pageBaseAddr
    if page.pageEndAddr == cursor.span.endAddr:
      # This is a page ending cursor
      page.endOffset = distance(baseAddr, cursor.span.startAddr) + data.len
      copyMem(cursor.span.startAddr, unsafeAddr data[0], data.len)
      finalize cursor
      return

    if cursor.span.startAddr == baseAddr:
      # This is page starting cursor
      page.startOffset = overestimatedBytes
      copyMem(offset(baseAddr, overestimatedBytes), unsafeAddr data[0], data.len)
      finalize cursor
      return

  doAssert false

proc tryMovingToNextPage(c: var WriteCursor) =
  # A split cursor is a fixed-size cursor that ended up on page boundary.
  #
  # Part of the cursor used the last few bytes of the first page and we've
  # left some empty space at the beginning of the second page.
  #
  # Even if the cursor size was very large, we've made sure the next
  # page is big enough to hold all the data. When we created the cursor,
  # we've taken a note regarding the number of bytes on the second page
  # that are reserved by writing them as a negative value for the page
  # `startOffset`.
  #
  # All we need to do here is update the cursor span to point to the next
  # page and set the now final `endAddr`. The page `startOffset` is updated
  # to 0 to indicate that the cursor has made the flip.
  #
  # If you are wondering, var-sized cursors cannot be split, because our
  # strategy is to always place them at the beggining or end of pages.
  #
  # When we try to create a var-sized cursor, we check if there are enough
  # bytes on the current page to contain the worst case scenario (the var
  # sized cursor has an upper size limit). If there are enough bytes, we
  # end the page prematurely (it will end up with an `endOffset`). We can
  # then recycle the same memory for the next page that will use an adjusted
  # `startOffset`. The `endOffset` of the first page will be written when
  # the cursor is finalized and its final size becomes known.
  #
  # If there weren't enough bytes (a much more rare event), we allocate a
  # new page. We adjust the `endOffset` of the current page to mark it's
  # premature end and we mark the cursor as special by writing a

  # The split cursor is definetely not on the last page, so we can iterate
  # only over the preceeding pages to find where it was:
  var prevPage = c.stream.buffers.queue[0]
  for i in 1 ..< c.stream.buffers.queue.len:
    let page = c.stream.buffers.queue[i]
    if c.span.endAddr == prevPage.pageEndAddr and page.startOffset < 0:
      # We found what we need, so let's get to business:
      c.span.startAddr = page.pageBaseAddr
      c.span.endAddr = offset(c.span.startAddr, -page.startOffset)
      page.startOffset = 0
      return
    prevPage = page

  # We didn't find any page that this cursor was ending, so this is not
  # a split cursor. This means that the user just tried to write past the
  # pre-allocated cursor span, which is considered a Defect (a range error)
  doAssert false, "Attempt to write past the end of a cursor"

template flushImpl(s: OutputStream, awaiter, writeOp, flushOp: untyped) =
  doAssert s.extCursorsCount == 0
  if s.vtable != nil:
    if s.buffers != nil:
      s.buffers.endLastPageAt s.span.startAddr
      awaiter s.vtable.writeOp(s, nil, 0)
      s.span = s.buffers.getWritableSpan()
      s.spanEndPos += s.span.len

    if s.vtable.flushOp != nil:
      awaiter s.vtable.flushOp(s)

proc flush*(s: OutputStream) =
  flushImpl(s, noAwait, writeSync, flushSync)

template flush*(s: AsyncOutputStream) =
  let s = sp
  flushImpl(s, fsAwait, writeAsync, flushAsync)

template writeByteImpl(s: OutputStream, b: byte, awaiter, writeOp, drainOp: untyped) =
  if s.span.atEnd:
    # Unsafe memory outputs don't use pages at all, so if our cursor
    # reached here, this is a range violation defect:
    doAssert canExtendOutput(s)

    if s.vtable == nil or s.extCursorsCount > 0:
      # This is the main cursor of a stream, but we are either not
      # ready to flush due to outstanding delayed writes or this is
      # just a memory output stream. In both cases, we just need to
      # allocate more memory and continue writing:
      addPage(s)
    elif s.buffers == nil:
      awaiter s.vtable.writeOp(nil, unsafeAddr b, 1)
    else:
      awaiter drainOp(s, nil, 0)

  writeByte(s.span, b)

proc write*(c: var WriteCursor, b: byte) =
  if c.span.atEnd:
    # The cursor has reached the end of its buffer, but it may be a
    # split cursor. If that's the case, the following function will
    # succeed. If that's not a split cursor, we'll raise a Defect.
    tryMovingToNextPage(c)

  writeByte(c.span, b)

proc write*(s: OutputStream, b: byte) =
  writeByteImpl(s, b, noAwait, writeSync, drainAllBuffersSync)

template write*(s: AsyncOutputStream, b: byte) =
  # TODO: I should do something with the write async Futures
  bind write
  write OutputStream(s)

template writeAndWait*(sp: AsyncOutputStream, b: byte) =
  let s = sp
  writeByteImpl(s, b, fsAwait, writeAsync, drainAllBuffersAsync)

template write*(s: OutputStream|AsyncOutputStream|var WriteCursor, x: char) =
  bind write
  write s, byte(x)

proc writeToANewPage(s: OutputStream, bytes: openArray[byte]) =
  var
    runway = s.span.len
    inputPos = unsafeAddr bytes[0]
    inputLen = bytes.len

  template reduceInput(delta: int) =
    inputPos = offset(inputPos, delta)
    inputLen -= delta

  if runway > 0:
    copyMem(s.span.startAddr, inputPos, runway)
    reduceInput runway

  doAssert s.buffers != nil

  let nextPageSize = nextAlignedSize(inputLen, s.buffers.pageSize)
  let nextPage = s.buffers.addWritablePage(nextPageSize)

  s.span = nextPage.writableSpan
  s.spanEndPos += s.span.len

  copyMem(s.span.startAddr, inputPos, inputLen)
  s.span.startAddr = offset(s.span.startAddr, inputLen)

template writeBytesImpl(s: OutputStream,
                        bytes: openArray[byte],
                        drainOp: untyped) =
  let inputLen = bytes.len
  if inputLen == 0: return

  # We have a short inlinable function handling the case when the input is
  # short enough to fit in the current page. We'll keep buffering until the
  # page is full:
  let runway = s.span.len
  if inputLen <= runway:
    copyMem(s.span.startAddr, unsafeAddr bytes[0], inputLen)
    s.span.startAddr = offset(s.span.startAddr, inputLen)
  elif s.vtable == nil or s.extCursorsCount > 0:
    # We are not ready to flush, so we must create pending pages.
    # We'll try to create them as large as possible:
    s.writeToANewPage(bytes)
  else:
    s.buffers.endLastPageAt(s.span.startAddr)
    drainOp

proc write*(s: OutputStream, bytes: openArray[byte]) =
  writeBytesImpl(s, bytes):
    drainAllBuffersSync(s, unsafeAddr bytes[0], bytes.len)

proc write*(s: OutputStream, chars: openArray[char]) =
  write s, charsToBytes(chars)

proc write*(s: OutputStream, value: string) {.inline.} =
  write s, value.toOpenArrayByte(0, value.len - 1)

template memCopyToBytes(value: auto): untyped =
  type T = type(value)
  static: assert supportsCopyMem(T)
  let valueAddr = unsafeAddr value
  makeOpenArray(cast[ptr byte](valueAddr), sizeof(T))

proc writeMemCopy*(s: OutputStream, value: auto) =
  bind write
  write s, memCopyToBytes(value)

proc writeBytesAsyncImpl(sp: AsyncOutputStream,
                         bytes: openarray[byte]): Future[void] =
  let s = OutputStream(sp)
  writeBytesImpl(s, bytes):
    return s.vtable.writeAsync(s, unsafeAddr bytes[0], bytes.len)

proc writeBytesAsyncImpl(s: AsyncOutputStream,
                         chars: openarray[char]): Future[void] =
  writeBytesAsyncImpl s, charsToBytes(chars)

proc writeBytesAsyncImpl(s: AsyncOutputStream,
                         str: string): Future[void] =
  writeBytesAsyncImpl s, toOpenArray(str, 0, str.len - 1)

template writeAndWait*(sp: AsyncOutputStream, value: auto) =
  bind writeBytesAsyncImpl

  let
    s = sp
    f = writeBytesAsyncImpl(s, value)

  if f != nil:
    fsAwait(f)
    s.span = s.buffers.getWritableSpan()
    s.spanEndPos += s.span.len

template writeMemCopyAndWait*(sp: AsyncOutputStream, value: auto) =
  writeAndWait(sp, memCopyToBytes(value))

proc writeBytesToCursor(c: var WriteCursor, bytes: openarray[byte]) =
  var
    runway = c.span.len
    inputPos = unsafeAddr bytes[0]
    inputLen = bytes.len

  template reduceInput(delta: int) =
    inputPos = offset(inputPos, delta)
    inputLen -= delta

  if inputLen <= runway:
    copyMem(c.span.startAddr, inputPos, inputLen)
    c.span.startAddr = offset(c.span.startAddr, inputLen)
  else:
    # This must be a split cursor. We need to complete its first page first,
    # then switch to the second and continue the write there.
    copyMem(c.span.startAddr, unsafeAddr bytes[0], runway)
    reduceInput runway
    # If this really is a split cursor, the following operation will succeed.
    # Otherwise, it will Defect and the conclusion is that this was a write
    # past the cursor end.
    c.tryMovingToNextPage()
    # On the next page, we have a new runway
    runway = c.span.len
    # The write shouldn't go past the end of the new runway
    doAssert inputLen <= runway
    copyMem(c.span.startAddr, inputPos, inputLen)
    c.span.startAddr = offset(c.span.startAddr, inputLen)

template write*(c: var WriteCursor, bytes: openarray[byte]) =
  bind writeBytesToCursor
  writeBytesToCursor(c, bytes)

proc write*(c: var WriteCursor, chars: openarray[char]) {.inline.} =
  var charsStart = unsafeAddr chars[0]
  writeBytesToCursor(c, makeOpenArray(cast[ptr byte](charsStart), chars.len))

proc writeMemCopy*[T](c: var WriteCursor, value: T) =
  bind writeBytesToCursor
  writeBytesToCursor(c, memCopyToBytes(value))

proc write*(c: var WriteCursor, str: string) =
  writeBytesToCursor(c, str.toOpenArrayByte(0, str.len - 1))

template consumeOutputs*(sp: OutputStream, bytesVar, body: untyped) =
  ## Please note that calling `consumeOutputs` on an unbuffered stream
  ## or an unsafe memory stream is considered a Defect.
  ##
  ## Before consuming the outputs, all outstanding delayed writes must be finalized.
  let s = sp
  doAssert s.extCursorsCount == 0 and s.buffers != nil

  consumeAllPages(s.buffers, pageStartAddr, pageLen):
    template bytesVar: untyped =
      makeOpenArray(pageStartAddr, pageLen)

    body

template consumeContiguousOutput*(sp: OutputStream, bytesVar, body: untyped) =
  ## Please note that calling `consumeContiguousOutput` on an unbuffered stream
  ## or an unsafe memory stream is considered a Defect.
  ##
  ## Before consuming the output, all outstanding delayed writes must be finalized.
  ##

  # TODO: This code is a bit too much to be inlined. Maybe this should be a proc
  # with a callback, but this will restrict the types of variables it can write to.
  # OTOH, perhaps only `consumeAllPages` is the offending part.
  var
    s = sp
    contigiousBytes: string # this may remain null
    bytesPtr: ptr byte
    bytesLen: int

  doAssert s.extCursorsCount == 0 and s.buffers != nil

  if s.buffers.queue.len == 1:
    let page = s.buffers.queue[0]
    bytesPtr = page.pageStartAddr
    bytesLen = page.endOffset - pageStartOffset
    # We need to reset the page to an empty state, so it can be reused
    page.startOffset = 0
    page.endOffset = 0
  else:
    contigiousBytes = newStringOfCap(s.pos)

    consumeAllPages(s.buffers, pageStartAddr, pageLen):
      contigiousBytes.add makeOpenArray(cast[ptr char](pageStartAddr), pageLen)

    bytesPtr = addr contigiousBytes[0]
    bytesLen = contigiousBytes.len

  template bytesVar: untyped =
    makeOpenArray(bytesPtr, bytesLen)

  body

proc getOutput*(s: OutputStream, T: type string): string =
  ## Please note that calling `getOutput` on an unbuffered stream
  ## or an unsafe memory stream is considered a Defect.
  ##
  ## Before consuming the output, all outstanding delayed writes must be finalized.
  ##
  doAssert s.extCursorsCount == 0 and s.buffers != nil
  s.buffers.endLastPageAt s.span.startAddr

  if s.buffers.queue.len == 1:
    let page = s.buffers.queue[0]
    if page.kind == stringPage and page.startOffset == 0:
      result.swap page.data[]
      result.setLen page.endOffset
      # We clear the buffers, so the stream will be in pristine state.
      # The next write is going to create a fresh new starting page.
      s.buffers.queue.clear()
      return

  result = newStringOfCap(s.pos)
  for page in items(s.buffers.queue):
    result.add page.pageChars

template getOutput*(s: OutputStream, T: type seq[byte]): seq[byte] =
  cast[seq[byte]](s.getOutput(string))

template getOutput*(s: OutputStream): seq[byte] =
  cast[seq[byte]](s.getOutput(string))
