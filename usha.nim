## Useful command-line utility that maintains a simple database of
## shell commands along with their frequency.
import db_sqlite, os, docopt, strutils, sequtils

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
type Verbosity = enum
  vNormal, vVerbose

var
  db: DbConn
  verbosity = vNormal

const
  tableName = "history"

proc openDb(): DbConn =
  ## Open a DB connection.
  const dbName = ".esdb"
  let dbPath = getHomeDir() / dbName

  db = open(dbPath, nil, nil, nil)
  return db

proc closeDb() =
  ## Close the DB connection.
  db.close()

type OrderBy = enum
  obCount = "count"
  obSumCount = "SUM(count)"
  obEnteredOn = "entered_on"

proc search(
  cwd: string,
  limit: int,
  containsStr: string,
  orderBy: OrderBy
): seq[Row] =
  ## Search the database for commands.
  const
    selectStmt          = "SELECT cmd, $1$2 FROM ? "
    datetimeConversion  = "datetime(entered_on, \"localtime\")"
    orderByStr          = "ORDER BY $1 DESC "
    limitStmt           = "LIMIT ? "
    where               = "WHERE "
    whereAnd            = "AND "
    whereCwd            = "cwd = ? "
    whereLike           = "cmd LIKE ? "
    groupBy             = "GROUP BY cmd "
  # Start building a SQL query.
  var
    q = selectStmt % [
      # In global search, work with total command counts
      (if cwd.isNil: "SUM(count)" else: "count"),
      # If the search is ordered by time, include the most-recent-usage timestamp
      # as well as command and count.
      (if orderBy == obEnteredOn: ", " & datetimeConversion else: "")
    ]
    # Keep a list of args to be included for parameter interpolation.
    args: seq[string] = @[tableName]
    addedWhere = false

  proc handleWhere() =
    ## Ensure that a filter begins with a WHERE and additional conditions are
    ## added with AND.
    if addedWhere:
      q.add whereAnd
    else:
      q.add where
      addedWhere = true

  if not cwd.isNil:
    # If a directory was specified, add a lookup against `cwd`.
    handleWhere()
    q.add whereCwd
    args.add cwd

  if not containsStr.isNil:
    # If a search string was specified, add a LIKE clause.
    handleWhere()
    q.add whereLike
    args.add("%$1%" % containsStr)

  if cwd.isNil:
    # In global search, only show each command once.
    q.add groupBy

  # Add the ordering and limit clauses.
  q.add orderByStr % $orderBy
  q.add limitStmt
  args.add $limit

  if verbosity == vVerbose:
    echo "Executing query:\n$1\nwith $2 argument(s): $3\n" % [
      q, $args.len, args.join(", ")
    ]

  result = db.getAllRows(q.sql, args)

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

# User functions

proc init() {.raises: [].} =
  try:
    db.exec sql"""
      CREATE TABLE IF NOT EXISTS ? (
          id          INTEGER PRIMARY KEY,
          cwd         VARCHAR(256),
          cmd         VARCHAR(4096),
          count       INTEGER,
          entered_on  DATETIME DEFAULT CURRENT_TIMESTAMP
      )""", tableName
    db.exec sql"CREATE UNIQUE INDEX IF NOT EXISTS command_idx ON ? (cwd, cmd)", tableName
    db.exec sql"CREATE INDEX IF NOT EXISTS count_order_idx ON ? (count)", tableName
    db.exec sql"CREATE INDEX IF NOT EXISTS entered_order_idx ON ? (entered_on)", tableName
  except DbError as e:
    if verbosity == vVerbose:
      echo "Error: ", e.msg
    try:
      quit "Could not initialize $1 database." % programName
    except ValueError:
      quit "Unknown failure during database initialization."

proc handleDbError(e: ref DbError, msg: string) =
    case e.msg
    of "no such table: $1" % tableName:
      quit "History database not initialized. Did you run `$1 init`?" % programName
    else:
      if verbosity == vVerbose:
        echo e.msg
      quit msg

proc insert(cwd, cmd: string) {.raises: [].} =
  if filter(cmd):
    try:
      db.exec sql"""
        INSERT OR REPLACE INTO ?
          (cwd, cmd, count) VALUES
          (?, ?, COALESCE(
            (SELECT count FROM ? WHERE cwd=? AND cmd=?), 0) + 1)
          """, tableName, cwd, cmd, tableName, cwd, cmd
    except DbError as e:
      try:
        handleDbError(e, "Could not insert command into $1 database." % programName)
      except ValueError:
        quit "Unknown failure during database insertion."

proc clean(args: Table[string, docopt.Value]) {.raises: [].} =
  try:
    let
      timedelta = "-$1 day" % $args["DAYS"]
      q = "DELETE FROM ? WHERE entered_on <= date('now', ?)"

    db.exec q.sql, tableName, timedelta
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

    let results = search(cwd, n, containsStr, orderBy)
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
    verbosity = vVerbose

  discard openDb()
  defer: closeDb()

  if args["init"]:
    init()

  elif args["update"]:
    insert(getCurrentDir(), $args["CMD"])

  elif args["clean"]:
    clean(args)

  else:
    main(args)