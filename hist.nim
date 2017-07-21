## Useful command-line utility that maintains a simple database of
## shell commands along with their frequency.
import db_sqlite, os, docopt, strutils, sequtils

const help = """
hist

Usage:
  hist create
  hist -u CMD
  hist [DIR] [-n N] [-s SEARCHSTRING] [-t]

Options:

  DIR             Directory to search within. [default: .]
  -u CMD          Insert command into database.
  -n N            Retrieve the N most common commands. [default: 5]
  -s SEARCHSTRING Search for commands containing a string.
  -t              Order by most recently entered.
"""

var db: DbConn

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

proc search(
  cwd: string,
  limit: int,
  containsStr: string,
  orderByDate = false
): seq[Row] =
  const
    selectStmt          = "SELECT cmd, count$1 FROM history "
    datetimeConversion  = "datetime(entered_on, \"localtime\")"
    orderByCount        = "ORDER BY count DESC "
    orderByEntered      = "ORDER BY entered_on DESC "
    limitStmt           = "LIMIT ? "
    where               = "WHERE "
    whereAnd            = "AND "
    whereCwd            = "cwd = ? "
    whereLike           = "cmd LIKE ? "

  var
    q = selectStmt % (if orderByDate: ", " & datetimeConversion else: "")
    args: seq[string] = @[]
    addedWhere = false

  proc handleWhere() =
    if addedWhere:
      q.add whereAnd
    else:
      q.add where
      addedWhere = true

  if not cwd.isNil:
    handleWhere()
    q.add whereCwd
    args.add cwd

  if not containsStr.isNil:
    handleWhere()
    q.add whereLike
    args.add("%$1%" % containsStr)

  if orderByDate:
    q.add orderByEntered
  else:
    q.add orderByCount

  q.add limitStmt
  args.add $limit

  db.getAllRows(q.sql, args)

proc filter(cmd: string): bool =
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

proc main(args: Table[string, docopt.Value], results: var seq[Row]) {.raises: [].} =
  try:

    let
      n = ($args["-n"]).parseInt
      containsStr = if args["-s"]: $args["-s"] else: nil
      cwd = if args["DIR"]: expandFileName($args["DIR"]) else: nil

    results = search(
      cwd, n, containsStr, args["-t"]
    )

  except ValueError:
    quit "Value supplied for -n must be a number."
  except OverflowError:
    quit "Value supplied for -n out of bounds."
  except OSError:
    quit "No such directory."
  except DbError:
    quit "Could not access hist database file."

  if results.len > 0:
    displayResults(results)

when isMainModule:
  var
    args = docopt(help)
    results: seq[Row]

  discard openDb()
  defer: closeDb()

  if args["create"]:
    createTables()

  elif args["-u"]:
    insert(getCurrentDir(), $args["-u"])

  else:
    main(args, results)
