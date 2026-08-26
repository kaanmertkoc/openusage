#!/usr/bin/env bash
# Pulls usage data from remote servers (over Tailscale SSH) into ~/.openusage-remote/<label>/ for the
# Claude Server / OpenCode Server tiles. Add hosts as "label:ssh-target" entries.
#
# Two independent legs per host, each with its own `.last-sync` marker so a failure in one never makes
# the other tile claim staleness:
#   claude/   <- rsync of ~/.claude/projects (JSONL logs, ~85 MB)
#   opencode/ <- a compact extract of the server's opencode.db (see EXTRACT_PY)
set -u

HOSTS=("server1:root@100.121.7.20")
DEST_ROOT="$HOME/.openusage-remote"
SSH_OPTS="ssh -o ConnectTimeout=10 -o BatchMode=yes"
# Where the extract lands on the server before it is pulled.
REMOTE_EXTRACT="/tmp/openusage-opencode-extract.db"

mkdir -p "$DEST_ROOT"

# Tailscale SSH can stall a connection waiting for a browser re-auth check, which ConnectTimeout does
# not cover. Kill anything that runs too long so unattended launchd runs fail fast instead of piling up
# hung ssh processes.
with_timeout() {
  local secs="$1"
  shift
  "$@" &
  local pid=$!
  ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
  local watcher=$!
  wait "$pid"
  local rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return "$rc"
}

# Marks a leg as freshly synced. The app reads these markers (RemoteServerSync.Leg) and shows the amber
# "sync is stale" triangle once one ages past 15 minutes.
stamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$1/.last-sync"
}

# Runs on the server: the live opencode.db is multi-GB (full message payloads, growing ~5 GB/day) and
# pulling it whole blew rsync's I/O timeout on nearly every run. The tiles only need one
# (timestamp, token-total) pair per assistant message, so aggregate server-side and ship ~1 MB instead.
# The extract keeps the `message`/`time_created`/`data` shape the app's SQL expects, with a minimal
# synthesized `data` payload, so OpenCodeServerScanner needs no special case for it.
EXTRACT_PY=$(cat <<'PY'
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
PY
)
# Shipped base64-encoded: the payload then survives as a single shell word through ssh, with no
# quoting to escape and no stdin plumbing (with_timeout backgrounds its command, and bash hands a
# backgrounded command /dev/null on stdin).
EXTRACT_B64=$(printf '%s' "$EXTRACT_PY" | base64 | tr -d '\n')

for entry in "${HOSTS[@]}"; do
  label="${entry%%:*}"
  target="${entry#*:}"
  dest="$DEST_ROOT/$label"
  mkdir -p "$dest/claude" "$dest/opencode"

  # --- claude leg -----------------------------------------------------------------------------
  # Claude Code may not be in use on the host yet, so probe first. Exit 1 means ssh worked and the
  # directory is simply absent; anything else is a connection failure and must not pass for a sync.
  with_timeout 60 $SSH_OPTS "$target" 'test -d ~/.claude/projects'
  probe=$?
  if [ "$probe" -eq 0 ]; then
    if with_timeout 300 rsync -az --delete --timeout=30 -e "$SSH_OPTS" \
      "$target:~/.claude/projects/" "$dest/claude/projects/"; then
      stamp "$dest/claude"
      echo "synced $label/claude"
    else
      echo "sync failed for $label/claude" >&2
    fi
  elif [ "$probe" -eq 1 ]; then
    # Nothing to pull, so the leg is up to date by definition — the tile reads "No data" rather than
    # a never-synced error.
    stamp "$dest/claude"
    echo "no claude data on $label yet, skipping"
  else
    echo "claude probe failed for $label (rc=$probe)" >&2
  fi

  # --- opencode leg ---------------------------------------------------------------------------
  if with_timeout 120 $SSH_OPTS "$target" "printf %s $EXTRACT_B64 | base64 -d | python3 -"; then
    if with_timeout 120 rsync -az --timeout=30 -e "$SSH_OPTS" \
      "$target:$REMOTE_EXTRACT" "$dest/opencode/opencode.db"; then
      stamp "$dest/opencode"
      echo "synced $label/opencode"
    else
      echo "sync failed for $label/opencode" >&2
    fi
  else
    echo "opencode extract failed on $label" >&2
  fi
done
