# Remote Server Usage (Personal Fork)

Each configured server gets its own Claude card with tokens, estimated cost, model breakdown,
and daily trend. The Mac pulls saved Claude Code session logs over Tailscale SSH every five
minutes. It uses the same native scanner as the local Claude card. No agent needs installing
on the servers.

## Servers

The app and sync job share `Sources/OpenUsage/Resources/remote_servers.json`:

| Card | SSH User | Claude Projects Folder |
|---|---|---|
| Claude · Ubuntu NBG1 | root | `/root/.claude/projects` |
| Claude · Cosmo Shop | root | `/home/kahya/.claude/projects` |
| Claude · Pleasure Server 1 | kahya | `/home/kahya/.claude/projects` |
| Claude · Mac Mini | Setup required | Not yet verified |

Ubuntu keeps the existing `server1` identity, saved layout, and history. Its Codex and OpenCode
cards continue to sync independently. Cosmo currently has no Claude logs in its configured
folder; its card reports the missing logs and starts counting once sessions appear there.
Mac Mini is explicitly listed with **SSH Setup Required** until its SSH login and Claude log
folder are verified. It appears immediately, makes no remote requests, and shows no invented counts.

## When Tailscale Is Off

Before any SSH or rsync call, the job asks the local Tailscale client for its connection state.
If Tailscale is disconnected, logged out, or unavailable, it pauses all remote requests.
Cards retain the last successful counts and show the pause reason. Sync resumes automatically
on the next scheduled check after Tailscale reconnects (within five minutes).

An individual offline server is skipped too. Other servers keep syncing. A failed transfer
never updates that server's last-success timestamp. Missing or unreadable log folders show a
clear error, rather than fresh zero usage. After a successful retry, the warning clears.

## How Data Gets Here

`scripts/remote-sync.sh` starts the standard-library Python worker in `scripts/remote_sync.py`.
The existing launchd job is `com.kaanmertkoc.openusage.remote-sync` (plist in `scripts/`).
Up to three servers sync concurrently, with a process lock preventing overlapping runs.
SSH and rsync have deadlines, including connections waiting for Tailscale re-authentication.

Copies are stored under `~/.openusage-remote/<id>/`:

- **claude** — only session `*.jsonl` files beneath the configured projects folder.
- **codex** — only `~/.codex/sessions/` and `archived_sessions/`, for server1.
- **opencode** — a compact extract of the last 31 days from server1's database. The existing
  Python extract is in `scripts/remote_opencode_extract.py`; message bodies stay remote.

Claude session files contain conversations as well as usage. These copies stay on this Mac;
credentials and configuration files are excluded. Previously copied Claude/Codex history is
retained when remote cleanup removes sessions. The scanners count only their normal history
window and deduplicate replayed records within each server.

Each dataset has its own `.last-sync` and `.sync-error`. The shared `.sync-paused` records a
Tailscale pause. Successful syncs clear errors; a success older than 15 minutes shows a stale
warning. The job's output is in `~/.openusage-remote/sync.log`.

## What Counts

Today, Yesterday, Last 30 Days, and Usage Trend describe the named server only. Claude token
counts are measured from persisted session logs; costs are estimates at API rates. Session and
weekly subscription limits are account-wide and stay on the main Claude cards. OpenCode's
existing server card shows tokens only.

Nested workflow and subagent logs count. Runs with session persistence disabled cannot count.
Only the configured user's log folder is read; extra users or container log locations need
explicit configuration. Copied histories on different servers cannot establish where the
original request ran, so these cards attribute logs to their configured source machine.

New Claude cards use the existing server defaults: all four metrics enabled, Today always
visible, the trend and other periods on demand, and no menu-bar pins. Saved customizations
remain intact. A server card is detected after its first sync attempt, including failed attempts,
so connection problems remain visible. Explicit setup-required entries appear before any sync attempt.

## Adding Or Updating A Server

1. Find its Tailscale IP or MagicDNS name with `tailscale status` and verify SSH access once.
   The unattended job uses existing trusted SSH host keys and never accepts changed keys.
2. Add an entry to `Sources/OpenUsage/Resources/remote_servers.json` with a unique stable `id`,
   friendly `name`, `sshTarget` (`user@host`), and absolute `claudeProjectsPath`.
3. Run `scripts/remote-sync.sh`, then rebuild and restart with `script/build_and_run.sh`.
   The app loads its bundled server list at launch; source configuration changes require a build.

Keep `server1`'s ID. Names and connection details can change without losing saved customization.
New servers reuse the same Claude provider and defaults; there is no provider class to clone.
For a known machine awaiting access, use a `setupRequired` message instead of `sshTarget` and
`claudeProjectsPath`. To connect Mac Mini, replace that message with its verified connection fields,
sync, and rebuild. Keep its `mac-mini` ID so its layout survives setup.

## Verification

Run `python3 -m unittest discover -s scripts -p test_remote_sync.py` for the offline/resume,
per-server failure, and transfer-filter checks. Swift's `RemoteClaudeServerTests` cover separate
counts, stale/paused displays, and preservation of saved layout preferences.
