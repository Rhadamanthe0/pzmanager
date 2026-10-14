#!/usr/bin/env python3
"""Regression tests for the Discord ready notification and webhook transport."""
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOOT_A = "a" * 32
BOOT_B = "b" * 32


class ReadyNotificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manager = self.root / "manager"
        self.internal = self.manager / "data/scripts/internal"
        self.lib = self.manager / "data/scripts/lib"
        self.mockbin = self.root / "bin"
        self.internal.mkdir(parents=True)
        self.lib.mkdir(parents=True)
        self.mockbin.mkdir()
        self.script = self.internal / "notifyServerReady.sh"
        self.discord = self.internal / "sendDiscord.sh"
        shutil.copy2(ROOT / "data/scripts/internal/notifyServerReady.sh", self.script)
        shutil.copy2(ROOT / "data/scripts/internal/sendDiscord.sh", self.discord)
        self.script.chmod(0o755)
        self.discord.chmod(0o755)
        (self.lib / "common.sh").write_text(
            'source_env() {\n'
            '  PZ_MANAGER_DIR="$MOCK_MANAGER_DIR"\n'
            '  PZ_SERVICE_NAME=zomboid.service\n'
            '  DISCORD_WEBHOOK="$MOCK_DISCORD_WEBHOOK"\n'
            '  export PZ_MANAGER_DIR PZ_SERVICE_NAME DISCORD_WEBHOOK\n'
            '}\n'
        )
        (self.mockbin / "systemctl").write_text(
            '#!/usr/bin/env python3\n'
            'import os, pathlib, sys\n'
            'base = pathlib.Path(os.environ["MOCK_BASE"])\n'
            'args = sys.argv[1:]\n'
            'if "-p" in args and "ExecMainStartTimestamp" in args:\n'
            '    print("Wed 2026-10-14 20:03:44 CEST")\n'
            'elif "-p" in args and "InvocationID" in args and "--value" in args:\n'
            '    print((base / "invocation").read_text().strip())\n'
            'else:\n'
            '    print("ActiveState=" + (base / "state").read_text().strip())\n'
            '    print("InvocationID=" + (base / "invocation").read_text().strip())\n'
        )
        (self.mockbin / "journalctl").write_text(
            '#!/usr/bin/env python3\n'
            'import os, pathlib, sys, time\n'
            'base = pathlib.Path(os.environ["MOCK_BASE"])\n'
            '(base / "journal.args").write_text(" ".join(sys.argv[1:]))\n'
            'mode = os.environ.get("MOCK_JOURNAL_MODE", "instant")\n'
            'if mode == "delayed": time.sleep(2)\n'
            'if mode in ("instant", "delayed"):\n'
            '    print("LOG : General f:0 st:123> loading", flush=True)\n'
            '    print("LOG : General f:2 st:456> ready", flush=True)\n'
            'if mode == "eof": sys.exit(0)\n'
            'time.sleep(15)\n'
        )
        for executable in self.mockbin.iterdir():
            executable.chmod(0o755)
        self.sent = self.root / "sent"
        self.discord.write_text(
            '#!/usr/bin/env bash\n'
            'printf "%s\\n" "$*" >> "$MOCK_SENT"\n'
            '[[ "$MOCK_NOTIFY_FAIL" != 1 ]]\n'
        )
        self.discord.chmod(0o755)
        (self.root / "invocation").write_text(BOOT_A)
        (self.root / "state").write_text("active")
        self.env = dict(os.environ)
        self.env.update({
            "PATH": f'{self.mockbin}:{os.environ.get("PATH", "")}',
            "MOCK_BASE": str(self.root),
            "MOCK_MANAGER_DIR": str(self.manager),
            "MOCK_DISCORD_WEBHOOK": "https://discord.invalid/SECRET",
            "MOCK_SENT": str(self.sent),
            "XDG_RUNTIME_DIR": str(self.root / "runtime"),
            "INVOCATION_ID": BOOT_A,
            "PZ_NOTIFY_READY_TIMEOUT": "5",
            "PZ_NOTIFY_READY_POLL_INTERVAL": "1",
            "MOCK_JOURNAL_MODE": "instant",
        })

    def run_ready(self, *, env=None):
        return subprocess.run(
            ["bash", str(self.script)], env=env or self.env,
            text=True, capture_output=True, timeout=9
        )

    def sent_count(self):
        return len(self.sent.read_text().splitlines()) if self.sent.exists() else 0

    def test_ready_frame_announced_once(self):
        result = self.run_ready()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent_count(), 1)
        self.assertIn("envoyée", result.stderr)
        args = (self.root / "journal.args").read_text()
        self.assertIn("--follow", args)
        self.assertIn("--no-tail", args)
        self.assertIn("--grep", args)
        self.assertIn("_SYSTEMD_USER_UNIT=zomboid.service", args)
        self.assertIn("_SYSTEMD_INVOCATION_ID=" + BOOT_A, args)
        self.assertNotIn("--since", args)
        again = self.run_ready()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.sent_count(), 1)

    def test_long_boot_after_old_five_minute_window(self):
        env = dict(self.env, MOCK_JOURNAL_MODE="delayed")
        result = self.run_ready(env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent_count(), 1)

    def test_timeout_is_reported_without_announcement(self):
        env = dict(self.env, MOCK_JOURNAL_MODE="never",
                   PZ_NOTIFY_READY_TIMEOUT="1")
        result = self.run_ready(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sent_count(), 0)
        self.assertIn("Aucune frame", result.stderr)

    def test_invalid_timeout_is_rejected(self):
        env = dict(self.env, PZ_NOTIFY_READY_TIMEOUT="999999999999999999999999")
        result = self.run_ready(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalide", result.stderr)
        self.assertFalse((self.root / "journal.args").exists())

    def test_journald_early_exit_is_reported(self):
        env = dict(self.env, MOCK_JOURNAL_MODE="eof")
        result = self.run_ready(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sent_count(), 0)
        self.assertIn("journald", result.stderr)

    def test_stopped_service_aborts_wait(self):
        self._assert_lifecycle_aborts(state="inactive")

    def test_replaced_invocation_aborts_wait(self):
        self._assert_lifecycle_aborts(boot=BOOT_B)

    def _assert_lifecycle_aborts(self, *, state=None, boot=None):
        env = dict(self.env, MOCK_JOURNAL_MODE="never")
        proc = subprocess.Popen(
            ["bash", str(self.script)], env=env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        try:
            for _ in range(80):
                if (self.root / "journal.args").exists():
                    break
                time.sleep(.05)
            else:
                self.fail("journalctl never started")
            if state is not None:
                (self.root / "state").write_text(state)
            if boot is not None:
                (self.root / "invocation").write_text(boot)
            _, stderr = proc.communicate(timeout=6)
            self.assertEqual(proc.returncode, 0, stderr)
            self.assertIn("annulée", stderr)
            self.assertEqual(self.sent_count(), 0)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()

    def test_new_invocation_not_blocked_by_old_cooldown(self):
        self.assertEqual(self.run_ready().returncode, 0)
        (self.root / "invocation").write_text(BOOT_B)
        env = dict(self.env, INVOCATION_ID=BOOT_B)
        result = self.run_ready(env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent_count(), 2)

    def test_maintenance_silences_next_start(self):
        (self.manager / ".silent_next_start").touch()
        result = self.run_ready()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.manager / ".silent_next_start").exists())
        self.assertEqual(self.sent_count(), 0)
        self.assertFalse((self.root / "journal.args").exists())

    def test_discord_failure_reported_and_retry_permitted(self):
        env = dict(self.env, MOCK_NOTIFY_FAIL="1")
        result = self.run_ready(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Échec de la notification", result.stderr)
        success = self.run_ready()
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertEqual(self.sent_count(), 2)


class DiscordTransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        internal = self.base / "data/scripts/internal"
        lib = self.base / "data/scripts/lib"
        binpath = self.base / "bin"
        internal.mkdir(parents=True)
        lib.mkdir(parents=True)
        binpath.mkdir()
        self.script = internal / "sendDiscord.sh"
        shutil.copy2(ROOT / "data/scripts/internal/sendDiscord.sh", self.script)
        (lib / "common.sh").write_text(
            'source_env() { DISCORD_WEBHOOK="$MOCK_DISCORD_WEBHOOK"; }\n'
        )
        curl = binpath / "curl"
        curl.write_text(
            '#!/usr/bin/env python3\n'
            'import os, sys\n'
            'print(os.environ.get("MOCK_HTTP", "204"), end="")\n'
            'sys.exit(int(os.environ.get("MOCK_CURL_RC", "0")))\n'
        )
        curl.chmod(0o755)
        self.env = dict(os.environ)
        self.env.update({
            "PATH": f'{binpath}:{os.environ.get("PATH", "")}',
            "MOCK_DISCORD_WEBHOOK": "https://discord.invalid/SECRET",
            "MOCK_HTTP": "204",
        })

    def run_discord(self, *, strict=False, env=None):
        args = ["bash", str(self.script), "Disponibilité"]
        if strict:
            args.append("--strict")
        return subprocess.run(
            args, env=env or self.env, text=True, capture_output=True,
            timeout=5
        )

    def test_discord_success(self):
        result = self.run_discord(strict=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_discord_http_error_strict_and_best_effort(self):
        env = dict(self.env, MOCK_HTTP="429")
        strict = self.run_discord(strict=True, env=env)
        self.assertNotEqual(strict.returncode, 0)
        self.assertIn("HTTP=429", strict.stderr)
        self.assertNotIn("SECRET", strict.stderr)
        best_effort = self.run_discord(env=env)
        self.assertEqual(best_effort.returncode, 0, best_effort.stderr)
        self.assertIn("HTTP=429", best_effort.stderr)

    def test_discord_transport_failure(self):
        env = dict(self.env, MOCK_HTTP="000", MOCK_CURL_RC="7")
        result = self.run_discord(strict=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("curl=7", result.stderr)

    def test_missing_webhook_in_strict_mode(self):
        env = dict(self.env, MOCK_DISCORD_WEBHOOK="")
        self.assertNotEqual(self.run_discord(strict=True, env=env).returncode, 0)
        self.assertEqual(self.run_discord(env=env).returncode, 0)


if __name__ == "__main__":
    unittest.main()
