#!/usr/bin/env python3
"""Personal tailnet usage sync. Standard library only; no resident server agent."""

import argparse
import base64
import concurrent.futures
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys


CONFIG = Path(__file__).resolve().parents[1] / "Sources/OpenUsage/Resources/remote_servers.json"
SSH = ["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"]


class SyncError(RuntimeError):
    pass


class MissingLogsError(SyncError):
    pass


def run_command(args, timeout=60):
    """Bound the whole process group, including ssh/rsync children waiting for re-auth."""
    with subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise SyncError(f"{Path(args[0]).name} timed out after {timeout}s") from None
        if process.returncode:
            raise SyncError(f"{Path(args[0]).name} failed: {stderr.strip()[-600:] or process.returncode}")
        return stdout


def write_status(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text + "\n" if text else "")
    temporary.replace(path)


def load_servers(path):
    servers = json.loads(path.read_text())
    if not isinstance(servers, list):
        raise SyncError("remote_servers.json must contain a list")
    ids = set()
    for server in servers:
        identifier = server.get("id", "")
        target = server.get("sshTarget", "")
        source = server.get("claudeProjectsPath", "")
        setup = server.get("setupRequired")
        if (not re.fullmatch(r"[a-z0-9][a-z0-9-]*", identifier) or identifier in ids
                or not server.get("name", "").strip()):
            raise SyncError(f"Invalid or duplicate server configuration: {identifier}")
        if setup is not None:
            if (not isinstance(setup, str) or not setup.strip()
                    or server.get("sshTarget") is not None or server.get("claudeProjectsPath") is not None):
                raise SyncError(f"Invalid pending server setup: {identifier}")
        elif (not isinstance(target, str) or not isinstance(source, str)
              or not re.fullmatch(r"[a-zA-Z0-9_-]+@[a-zA-Z0-9][a-zA-Z0-9.-]*", target)
              or not source.startswith("/") or "\n" in source or "\0" in source):
            raise SyncError(f"Invalid remote server connection: {identifier}")
        for flag in ("syncCodex", "syncOpenCode"):
            if flag in server and not isinstance(server[flag], bool):
                raise SyncError(f"{identifier}: {flag} must be a boolean")
        ids.add(identifier)
    if "server1" not in ids:
        raise SyncError("Keep server1's ID to preserve its existing history and layout")
    return servers


def tailscale_status(root):
    """Local daemon query only. Offline/error paths must never reach ssh or rsync."""
    binary = shutil.which("tailscale")
    if binary is None:
        bundled = Path("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        binary = str(bundled) if bundled.is_file() else None
    try:
        if binary is None:
            raise SyncError("Tailscale CLI was not found")
        status = json.loads(run_command([binary, "status", "--json"], timeout=15))
        if not isinstance(status, dict):
            raise SyncError("Tailscale returned an invalid status")
        if status.get("BackendState") != "Running" or status.get("Self", {}).get("Online") is not True:
            write_status(root / ".sync-paused", "Sync Paused — Tailscale Offline")
            print("Tailscale offline; remote requests skipped. Will retry on the next scheduled run.", flush=True)
            return None
        write_status(root / ".sync-paused", "")
        return status
    except (OSError, SyncError, ValueError, TypeError, AttributeError) as error:
        write_status(root / ".sync-paused", "Sync Paused — Cannot Read Tailscale Status")
        raise SyncError(f"Cannot read local Tailscale status; no remote requests made: {error}") from error


def peer_online(server, status):
    hostname = server["sshTarget"].split("@", 1)[1].rstrip(".").lower()
    for peer in (status.get("Peer") or {}).values():
        dns = peer.get("DNSName", "").rstrip(".").lower()
        names = {dns, dns.split(".")[0], peer.get("HostName", "").lower()}
        names.update(peer.get("TailscaleIPs") or [])
        if hostname in names:
            return peer.get("Online") is True
    raise SyncError(f"{server['name']} is not visible in this Tailscale connection")


def rsync(server, source, destination, filters=()):
    destination.mkdir(parents=True, exist_ok=True)
    remote_path = "~/" + shlex.quote(source[2:]) if source.startswith("~/") else shlex.quote(source)
    run_command(["rsync", "-az", "--timeout=30", *filters, "-e", shlex.join(SSH),
                 f"{server['sshTarget']}:{remote_path}", str(destination) + "/"], timeout=300)


def sync_claude(server, destination):
    source = server["claudeProjectsPath"].rstrip("/")
    present = run_command([*SSH, server["sshTarget"],
                           f"if test -d {shlex.quote(source)}; then printf found; else printf missing; fi"], timeout=30)
    if present.strip() != "found":
        raise MissingLogsError(f"No Claude logs found on {server['name']} at {source}. Waiting for session logs.")
    # Session JSONL only; prompts are in these logs, but credentials/config and other artifacts stay
    # remote. Keep previously synced history when Claude's remote cleanup removes older sessions.
    rsync(server, source + "/", destination / "projects",
          ["--include=*/", "--include=*.jsonl", "--exclude=*"])


def sync_codex(server, destination):
    run_command([*SSH, server["sshTarget"], "test -d ~/.codex"], timeout=30)
    rsync(server, "~/.codex/", destination,
          ["--include=/sessions/***", "--include=/archived_sessions/***", "--exclude=*"])


def sync_opencode(server, destination):
    extract = Path(__file__).with_name("remote_opencode_extract.py").read_bytes()
    encoded = base64.b64encode(extract).decode("ascii")
    command = f"printf %s {encoded} | base64 -d | python3 -"
    run_command([*SSH, server["sshTarget"], command], timeout=120)
    rsync(server, "/tmp/openusage-opencode-extract.db", destination)
    (destination / "openusage-opencode-extract.db").replace(destination / "opencode.db")


def sync_server(server, root, status):
    legs = [("claude", sync_claude)]
    if server.get("syncCodex", False):
        legs.append(("codex", sync_codex))
    if server.get("syncOpenCode", False):
        legs.append(("opencode", sync_opencode))
    try:
        if server.get("setupRequired"):
            raise SyncError(server["setupRequired"])
        if not peer_online(server, status):
            raise SyncError(f"Sync Paused — {server['name']} Is Offline")
    except SyncError as error:
        for leg, _ in legs:
            write_status(root / server["id"] / leg / ".sync-error", str(error))
        print(str(error), file=sys.stderr, flush=True)
        return False

    succeeded = True
    for leg, action in legs:
        destination = root / server["id"] / leg
        destination.mkdir(parents=True, exist_ok=True)
        try:
            action(server, destination)
            write_status(destination / ".last-sync",
                         datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
            write_status(destination / ".sync-error", "")
            print(f"synced {server['id']}/{leg}", flush=True)
        except (OSError, SyncError) as error:
            succeeded = False
            message = str(error) if isinstance(error, MissingLogsError) else (
                f"Could not sync {leg} from {server['name']}. Check SSH access and the configured log folder.")
            write_status(destination / ".sync-error", message)
            print(message if message == str(error) else f"{message} {error}", file=sys.stderr, flush=True)
    return succeeded


def synchronize(config, root):
    servers = load_servers(config)
    status = tailscale_status(root)
    if status is None:
        return 0
    # Each host advances independently, so a slow/unreachable machine cannot hold up another card.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        results = list(executor.map(lambda server: sync_server(server, root, status), servers))
    return 0 if all(results) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=CONFIG)
    parser.add_argument("--root", type=Path, default=Path.home() / ".openusage-remote")
    args = parser.parse_args()
    try:
        args.root.mkdir(parents=True, exist_ok=True)
        # launchd and a manual run may overlap. The OS releases this lock even on a crash.
        with (args.root / ".sync-lock").open("w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("Remote sync already running; skipping this run.", flush=True)
                return 0
            return synchronize(args.config, args.root)
    except (OSError, SyncError, ValueError, TypeError, AttributeError) as error:
        print(f"Remote sync failed: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
