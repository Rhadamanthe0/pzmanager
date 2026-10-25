#!/usr/bin/env python3
"""Regression tests for the Discord ready notification and webhook transport."""
import json
import ast
import re
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
        for name in ("writing_start_admission.py", "configureWritingTextOnly.py"):
            shutil.copy2(ROOT / "data/scripts/internal" / name, self.internal / name)
        shutil.copy2(ROOT / "data/scripts/lib/shared_memory_budget.py", self.lib / "shared_memory_budget.py")
        for name in ('console_command.py', 'service_process.py'):
            shutil.copy2(ROOT / 'data/scripts/lib' / name, self.lib / name)
        self.script.chmod(0o755)
        self.discord.chmod(0o755)
        common_source = (ROOT / "data/scripts/lib/common.sh").read_text()
        helper_start = common_source.index("private_state_path() {")
        helper_end = common_source.index("\n}\n", helper_start) + 2
        private_state_helper = common_source[helper_start:helper_end]
        console_start = common_source.index('console_players_responded() {')
        console_end = common_source.index('\n}\n', console_start) + 2
        console_helper = common_source[console_start:console_end]
        frame_start = common_source.index('game_log_frame() {')
        frame_end = common_source.index('\n}\n', frame_start) + 2
        frame_helper = common_source[frame_start:frame_end]
        (self.lib / "common.sh").write_text(
            'source_env() {\n'
            '  PZ_MANAGER_DIR="$MOCK_MANAGER_DIR"\n'
            '  PZ_SERVICE_NAME=zomboid.service\n'
            '  DISCORD_WEBHOOK="$MOCK_DISCORD_WEBHOOK"\n'
            '  export PZ_MANAGER_DIR PZ_SERVICE_NAME DISCORD_WEBHOOK\n'
            '}\n'
            + private_state_helper + "\n" + console_helper + "\n" + frame_helper + "\n"
        )
        (self.mockbin / "systemctl").write_text(
            '#!/usr/bin/env python3\n'
            'import os, pathlib, sys\n'
            'base = pathlib.Path(os.environ["MOCK_BASE"])\n'
            'args = sys.argv[1:]\n'
            'if "-p" in args and "ExecMainStartTimestamp" in args:\n'
            '    print("Wed 2026-10-14 20:03:44 CEST")\n'
            'elif "ActiveState,MainPID,InvocationID,ControlGroup" in args:\n'
            '    print("ActiveState=active\\nMainPID=10\\nControlGroup=/fixture/zomboid.service\\nInvocationID=" + (base / "invocation").read_text().strip())\n'
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
            'if "--follow" not in sys.argv and os.environ.get("MOCK_CONSOLE_MODE"):\n'
            '    console = os.environ["MOCK_CONSOLE_MODE"]\n'
            '    print(\'LOG : General f:0 st:123> command entered via server console (System.in): "players"\')\n'
            '    if console in ("zero", "restart"): print("LOG : General f:0 st:124> Players connected (0):")\n'
            '    if console == "players": print("Players connected (2):\\n-alice\\n-bob")\n'
            '    if console == "lua": print("LOG : Lua f:0 st:124> Players connected (0):")\n'
            '    if console == "restart": (base / "invocation").write_text("b"*32)\n'
            '    sys.exit(0)\n'
            'if mode == "invocation_only":\n'
            '    boot = (base / "invocation").read_text().strip()\n'
            '    if "INVOCATION_ID=" + boot not in sys.argv[1:]: sys.exit(0)\n'
            '    mode = "instant"\n'
            'if mode == "delayed": time.sleep(2)\n'
            'if mode == "payload-frame":\n'
            '    print(\'LOG : General f:0 st:123> command entered via server console (System.in): "servermsg f:42 st: f:19 st:"\', flush=True)\n'
            'if mode == "native-frame-with-payload":\n'
            '    print("LOG  : General      f:42 t:1,234 st:1\\u202f234 at GameServer.main> servermsg f:0 st:999> loading", flush=True)\n'
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
            "PZ_MANAGER_ROOT": str(self.manager),
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

    def console_fixture(self, mode):
        pipe = self.root / 'control'
        os.mkfifo(pipe)
        fd = os.open(pipe, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, fd)
        env = dict(self.env, MOCK_JOURNAL_MODE='never', MOCK_CONSOLE_MODE=mode,
                   PZ_CONTROL_PIPE=str(pipe), PZ_NOTIFY_READY_TIMEOUT='3')
        return fd, env

    def test_idle_zero_players_is_announced(self):
        fd, env = self.console_fixture('zero')
        result = self.run_ready(env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent_count(), 1)
        self.assertEqual(os.read(fd, 100), b'players\n')

    def test_native_players_response_is_announced(self):
        fd, env = self.console_fixture('players')
        result = self.run_ready(env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent_count(), 1)
        self.assertEqual(os.read(fd, 100), b'players\n')

    def test_console_echo_is_not_announced(self):
        _, env = self.console_fixture('echo')
        self.assertNotEqual(self.run_ready(env=env).returncode, 0)
        self.assertEqual(self.sent_count(), 0)

    def test_console_lua_lookalike_is_not_announced(self):
        _, env = self.console_fixture('lua')
        self.assertNotEqual(self.run_ready(env=env).returncode, 0)
        self.assertEqual(self.sent_count(), 0)

    def test_console_replaced_invocation_is_not_announced(self):
        _, env = self.console_fixture('restart')
        result = self.run_ready(env=env)
        self.assertEqual(self.sent_count(), 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'invocation').read_text(), BOOT_B)

    def test_payload_frame_does_not_announce_ready(self):
        env=dict(self.env,MOCK_JOURNAL_MODE='payload-frame',PZ_NOTIFY_READY_TIMEOUT='1')
        result=self.run_ready(env=env)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.sent_count(),0)
    def test_native_positive_frame_with_zero_payload_is_announced(self):
        env=dict(self.env,MOCK_JOURNAL_MODE='native-frame-with-payload')
        result=self.run_ready(env=env)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.sent_count(),1)
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

    def test_ready_in_real_user_namespace(self):
        if not shutil.which('unshare'):
            self.skipTest('unshare unavailable')
        probe=subprocess.run(['unshare','--user','--map-current-user','/bin/true'],capture_output=True)
        if probe.returncode:self.skipTest('kernel disallows user namespaces')
        result=subprocess.run(['unshare','--user','--map-current-user','bash',str(self.script)],
                              env=self.env,text=True,capture_output=True,timeout=9)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.sent_count(),1)
        self.assertEqual(self.run_ready().returncode,0)
        self.assertEqual(self.sent_count(),1)

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
        target.chmod(0o755)
        (self.runtime_dir / "pzmanager").symlink_to(target, target_is_directory=True)
        result = self.run_ready()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Chemin privé", result.stderr)
        self.assertEqual(self.sent_count(), 0)
        # Ne pas seulement refuser le lien : l'ancien code faisait chmod AVANT
        # la vérification et modifiait la cible même sur retour en erreur.
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)

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
            'source_env() { source "$MOCK_ENV_FILE"; DISCORD_WEBHOOK="${MOCK_DISCORD_WEBHOOK-$DISCORD_WEBHOOK}"; if [[ -v MOCK_SOURCE_OVERRIDE ]]; then export PZ_DISCORD_WEBHOOK_OVERRIDE="$MOCK_SOURCE_OVERRIDE"; fi; }\n'
        )
        self.binpath=binpath
        self.real_curl=shutil.which('curl')
        (self.base/'.env').write_text("DISCORD_WEBHOOK='https://discord.invalid/SECRET'\n")
        python=binpath/'python3'
        python.write_text('#!/usr/bin/python3\nimport json,os,pathlib,sys\n'
                          'with pathlib.Path(os.environ["MOCK_ARGV"]).open("a") as stream: stream.write(json.dumps({"command":"python3","arguments":sys.argv[1:]})+"\\n")\n'
                          'if os.environ.get("MOCK_CONFIG_FAIL"):sys.exit(9)\n'
                          'os.execv("/usr/bin/python3",["/usr/bin/python3",*sys.argv[1:]])\n')
        python.chmod(0o700)
        curl = binpath / "curl"
        curl.write_text(r"""#!/usr/bin/python3
import json,os,pathlib,re,sys
args=sys.argv[1:]
with pathlib.Path(os.environ['MOCK_ARGV']).open('a') as stream:stream.write(json.dumps({'command':'curl','arguments':args})+'\n')
if '--config' in args:
 config=sys.stdin.read();pathlib.Path(os.environ['MOCK_CONFIG']).write_text(config)
 fields={}
 for line in config.split('\n'):
  if not line.strip():continue
  key,separator,value=line.partition('=');value=value.strip()
  if not separator or not (value.startswith('"') and value.endswith('"')):raise SystemExit(2)
  escapes={'n':'\n','r':'\r','t':'\t','v':'\v','"':'"','\\':'\\'}
  fields[key.strip()]=re.sub(r'\\(.)',lambda match:escapes.get(match[1],match[1]),value[1:-1])
 target=fields['url'];payload=fields['data']
else:
 target=args[-1];payload=args[args.index('-d')+1]
pathlib.Path(os.environ['MOCK_TARGET']).write_text(target)
pathlib.Path(os.environ['MOCK_PAYLOAD']).write_text(payload)
print(os.environ.get('MOCK_HTTP','204'),end='')
sys.exit(int(os.environ.get('MOCK_CURL_RC','0')))
""")
        curl.chmod(0o755)
        self.env = dict(os.environ)
        self.env.update({
            "PATH": f'{binpath}:{os.environ.get("PATH", "")}',
            "MOCK_ENV_FILE": str(self.base/'.env'),
            "MOCK_ARGV": str(self.base/'argv.jsonl'),
            "MOCK_CONFIG": str(self.base/'curl.config'),
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

    def test_private_environment_override_is_snapshotted_and_cli_wins(self):
        env=dict(self.env,PZ_DISCORD_WEBHOOK_OVERRIDE='https://discord.invalid/PRIVATE',MOCK_SOURCE_OVERRIDE='https://discord.invalid/REEXPORTED')
        result=self.run_discord(strict=True,env=env)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.base/'target.txt').read_text(),'https://discord.invalid/PRIVATE')
        result=subprocess.run(['bash',str(self.script),'incident','--webhook','https://discord.invalid/EXPLICIT','--strict'],
                              env=env,capture_output=True,text=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.base/'target.txt').read_text(),'https://discord.invalid/EXPLICIT')

    def test_empty_private_environment_does_not_fall_back_to_public(self):
        env=dict(self.env,PZ_DISCORD_WEBHOOK_OVERRIDE='')
        self.assertEqual(self.run_discord(env=env).returncode,0)
        self.assertEqual(self.run_discord(strict=True,env=env).returncode,1)
        self.assertFalse((self.base/'target.txt').exists())

    def test_default_env_webhook_is_not_forwarded_in_process_arguments(self):
        result=self.run_discord(strict=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.base/'target.txt').read_text(),'https://discord.invalid/SECRET')
        argv=(self.base/'argv.jsonl').read_text()
        self.assertNotIn('https://discord.invalid/SECRET',argv)
        self.assertNotIn('SECRET',argv)
        self.assertNotIn('SECRET',result.stdout+result.stderr)

    def test_native_curl_config_parser_preserves_url_and_payload_without_network(self):
        if not self.real_curl:self.skipTest('curl unavailable')
        destinations=('https://discord.invalid/quo"te\\slash/SECRET?path=é', 'https://discord.invalid/SECRET\b\f\x01\nheader=not-an-option')
        content='Annonce\n\r\t"citation" \\ slash 🧟 contrôle\b\f\x01'
        for destination in destinations:
            with self.subTest(destination=destination):
                result=self.run_discord(strict=True,env=dict(self.env,MOCK_DISCORD_WEBHOOK=destination),message=content)
                self.assertEqual(result.returncode,0,result.stderr)
                config=self.base/'curl.config';self.assertTrue(config.exists())
                output=self.base/'curl-native.c'
                native=subprocess.run([self.real_curl,'--config','-','--proto','=file','--libcurl',str(output),'--output','/dev/null'],
                                      input=config.read_text(),capture_output=True,text=True,timeout=5)
                self.assertNotEqual(native.returncode,0)
                self.assertTrue(output.is_file(),native.stderr)
                source=output.read_text()
                for option,expected in (('CURLOPT_URL',destination),('CURLOPT_POSTFIELDS',json.dumps({'content':content},ensure_ascii=False))):
                    literal=re.search(option+r',\s*((?:"(?:\\.|[^"\\])*"\s*)+)\);',source)
                    self.assertIsNotNone(literal,source)
                    chunks=re.findall(r'"(?:\\.|[^"\\])*"',literal[1])
                    value=b''.join(ast.literal_eval('b'+chunk.replace(r'\?', '?')) for chunk in chunks).decode('utf-8')
                    self.assertEqual(value,expected)
                self.assertEqual((self.base/'target.txt').read_text(),destination)
                self.assertEqual(json.loads((self.base/'payload.json').read_text()),{'content':content})

    def test_config_generation_failure_is_strict_or_best_effort_without_transport(self):
        env=dict(self.env,MOCK_CONFIG_FAIL='1')
        self.assertEqual(self.run_discord(strict=True,env=env).returncode,1)
        self.assertEqual(self.run_discord(env=env).returncode,0)
        self.assertFalse((self.base/'target.txt').exists())

    def test_discord_success(self):
        for status in ('200','201','204','207','299'):
            with self.subTest(status=status):
                result = self.run_discord(strict=True,env=dict(self.env,MOCK_HTTP=status))
                self.assertEqual(result.returncode,0,result.stderr)

    def test_multiline_control_and_unicode_json(self):
        content = 'Annonce\nLigne 2\r\t"citation" \\ barre 🧟'
        result = self.run_discord(strict=True, message=content)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads((self.base / "payload.json").read_text())
        self.assertEqual(payload, {"content": content})

    def test_discord_http_error_strict_and_best_effort(self):
        for status in ('400','429','500','503'):
            with self.subTest(status=status):
                env=dict(self.env,MOCK_HTTP=status)
                for strict,expected in ((True,1),(False,0)):
                    result=self.run_discord(strict=strict,env=env)
                    self.assertEqual(result.returncode,expected,result.stderr)
                    self.assertIn('HTTP='+status,result.stderr)
                    self.assertNotIn('SECRET',result.stdout+result.stderr)

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
        for code in ('7','28'):
            with self.subTest(code=code):
                env=dict(self.env,MOCK_HTTP='000',MOCK_CURL_RC=code)
                for strict,expected in ((True,1),(False,0)):
                    result=self.run_discord(strict=strict,env=env)
                    self.assertEqual(result.returncode,expected,result.stderr)
                    self.assertIn('curl='+code,result.stderr)
                    self.assertNotIn('SECRET',result.stdout+result.stderr)

    def test_missing_webhook_in_strict_mode(self):
        env = dict(self.env, MOCK_DISCORD_WEBHOOK="")
        self.assertNotEqual(self.run_discord(strict=True, env=env).returncode, 0)
        self.assertEqual(self.run_discord(env=env).returncode, 0)


if __name__ == "__main__":
    unittest.main()
