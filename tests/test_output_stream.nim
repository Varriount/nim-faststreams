import
  os, unittest,
  ranges/ptr_arith,
  ../faststreams

proc bytes(s: string): seq[byte] =
  result = newSeqOfCap[byte](s.len)
  for c in s: result.add byte(c)

template bytes(c: char): byte = byte(c)
template bytes(b: seq[byte]): seq[byte] = b

proc repeat(b: byte, count: int): seq[byte] =
  result = newSeq[byte](count)
  for i in 0 ..< count: result[i] = b

suite "output stream":
  setup:
    var memStream = OutputStream.init
    var altOutput: seq[byte] = @[]
    var tempFilePath = getTempDir() / "faststreams_testfile"
    var fileStream = OutputStream.init tempFilePath

    const bufferSize = 1000000
    var buffer = alloc(bufferSize)
    var existingBufferStream = OutputStream.init(buffer, bufferSize)

  teardown:
    removeFile tempFilePath

  template output(val: auto) {.dirty.} =
    altOutput.add bytes(val)

    memStream.append val
    fileStream.append val
    existingBufferStream.append val

  template checkOutputsMatch =
    fileStream.flush

    let
      fileContents = readFile(tempFilePath).string.bytes
      memStreamContents = memStream.getOutput

    check altOutput == memStreamContents
    check altOutput == fileContents
    check altOutput == makeOpenArray(cast[ptr byte](buffer),
                                     existingBufferStream.pos)

  test "no appends produce an empty output":
    checkOutputsMatch()

  test "string output":
    for i in 0 .. 1:
      output $i
      output " bottles on the wall"
      output '\n'

    checkOutputsMatch()

  test "delayed write":
    output "initial output\n"
    const delayedWriteContent = bytes "delayed write\n"

    var cursor = memStream.delayFixedSizeWrite(delayedWriteContent.len)
    let cursorStart = memStream.pos
    altOutput.add delayedWriteContent

    fileStream.append delayedWriteContent
    existingBufferStream.append delayedWriteContent

    var totalBytesWritten = 0
    for i, count in [12, 342, 2121, 23, 1, 34012, 932]:
      output repeat(byte(i), count)
      totalBytesWritten += count
      check memStream.pos - cursorStart == totalBytesWritten

    cursor.endWrite delayedWriteContent

    checkOutputsMatch()

