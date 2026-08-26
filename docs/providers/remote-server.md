# Claude Server & OpenCode Server (personal fork)

Two tiles showing what the remote server (`server1`, reached over Tailscale) spends in Claude Code and
OpenCode. Nothing to install on the server: a launchd job on this Mac pulls the server's usage every
5 minutes, and the tiles read the synced copies. Nothing is sent anywhere.

## How the data gets here

`scripts/remote-sync.sh` (launchd job `com.kaanmertkoc.openusage.remote-sync`, plist in `scripts/`)
pulls over Tailscale SSH into `~/.openusage-remote/server1/`, in two independent legs:

- **claude** — rsync of `~/.claude/projects/` → `claude/projects/`, Claude Code's session logs.
- **opencode** — the server's `opencode.db` holds every message body and runs to several GB, far too
  much to pull every 5 minutes. Instead the job runs a small `python3` snippet on the server that
  boils the last 31 days down to one timestamp-and-token-total row per assistant message, and pulls
  that ~1 MB extract to `opencode/opencode.db`. It keeps the same table shape the tile queries, so
  nothing downstream knows the difference.

Each leg stamps its own `.last-sync` (`claude/.last-sync`, `opencode/.last-sync`) when it succeeds,
and each tile only reads its own. A tile shows an amber header warning when its stamp is older than
15 minutes (server unreachable, Tailscale SSH re-auth needed, job unloaded) — a failure in one leg
never makes the other tile look stale. Sync log: `~/.openusage-remote/sync.log`.

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
- Each tile auto-enables once its own leg has synced at least once (that `.last-sync` marker is the
  "credential").

## Adding another server

Add a `label:ssh-target` entry to `HOSTS` in `scripts/remote-sync.sh` and clone the two providers in
`Sources/OpenUsage/Providers/RemoteServer/` with the new label's paths and ids.
