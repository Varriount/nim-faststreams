import
  macros,
  inputs, outputs, buffers, async_backend

export
  inputs, outputs, async_backend

template clearAndWait(ep: AsyncEvent) =
  let e = ep
  clear e
  await e.wait()

type
  FsAsyncPipe* = ref object
    # TODO: Make these stream handles
    input*: AsyncInputStream
    output*: AsyncOutputStream
    buffers*: PageBuffers

template enterWait(fut: var Future, context: static string) =
  let wait = newFuture[void](context)
  fut = wait
  try: await wait
  finally: fut = nil

template awake(fp: Future) =
  let f = fp
  if f != nil and not finished(f):
    complete f

proc pipeRead(s: LayeredInputStream,
              dst: pointer, dstLen: Natural): Future[Natural] {.async.} =
  let buffers = s.buffers
  if buffers.eofReached: return 0

  var
    bytesInBuffersAtStart = buffers.totalBufferedBytes
    minBytesExpected = max(1, dstLen)
    bytesInBuffersNow = bytesInBuffersAtStart

  describeBuffers "at start", buffers

  while bytesInBuffersNow < minBytesExpected:
    awake buffers.waitingWriter
    echo "About to wait for writer"
    buffers.waitingReader.enterWait "waiting for writer to buffer more data"
    echo "Awaken from wait"

    bytesInBuffersNow = buffers.totalBufferedBytes
    if buffers.eofReached:
      echo "read bytes ", bytesInBuffersNow - bytesInBuffersAtStart
      describeBuffers "at end", buffers
      return bytesInBuffersNow - bytesInBuffersAtStart

  if dst != nil:
    doAssert drainBuffersInto(s, cast[ptr byte](dst), dstLen) == dstLen

  awake buffers.waitingWriter

  return bytesInBuffersNow - bytesInBuffersAtStart

proc pipeWrite(s: LayeredOutputStream, src: pointer, srcLen: Natural) {.async.} =
  let buffers = s.buffers
  echo "pipe write"
  while buffers.canAcceptWrite(srcLen) == false:
    buffers.waitingWriter.enterWait "waiting for reader to drain the buffers"

  if src != nil:
    buffers.appendUnbufferedWrite(src, srcLen)

  awake buffers.waitingReader
  describeBuffers "pipeWrite", buffers

template completedFuture(name: static string): untyped =
  let fut = newFuture[void](name)
  complete fut
  fut

let pipeInputVTable = InputStreamVTable(
  readSync: proc (s: InputStream, dst: pointer, dstLen: Natural): Natural
                 {.nimcall, gcsafe, raises: [IOError, Defect].} =
    fsTranslateErrors "Failed to read from pipe":
      let ls = LayeredInputStream(s)
      doAssert ls.allowWaitFor
      return waitFor pipeRead(ls, dst, dstLen)
  ,
  readAsync: proc (s: InputStream, dst: pointer, dstLen: Natural): Future[Natural]
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =
    fsTranslateErrors "Unexpected error from the async macro":
      let ls = LayeredInputStream(s)
      return pipeRead(ls, dst, dstLen)
  ,
  getLenSync: proc (s: InputStream): Option[Natural]
                   {.nimcall, gcsafe, raises: [IOError, Defect].} =
    let source = LayeredInputStream(s).source
    if source != nil:
      return source.len
  ,
  closeSync: proc (s: InputStream)
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =
    let source = LayeredInputStream(s).source
    if source != nil:
      close source
  ,
  closeAsync: proc (s: InputStream): Future[void]
                   {.nimcall, gcsafe, raises: [IOError, Defect].} =
    fsTranslateErrors "Unexpected error from the async macro":
      let source = LayeredInputStream(s).source
      if source != nil:
        return closeAsync(Async source)
      else:
        return completedFuture("pipeInput.closeAsync")
)

let pipeOutputVTable = OutputStreamVTable(
  writeSync: proc (s: OutputStream, src: pointer, srcLen: Natural)
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =
    fsTranslateErrors "Failed to write all bytes to pipe":
      var ls = LayeredOutputStream(s)
      doAssert ls.allowWaitFor
      waitFor pipeWrite(ls, src, srcLen)
  ,
  writeAsync: proc (s: OutputStream, src: pointer, srcLen: Natural): Future[void]
                   {.nimcall, gcsafe, raises: [IOError, Defect].} =
    # TODO: The async macro is raising exceptions even when
    #       merely forwarding a future:
    fsTranslateErrors "Unexpected error from the async macro":
      return pipeWrite(LayeredOutputStream s, src, srcLen)
  ,
  flushSync: proc (s: OutputStream)
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =
    let destination = LayeredOutputStream(s).destination
    if destination != nil:
      flush destination
  ,
  flushAsync: proc (s: OutputStream): Future[void]
                   {.nimcall, gcsafe, raises: [IOError, Defect].} =
    fsTranslateErrors "Unexpected error from the async macro":
      let destination = LayeredOutputStream(s).destination
      if destination != nil:
        return flushAsync(Async destination)
      else:
        return completedFuture("pipeOutput.flushAsync")
  ,
  closeSync: proc (s: OutputStream)
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =

    s.buffers.eofReached = true
    echo "writer closes the stream"

    fsTranslateErrors "Unexpected error from Future.complete":
      awake s.buffers.waitingReader

    let destination = LayeredOutputStream(s).destination
    if destination != nil:
      close destination
  ,
  closeAsync: proc (s: OutputStream): Future[void]
                   {.nimcall, gcsafe, raises: [IOError, Defect].} =
    s.buffers.eofReached = true

    fsTranslateErrors "Unexpected error from Future.complete":
      awake s.buffers.waitingReader

    fsTranslateErrors "Unexpected error from the async macro":
      let destination = LayeredOutputStream(s).destination
      if destination != nil:
        return closeAsync(Async destination)
      else:
        return completedFuture("pipeOutput.closeAsync")
)

func pipeInput*(source: InputStream,
                pageSize = defaultPageSize,
                allowWaitFor = false): AsyncInputStream =
  doAssert pageSize > 0

  AsyncInputStream LayeredInputStream(
    vtable: vtableAddr pipeInputVTable,
    buffers: initPageBuffers pageSize,
    allowWaitFor: allowWaitFor,
    source: source)

func pipeInput*(buffers: PageBuffers,
                allowWaitFor = false,
                source: InputStream = nil): AsyncInputStream =
  var span = if buffers.len == 0: default(PageSpan)
             else: obtainReadableSpan buffers.queue[0]

  AsyncInputStream LayeredInputStream(
    vtable: vtableAddr pipeInputVTable,
    buffers: buffers,
    span: span,
    spanEndPos: span.len,
    allowWaitFor: allowWaitFor,
    source: source)

proc pipeOutput*(destination: OutputStream,
                 pageSize = defaultPageSize,
                 maxBufferedBytes = defaultPageSize * 4,
                 allowWaitFor = false): AsyncOutputStream =
  doAssert pageSize > 0

  var
    buffers = initPageBuffers pageSize
    span = buffers.getWritableSpan()

  AsyncOutputStream LayeredOutputStream(
    vtable: vtableAddr pipeOutputVTable,
    buffers: buffers,
    span: span,
    spanEndPos: span.len,
    allowWaitFor: allowWaitFor,
    destination: destination)

proc pipeOutput*(buffers: PageBuffers,
                 allowWaitFor = false,
                 destination: OutputStream = nil): AsyncOutputStream =
  var span = buffers.getWritableSpan()

  AsyncOutputStream LayeredOutputStream(
    vtable: vtableAddr pipeOutputVTable,
    buffers: buffers,
    span: span,
    # TODO What if the buffers are partially populated?
    #      Should we adjust the spanEndPos? This would
    #      need the old buffers.totalBytesWritten var.
    spanEndPos: span.len,
    allowWaitFor: allowWaitFor,
    destination: destination)

func asyncPipe*(pageSize = defaultPageSize,
                maxBufferedBytes = defaultPageSize * 4): FsAsyncPipe =
  doAssert pageSize > 0
  FsAsyncPipe(buffers: initPageBuffers(pageSize, maxBufferedBytes))

func initReader*(pipe: FsAsyncPipe): AsyncInputStream =
  result = pipeInput(pipe.buffers)
  pipe.input = result

func initWriter*(pipe: FsAsyncPipe): AsyncOutputStream =

  result = pipeOutput(pipe.buffers)
  pipe.output = result

proc exchangeBuffersAfterPipilineStep(input: InputStream, output: OutputStream) =
  let formerInputBuffers = input.buffers
  let formerOutputBuffers = output.getBuffers

  input.resetBuffers formerOutputBuffers
  output.recycleBuffers formerInputBuffers

macro executePipeline*(start: InputStream, steps: varargs[untyped]): untyped =
  result = newTree(nnkStmtListExpr)

  var
    inputVal = start
    outputVal = newCall(bindSym"memoryOutput")

    inputVar = genSym(nskVar, "input")
    outputVar = genSym(nskVar, "output")

    step0 = steps[0]

  result.add quote do:
    var
      `inputVar` = `inputVal`
      `outputVar` = OutputStream `outputVal`

    `step0`(`inputVar`, `outputVar`)

  if steps.len > 2:
    let step1 = steps[1]
    result.add quote do:
      let formerInputBuffers = `inputVar`.buffers
      `inputVar` = memoryInput(getBuffers `outputVar`)
      recycleBuffers(`outputVar`, formerInputBuffers)
      `step1`(`inputVar`, `outputVar`)

  for i in 2 .. steps.len - 2:
    let step = steps[i]
    result.add quote do:
      exchangeBuffersAfterPipilineStep(`inputVar`, `outputVar`)
      `step`(`inputVar`, `outputVar`)

  var closingCall = steps[^1]
  closingCall.insert(1, outputVar)
  result.add closingCall

  if defined(debugMacros) or defined(debugPipelines):
    echo result.repr

macro executePipeline*(start: AsyncInputStream, steps: varargs[untyped]): untyped =
  var
    stream = ident "stream"
    pipelineSteps = ident "pipelineSteps"
    pipelineBody = newTree(nnkStmtList)

    step0 = steps[0]
    stepOutput = genSym(nskVar, "pipe")

  pipelineBody.add quote do:
    var `pipelineSteps` = newSeq[Future[void]]()
    var `stepOutput` = asyncPipe()
    add `pipelineSteps`, `step0`(`stream`, initWriter(`stepOutput`))

  var
    stepInput = stepOutput

  for i in 1 .. steps.len - 2:
    var step = steps[i]
    stepOutput = genSym(nskVar, "pipe")

    pipelineBody.add quote do:
      var `stepOutput` = asyncPipe()
      add `pipelineSteps`, `step`(initReader(`stepInput`), initWriter(`stepOutput`))

    stepInput = stepOutput

  var RetTypeExpr = copy steps[^1]
  RetTypeExpr.insert(1, newCall("default", ident"AsyncOutputStream"))

  var closingCall = steps[^1]
  closingCall.insert(1, newDotExpr(stepInput, ident"output"))

  pipelineBody.add quote do:
    await allFutures(`pipelineSteps`)
    return `closingCall`

  result = quote do:
    type RetType = type(`RetTypeExpr`)

    proc pipelineProc(`stream`: AsyncInputStream): Future[RetType] {.async.} =
      `pipelineBody`

    pipelineProc(`start`)

  when defined(debugMacros):
    echo result.repr

