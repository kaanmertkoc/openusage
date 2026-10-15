#!/usr/bin/env bash
# launchd entrypoint. The Python worker checks local Tailscale state before any remote requests.
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/remote_sync.py" "$@"
