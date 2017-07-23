import db_sqlite, os, strutils, sequtils
import logger

var db: DbConn

const tableName* = "history"

type OrderBy* = enum
  obCount = "count"
  obSumCount = "SUM(count)"
  obEnteredOn = "entered_on"

proc dbOpen*(): DbConn =
  ## Open a DB connection.
  const dbName = ".esdb"
  let dbPath = getHomeDir() / dbName

  db = open(dbPath, nil, nil, nil)
  return db

proc dbClose*() =
  ## Close the DB connection.
  db.close()

proc dbInit*() =
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

type SearchResponse* = object
  cmd, count, timestamp: string

proc lineWidth(resp: SearchResponse): int =
  resp.cmd.len + resp.count.len + 2

proc toLine(resp: SearchResponse, maxLineWidth: int): string =
  var dateStr: string
  if not resp.timestamp.isNil:
    dateStr = "  " & resp.timestamp
  else:
    dateStr = ""

  result = resp.cmd & resp.count.align(maxLineWidth - resp.cmd.len) & dateStr

proc format*(responses: seq[SearchResponse]): string =
  let lineWidth = responses.mapIt(it.lineWidth).max
  result = responses.mapIt(it.toLine(lineWidth)).join("\n")

proc dbSearch*(
  cwd: string,
  limit: int,
  containsStr: string,
  orderBy: OrderBy
): seq[SearchResponse] =
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
    orderByTimeStamp = orderBy == obEnteredOn
    q = selectStmt % [
      # In global search, work with total command counts
      (if cwd.isNil: "SUM(count)" else: "count"),
      # If the search is ordered by time, include the most-recent-usage timestamp
      # as well as command and count.
      (if orderByTimeStamp: ", " & datetimeConversion else: "")
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

  log "Executing query:\n$1\nwith $2 argument(s): $3\n" % [
      q, $args.len, args.join(", ")
    ]

  result = db.getAllRows(q.sql, args).mapIt(SearchResponse(
    cmd: it[0],
    count: it[1],
    timestamp: if orderByTimeStamp: it[2] else: nil
  ))

proc dbInsert*(cwd, cmd: string)  =
  db.exec sql"""
    INSERT OR REPLACE INTO ?
      (cwd, cmd, count) VALUES
      (?, ?, COALESCE(
        (SELECT count FROM ? WHERE cwd=? AND cmd=?), 0) + 1)
      """, tableName, cwd, cmd, tableName, cwd, cmd

proc dbClean*(days: string)  =
  let
    timedelta = "-$1 day" % days
    q = "DELETE FROM ? WHERE entered_on <= date('now', ?)"

  db.exec q.sql, tableName, timedelta
