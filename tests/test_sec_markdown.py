"""Sec (markdown) : le nom du client le plus actif est neutralisé dans l'embed.

Constat Codex Security (10/2026, commit:7788583) : le nom, contrôlé par un
joueur whitelisté, était interpolé brut dans du Markdown Discord (`**{nom}**`),
permettant de casser la mise en forme / tromper la télémétrie affichée.

Exécute la vraie fonction _monitoring_embed (stub discord) : un nom hostile ne
doit plus produire de Markdown actif et un nom très long est borné.
"""
import importlib.util
import sys
import types
import unittest
from pathlib import Path

BOT_PY = Path(__file__).resolve().parents[1] / "data/scripts/discord/bot.py"


def _install_discord_stub():
    if "discord" in sys.modules:
        return

    def _escape_markdown(text):
        # Double de test de discord.utils.escape_markdown : neutralise les
        # caractères spéciaux Markdown. La prod utilise la vraie bibliothèque.
        out = []
        for ch in str(text):
            if ch in "\\*_~`|}>":
                out.append("\\")
            out.append(ch)
        return "".join(out)

    class _Embed:
        def __init__(self, *args, **kwargs):
            self.fields = []

        def add_field(self, *args, **kwargs):
            if kwargs:
                self.fields.append(kwargs)
            else:
                names = ("name", "value", "inline")
                self.fields.append(dict(zip(names, args)))

        def set_footer(self, *args, **kwargs):
            pass

    class _Client:
        def __init__(self, *args, **kwargs):
            pass

        def event(self, func):
            return func

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

    utils = types.ModuleType("discord.utils")
    utils.escape_markdown = _escape_markdown
    discord = types.ModuleType("discord")
    discord.utils = utils
    discord.Forbidden = type("Forbidden", (Exception,), {})
    discord.HTTPException = type("HTTPException", (Exception,), {})
    discord.NotFound = type("NotFound", (Exception,), {})
    discord.Interaction = type("Interaction", (), {})
    discord.Message = type("Message", (), {})
    discord.Object = type("Object", (), {"__init__": lambda self, *a, **k: None})
    discord.Embed = _Embed
    discord.Intents = type("Intents", (), {"__init__": lambda self, *a, **k: None})
    discord.Client = _Client
    discord.File = _File
    app_commands = types.ModuleType("discord.app_commands")
    app_commands.Group = _Group
    app_commands.CommandTree = _Tree
    app_commands.describe = _describe
    discord.app_commands = app_commands
    sys.modules["discord"] = discord
    sys.modules["discord.utils"] = utils
    sys.modules["discord.app_commands"] = app_commands


_install_discord_stub()
_spec = importlib.util.spec_from_file_location("pzm_bot_markdown", BOT_PY)
bot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bot)


def _serveur(nom):
    return {
        "pid": 1234,
        "uptime": 3600,
        "players": None,
        "mem": {"MemTotal": 8 * 1048576, "MemAvailable": 4 * 1048576},
        "gc": (),
        "rss_kb": 0,
        "hwm_kb": 0,
        "pswap_kb": 0,
        "temps": {},
        "disk": None,
        "heapdump": None,
        "load": None,
        "cpu_cores": None,
        "max_pps": 100,
        "game_net": {
            "pps_sent": 10,
            "pps_recv": 20,
            "recv_pps_max_client": 50,
            "recv_pps_max_name": nom,
        },
    }


def _champ_serveur(embed):
    for field in embed.fields:
        if field.get("name") == "Serveur":
            return field.get("value", "")
    raise AssertionError("champ Serveur absent de l'embed")


class MarkdownNeutralise(unittest.TestCase):
    def test_nom_hostile_sans_markdown_actif(self):
        embed = bot._monitoring_embed(_serveur("A**B__C~~D||E`F"))
        valeur = _champ_serveur(embed)
        self.assertNotIn("A**B", valeur)
        self.assertIn("A\\*\\*B", valeur)

    def test_nom_long_borne(self):
        embed = bot._monitoring_embed(_serveur("z" * 100))
        valeur = _champ_serveur(embed)
        self.assertIn("z" * 64, valeur)
        self.assertNotIn("z" * 65, valeur)

    def test_nom_benin_inchange(self):
        embed = bot._monitoring_embed(_serveur("Clem"))
        self.assertIn("**Clem**", _champ_serveur(embed))


if __name__ == "__main__":
    unittest.main()
