## Useful command-line utility that maintains a simple database of
## shell commands along with their frequency.
import os, docopt, strutils, sequtils, sets
from db_sqlite import DbError, Row
import ushapkg/[db, logger]

const help = """
$1: search your command-line history.

Usage:
  $1 init [-v]
  $1 clean [DAYS]
  $1 update [-v] CMD [-c CHECKSUM]
  $1 [DIR] [-n N] [-tvrs SEARCHSTRING]

Options:
  DIR             Directory to search within.
  CMD             Insert command into database.
  DAYS            Number of days of history to preserve. [default: 60]
  -n N            Retrieve the N most common commands. [default: 5]
  -s SEARCHSTRING Search for commands containing a string.
  -t              Order by most recently entered.
  -v              Verbose.
  -r              Recurse current directory.
  -c CHECKSUM     Optional argument to update to prevent duplication.
""" % programName

proc filter(ignorePath, cmd: string): bool =
  ## Verify that a command is not 0-length and is not in the ignore
  ## list.
  if not existsFile(ignorePath):
    return true
  let stopWords = toSeq(lines(ignorePath)).toSet
  case cmd
  of "":
    false
  else:
    not stopWords.isValid or cmd.split[0] notin stopWords

proc displayResults(results: seq[SearchResponse]) =
  echo results.format()

proc handleDbError(e: ref DbError, msg: string) =
  case e.msg
  of "no such table: $1" % tableName:
    quit "History database not initialized. Did you run `$1 init`?" % programName
  else:
    log e.msg
    quit msg

# User functions
proc historyInit() {.raises: [].} =
  const failureMsg = "Unknown failure during database initialization."
  try:
    dbInit()
  except DbError as e:
    log "Error: " & e.msg
    try:
      quit "Could not initialize $1 database." % programName
    except ValueError:
      quit failureMsg
  except ValueError:
    quit failureMsg

proc historyUpdate(args: Table[string, docopt.Value]) {.raises: [].} =
  const
    ignoreFile = ".$1ignore" % programName
    genericErrorMessage = "Unknown failure during database insertion."

  try:
    let
      cwd = getCurrentDir()
      cmd = $args["CMD"]
      checksum = if args["-c"]: $args["-c"] else: nil
      ignorePath = getHomeDir() / ignoreFile

    if not ignorePath.filter(cmd):
      log "Skipping update; value in stop words: " & cmd
    elif not checksum.isNil and not dbChecksum(checksum):
      log "Skipping update; checksum matches: " & checksum
    else:
      dbInsert(cwd, cmd, checksum)

  except DbError as e:
    try:
      handleDbError(e, "Could not insert command into $1 database." % programName)
    except ValueError:
      quit genericErrorMessage
  except Exception, AssertionError, IOError:
    quit genericErrorMessage

proc historyClean(args: Table[string, docopt.Value]) {.raises: [] .} =
  try:
    dbClean($args["DAYS"])
  except DbError:
    quit "Could not clean $1 database." % programName
  except ValueError:
    quit "Argument provided to `clean` must be a number."

proc historySearch(args: Table[string, docopt.Value]) {.raises: [].} =
  ## Parse command arguments and perform a search of the history database.
  try:
    var orderBy: OrderBy

    let
      n = ($args["-n"]).parseInt
      containsStr = if args["-s"]: $args["-s"] else: nil
      cwd = if args["DIR"]: expandFileName($args["DIR"]) else: nil
    # Ordering: in time-based ordering, order by time most recently entered.
    # Otherwise, use count; within a single directory, use the count for that
    # entry; otherwise, use the sum of counts for all entries for that command.
    if args["-t"]:
      orderBy = obEnteredOn
    elif cwd.isNil:
      orderBy = obSumCount
    else:
      orderBy = obCount

    let results = dbSearch(cwd, n, containsStr, orderBy, args["-r"])
    if results.len > 0:
      displayResults(results)

  except ValueError:
    quit "Value supplied for -n must be a number."
  except OverflowError:
    quit "Value supplied for -n out of bounds."
  except OSError:
    quit "No such directory."
  except DbError as e:
    try:
      handleDbError(e, "Could not access $1 database file." % programName)
    except ValueError:
      quit "Unknown error during database search."

proc processArgs(args: Table[string, Value]) =
  if args["-v"]:
    setLogLevel vVerbose

  if args["init"]:
    historyInit()
  elif args["update"]:
    historyUpdate(args)
  elif args["clean"]:
    historyClean(args)
  else:
    historySearch(args)

when isMainModule:
  var args = docopt(help)

  discard dbOpen()
  defer: dbClose()

  processArgs(args)
