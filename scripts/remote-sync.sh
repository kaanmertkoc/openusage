#!/usr/bin/env bash
# Pulls usage files from remote servers (over Tailscale SSH) into
# ~/.openusage-remote/<label>/ for the claude-<label> / opencode-<label> plugins.
# Add hosts as "label:ssh-target" entries.
set -u

HOSTS=("server1:root@100.121.7.20")
DEST_ROOT="$HOME/.openusage-remote"
SSH_OPTS="ssh -o ConnectTimeout=10 -o BatchMode=yes"

mkdir -p "$DEST_ROOT"

for entry in "${HOSTS[@]}"; do
  label="${entry%%:*}"
  target="${entry#*:}"
  dest="$DEST_ROOT/$label"
  mkdir -p "$dest/claude" "$dest/opencode"

  ok=1

  # Claude Code may not be in use on the host yet; skip its sync until
  # ~/.claude/projects appears rather than failing the whole host.
  if $SSH_OPTS "$target" 'test -d ~/.claude/projects'; then
    rsync -az --delete --timeout=30 -e "$SSH_OPTS" \
      "$target:~/.claude/projects/" "$dest/claude/projects/" || ok=0
  else
    echo "no claude data on $label yet, skipping"
  fi

  rsync -az --timeout=30 -e "$SSH_OPTS" \
    "$target:~/.local/share/opencode/opencode.db*" "$dest/opencode/" || ok=0

  if [ "$ok" -eq 1 ]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$dest/.last-sync"
    echo "synced $label"
  else
    echo "sync failed for $label" >&2
  fi
done
