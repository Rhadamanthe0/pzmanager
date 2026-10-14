#!/usr/bin/env python3
"""Regression tests for the Discord ready notification and webhook transport."""
import json
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
        self.runtime_dir = self.root / "runtime"
        self.runtime_dir.mkdir(mode=0o700)
        self.script = self.internal / "notifyServerReady.sh"
        self.discord = self.internal / "sendDiscord.sh"
        shutil.copy2(ROOT / "data/scripts/internal/notifyServerReady.sh", self.script)
        shutil.copy2(ROOT / "data/scripts/internal/sendDiscord.sh", self.discord)
        self.script.chmod(0o755)
        self.discord.chmod(0o755)
        common_source = (ROOT / "data/scripts/lib/common.sh").read_text()
        helper_start = common_source.index("private_state_path() {")
        helper_end = common_source.index("\n}\n", helper_start) + 2
        private_state_helper = common_source[helper_start:helper_end]
        (self.lib / "common.sh").write_text(
            'source_env() {\n'
            '  PZ_MANAGER_DIR="$MOCK_MANAGER_DIR"\n'
            '  PZ_SERVICE_NAME=zomboid.service\n'
            '  DISCORD_WEBHOOK="$MOCK_DISCORD_WEBHOOK"\n'
            '  export PZ_MANAGER_DIR PZ_SERVICE_NAME DISCORD_WEBHOOK\n'
            '}\n'
            + private_state_helper + "\n"
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
            'if mode == "invocation_only":\n'
            '    boot = (base / "invocation").read_text().strip()\n'
            '    if "INVOCATION_ID=" + boot not in sys.argv[1:]: sys.exit(0)\n'
            '    mode = "instant"\n'
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
            "XDG_RUNTIME_DIR": str(self.runtime_dir),
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
        self.assertIn("-n all", args)
        self.assertIn("--grep", args)
        self.assertIn("INVOCATION_ID=" + BOOT_A, args)
        self.assertIn(" + ", args)
        self.assertIn("_SYSTEMD_INVOCATION_ID=" + BOOT_A, args)
        self.assertNotIn("--since", args)
        again = self.run_ready()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.sent_count(), 1)

    def test_stdout_frame_matched_with_invocation_id(self):
        env = dict(self.env, MOCK_JOURNAL_MODE="invocation_only")
        result = self.run_ready(env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
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

    def test_existing_lock_symlink_is_rejected(self):
        state_dir = self.runtime_dir / "pzmanager"
        state_dir.mkdir(mode=0o700)
        target = self.root / "outside.txt"
        target.write_text("untouched")
        (state_dir / ("notify-ready-" + BOOT_A + ".lock")).symlink_to(target)
        result = self.run_ready()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verrou invalide", result.stderr)
        self.assertEqual(target.read_text(), "untouched")
        self.assertEqual(self.sent_count(), 0)

    def test_symlinked_runtime_state_directory_is_rejected(self):
        target = self.root / "other-state"
        target.mkdir()
        (self.runtime_dir / "pzmanager").symlink_to(target, target_is_directory=True)
        result = self.run_ready()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Répertoire privé", result.stderr)
        self.assertEqual(self.sent_count(), 0)

    def test_new_invocation_not_blocked_by_old_cooldown(self):
        self.assertEqual(self.run_ready().returncode, 0)
        (self.root / "invocation").write_text(BOOT_B)
        env = dict(self.env, INVOCATION_ID=BOOT_B)
        result = self.run_ready(env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent_count(), 2)

    def test_maintenance_silences_next_start(self):
        flag = self.manager / "logs/.silent_next_start"
        flag.parent.mkdir()
        flag.touch()
        result = self.run_ready()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(flag.exists())
        self.assertEqual(self.sent_count(), 0)
        self.assertFalse((self.root / "journal.args").exists())
        self.assertEqual(self.run_ready().returncode, 0)
        self.assertEqual(self.sent_count(), 0)
        (self.root / "invocation").write_text(BOOT_B)
        self.assertEqual(self.run_ready(env=dict(self.env, INVOCATION_ID=BOOT_B)).returncode, 0)
        self.assertEqual(self.sent_count(), 1)

    def test_legacy_maintenance_flag_consumed_once(self):
        flag = self.manager / ".silent_next_start"
        (self.manager / "logs").mkdir()
        flag.touch()
        first = self.run_ready()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertTrue(flag.exists())
        self.assertEqual(self.sent_count(), 0)
        self.assertTrue((self.manager / "logs/.legacy_silent_next_start_consumed").exists())
        second = self.run_ready()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.sent_count(), 0)
        (self.root / "invocation").write_text(BOOT_B)
        newer = self.run_ready(env=dict(self.env, INVOCATION_ID=BOOT_B))
        self.assertEqual(newer.returncode, 0, newer.stderr)
        self.assertEqual(self.sent_count(), 1)

    def test_new_maintenance_flag_supersedes_legacy(self):
        (self.manager / "logs").mkdir()
        (self.manager / ".silent_next_start").touch()
        (self.manager / "logs/.silent_next_start").touch()
        first = self.run_ready()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.sent_count(), 0)
        self.assertFalse((self.manager / "logs/.silent_next_start").exists())
        second = self.run_ready()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.sent_count(), 0)
        (self.root / "invocation").write_text(BOOT_B)
        newer = self.run_ready(env=dict(self.env, INVOCATION_ID=BOOT_B))
        self.assertEqual(newer.returncode, 0, newer.stderr)
        self.assertEqual(self.sent_count(), 1)

    def test_silence_flag_path_is_writable_by_hardened_service(self):
        template = (ROOT / "data/setupTemplates/zomboid.service").read_text()
        maintenance = (ROOT / "data/scripts/admin/performFullMaintenance.sh").read_text()
        self.assertIn("ProtectSystem=strict", template)
        self.assertIn("%h/pzmanager/logs", template)
        self.assertIn('SILENT_FLAG_FILE="${PZ_MANAGER_DIR}/logs/.silent_next_start"', maintenance)
        start_block = maintenance.split('log "Maintenance terminée, redémarrage du service..."', 1)[1]
        start_block = start_block.split("if validate_final_start", 1)[0]
        self.assertIn('[[ "$SILENT_MODE" == true ]] && opts+=(--silent)', start_block)

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
            'import os, pathlib, sys\n'
            'args = sys.argv[1:]\n'
            'if os.environ.get("MOCK_TARGET"):\n'
            '    pathlib.Path(os.environ["MOCK_TARGET"]).write_text(args[-1])\n'
            'path = os.environ.get("MOCK_PAYLOAD")\n'
            'if path and "-d" in args:\n'
            '    pathlib.Path(path).write_text(args[args.index("-d") + 1])\n'
            'print(os.environ.get("MOCK_HTTP", "204"), end="")\n'
            'sys.exit(int(os.environ.get("MOCK_CURL_RC", "0")))\n'
        )
        curl.chmod(0o755)
        self.env = dict(os.environ)
        self.env.update({
            "PATH": f'{binpath}:{os.environ.get("PATH", "")}',
            "MOCK_DISCORD_WEBHOOK": "https://discord.invalid/SECRET",
            "MOCK_HTTP": "204",
            "MOCK_PAYLOAD": str(self.base / "payload.json"),
            "MOCK_TARGET": str(self.base / "target.txt"),
        })

    def run_discord(self, *, strict=False, env=None, message="Disponibilité"):
        args = ["bash", str(self.script), message]
        if strict:
            args.append("--strict")
        return subprocess.run(
            args, env=env or self.env, text=True, capture_output=True,
            timeout=5
        )

    def test_discord_success(self):
        result = self.run_discord(strict=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_multiline_control_and_unicode_json(self):
        content = 'Annonce\nLigne 2\r\t"citation" \\ barre 🧟'
        result = self.run_discord(strict=True, message=content)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads((self.base / "payload.json").read_text())
        self.assertEqual(payload, {"content": content})

    def test_discord_http_error_strict_and_best_effort(self):
        env = dict(self.env, MOCK_HTTP="429")
        strict = self.run_discord(strict=True, env=env)
        self.assertNotEqual(strict.returncode, 0)
        self.assertIn("HTTP=429", strict.stderr)
        self.assertNotIn("SECRET", strict.stderr)
        best_effort = self.run_discord(env=env)
        self.assertEqual(best_effort.returncode, 0, best_effort.stderr)
        self.assertIn("HTTP=429", best_effort.stderr)

    def test_explicit_webhook_options_in_both_orders(self):
        destination = "https://discord.invalid/ADMIN"
        message = "Private incident alert"
        env = dict(self.env, MOCK_HTTP="429")
        variants = (
            [message, "--webhook", destination, "--strict"],
            ["--webhook", destination, message, "--strict"],
            ["--strict", "--webhook", destination, message],
            [message, "--webhook=" + destination, "--strict"],
        )
        for arguments in variants:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    ["bash", str(self.script), *arguments],
                    env=env, text=True, capture_output=True, timeout=5
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("HTTP=429", result.stderr)
                self.assertEqual((self.base / "target.txt").read_text(), destination)
                self.assertEqual(
                    json.loads((self.base / "payload.json").read_text()),
                    {"content": message},
                )

    def test_explicit_webhook_missing_argument(self):
        for arguments in (
            ["Incident", "--webhook"],
            ["Incident", "--webhook="],
            ["--webhook", "--strict", "Incident"],
        ):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    ["bash", str(self.script), *arguments],
                    env=self.env, text=True, capture_output=True, timeout=5
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("--webhook requiert une URL", result.stderr)

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
