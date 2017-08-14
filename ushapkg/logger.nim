type
  Verbosity* = enum
    vNormal, vVerbose
  LogLevel* = enum
    llDebug, llInfo

const programName* = "usha"

var verbosity = vNormal

proc log*(s: string, level = llDebug) =
  if level >= llInfo or verbosity >= vVerbose:
    echo s

proc setLogLevel*(v: Verbosity) =
  verbosity = v

template doVerbose*(body: untyped): typed =
  if verbosity >= vVerbose:
    body
