import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import remote_sync as sync


class RemoteSyncTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.server = {"id": "server1", "name": "First Server", "sshTarget": "root@100.1.1.1",
                       "claudeProjectsPath": "/root/.claude/projects"}
        self.second = {**self.server, "id": "second", "name": "Second Server", "sshTarget": "kaan@100.1.1.2"}
        self.config = self.root / "servers.json"
        self.config.write_text(json.dumps([self.server, self.second]))
        self.status = {"BackendState": "Running", "Self": {"Online": True}, "Peer": {
            "one": {"TailscaleIPs": ["100.1.1.1"], "Online": True},
            "two": {"TailscaleIPs": ["100.1.1.2"], "Online": True}
        }}
        self.addCleanup(patch.stopall)
        patch.object(sync.shutil, "which", return_value="/usr/local/bin/tailscale").start()
        self.run = patch.object(sync, "run_command", side_effect=lambda args, **kw:
                                json.dumps(self.status) if args[0].endswith("tailscale") else "found").start()

    def test_offline_never_calls_ssh_or_rsync_and_keeps_success_marker(self):
        marker = self.root / "server1/claude/.last-sync"
        sync.write_status(marker, "2026-10-15T10:00:00Z")
        for state, online in [("Stopped", True), ("NeedsLogin", False), ("Running", False)]:
            with self.subTest(state=state, online=online):
                self.run.reset_mock()
                self.status.update(BackendState=state, Self={"Online": online})
                self.assertEqual(sync.synchronize(self.config, self.root), 0)
                self.assertEqual(self.run.call_count, 1)
                self.assertEqual(self.run.call_args.args[0][1:], ["status", "--json"])
                self.assertEqual(marker.read_text().strip(), "2026-10-15T10:00:00Z")
                self.assertIn("Tailscale Offline", (self.root / ".sync-paused").read_text())

    def test_unreadable_status_never_fetches(self):
        for result in ["not json", "[]"]:
            self.run.reset_mock()
            self.run.side_effect = None
            self.run.return_value = result
            with self.assertRaises(sync.SyncError):
                sync.synchronize(self.config, self.root)
            self.assertEqual(self.run.call_count, 1)
        self.assertIn("Cannot Read Tailscale", (self.root / ".sync-paused").read_text())

    def test_reconnect_resumes_and_clears_pause(self):
        self.status["BackendState"] = "Stopped"
        sync.synchronize(self.config, self.root)
        self.status["BackendState"] = "Running"
        self.run.reset_mock()
        self.assertEqual(sync.synchronize(self.config, self.root), 0)
        self.assertEqual((self.root / ".sync-paused").read_text(), "")
        self.assertTrue((self.root / "server1/claude/.last-sync").exists())
        self.assertTrue((self.root / "second/claude/.last-sync").exists())
        transfers = [call.args[0] for call in self.run.call_args_list if call.args[0][0] == "rsync"]
        self.assertEqual(len(transfers), 2)
        for transfer in transfers:
            self.assertIn("--include=*.jsonl", transfer)
            self.assertIn("--exclude=*", transfer)
            self.assertNotIn("--delete", transfer)

    def test_failed_host_does_not_block_other_host_or_refresh_old_marker(self):
        marker = self.root / "server1/claude/.last-sync"
        sync.write_status(marker, "old success")
        def run(args, **kwargs):
            if args[0].endswith("tailscale"):
                return json.dumps(self.status)
            if "root@100.1.1.1" in args:
                raise sync.SyncError("permission denied")
            return "found"
        self.run.side_effect = run
        self.assertEqual(sync.synchronize(self.config, self.root), 1)
        self.assertEqual(marker.read_text().strip(), "old success")
        self.assertIn("First Server", (self.root / "server1/claude/.sync-error").read_text())
        self.assertTrue((self.root / "second/claude/.last-sync").exists())

    def test_offline_peer_makes_no_remote_requests_for_that_host(self):
        self.status["Peer"]["one"]["Online"] = False
        self.assertEqual(sync.synchronize(self.config, self.root), 1)
        self.assertFalse(any("root@100.1.1.1" in str(call) for call in self.run.call_args_list))
        self.assertTrue((self.root / "second/claude/.last-sync").exists())

    def test_pending_setup_is_visible_without_remote_calls_and_others_still_sync(self):
        pending = {"id": "mac-mini", "name": "Mac Mini", "setupRequired": "SSH Setup Required"}
        self.config.write_text(json.dumps([self.server, pending]))
        self.assertEqual(sync.synchronize(self.config, self.root), 1)
        self.assertTrue((self.root / "server1/claude/.last-sync").exists())
        self.assertFalse((self.root / "mac-mini/claude/.last-sync").exists())
        self.assertEqual((self.root / "mac-mini/claude/.sync-error").read_text().strip(), "SSH Setup Required")
        self.run.reset_mock()
        self.assertFalse(sync.sync_server(pending, self.root, self.status))
        self.run.assert_not_called()

    def test_pending_configuration_cannot_hide_invalid_connection_details(self):
        for pending in [
            {"id": "pending", "name": "Pending", "setupRequired": " "},
            {"id": "pending", "name": "Pending"},
            {**self.second, "setupRequired": "SSH Setup Required"}
        ]:
            self.config.write_text(json.dumps([self.server, pending]))
            with self.assertRaises(sync.SyncError):
                sync.synchronize(self.config, self.root)
        self.run.assert_not_called()

    def test_missing_logs_are_not_stamped_fresh_or_reported_as_zero_usage(self):
        self.run.side_effect = lambda args, **kw: "missing"
        self.assertFalse(sync.sync_server(self.server, self.root, self.status))
        self.assertFalse((self.root / "server1/claude/.last-sync").exists())
        self.assertIn("No Claude logs found", (self.root / "server1/claude/.sync-error").read_text())
        self.assertFalse(any(call.args[0][0] == "rsync" for call in self.run.call_args_list))

    def test_duplicate_or_unsafe_ids_are_rejected_before_network(self):
        for identifier in ["server1", "../escape"]:
            self.config.write_text(json.dumps([self.server, {**self.second, "id": identifier}]))
            with self.assertRaises(sync.SyncError):
                sync.synchronize(self.config, self.root)
        self.run.assert_not_called()

    def test_codex_source_preserves_remote_home_expansion(self):
        sync.sync_codex(self.server, self.root / "codex")
        transfer = self.run.call_args.args[0]
        self.assertIn("root@100.1.1.1:~/.codex/", transfer)
        self.assertIn("--exclude=*", transfer)

    def test_opencode_extract_keeps_expected_database_name(self):
        destination = self.root / "opencode"
        destination.mkdir()
        (destination / "opencode.db").write_bytes(b"previous")
        def run(args, **kwargs):
            if args[0] == "rsync":
                (destination / "openusage-opencode-extract.db").write_bytes(b"new extract")
            return ""
        self.run.side_effect = run
        sync.sync_opencode(self.server, destination)
        self.assertEqual((destination / "opencode.db").read_bytes(), b"new extract")


if __name__ == "__main__":
    unittest.main()
