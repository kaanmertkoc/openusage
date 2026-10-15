import os, sqlite3, time

SRC = os.path.expanduser("~/.local/share/opencode/opencode.db")
OUT = "/tmp/openusage-opencode-extract.db"
DAYS = 31

cutoff = int((time.time() - DAYS * 86400) * 1000)
src = sqlite3.connect("file:%s?mode=ro" % SRC, uri=True)
rows = src.execute(
    "SELECT time_created, COALESCE(json_extract(data, '$.tokens.total'), 0) "
    "FROM message "
    "WHERE time_created >= ? AND json_valid(data) "
    "AND json_extract(data, '$.role') = 'assistant'",
    (cutoff,),
).fetchall()
src.close()

# Build beside the target and rename, so a reader never sees a half-written extract.
tmp = OUT + ".tmp"
if os.path.exists(tmp):
    os.remove(tmp)
out = sqlite3.connect(tmp)
out.execute(
    "CREATE TABLE message ("
    "  id INTEGER PRIMARY KEY,"
    "  time_created INTEGER NOT NULL,"
    "  data TEXT NOT NULL)"
)
out.executemany(
    "INSERT INTO message (time_created, data) VALUES "
    "(?, json_object('role', 'assistant', 'tokens', json_object('total', ?)))",
    rows,
)
out.commit()
out.close()
os.replace(tmp, OUT)
print("opencode extract: %d rows" % len(rows))
