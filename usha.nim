## Useful command-line utility that maintains a simple database of
## shell commands along with their frequency.
import os, docopt, strutils, sequtils
from db_sqlite import DbError, Row
import ushapkg/[db, logger]

const
  programName = "usha"
  help = """
hist: search your command-line history.

Usage:
  $1 init [-v]
  $1 clean [DAYS]
  $1 update [-v] CMD
  $1 [DIR] [-n N] [-s SEARCHSTRING] [-t] [-v]

Options:
  DIR             Directory to search within.
  CMD          Insert command into database.
  DAYS         Number of days of history to preserve. [default: 60]
  -n N            Retrieve the N most common commands. [default: 5]
  -s SEARCHSTRING Search for commands containing a string.
  -t              Order by most recently entered.
  -v              Verbose.
""" % programName

proc filter(cmd: string): bool =
  ## Maintain a list of common commands not to be included.
  const stopWords = [programName, "exit"]
  case cmd
  of "":
    false
  else:
    case cmd.split[0]
    of stopWords:
      false
    else:
      true

proc displayResults(results: seq[Row]) =
  let
    showDate = results[0].len > 2
    lineWidth = results.mapIt(it[0].len + it[1].len).max + 2
  for row in results:
    let dateStr = if showDate: "  " & row[2] else: ""
    echo row[0] & row[1].align(lineWidth - row[0].len) & dateStr

proc handleDbError(e: ref DbError, msg: string) =
  case e.msg
  of "no such table: $1" % tableName:
    quit "History database not initialized. Did you run `$1 init`?" % programName
  else:
    log e.msg
    quit msg

# User functions
proc historyInit() {.raises: [].} =
  try:
    dbInit()
  except DbError as e:
    log "Error: " & e.msg
    try:
      quit "Could not initialize $1 database." % programName
    except ValueError:
      quit "Unknown failure during database initialization."

proc historyUpdate(cwd, cmd: string) {.raises: [].} =
  if filter(cmd):
    try:
      dbInsert(cwd, cmd)
    except DbError as e:
      try:
        handleDbError(e, "Could not insert command into $1 database." % programName)
      except ValueError:
        quit "Unknown failure during database insertion."

proc historyClean(args: Table[string, docopt.Value]) {.raises: [] .} =
  try:
    dbClean($args["DAYS"])
  except DbError:
    quit "Could not clean $1 database." % programName
  except ValueError:
    quit "Argument provided to `clean` must be a number."

proc main(args: Table[string, docopt.Value]) {.raises: [].} =
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

    let results = dbSearch(cwd, n, containsStr, orderBy)
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

when isMainModule:
  var args = docopt(help)

  if args["-v"]:
    setLogLevel vVerbose

  discard dbOpen()
  defer: dbClose()

  if args["init"]:
    historyInit()

  elif args["update"]:
    historyUpdate(getCurrentDir(), $args["CMD"])

  elif args["clean"]:
    historyClean(args)

  else:
    main(args)
