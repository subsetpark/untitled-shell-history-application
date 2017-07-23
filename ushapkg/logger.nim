type Verbosity* = enum
  vNormal, vVerbose

var verbosity = vNormal

proc log*(s: string) =
  if verbosity == vVerbose:
    echo s

proc setLogLevel*(v: Verbosity) =
  verbosity = v
