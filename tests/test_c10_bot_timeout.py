"""C10 (bot) : timeout tue réellement le groupe + batch fail-fast.

Exécute le vrai bot.py (stub discord) avec un faux `pzm` :
- timeout : faux pzm qui ignore TERM et fuit avec un enfant `sleep` ;
  vérifie code 124 et qu'aucun (parent ni enfant) ne survit ;
- annulation : CancelledError applique la même séquence ;
- fail-fast : lot de 3 dont la 2e échoue -> 3e jamais exécutée
  (fichier témoin absent), header avec échec + non-exécutées.

POSIX uniquement (killpg/session) : ignoré ailleurs.
"""
import asyncio
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from types import SimpleNamespace

BOT_PY = Path(__file__).resolve().parents[1] / "data/scripts/discord/bot.py"

# Timeout court via env (lu par bot.py à l'import).
os.environ["DISCORD_BOT_CMD_TIMEOUT"] = "2"


def _install_discord_stub():
    if "discord" in sys.modules:
        return

    class _Group:
        def __init__(self, *args, **kwargs):
            pass

        def command(self, *args, **kwargs):
            def deco(func):
                return func

            return deco

    class _Tree:
        def __init__(self, *args, **kwargs):
            pass

        def add_command(self, *args, **kwargs):
            pass

    def _describe(*args, **kwargs):
        def deco(func):
            return func

        return deco

    class _File:
        def __init__(self, fp, filename="pzm-output.txt"):
            self.fp = fp
            self.filename = filename

    class _Client:
        def __init__(self, *args, **kwargs):
            pass

        def event(self, func):
            return func

    discord = types.ModuleType("discord")
    discord.Forbidden = type("Forbidden", (Exception,), {})
    discord.HTTPException = type("HTTPException", (Exception,), {})
    discord.NotFound = type("NotFound", (Exception,), {})
    discord.Interaction = type("Interaction", (), {})
    discord.Message = type("Message", (), {})
    discord.Object = type("Object", (), {"__init__": lambda self, *a, **k: None})
    discord.Embed = type("Embed", (), {"__init__": lambda self, *a, **k: None})
    discord.Intents = type("Intents", (), {"__init__": lambda self, *a, **k: None})
    discord.Client = _Client
    discord.File = _File
    app_commands = types.ModuleType("discord.app_commands")
    app_commands.Group = _Group
    app_commands.CommandTree = _Tree
    app_commands.describe = _describe
    discord.app_commands = app_commands
    sys.modules["discord"] = discord
    sys.modules["discord.app_commands"] = app_commands


_install_discord_stub()
_spec = importlib.util.spec_from_file_location("pzm_bot_c10", BOT_PY)
bot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bot)

HANG_PY = """#!/usr/bin/env python3
import os, signal, subprocess, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)  # parent sourd : seul KILL l'arrête
Path = __import__("pathlib").Path
Path(sys.argv[1]).write_text(str(os.getpid()))
child = subprocess.Popen(["sleep", "60"])
Path(sys.argv[2]).write_text(str(child.pid))
child.wait()  # l'enfant (sleep) meurt sur TERM ; le parent survit...
time.sleep(60)  # ... jusqu'au SIGKILL du groupe
"""

BATCH_SH = """#!/bin/sh
case "$1" in
  ok1) echo "premiere ok"; exit 0 ;;
  fail) echo "boom"; exit 1 ;;
  witness) touch "$2"; echo "ne devrait jamais tourner"; exit 0 ;;
  *) echo "inattendu: $1"; exit 99 ;;
esac
"""


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


@unittest.skipUnless(hasattr(os, "killpg") and hasattr(os, "getpgid"),
                     "groupes de process POSIX requis")
class C10BotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self._grace = getattr(bot, "_TERM_GRACE", None)
        if self._grace is not None:  # grâce courte : test rapide, prod inchangée (5s)
            bot._TERM_GRACE = 0.5
            self.addCleanup(setattr, bot, "_TERM_GRACE", self._grace)
        self._pzm = bot.PZM
        self.addCleanup(setattr, bot, "PZM", self._pzm)
        self._timeout = bot.CMD_TIMEOUT
        self.addCleanup(setattr, bot, "CMD_TIMEOUT", self._timeout)

    def _assert_dead(self, pid: int):
        for _ in range(30):  # le init récolte l'orphelin : pas de zombie résiduel
            if not _alive(pid):
                return
            asyncio.run(asyncio.sleep(0.1))
        self.fail(f"process {pid} toujours vivant (fuite du groupe)")

    def test_timeout_kills_group(self):
        fake = self.root / "pzm-hang"
        fake.write_text(HANG_PY)
        fake.chmod(0o700)
        parent_pid = self.root / "parent.pid"
        child_pid = self.root / "child.pid"
        bot.PZM = str(fake)

        async def prompt_run():
            # Le kill du groupe doit être prompt : sans lui, wait() reste
            # bloqué sur les tuyaux hérités par l'enfant (sleep 60s).
            return await asyncio.wait_for(
                bot.run_pzm([str(parent_pid), str(child_pid)]),
                timeout=bot.CMD_TIMEOUT + 10)

        code, out = asyncio.run(prompt_run())

        self.assertEqual(code, 124)
        self.assertIn("timeout", out)
        self._assert_dead(int(parent_pid.read_text()))
        self._assert_dead(int(child_pid.read_text()))

    def test_cancel_kills_group(self):
        fake = self.root / "pzm-hang"
        fake.write_text(HANG_PY)
        fake.chmod(0o700)
        parent_pid = self.root / "parent.pid"
        child_pid = self.root / "child.pid"
        bot.PZM = str(fake)
        bot.CMD_TIMEOUT = 60

        async def cancelled():
            task = asyncio.ensure_future(bot.run_pzm([str(parent_pid), str(child_pid)]))
            await asyncio.sleep(0.5)
            task.cancel()
            return await task

        with self.assertRaises(asyncio.CancelledError):
            asyncio.run(cancelled())
        self._assert_dead(int(parent_pid.read_text()))
        self._assert_dead(int(child_pid.read_text()))

    def test_batch_fail_fast(self):
        fake = self.root / "pzm"
        fake.write_text(BATCH_SH)
        fake.chmod(0o700)
        bot.PZM = str(fake)
        bot.CMD_TIMEOUT = 10
        witness = self.root / "witness"
        captured = {}

        async def fake_dispatch(message, label, work):
            captured["header"], captured["output"] = await work(
                SimpleNamespace(id=1), SimpleNamespace(mention="@test"))

        bot._dispatch_pasted, real = fake_dispatch, bot._dispatch_pasted
        self.addCleanup(setattr, bot, "_dispatch_pasted", real)
        asyncio.run(bot.run_batch(
            object(), [["ok1"], ["fail"], ["witness", str(witness)]]))

        self.assertFalse(witness.exists(), "3e commande exécutée malgré l'échec")
        header, output = captured["header"], captured["output"]
        self.assertIn("1/3 OK", header)
        self.assertIn("échec à la commande 2", header)
        self.assertIn("non exécutée", header)
        self.assertIn("✅ pzm ok1", output)
        self.assertIn("❌ pzm fail (exit=1)", output)
        self.assertIn("boom", output)
        self.assertIn("⏭ pzm witness", output)
        self.assertIn("non exécutée", output)


if __name__ == "__main__":
    unittest.main()
