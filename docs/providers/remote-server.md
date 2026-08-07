# Claude Server & OpenCode Server (personal fork)

Two tiles showing what the remote server (`server1`, reached over Tailscale) spends in Claude Code and
OpenCode. No server-side software: a launchd job on this Mac rsyncs the server's usage files every
5 minutes, and the tiles read the synced copies. Nothing is sent anywhere.

## How the data gets here

`scripts/remote-sync.sh` (launchd job `com.kaanmertkoc.openusage.remote-sync`, plist in `scripts/`)
pulls over Tailscale SSH into `~/.openusage-remote/server1/`:

- `~/.claude/projects/` → `claude/projects/` — Claude Code's session logs
- `~/.local/share/opencode/opencode.db*` → `opencode/` — OpenCode's SQLite logs

After a fully successful sync it stamps `.last-sync`. Both tiles surface an amber header warning when
that stamp is older than 15 minutes (server unreachable, Tailscale SSH re-auth needed, job unloaded).
Sync log: `~/.openusage-remote/sync.log`.

## What the tiles track

| Metric | Meaning |
|---|---|
| Today / Yesterday / Last 30 Days | The server's daily usage — Claude: estimated cost + tokens (native log scan, same engine as the main Claude tile); OpenCode: tokens only |
| Usage Trend | A day-by-day sparkline of the server's tokens over the last month |

Notes:

- **Claude Server** is history-only. Session/weekly limits are account-wide and already live on the
  main Claude tile — server usage counts into those same meters.
- **OpenCode Server** shows no dollars: the server runs subscription providers (e.g. `openai`) whose
  rows cost $0, so dollar figures would be a misleading `$0.00`. All assistant rows count, with no
  providerID filter.
- Both tiles auto-enable once the first sync completes (the `.last-sync` marker is the "credential").

## Adding another server

Add a `label:ssh-target` entry to `HOSTS` in `scripts/remote-sync.sh` and clone the two providers in
`Sources/OpenUsage/Providers/RemoteServer/` with the new label's paths and ids.
