import db_sqlite, os, strutils, sequtils
import logger

var db: DbConn

const
  tableName* = "history"
  dbName = ".esdb"

type OrderBy* = enum
  obCount = "count"
  obSumCount = "SUM(count)"
  obEnteredOn = "entered_on"

proc dbOpen*(): DbConn =
  ## Open a DB connection.
  let dbPath = getHomeDir() / dbName

  db = open(dbPath, nil, nil, nil)
  return db

proc dbClose*() =
  ## Close the DB connection.
  db.close()

proc dbInit*() =

  proc logEnsureTable(tableName: string) =
    log("Ensuring presence of $1 table at $2..." % [
      tableName, dbName
    ], llInfo)

    doVerbose:
      let tableCheck = db.getRow(sql"""
        SELECT 1 FROM sqlite_master WHERE type="table" AND name=?
      """, tableName)
      if tableCheck[0] == "":
        log "Table $1 not found. Creating..." % tableName
      else:
        log "Table $1 found." % tableName

  log "Initializing $1 database." % programName

  logEnsureTable "history"
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

  logEnsureTable "checksum"
  db.exec sql"""
    CREATE TABLE IF NOT EXISTS checksum (
        hash        VARCHAR(256)
    )"""

  doVerbose:
    log "Checking for checksum value..."
    let checksumValue = db.getRow(sql"""
      SELECT hash FROM checksum
    """)
    if checksumValue[0] == "":
      log "Checksum not present. Inserting empty value."
    else:
      log "Checksum present. Value: " & checksumValue[0]

  db.exec sql"""
    INSERT INTO checksum
    SELECT "" WHERE NOT EXISTS (
      SELECT 1 FROM checksum
    )"""

type SearchResponse* = object
  cmd, count, timestamp: string

proc lineWidth(resp: SearchResponse): int =
  result = resp.cmd.len
  if not resp.count.isNil:
    result += resp.count.len + 2

proc toLine(resp: SearchResponse, maxLineWidth: int): string =
  result = resp.cmd
  if not resp.count.isNil:
    result.add(resp.count.align(maxLineWidth - resp.cmd.len))
  if not resp.timestamp.isNil:
    result.add("  " & resp.timestamp)

proc formatResponses*(responses: seq[SearchResponse]): string =
  let lineWidth = responses.mapIt(it.lineWidth).max
  result = responses.mapIt(it.toLine(lineWidth)).join("\n")

converter toSearchResponse(rows: seq[Row]): seq[SearchResponse] =
  result = newSeqWith(rows.len, SearchResponse())
  for i in rows.low..rows.high:
    let row = rows[i]
    result[i].cmd = row[0]
    if row.len > 1:
      result[i].count = row[1]
    if row.len > 2:
      result[i].timestamp = row[2]

proc dbSearch*(
  cwd: string,
  limit: int,
  containsStr: string,
  orderBy: OrderBy,
  recurse: bool,
  cmdOnly: bool
): seq[SearchResponse] =
  ## Search the database for commands.
  const
    selectStmt          = "SELECT $1 FROM $2"
    sumCount            = "SUM(count)"
    justCount           = "count"
    datetimeConversion  = "datetime(entered_on, \"localtime\")"
    where               = "WHERE"
    whereAnd            = "AND"
    cwdEquals           = "cwd = ?"
    cwdLike             = "( cwd = ? OR cwd LIKE ? )"
    whereLike           = "cmd LIKE ?"
    orderByStr          = "ORDER BY $1 DESC"
    limitStmt           = "LIMIT ?"
    groupBy             = "GROUP BY cmd"
  # Start building a SQL query.
  let orderByTimeStamp = orderBy == obEnteredOn
  var selectColumns = @["cmd"]

  if not cmdOnly:
    if cwd.isNil:
      # In global search, work with total command counts.
      selectColumns.add(sumCount)
    else:
      selectColumns.add(justCount)
    if orderByTimeStamp:
      # If the search is ordered by time, include the
      # most-recent-usage timestamp as well as command and count.
      selectColumns.add(datetimeConversion)

  var
    q = @[selectStmt % [selectColumns.join(","), tableName]]
    # Keep a list of args to be included for parameter
    # interpolation.
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
    if recurse:
      q.add cwdLike
      args.add cwd
      args.add "$1/%" % cwd
    else:
      q.add cwdEquals
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

  let query = q.join(" ")
  log "Executing query:\n$1\nwith $2 argument(s): $3\n" % [
      query, $args.len, args.join(", ")
    ]

  result = db.getAllRows(query.sql, args)

proc dbChecksum*(checksum: string): bool =
  log "Checking checksum against value: " & checksum

  let currentValue = db.getValue sql"""
    SELECT hash FROM checksum LIMIT 1
  """
  log "Current checksum value: " & currentValue

  currentValue != checksum

proc dbInsert*(cwd, cmd, checksum: string)  =
  db.exec sql"""
    INSERT OR REPLACE INTO ?
      (cwd, cmd, count) VALUES
      (?, ?, COALESCE(
        (SELECT count FROM ? WHERE cwd=? AND cmd=?), 0) + 1)
      """, tableName, cwd, cmd, tableName, cwd, cmd
  if not checksum.isNil:
    log "Updating checksum with value: " & checksum
    db.exec sql"""
      UPDATE checksum SET hash = ?
    """, checksum

proc dbClean*(days: string)  =
  let
    timedelta = "-$1 day" % days
    q = "DELETE FROM ? WHERE entered_on <= date('now', ?)"

  db.exec q.sql, tableName, timedelta
