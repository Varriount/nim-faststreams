mode = ScriptMode.Verbose

packageName   = "faststreams"
version       = "0.3.0"
author        = "Status Research & Development GmbH"
description   = "Nearly zero-overhead input/output streams for Nim"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 1.6.0",
         "stew",
         "unittest2"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") &
  " --skipParentCfg --skipUserCfg --outdir:build --nimcache:build/nimcache -f"

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path
  if (NimMajor, NimMinor) > (1, 6):
    build args & " --mm:refc -r", path

task test, "Run all tests":
  # TODO asyncdispatch backend is broken / untested
  # TODO chronos backend uses nested waitFor which is not supported
  for backend in ["-d:asyncBackend=none"]:
    for threads in ["--threads:off", "--threads:on"]:
      for mode in ["-d:debug", "-d:release", "-d:danger", "-d:useMalloc"]:
        run backend & " " & threads & " " & mode, "tests/all_tests"

task testChronos, "Run chronos tests":
  # TODO chronos backend uses nested waitFor which is not supported
  for backend in ["-d:asyncBackend=chronos"]:
    for threads in ["--threads:off", "--threads:on"]:
      for mode in ["-d:debug", "-d:release", "-d:danger"]:
        run backend & " " & threads & " " & mode, "tests/all_tests"
