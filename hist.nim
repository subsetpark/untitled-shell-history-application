## Useful command-line utility that maintains a simple database of
## shell commands along with their frequency.
import db_sqlite, os, docopt, strutils, sequtils

const help = """
hist: search your command-line history.

Usage:
  hist create
  hist clean [DAYS]
  hist update CMD
  hist [DIR] [-n N] [-s SEARCHSTRING] [-t] [-v]

Options:
  DIR             Directory to search within.
  CMD          Insert command into database.
  DAYS         Number of days of history to preserve. [default: 60]
  -n N            Retrieve the N most common commands. [default: 5]
  -s SEARCHSTRING Search for commands containing a string.
  -t              Order by most recently entered.
  -v              Verbose.
"""
type Verbosity = enum
  vNormal, vVerbose

var
  db: DbConn
  verbosity = vNormal

proc openDb(): DbConn =
  ## Open a DB connection and ensure presence of tables.
  const dbName = ".esdb"
  let
    dbPath = getHomeDir() / dbName

  db = open(dbPath, nil, nil, nil)
  return db

proc closeDb() =
  ## Close the DB connection.
  db.close()

type OrderBy = enum
  obCount = "count"
  obEnteredOn = "entered_on"

proc search(
  cwd: string,
  limit: int,
  containsStr: string,
  orderBy: OrderBy
): seq[Row] =
  ## Search the database for commands.
  const
    selectStmt          = "SELECT cmd, count$1 FROM history "
    datetimeConversion  = "datetime(entered_on, \"localtime\")"
    orderByStr          = "ORDER BY $1 DESC "
    limitStmt           = "LIMIT ? "
    where               = "WHERE "
    whereAnd            = "AND "
    whereCwd            = "cwd = ? "
    whereLike           = "cmd LIKE ? "
  # Start building a SQL query.
  var
    # If the search is ordered by time, include the most-recent-usage timestamp
    # as well as command and count.
    q = selectStmt % (if orderBy == obEnteredOn: ", " & datetimeConversion else: "")
    # Keep a list of args to be included for parameter interpolation.
    args: seq[string] = @[]
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
  const stopWords = ["hist", "exit"]
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

proc createTables() {.raises: [].} =
  try:
    db.exec sql"""
      CREATE TABLE IF NOT EXISTS history (
          id          INTEGER PRIMARY KEY,
          cwd         VARCHAR(256),
          cmd         VARCHAR(4096),
          count       INTEGER,
          entered_on  DATETIME DEFAULT CURRENT_TIMESTAMP
      );
      CREATE UNIQUE INDEX IF NOT EXISTS command_idx ON history (cwd, cmd);
      CREATE INDEX IF NOT EXISTS count_order_idx ON history (count);
      CREATE INDEX IF NOT EXISTS entered_order_idx ON history (entered_on);
      """
  except DbError:
    quit "Could not initialize hist database."

proc insert(cwd, cmd: string) {.raises: [].} =
  if filter(cmd):
    try:
      db.exec sql"""
        INSERT OR REPLACE INTO history
          (cwd, cmd, count) VALUES
          (?, ?, COALESCE(
            (SELECT count FROM history WHERE cwd=? AND cmd=?), 0) + 1)
          """, cwd, cmd, cwd, cmd
    except DbError:
      quit "Could not insert command into hist database."

proc clean(args: Table[string, docopt.Value]) {.raises: [].} =
  try:
    let
      timedelta = "-$1 day" % $args["DAYS"]
      q = "DELETE FROM history WHERE entered_on <= date('now', ?)"

    db.exec q.sql, timedelta
  except DbError:
    quit "Could not clean hist database."
  except ValueError:
    quit "Argument provided to `clean` must be a number."

proc main(args: Table[string, docopt.Value]) {.raises: [].} =
  ## Parse command arguments and perform a search of the history database.
  try:

    let
      n = ($args["-n"]).parseInt
      containsStr = if args["-s"]: $args["-s"] else: nil
      cwd = if args["DIR"]: expandFileName($args["DIR"]) else: nil
      orderBy = if args["-t"]: obEnteredOn else: obCount
      results = search(cwd, n, containsStr, orderBy)

    if results.len > 0:
      displayResults(results)

  except ValueError:
    quit "Value supplied for -n must be a number."
  except OverflowError:
    quit "Value supplied for -n out of bounds."
  except OSError:
    quit "No such directory."
  except DbError:
    quit "Could not access hist database file."

when isMainModule:
  var args = docopt(help)

  if args["-v"]:
    verbosity = vVerbose

  discard openDb()
  defer: closeDb()

  if args["create"]:
    createTables()

  elif args["update"]:
    insert(getCurrentDir(), $args["CMD"])

  elif args["clean"]:
    clean(args)

  else:
    main(args)
