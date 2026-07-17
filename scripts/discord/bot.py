#!/usr/bin/env python3
"""
bot.py - Bot Discord pzmanager

Expose un groupe de slash commands `/pzm …` (server/backup/whitelist/admin/install
+ rcon/discord/help) calqué sur le dispatcher `pzm`, qui exécute UNIQUEMENT des
commandes `pzm` (aucun shell arbitraire), depuis un salon dédié et réservé à un
rôle admin.

Configuration lue depuis l'environnement (exporté par run-bot.sh via .env) :
  DISCORD_BOT_TOKEN          Token du bot Discord (obligatoire)
  DISCORD_BOT_GUILD_ID       ID du serveur Discord (sync instantané des commandes)
  DISCORD_BOT_CHANNEL_ID     ID(s) du/des salon(s) autorisé(s) (séparés par virgule)
  DISCORD_BOT_ADMIN_ROLE_ID  ID du rôle autorisé à lancer des commandes
  DISCORD_BOT_CMD_TIMEOUT    Timeout d'exécution d'une commande, secondes (défaut 2400)
  DISCORD_BOT_DEATH_CHANNEL_ID  Salon où notifier les morts de joueurs (optionnel)
  DISCORD_BOT_MONITORING_CHANNEL_ID  Salon de télémétrie périodique (optionnel)
  DISCORD_BOT_MONITORING_INTERVAL    Intervalle du monitoring, secondes (défaut 60)
  PZ_MANAGER_DIR             Racine pzmanager (contient le dispatcher `pzm`)
  PZ_SOURCE_DIR              Racine Zomboid (contient Logs/ pour les morts)

Sécurité : chaque sous-commande construit un argv fixe passé à `pzm` via
create_subprocess_exec (jamais shell=True). Aucune injection shell possible ;
seul `pzm` peut être invoqué.
"""

import asyncio
import functools
import glob
import io
import logging
import os
import re
import shlex
import shutil
import time
from datetime import datetime, timezone
from typing import Literal, Optional

import discord
from discord import app_commands

# --- Configuration -----------------------------------------------------------

TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "")
GUILD_ID = os.environ.get("DISCORD_BOT_GUILD_ID", "").strip()
ADMIN_ROLE_ID = os.environ.get("DISCORD_BOT_ADMIN_ROLE_ID", "").strip()
CMD_TIMEOUT = int(os.environ.get("DISCORD_BOT_CMD_TIMEOUT", "2400") or "2400")
PZ_MANAGER_DIR = os.environ.get("PZ_MANAGER_DIR", "").rstrip("/")
PZM = f"{PZ_MANAGER_DIR}/pzm"

# Salons autorisés (liste d'IDs séparés par des virgules)
ALLOWED_CHANNELS = {
    int(c) for c in os.environ.get("DISCORD_BOT_CHANNEL_ID", "").replace(" ", "").split(",") if c
}
ROLE_ID = int(ADMIN_ROLE_ID) if ADMIN_ROLE_ID.isdigit() else None

# Limite d'un message Discord. Dès que la sortie ne tient pas dans un seul bloc
# de code, on la joint en fichier plutôt que d'empiler plusieurs messages.
DISCORD_MAX = 2000

# --- Notification des morts de joueurs ---------------------------------------
# PZ écrit chaque mort dans Zomboid/Logs/<session>_user.txt (fichier TOURNANT,
# recréé à chaque session ; absent de journald). Format d'une ligne de mort :
#   [dd-mm-yy HH:MM:SS.mmm] user <NOM> died at (x,y,z) (non pvp).
# La cause de la mort n'est PAS journalisée par le serveur vanilla : on remonte
# donc le maximum de contexte disponible — pseudo, coordonnées (x,y,étage),
# PvP/Non-PvP, heure. Désactivé si DISCORD_BOT_DEATH_CHANNEL_ID est vide.
_DEATH_CHANNEL_RAW = os.environ.get("DISCORD_BOT_DEATH_CHANNEL_ID", "").strip()
DEATH_CHANNEL_ID = int(_DEATH_CHANNEL_RAW) if _DEATH_CHANNEL_RAW.isdigit() else None
PZ_SOURCE_DIR = os.environ.get("PZ_SOURCE_DIR", "").rstrip("/")
DEATH_LOG_DIR = f"{PZ_SOURCE_DIR}/Logs" if PZ_SOURCE_DIR else ""
DEATH_POLL_SECONDS = 4       # fréquence de lecture du log
DEATH_DEDUP_SECONDS = 15     # même joueur = 1 notif (le moteur logge parfois
                             # plusieurs lignes en < 1 s pour une même mort)
DEATH_LINE_RE = re.compile(
    r"user (?P<name>.+?) died at \((?P<x>-?\d+),(?P<y>-?\d+),(?P<z>-?\d+)\) "
    r"\((?P<pvp>non pvp|pvp)\)")

# --- Monitoring serveur (télémétrie périodique) ------------------------------
# Poste, toutes les MONITORING_INTERVAL secondes, un embed de santé du serveur
# dans DISCORD_BOT_MONITORING_CHANNEL_ID : uptime, heap Java (gc.log), RSS/natif
# du process, RAM système, températures (hwmon), charge CPU, disque, état GC et
# alertes pré-crash. Zéro dépendance (lecture directe de /proc et /sys). Chaque
# cycle = un NOUVEAU message : l'historique du salon sert de « boîte noire » pour
# diagnostiquer un crash a posteriori. Désactivé si le salon est vide.
_MON_CHANNEL_RAW = os.environ.get("DISCORD_BOT_MONITORING_CHANNEL_ID", "").strip()
MONITORING_CHANNEL_ID = int(_MON_CHANNEL_RAW) if _MON_CHANNEL_RAW.isdigit() else None
MONITORING_INTERVAL = max(15, int(os.environ.get("DISCORD_BOT_MONITORING_INTERVAL", "60") or "60"))
LOG_ZOMBOID_DIR = os.environ.get("LOG_ZOMBOID_DIR", "").rstrip("/")
GC_LOG_PATH = f"{LOG_ZOMBOID_DIR}/gc.log" if LOG_ZOMBOID_DIR else ""
HEAP_RESTART_PERCENT = int(os.environ.get("HEAP_RESTART_PERCENT", "95") or "95")
_PZ_XMX_RAW = os.environ.get("PZ_XMX_GB", "").strip()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("pzm-discord-bot")

# guilds : résolution salon/rôle. guild_messages + message_content : lire les
# messages "batch" collés dans le salon (plusieurs `pzm …` d'un coup). ATTENTION :
# message_content est un intent PRIVILÉGIÉ — il faut l'activer dans le Developer
# Portal (onglet Bot) sinon le bot refuse de démarrer. Members n'est PAS requis :
# les rôles de l'auteur arrivent déjà dans l'événement message d'une guilde.
intents = discord.Intents(guilds=True, guild_messages=True, message_content=True)
bot = discord.Client(intents=intents)
tree = app_commands.CommandTree(bot)

# Commandes pzm reconnues en tête de ligne d'un batch (évite de réagir au bavardage).
KNOWN_CMDS = {"server", "backup", "whitelist", "admin", "install", "map",
              "rcon", "discord", "help", "--help", "-h"}

# Un seul pzm à la fois (un `server stop 2m` tient le process plusieurs minutes).
run_lock = asyncio.Lock()


# --- Helpers -----------------------------------------------------------------

def has_admin_role(user) -> bool:
    """True si l'utilisateur (Member) possède le rôle admin configuré."""
    roles = getattr(user, "roles", None)
    return ROLE_ID is not None and bool(roles) and any(r.id == ROLE_ID for r in roles)


def authz_error(interaction: discord.Interaction) -> str | None:
    """Retourne un message d'erreur si l'appelant n'est pas autorisé, sinon None."""
    if not ALLOWED_CHANNELS or ROLE_ID is None:
        return ("⚠️ Bot mal configuré : renseigne `DISCORD_BOT_CHANNEL_ID` et "
                "`DISCORD_BOT_ADMIN_ROLE_ID` dans `scripts/.env`.")
    if interaction.channel_id not in ALLOWED_CHANNELS:
        return "⛔ Commande non autorisée dans ce salon."
    if not has_admin_role(interaction.user):
        return "⛔ Tu n'as pas le rôle requis pour piloter le serveur."
    return None


def pzm_label(argv: list[str]) -> str:
    """Représentation lisible et sûre d'une commande pzm, pour l'affichage."""
    return "pzm " + " ".join(shlex.quote(a) for a in argv)


def _result_header(label: str, code: int, mention: str | None = None) -> str:
    """En-tête ✅/❌ d'un résultat pzm (label entre backticks, code retour si échec ;
    mention optionnelle en suffixe)."""
    tail = f" · {mention}" if mention else ""
    return (f"✅ `{label}`{tail}" if code == 0
            else f"❌ `{label}` (exit={code}){tail}")


async def _send_chunked(send, header: str, output: str):
    """Repli quand la pièce jointe est refusée (permission « Joindre des fichiers »
    absente) : poste l'en-tête puis la sortie en blocs de code < 2000 caractères.
    Ne requiert que « Envoyer des messages »."""
    await send(header)
    budget = DISCORD_MAX - len("```\n\n```") - 1
    for i in range(0, len(output), budget):
        await send(f"```\n{output[i:i + budget]}\n```")


async def deliver(send, header: str, output: str, *, filename: str = "pzm-output.txt"):
    """Envoie statut + sortie en UN SEUL message via le callable `send`.
    Si tout tient dans un bloc de code -> inline ; sinon -> pièce jointe (Discord
    ne fait pas ce repli automatiquement via l'API). Si l'envoi du fichier est
    refusé (permission « Joindre des fichiers » manquante), repli en messages
    découpés plutôt que de planter sans rien répondre."""
    output = output.rstrip() or "(aucune sortie)"
    inline_limit = DISCORD_MAX - len(header) - len("\n```\n\n```") - 1
    if len(output) <= inline_limit:
        await send(f"{header}\n```\n{output}\n```")
        return
    file = discord.File(io.BytesIO(output.encode("utf-8")), filename=filename)
    try:
        await send(header, file=file)
    except discord.Forbidden:
        log.warning("Envoi en pièce jointe refusé (permission « Joindre des fichiers » "
                    "manquante) -> repli en messages découpés")
        await _send_chunked(send, header, output)


async def run_pzm(args: list[str]) -> tuple[int, str]:
    """Exécute `pzm <args>` sans shell. Retourne (code_retour, sortie_combinée)."""
    proc = await asyncio.create_subprocess_exec(
        PZM, *args,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        cwd=PZ_MANAGER_DIR or None,
    )
    try:
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=CMD_TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return 124, f"⏱️ Commande interrompue après {CMD_TIMEOUT}s (timeout)."
    return proc.returncode, stdout.decode("utf-8", errors="replace")


async def execute(interaction: discord.Interaction, args: list[str]):
    """Contrôle salon+rôle, sérialise, exécute `pzm args` et renvoie le résultat
    dans un unique message. Point de passage commun de toutes les sous-commandes."""
    err = authz_error(interaction)
    if err:
        await interaction.response.send_message(err, ephemeral=True)
        log.info("REFUSÉ user=%s channel=%s cmd=%r (%s)",
                 interaction.user, interaction.channel_id, args, err)
        return
    await interaction.response.defer()  # « réfléchit… » : tient pendant l'attente en file
    label = pzm_label(args)
    if run_lock.locked():
        log.info("QUEUE user=%s cmd=%r (une commande est déjà en cours)",
                 interaction.user, args)
    log.info("EXEC user=%s channel=%s cmd=%r", interaction.user, interaction.channel_id, args)
    async with run_lock:  # lock FIFO : attend son tour au lieu de refuser
        code, output = await run_pzm(args)
    log.info("DONE cmd=%r exit=%s", args, code)

    header = _result_header(label, code)
    try:
        await deliver(interaction.followup.send, header, output)
    except discord.HTTPException:
        # Token d'interaction expiré (commande > 15 min) -> repli sur le salon
        await deliver(interaction.channel.send, header, output)


# --- Batch : plusieurs commandes collées dans le salon -----------------------
# Un message dont CHAQUE ligne utile est `pzm <commande> …` est exécuté ligne par
# ligne (séquentiel, même lock que les slash commands), le message source est
# supprimé, et un unique récap est posté. Un seul `pzm …` non reconnu -> tout le
# lot est rejeté (rien n'est exécuté) : le message source est supprimé et le bot
# poste la/les ligne(s) fautive(s) avec `pzm help` en pièce jointe.

def parse_pzm_line(line: str) -> Optional[list[str]]:
    """argv (sans le préfixe) si la ligne est `pzm|/pzm <commande connue> …`,
    sinon None (ligne non reconnue ou guillemets invalides)."""
    try:
        toks = shlex.split(line)
    except ValueError:
        return None
    if not toks or toks[0] not in ("pzm", "/pzm"):
        return None
    rest = toks[1:]
    if not rest or rest[0] not in KNOWN_CMDS:
        return None
    return rest


def parse_batch(text: str) -> tuple[Optional[list[list[str]]], Optional[list[tuple[int, str]]]]:
    """Analyse un message collé et retourne :
      (batch, None)  si TOUTES les lignes utiles sont des commandes pzm ;
      (None, bad)    si certaines seulement le sont (typo -> [(num, texte), …]) ;
      (None, None)   si aucune (bavardage normal -> on ignore).
    Les lignes vides et celles commençant par '#' sont ignorées."""
    content = [s for raw in text.splitlines()
               if (s := raw.strip()) and not s.startswith("#")]
    if not content:
        return None, None
    parsed = [parse_pzm_line(l) for l in content]
    if all(p is None for p in parsed):
        return None, None
    bad = [(i, content[i - 1]) for i, p in enumerate(parsed, 1) if p is None]
    if bad:
        return None, bad
    return parsed, None


async def _delete_source(message: discord.Message) -> str:
    """Supprime le message source d'un batch. Retourne une note d'avertissement à
    accoler au statut si la permission « Gérer les messages » manque, sinon ""."""
    try:
        await message.delete()
    except discord.Forbidden:
        return " (⚠️ permission « Gérer les messages » manquante : message non supprimé)"
    except discord.NotFound:
        pass
    return ""


async def reject_batch(message: discord.Message, bad: list[tuple[int, str]]):
    """Commande(s) collée(s) non reconnue(s) : supprime le message source, indique
    la/les ligne(s) fautive(s) et joint `pzm help` en pièce jointe. Rien n'est exécuté."""
    channel = message.channel
    author = message.author
    log.info("REJET batch user=%s channel=%s bad=%r",
             author, channel.id, [n for n, _ in bad])

    note = await _delete_source(message)
    detail = "\n".join(f"{n}. {txt}" for n, txt in bad)
    header = (f"⛔ Commande non reconnue ({author.mention}){note} — rien n'a été exécuté.\n"
              f"Ligne(s) invalide(s) (attendu `pzm <commande> …`) :\n```\n{detail}\n```\n"
              f"Voir l'aide `pzm help` en pièce jointe.")
    if len(header) > DISCORD_MAX:
        header = header[:DISCORD_MAX - 1] + "…"
    _, help_out = await run_pzm(["help"])
    # deliver() gère la pièce jointe (ou le repli en messages découpés si la
    # permission « Joindre des fichiers » manque).
    await deliver(channel.send, header, help_out, filename="pzm-help.txt")


async def _dispatch_pasted(message: discord.Message, label: str, work):
    """Scaffold commun aux messages collés : supprime la source, affiche un statut
    (file d'attente FIFO puis « en cours »), sérialise `work(channel, author)` sur
    run_lock, puis poste le `(header, output)` qu'il renvoie — hors du verrou, pour
    ne pas bloquer la commande suivante pendant l'envoi Discord. Retire le statut
    à la fin, quoi qu'il arrive."""
    channel = message.channel
    author = message.author
    note = await _delete_source(message)

    # Si un pzm tourne déjà, on met en file d'attente (lock FIFO) au lieu de refuser :
    # le statut l'indique puis bascule sur « en cours… » quand c'est son tour.
    running = f"▶️ {label} en cours… (demandé par {author.mention}){note}"
    queued = run_lock.locked()
    status = await channel.send(
        f"⏳ {label} en file d'attente… (demandé par {author.mention}){note}"
        if queued else running)
    try:
        async with run_lock:
            if queued:
                try:
                    await status.edit(content=running)
                except discord.HTTPException:
                    pass
            header, output = await work(channel, author)
        await deliver(channel.send, header, output)
    finally:
        try:
            await status.delete()
        except discord.HTTPException:
            pass


async def run_single(message: discord.Message, argv: list[str]):
    """Un message collé ne contenant qu'UNE commande : traité comme une commande
    normale (sortie complète + logs), pas comme un lot. Supprime la source."""
    label = pzm_label(argv)

    async def work(channel, author):
        log.info("EXEC user=%s channel=%s cmd=%r (message collé)", author, channel.id, argv)
        code, output = await run_pzm(argv)
        log.info("DONE cmd=%r exit=%s", argv, code)
        return _result_header(label, code, author.mention), output

    await _dispatch_pasted(message, f"`{label}`", work)


async def run_batch(message: discord.Message, batch: list[list[str]]):
    """Exécute séquentiellement chaque commande, supprime le message source et
    poste un récap unique (inline, ou en pièce jointe si trop long)."""
    n = len(batch)

    async def work(channel, author):
        log.info("EXEC BATCH user=%s channel=%s n=%d", author, channel.id, n)
        results = []
        for argv in batch:
            code, output = await run_pzm(argv)
            results.append((argv, code, output))
            log.info("BATCH item cmd=%r exit=%s", argv, code)

        ok = sum(1 for _, code, _ in results if code == 0)
        lines = []
        for argv, code, output in results:
            label = pzm_label(argv)
            if code == 0:
                lines.append(f"✅ {label}")
            else:
                lines.append(f"❌ {label} (exit={code})")
                out = output.strip()
                if out:
                    lines.append("   " + out.replace("\n", "\n   "))
        header = (f"✅ Lot pzm : {ok}/{n} OK" if ok == n
                  else f"⚠️ Lot pzm : {ok}/{n} OK, {n - ok} échec(s)")
        header += f" · {author.mention}"
        return header, "\n".join(lines)

    await _dispatch_pasted(message, f"Lot de {n} commande(s)", work)


# --- Commandes ---------------------------------------------------------------
# Groupe /pzm calqué sur le dispatcher : chaque sous-commande construit un argv
# fixe puis délègue à execute(). Les délais sont des menus déroulants (Literal).

Delay = Literal["30m", "15m", "5m", "2m", "30s", "now", "auto"]

pzm_group = app_commands.Group(name="pzm", description="Gestion du serveur Project Zomboid")

server_group = app_commands.Group(name="server", description="Cycle de vie du serveur", parent=pzm_group)
backup_group = app_commands.Group(name="backup", description="Sauvegardes", parent=pzm_group)
whitelist_group = app_commands.Group(name="whitelist", description="Liste blanche / accès", parent=pzm_group)
admin_group = app_commands.Group(name="admin", description="Maintenance / reset", parent=pzm_group)
install_group = app_commands.Group(name="install", description="Installation (setup)", parent=pzm_group)


# --- server ---
@server_group.command(name="start", description="Démarrer le serveur")
async def server_start(interaction: discord.Interaction):
    await execute(interaction, ["server", "start"])


@server_group.command(name="status", description="Statut + logs récents")
async def server_status(interaction: discord.Interaction):
    await execute(interaction, ["server", "status"])


async def _run_delayed(interaction, base: list[str], delai, reason):
    """Ajoute [delai] et [--reason ...] optionnels puis exécute (server stop/restart,
    admin maintenance : mêmes options de délai/raison)."""
    args = list(base)
    if delai:
        args.append(delai)
    if reason:
        args += ["--reason", reason]
    await execute(interaction, args)


@server_group.command(name="stop", description="Arrêter le serveur")
@app_commands.describe(delai="Délai avant arrêt (défaut auto : 5m si 2+ joueurs, 2m si 1, now si 0)",
                       reason="Raison affichée aux joueurs")
async def server_stop(interaction: discord.Interaction, delai: Optional[Delay] = None,
                      reason: Optional[str] = None):
    await _run_delayed(interaction, ["server", "stop"], delai, reason)


@server_group.command(name="restart", description="Redémarrer le serveur")
@app_commands.describe(delai="Délai avant redémarrage (défaut auto : 5m si 2+ joueurs, 2m si 1, now si 0)",
                       reason="Raison affichée aux joueurs")
async def server_restart(interaction: discord.Interaction, delai: Optional[Delay] = None,
                         reason: Optional[str] = None):
    await _run_delayed(interaction, ["server", "restart"], delai, reason)


# --- backup ---
@backup_group.command(name="create", description="Backup incrémental")
async def backup_create(interaction: discord.Interaction):
    await execute(interaction, ["backup", "create"])


@backup_group.command(name="full", description="Backup complet avec sync")
async def backup_full(interaction: discord.Interaction):
    await execute(interaction, ["backup", "full"])


@backup_group.command(name="list", description="Lister les backups disponibles")
async def backup_list(interaction: discord.Interaction):
    await execute(interaction, ["backup", "list"])


@backup_group.command(name="restore", description="Restaurer les données Zomboid depuis un backup")
@app_commands.describe(chemin="Dossier de backup (nom sous data/dataBackups/ ou chemin complet)")
async def backup_restore(interaction: discord.Interaction, chemin: str):
    await execute(interaction, ["backup", "restore", chemin])


@backup_group.command(name="restore-character", description="Restaurer le perso d'un joueur (écrase l'existant)")
@app_commands.describe(pseudo="Pseudo du joueur", backup="Dossier de backup (nom ou chemin complet)")
async def backup_restore_character(interaction: discord.Interaction, pseudo: str, backup: str):
    await execute(interaction, ["backup", "restore-character", pseudo, backup])


# --- whitelist ---
@whitelist_group.command(name="list", description="Liste blanche SteamID + comptes + bannis")
async def whitelist_list(interaction: discord.Interaction):
    await execute(interaction, ["whitelist", "list"])


@whitelist_group.command(name="add", description="Autoriser un SteamID (serveur démarré requis)")
@app_commands.describe(id64="SteamID64", nom="Nom (optionnel)")
async def whitelist_add(interaction: discord.Interaction, id64: str, nom: Optional[str] = None):
    args = ["whitelist", "add", id64]
    if nom:
        args.append(nom)
    await execute(interaction, args)


@whitelist_group.command(name="remove", description="Retirer un SteamID (--ban = bannir définitivement)")
@app_commands.describe(cible="SteamID64 ou nom", ban="Bannir définitivement")
async def whitelist_remove(interaction: discord.Interaction, cible: str, ban: bool = False):
    args = ["whitelist", "remove", cible]
    if ban:
        args.append("--ban")
    await execute(interaction, args)


@whitelist_group.command(name="resetpassword", description="Reset du mot de passe d'un compte")
@app_commands.describe(nom="Nom du compte")
async def whitelist_resetpassword(interaction: discord.Interaction, nom: str):
    await execute(interaction, ["whitelist", "resetpassword", nom])


@whitelist_group.command(name="purge", description="Lister/supprimer les accès inactifs")
@app_commands.describe(duree="Seuil d'inactivité (ex: 3m, 60d ; défaut .env)",
                       delete="Supprimer (sinon liste seulement)")
async def whitelist_purge(interaction: discord.Interaction, duree: Optional[str] = None,
                          delete: bool = False):
    args = ["whitelist", "purge"]
    if duree:
        args.append(duree)
    if delete:
        args.append("--delete")
    await execute(interaction, args)


# --- admin ---
@admin_group.command(name="maintenance", description="Maintenance complète (défaut 30m)")
@app_commands.describe(delai="Délai avant maintenance", reason="Raison affichée aux joueurs")
async def admin_maintenance(interaction: discord.Interaction, delai: Optional[Delay] = None,
                            reason: Optional[str] = None):
    await _run_delayed(interaction, ["admin", "maintenance"], delai, reason)


@admin_group.command(name="reset", description="⚠️ Wipe complet du monde → nouveau monde")
@app_commands.describe(keep_config="Restaurer les configs (servertest.ini, SandboxVars, spawns)",
                       keep_whitelist="Restaurer la whitelist")
async def admin_reset(interaction: discord.Interaction, keep_config: bool = False,
                      keep_whitelist: bool = False):
    args = ["admin", "reset"]
    if keep_config:
        args.append("--keep-config")
    if keep_whitelist:
        args.append("--keep-whitelist")
    await execute(interaction, args)


# --- install ---
@install_group.command(name="system", description="Configuration système initiale (échoue via le bot : sudo)")
async def install_system(interaction: discord.Interaction):
    await execute(interaction, ["install", "system"])


@install_group.command(name="zomboid", description="Installer le serveur Project Zomboid (échoue via le bot : sudo)")
async def install_zomboid(interaction: discord.Interaction):
    await execute(interaction, ["install", "zomboid"])


@install_group.command(name="discord", description="Installer/activer le bot Discord")
async def install_discord(interaction: discord.Interaction):
    await execute(interaction, ["install", "discord"])


# --- commandes directes ---
@pzm_group.command(name="rcon", description="Envoyer une commande RCON au serveur")
@app_commands.describe(commande='Ex: players / servermsg "..." / save')
async def pzm_rcon(interaction: discord.Interaction, commande: str):
    try:
        parts = shlex.split(commande)
    except ValueError as e:
        await interaction.response.send_message(f"❌ Guillemets invalides : {e}", ephemeral=True)
        return
    if not parts:
        await interaction.response.send_message("❌ Commande RCON vide.", ephemeral=True)
        return
    await execute(interaction, ["rcon", *parts])


@pzm_group.command(name="discord", description="Envoyer un message sur le webhook Discord")
@app_commands.describe(message="Message à envoyer")
async def pzm_discord(interaction: discord.Interaction, message: str):
    await execute(interaction, ["discord", message])


@pzm_group.command(name="help", description="Afficher l'aide du dispatcher pzm")
async def pzm_help(interaction: discord.Interaction):
    err = authz_error(interaction)
    if err:
        await interaction.response.send_message(err, ephemeral=True)
        return
    await interaction.response.defer(ephemeral=True)
    _, output = await run_pzm(["help"])
    await deliver(functools.partial(interaction.followup.send, ephemeral=True), "📖 `pzm help`", output)


tree.add_command(pzm_group)


# --- Death-watcher : notification des morts de joueurs -----------------------

PVP_DEDUP_SECONDS = 45   # même victime PvP = 1 notif (une bagarre logge plusieurs
                         # « Kill » rapprochés, surtout avec un mod de réanimation)
# Délai max entre un KO PvP et la mort définitive qui peut s'ensuivre : JaxeRevival
# IncapacitatedTime=5 heures IN-GAME, et une heure in-game ≈ 11 min réelles ici
# (PerkLog « Hours Survived », DayLength=4) -> ~55 min réelles. On garde 75 min de
# marge pour continuer d'étiqueter « Combat PvP » une mort qui suit une incapacité PvP.
PVP_CAUSE_WINDOW = 75 * 60
PVP_CAUSE_RADIUS2 = 30 ** 2   # un incapacité meurt là où il est tombé -> match spatial serré

# La ligne « died at » (user.txt) ne porte QUE le nom du PERSONNAGE (jamais l'username
# de compte) + coordonnées, et son flag « (non pvp) » est TOUJOURS « non pvp » (inutile).
# Les PNJ du mod (nommés « Bob » par défaut) écrivent EXACTEMENT la même ligne que les
# joueurs. Le username de compte n'apparaît QUE sur les lignes connect (avec le SteamID).
# On recense donc tous les comptes connectés de la session : une mort n'est notifiée que
# si son nom figure dans cette liste (les PNJ ne se connectent jamais -> écartés ; et sur
# ce serveur le nom de perso == l'username de compte, donc aucune vraie mort n'est perdue).
CONNECT_RE = re.compile(r'(?P<sid>\d{17}) "(?P<user>.+?)" fully connected \(')
# Symétrique du connect : sert au comptage LIVE des joueurs (monitoring). user.txt logge
# aussi « <sid> "<user>" disconnected player (x,y,z). » à chaque départ.
DISCONNECT_RE = re.compile(r'(?P<sid>\d{17}) "(?P<user>.+?)" disconnected player \(')

# Le vrai PvP est dans pvp.txt (usernames de compte, pas noms de perso) :
#   Combat: "Tueur" (...) hit "Victime" (...) weapon="Arme" damage=...
#   Kill:   "Tueur" (...) killed "Victime" (x,y,z).
KILL_RE = re.compile(
    r'Kill: "(?P<killer>.+?)" \([^)]*\) killed "(?P<victim>.+?)" '
    r'\((?P<x>-?\d+),(?P<y>-?\d+),(?P<z>-?\d+)\)')
COMBAT_RE = re.compile(
    r'Combat: "(?P<attacker>.+?)" \([^)]*\) hit "(?P<victim>.+?)" \([^)]*\) '
    r'weapon="(?P<weapon>[^"]*)"')

# Incapacité NON-PvP : écrite par notre mod server-only (media/lua/server) dans
# <session>_pzmanager.txt. Un KO PvP est deja notifié via pvp.txt -> on dédup par
# username (les deux logs utilisent l'username de compte).
#   INCAPACITATED "<username>" @ x,y,z
INCAP_RE = re.compile(
    r'INCAPACITATED "(?P<user>.+?)" @ (?P<x>-?\d+),(?P<y>-?\d+),(?P<z>-?\d+)')
INCAP_DEDUP_SECONDS = 60        # même joueur à terre = 1 notif
INCAP_PVP_MATCH_SECONDS = 20    # KO déjà vu en PvP (pvp.txt) dans cette fenêtre -> pas de doublon

# Un téléport admin (admin.txt : « <compte> teleported to X,Y,Z. ») est parfois suivi,
# à ~la même position et dans les minutes qui suivent, d'un « died at » FACTICE : le
# joueur téléporté ne meurt pas vraiment (confirmé — il continue de jouer/téléporter
# après). On mémorise donc les téléports pour écarter une mort survenue peu après un
# téléport du MÊME compte tout près. Mesuré : morts factices <=15 tuiles du TP, vraies
# morts proches d'un TP >=61 -> un rayon de 50 tuiles les sépare nettement.
ADMIN_TP_RE = re.compile(
    r'\] (?P<user>.+?) teleported to (?P<x>-?\d+),(?P<y>-?\d+),-?\d+\.')  # z ignoré (match x,y)
TP_DEATH_WINDOW = 600           # 10 min : une mort dans cette fenêtre après un TP est suspecte
TP_DEATH_RADIUS2 = 50 ** 2      # ... si elle est aussi à <=50 tuiles de la destination du TP


class _Tail:
    """Suit un fichier de log tournant (glob), en gérant rotation de session,
    troncature et reliquat de ligne partielle. read() renvoie (lignes_complètes,
    emit) : emit vaut False uniquement pour l'historique du fichier DÉJÀ présent au
    tout premier read (au boot on saute l'historique). Un fichier qui apparaît
    ENSUITE (ex. pzmanager.txt créé à la 1re incapacité, ou rotation de session) est
    du live -> emit True. L'appelant met TOUJOURS à jour son état, mais n'émet que si emit."""

    def __init__(self, pattern: str):
        self._pattern = pattern
        self._path: Optional[str] = None
        self._offset = 0
        self._buffer = b""
        self._initialized = False

    def _newest(self) -> Optional[str]:
        try:
            files = glob.glob(self._pattern)
            return max(files, key=os.path.getmtime) if files else None
        except OSError:
            return None

    def _decode(self, data: bytes) -> list[str]:
        *lines, self._buffer = (self._buffer + data).split(b"\n")
        return [ln.decode("utf-8", "replace") for ln in lines]

    def read(self) -> tuple[list[str], bool]:
        first_read = not self._initialized
        self._initialized = True
        newest = self._newest()
        if newest is None:
            return [], True
        if newest != self._path:               # boot ou rotation -> relire tout
            self._path, self._buffer = newest, b""
            try:
                with open(newest, "rb") as f:
                    data = f.read()
            except OSError:
                data = b""
            self._offset = len(data)
            # Historique sauté seulement pour le fichier déjà là au 1er read (boot) ;
            # un fichier apparu ensuite est du live.
            emit = not first_read
            return self._decode(data), emit
        try:
            fsize = os.path.getsize(self._path)
        except OSError:
            return [], True
        if fsize < self._offset:               # tronqué/remplacé en place
            self._offset, self._buffer = 0, b""
        if fsize <= self._offset:
            return [], True
        try:
            with open(self._path, "rb") as f:
                f.seek(self._offset)
                data = f.read()
        except OSError:
            return [], True
        self._offset += len(data)
        return self._decode(data), True


def _position(x: str, y: str, z: str) -> str:
    pos = f"x={x}, y={y}"
    return pos + (f" · étage {z}" if z not in ("0", "-0") else "")


def _death_embed(name: str, x: str, y: str, z: str, cause: str) -> discord.Embed:
    """Mort DÉFINITIVE issue de user.txt (le perso meurt pour de bon). Le nom est déjà
    filtré en amont sur la liste des comptes connectés (perso == compte sur ce serveur),
    d'où pas de parenthèse de compte. Cause : « ⚔️ Combat PvP » si un takedown PvP récent
    proche est connu (le joueur a fini par succomber), sinon « 🧟 Environnement / zombie »
    (le flag « non pvp » de user.txt étant toujours faux, on déduit la cause de pvp.txt)."""
    embed = discord.Embed(
        title="☠️ Mort définitive",
        description=f"**{discord.utils.escape_markdown(name)}** est mort définitivement.",
        color=0xB03030,
        timestamp=datetime.now(timezone.utc),
    )
    embed.add_field(name="Cause",
                    value="⚔️ Combat PvP" if cause == "pvp" else "🧟 Environnement / zombie",
                    inline=True)
    embed.add_field(name="Position", value=_position(x, y, z), inline=True)
    return embed


def _pvp_embed(victim: str, killer: str, weapon: Optional[str],
               x: str, y: str, z: str) -> discord.Embed:
    """Incapacité PvP issue de pvp.txt : la victime est mise à terre par le tueur
    (usernames de compte). Avec le mod de réanimation, c'est un KO réanimable — la mort
    définitive, si elle suit, est notifiée séparément (☠️). Arme = dernier coup + position."""
    embed = discord.Embed(
        title="⚔️ Incapacité PvP",
        description=(f"**{discord.utils.escape_markdown(victim)}** a été mis à terre par "
                     f"**{discord.utils.escape_markdown(killer)}** (réanimable)."),
        color=0xE67E22,
        timestamp=datetime.now(timezone.utc),
    )
    if weapon:
        embed.add_field(name="Arme", value=discord.utils.escape_markdown(weapon), inline=True)
    embed.add_field(name="Position", value=_position(x, y, z), inline=True)
    return embed


def _incap_embed(account: str, x: str, y: str, z: str) -> discord.Embed:
    """Incapacité NON-PvP issue du mod server-only (<session>_pzmanager.txt) : un
    joueur est à terre suite à un zombie / l'environnement (les KO PvP arrivent par
    pvp.txt et sont notifiés séparément)."""
    embed = discord.Embed(
        title="🧟 Incapacité",
        description=(f"**{discord.utils.escape_markdown(account)}** est à terre "
                     f"(zombie / environnement) — réanimable."),
        color=0xC27C0E,
        timestamp=datetime.now(timezone.utc),
    )
    embed.add_field(name="Position", value=_position(x, y, z), inline=True)
    return embed


def _dedup(seen: dict[str, float], key: str, now: float, window: float) -> bool:
    """True s'il faut IGNORER (même clé revue dans la fenêtre). Marque et purge sinon."""
    if now - seen.get(key, float("-inf")) < window:
        return True
    seen[key] = now
    for stale in [k for k, t in seen.items() if now - t > window * 4]:
        del seen[stale]
    return False


async def _process_admin_line(channel, line: str, state: dict, emit: bool):
    """admin.txt : mémorise les téléports (compte + destination) pour écarter ensuite les
    morts factices qu'ils déclenchent. On n'enregistre que le live (`emit`) -> tous les
    horodatages restent en `time.monotonic()`, comparables à ceux des morts. `channel`
    n'est pas utilisé (signature homogène avec les autres processeurs)."""
    if not emit:
        return
    m = ADMIN_TP_RE.search(line)
    if not m:
        return
    now = time.monotonic()
    tps = state["recent_tps"]
    tps.append((now, m.group("user").strip(), int(m.group("x")), int(m.group("y"))))
    tps[:] = [k for k in tps if now - k[0] < TP_DEATH_WINDOW]


async def _process_user_line(channel, line: str, state: dict, emit: bool):
    """user.txt : met à jour les comptes connectés et, si `emit`, notifie une mort
    NON-PvP (les morts PvP sont couvertes par pvp.txt ; on saute donc une mort dont
    un « Kill » PvP tout récent au même endroit a déjà été notifié)."""
    accounts = state["accounts"]
    m = CONNECT_RE.search(line)
    if m:
        accounts.add(m.group("user").strip())
        return
    if not emit:
        return
    m = DEATH_LINE_RE.search(line)
    if not m:
        return
    name = m.group("name").strip()
    if name not in accounts:
        return  # PNJ (« Bob » par défaut) ou perso non rattaché à un compte -> pas de notif
    now = time.monotonic()
    x, y, z = m.group("x"), m.group("y"), m.group("z")
    ix, iy = int(x), int(y)
    # Mort factice consécutive à un téléport admin du même compte tout près -> on ignore
    # (avant le dédup, pour ne pas consommer sa fenêtre au détriment d'une vraie mort).
    if any(now - t <= TP_DEATH_WINDOW and acct == name
           and (tx - ix) ** 2 + (ty - iy) ** 2 <= TP_DEATH_RADIUS2
           for t, acct, tx, ty in state["recent_tps"]):
        log.info("Mort factice ignorée (téléport récent) : %s (%s,%s)", name, x, y)
        return
    if _dedup(state["last_death"], name, now, DEATH_DEDUP_SECONDS):
        return
    # Cause : un takedown PvP récent (≤ fenêtre d'incapacité) et proche -> le joueur a
    # succombé à ses blessures PvP ; sinon environnement / zombie.
    cause = "pvp" if any(now - t < PVP_CAUSE_WINDOW
                         and (kx - ix) ** 2 + (ky - iy) ** 2 <= PVP_CAUSE_RADIUS2
                         for t, kx, ky, _v in state["recent_kills"]) else "env"
    try:
        await channel.send(embed=_death_embed(name, x, y, z, cause))
        log.info("MORT DÉFINITIVE notifiée : %s (%s,%s,%s) cause=%s", name, x, y, z, cause)
    except discord.HTTPException as e:
        log.warning("Échec envoi notif mort pour %s : %s", name, e)


async def _process_pvp_line(channel, line: str, state: dict, emit: bool):
    """pvp.txt : mémorise l'arme des coups (Combat) et, si `emit`, notifie chaque
    Kill (victime tuée par tueur + arme), dédupliqué par victime."""
    weapon = state["weapon"]
    m = COMBAT_RE.search(line)
    if m:
        if len(weapon) > 200:
            weapon.clear()
        weapon[(m.group("attacker").strip(), m.group("victim").strip())] = m.group("weapon")
        return
    m = KILL_RE.search(line)
    if not m or not emit:
        return
    killer, victim = m.group("killer").strip(), m.group("victim").strip()
    now = time.monotonic()
    if _dedup(state["last_pvp"], victim, now, PVP_DEDUP_SECONDS):
        return
    x, y, z = m.group("x"), m.group("y"), m.group("z")
    state["recent_kills"].append((now, int(x), int(y), victim))
    state["recent_kills"][:] = [k for k in state["recent_kills"] if now - k[0] < PVP_CAUSE_WINDOW]
    try:
        await channel.send(embed=_pvp_embed(victim, killer, weapon.get((killer, victim)), x, y, z))
        log.info("INCAPACITÉ PvP notifiée : %s mis à terre par %s (%s,%s,%s)",
                 victim, killer, x, y, z)
    except discord.HTTPException as e:
        log.warning("Échec envoi notif PvP pour %s : %s", victim, e)


async def _process_pzm_line(channel, line: str, state: dict, emit: bool):
    """pzmanager.txt (mod server-only) : notifie une incapacité NON-PvP. On saute
    celles déjà couvertes par un « Kill » PvP tout récent pour le même username (les
    deux logs utilisent l'username de compte -> match direct, pas de coords)."""
    m = INCAP_RE.search(line)
    if not m or not emit:
        return
    user = m.group("user").strip()
    now = time.monotonic()
    if any(now - t < INCAP_PVP_MATCH_SECONDS and victim == user
           for t, _x, _y, victim in state["recent_kills"]):
        return  # KO déjà annoncé comme incapacité PvP (pvp.txt)
    if _dedup(state["last_incap"], user, now, INCAP_DEDUP_SECONDS):
        return
    x, y, z = m.group("x"), m.group("y"), m.group("z")
    try:
        await channel.send(embed=_incap_embed(user, x, y, z))
        log.info("INCAPACITÉ (non-PvP) notifiée : %s (%s,%s,%s)", user, x, y, z)
    except discord.HTTPException as e:
        log.warning("Échec envoi notif incapacité pour %s : %s", user, e)


async def death_watcher():
    """Tâche de fond : suit user.txt (morts non-PvP) ET pvp.txt (morts PvP) et poste
    dans le salon dédié. Gère la rotation de session et saute l'historique au démarrage
    (notifs « live » uniquement)."""
    await bot.wait_until_ready()
    if DEATH_CHANNEL_ID is None or not DEATH_LOG_DIR:
        return
    channel = bot.get_channel(DEATH_CHANNEL_ID)
    if channel is None:
        try:
            channel = await bot.fetch_channel(DEATH_CHANNEL_ID)
        except (discord.NotFound, discord.Forbidden, discord.HTTPException) as e:
            log.warning("Salon des morts %s inaccessible (%s) — notif désactivée",
                        DEATH_CHANNEL_ID, e)
            return
    log.info("Death-watcher actif : salon=%s dir=%s", DEATH_CHANNEL_ID, DEATH_LOG_DIR)

    state = {
        "accounts": set(),    # usernames connectés cette session (allow-list anti-PNJ)
        "last_death": {},     # perso -> t : dédup des morts user.txt
        "last_pvp": {},       # victime -> t : dédup des kills pvp.txt
        "last_incap": {},     # username -> t : dédup des incapacités non-PvP
        "weapon": {},         # (tueur, victime) -> arme du dernier coup
        "recent_kills": [],   # (t, x, y, victime) : kills PvP récents (dédup croisée)
        "recent_tps": [],     # (t, compte, x, y) : téléports admin récents (anti-mort factice)
    }
    admin_tail = _Tail(os.path.join(DEATH_LOG_DIR, "*_admin.txt"))
    user_tail = _Tail(os.path.join(DEATH_LOG_DIR, "*_user.txt"))
    pvp_tail = _Tail(os.path.join(DEATH_LOG_DIR, "*_pvp.txt"))
    pzm_tail = _Tail(os.path.join(DEATH_LOG_DIR, "*_pzmanager.txt"))

    while not bot.is_closed():
        lines, emit = admin_tail.read()   # traité AVANT user : recent_tps à jour pour écarter les morts factices
        for line in lines:
            await _process_admin_line(channel, line, state, emit)
        lines, emit = user_tail.read()
        for line in lines:
            await _process_user_line(channel, line, state, emit)
        lines, emit = pvp_tail.read()   # traité AVANT pzm : recent_kills à jour pour la dédup
        for line in lines:
            await _process_pvp_line(channel, line, state, emit)
        lines, emit = pzm_tail.read()
        for line in lines:
            await _process_pzm_line(channel, line, state, emit)
        await asyncio.sleep(DEATH_POLL_SECONDS)


# --- Monitoring : collecte des métriques -------------------------------------

_CLK_TCK = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
# Résumé d'une collecte ZGC : "NNNNM(PP%)->MMMMM(QQ%)" (majeure OU mineure).
_GC_HEAP_RE = re.compile(r"(\d+)M\((\d+)%\)->(\d+)M\((\d+)%\)")
_GC_MAJOR_RE = re.compile(
    r"Major Collection \([^)]*\) \d+M\(\d+%\)->(\d+)M\((\d+)%\) ([\d.,]+)s")


def _bar(pct, width=10) -> str:
    n = max(0, min(width, int(round((pct or 0) / 100 * width))))
    return "█" * n + "░" * (width - n)


def _read_int(path):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def _tail_text(path, nbytes=65536) -> str:
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - nbytes))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def _meminfo() -> dict:
    out = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, rest = line.partition(":")
                out[k] = int(rest.strip().split()[0])   # kB
    except OSError:
        pass
    return out


def _proc_status(pid) -> dict:
    out = {}
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                k, _, rest = line.partition(":")
                if k in ("VmRSS", "VmHWM", "VmSwap"):
                    out[k] = int(rest.strip().split()[0])   # kB
    except OSError:
        pass
    return out


def _java_pid():
    """PID de la JVM serveur : le process 'ProjectZomboid'/'java' au plus gros RSS
    (robuste au shell parent du service)."""
    best, best_rss = None, -1
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/comm") as f:
                comm = f.read().strip()
        except OSError:
            continue
        if "ProjectZomboid" not in comm and comm != "java":
            continue
        rss = _proc_status(pid).get("VmRSS", 0)
        if rss > best_rss:
            best, best_rss = int(pid), rss
    return best


def _proc_cpu_jiffies(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            parts = f.read().split()
        return int(parts[13]) + int(parts[14])          # utime + stime
    except (OSError, IndexError, ValueError):
        return None


def _proc_uptime_seconds(pid):
    """Âge du process = uptime serveur depuis le dernier (re)démarrage."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            starttime = int(f.read().split()[21]) / _CLK_TCK
        with open("/proc/uptime") as f:
            return float(f.read().split()[0]) - starttime
    except (OSError, IndexError, ValueError):
        return None


def _temps() -> dict:
    """Températures (°C) par capteur hwmon, résolues par NOM (les index sont volatils
    d'un boot à l'autre)."""
    want = {"k10temp": "cpu", "nvme": "nvme", "amdgpu": "gpu", "spd5118": "ram"}
    out = {}
    for h in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            with open(f"{h}/name") as f:
                key = want.get(f.read().strip())
        except OSError:
            continue
        if not key:
            continue
        val = None
        for inp in sorted(glob.glob(f"{h}/temp*_input")):
            raw = _read_int(inp)
            if not raw:                                  # 0 ou None = capteur muet
                continue
            val = raw / 1000.0
            try:
                with open(inp.replace("_input", "_label")) as f:
                    lbl = f.read().strip()
            except OSError:
                lbl = ""
            if lbl in ("Tctl", "Composite", "edge"):     # capteur principal du device
                break
        if val is not None:
            out[key] = val
    return out


def _gc_heap():
    """(used_mb, pct, major_pct, major_used_mb, major_pause_s) depuis gc.log.
    used/pct = dernière collecte (fraîche) ; major_* = dernière MAJEURE (plancher
    du live-set = indicateur d'OOM). Les % sont des % de Xmx."""
    txt = _tail_text(GC_LOG_PATH)
    if not txt:
        return None
    used = pct = None
    for m in _GC_HEAP_RE.finditer(txt):
        used, pct = int(m.group(3)), int(m.group(4))     # post-flèche = état courant
    maj_pct = maj_used = maj_pause = None
    for m in _GC_MAJOR_RE.finditer(txt):
        maj_used, maj_pct = int(m.group(1)), int(m.group(2))
        maj_pause = float(m.group(3).replace(",", "."))
    if used is None:
        return None
    return used, pct, maj_pct, maj_used, maj_pause


def _recent_heapdump():
    """(nom, âge_s) du dernier .hprof si présent (un dump = OOM survenu)."""
    if not LOG_ZOMBOID_DIR:
        return None
    dumps = glob.glob(f"{LOG_ZOMBOID_DIR}/*.hprof")
    if not dumps:
        return None
    newest = max(dumps, key=os.path.getmtime)
    return os.path.basename(newest), time.time() - os.path.getmtime(newest)


def _xmx_gb() -> int:
    if _PZ_XMX_RAW.isdigit():
        return int(_PZ_XMX_RAW)
    total = _meminfo().get("MemTotal", 0)
    return max(2, total // 1024 // 1024 // 2)


def collect_stats(prev: dict) -> dict:
    """Un instantané complet. `prev` porte l'état inter-cycles (CPU delta)."""
    now = time.monotonic()
    s = {"pid": _java_pid()}
    s["mem"] = _meminfo()
    st = _proc_status(s["pid"]) if s["pid"] else {}
    s["rss_kb"], s["hwm_kb"], s["pswap_kb"] = st.get("VmRSS"), st.get("VmHWM"), st.get("VmSwap")
    s["uptime"] = _proc_uptime_seconds(s["pid"]) if s["pid"] else None
    s["cpu_pct"] = None
    if s["pid"]:
        jif = _proc_cpu_jiffies(s["pid"])
        if jif is not None and prev.get("jif") is not None:
            dt = now - prev["ts"]
            if dt > 0:
                s["cpu_pct"] = max(0.0, (jif - prev["jif"]) / (_CLK_TCK * dt) * 100.0)
        prev["jif"], prev["ts"] = jif, now
    s["temps"] = _temps()
    try:
        s["load"] = os.getloadavg()
    except OSError:
        s["load"] = None
    s["gc"] = _gc_heap()
    try:
        s["disk"] = shutil.disk_usage(PZ_SOURCE_DIR or PZ_MANAGER_DIR)
    except OSError:
        s["disk"] = None
    s["heapdump"] = _recent_heapdump()
    s["players"] = _online_players(prev)
    return s


def _online_players(prev: dict):
    """Nombre de joueurs connectés, sans RCON : on rejoue user.txt (connexions/
    déconnexions) via un _Tail dédié. État porté par `prev` entre les cycles.
    None si le dossier de logs est inconnu. Remis à zéro sur rotation de session."""
    if not DEATH_LOG_DIR:
        return None
    tail = prev.get("user_tail")
    if tail is None:
        tail = prev["user_tail"] = _Tail(os.path.join(DEATH_LOG_DIR, "*_user.txt"))
        prev["online"], prev["user_path"] = set(), None
    online = prev["online"]
    # Nouvelle session (restart serveur) -> le fichier change : on repart de zéro
    # (le _Tail rejoue alors tout le nouveau fichier ci-dessous).
    try:
        files = glob.glob(os.path.join(DEATH_LOG_DIR, "*_user.txt"))
        newest = max(files, key=os.path.getmtime) if files else None
    except OSError:
        newest = None
    if newest != prev["user_path"]:
        online.clear()
        prev["user_path"] = newest
    lines, _ = tail.read()
    for line in lines:
        m = CONNECT_RE.search(line)
        if m:
            online.add(m.group("sid"))
            continue
        m = DISCONNECT_RE.search(line)
        if m:
            online.discard(m.group("sid"))
    return len(online)


# --- Monitoring : rendu de l'embed -------------------------------------------

def _fmt_dur(sec):
    if not sec:
        return "—"
    sec = int(sec)
    d, sec = divmod(sec, 86400)
    h, sec = divmod(sec, 3600)
    m = sec // 60
    if d:
        return f"{d}j {h}h {m}m"
    if h:
        return f"{h}h {m}m"
    return f"{m}m"


def _status(s):
    """(couleur, [alertes]) — évalue les prédicteurs de crash."""
    alerts, warn = [], False
    mem = s["mem"]
    total, avail = mem.get("MemTotal", 0), mem.get("MemAvailable", 0)
    avail_mb = avail / 1024
    gc = s["gc"]
    live = gc[2] if gc and gc[2] is not None else None      # plancher live-set (majeure)
    crit = False
    if s["pid"] is None:
        alerts.append("🔴 Serveur INACTIF (aucun process JVM)")
        crit = True
    if live is not None and live >= HEAP_RESTART_PERCENT - 3:
        alerts.append(f"🔴 Heap live-set {live}% ≈ seuil de restart ({HEAP_RESTART_PERCENT}%)")
        crit = True
    elif live is not None and live >= HEAP_RESTART_PERCENT - 15:
        alerts.append(f"🟠 Heap live-set {live}% — montée vers le seuil ({HEAP_RESTART_PERCENT}%)")
        warn = True
    if total and avail_mb < 600:
        alerts.append(f"🔴 RAM système dispo {avail_mb/1024:.1f} Go — risque d'OOM-kill OS")
        crit = True
    elif total and avail_mb < 1200:
        alerts.append(f"🟠 RAM système dispo {avail_mb/1024:.1f} Go — marge basse")
        warn = True
    if s["pswap_kb"]:
        alerts.append(f"🟠 Le process a swappé ({s['pswap_kb']/1024:.0f} Mo) — anormal (MemorySwapMax=0)")
        warn = True
    if gc and gc[4] and gc[4] > 8:
        alerts.append(f"🟠 Pause GC majeure longue ({gc[4]:.1f}s)")
        warn = True
    cpu_t = s["temps"].get("cpu")
    if cpu_t and cpu_t >= 90:
        alerts.append(f"🔴 CPU {cpu_t:.0f}°C — surchauffe")
        crit = True
    elif cpu_t and cpu_t >= 82:
        alerts.append(f"🟠 CPU {cpu_t:.0f}°C — chaud")
        warn = True
    if s["disk"] and s["disk"].free / s["disk"].total < 0.05:
        alerts.append("🔴 Disque du monde < 5% libre — la sauvegarde peut échouer")
        crit = True
    if s["heapdump"] and s["heapdump"][1] < 7200:
        alerts.append(f"🔴 Heap dump récent ({_fmt_dur(s['heapdump'][1])}) — OOM survenu")
        crit = True
    color = 0xE74C3C if crit else (0xE67E22 if warn else 0x2ECC71)
    return color, alerts


def _monitoring_embed(s: dict) -> discord.Embed:
    color, alerts = _status(s)
    mem = s["mem"]
    total = mem.get("MemTotal", 0)
    avail = mem.get("MemAvailable", 0)
    used_pct = (1 - avail / total) * 100 if total else 0
    cached = (mem.get("Buffers", 0) + mem.get("Cached", 0)) / 1048576
    shmem = mem.get("Shmem", 0) / 1048576
    sswap = (mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)) / 1024   # Mo
    xmx = _xmx_gb()
    gc = s["gc"]

    embed = discord.Embed(title="📊 Monitoring serveur", color=color,
                          timestamp=datetime.now(timezone.utc))

    state = "🟢 actif" if s["pid"] else "🔴 inactif"
    players = s.get("players")
    players_txt = (f" · 👥 **{players}** joueur{'s' if players != 1 else ''}"
                   if players is not None else "")
    embed.add_field(
        name="Serveur",
        value=f"{state}{players_txt} · uptime **{_fmt_dur(s['uptime'])}**"
              + (f" · pid `{s['pid']}`" if s["pid"] else ""),
        inline=False)

    # Heap Java (le nerf de la guerre : OOM = heap plein de cellules vivantes)
    if gc:
        used_mb, pct, maj_pct = gc[0], gc[1], gc[2]
        heap_line = f"**{used_mb} Mo / {xmx} Go** — {pct}% de Xmx"
        if maj_pct is not None:
            heap_line += f"\nPlancher live-set (dern. majeure) : **{maj_pct}%** · seuil restart {HEAP_RESTART_PERCENT}%"
    else:
        heap_line = "—"
    embed.add_field(name="🧠 Heap Java", value=heap_line, inline=False)

    # Process JVM : RSS = heap résident + natif hors-heap
    if s["rss_kb"]:
        rss_g = s["rss_kb"] / 1048576
        native_g = max(0.0, rss_g - (gc[0] / 1024 if gc else 0))
        hwm_g = s["hwm_kb"] / 1048576 if s["hwm_kb"] else 0
        proc_line = (f"RSS **{rss_g:.1f} Go** · natif ~{native_g:.1f} Go · pic {hwm_g:.1f} Go"
                     f" · swap {s['pswap_kb'] / 1024:.0f} Mo")
    else:
        proc_line = "—"
    embed.add_field(name="💾 Process (JVM)", value=proc_line, inline=False)

    # RAM système : la vraie marge anti OOM-kill OS
    embed.add_field(
        name="🖥️ RAM système",
        value=f"util **{used_pct:.0f}%** `{_bar(used_pct)}` · dispo **{avail/1048576:.1f} Go** / {total/1048576:.1f}\n"
              f"cache {cached:.1f} Go · shmem {shmem:.1f} Go · swap sys {sswap:.0f} Mo",
        inline=False)

    # Températures (le mobile initial : chauffe du mini-PC)
    t = s["temps"]
    temp_parts = []
    for key, lbl in (("cpu", "CPU"), ("nvme", "NVMe"), ("gpu", "GPU"), ("ram", "RAM")):
        if key in t:
            temp_parts.append(f"{lbl} **{t[key]:.0f}°C**")
    embed.add_field(
        name="🌡️ Températures",
        value=" · ".join(temp_parts) or "—",
        inline=True)

    # CPU
    if s["load"]:
        cores = os.cpu_count() or 1
        load1 = s["load"][0] / cores * 100
        load5 = s["load"][1] / cores * 100
        cpu_line = f"charge **{load1:.0f}%** (1 min) / **{load5:.0f}%** (5 min)"
        if s["cpu_pct"] is not None:
            cpu_line += f"\nprocess **{s['cpu_pct']:.0f}%**"
    else:
        cpu_line = "—"
    embed.add_field(name="⚙️ CPU", value=cpu_line, inline=True)

    # Disque + GC
    if s["disk"]:
        free_pct = s["disk"].free / s["disk"].total * 100
        disk_line = f"libre **{s['disk'].free / 1e9:.0f} Go** ({free_pct:.0f}%)"
    else:
        disk_line = "—"
    if gc and gc[2] is not None:
        disk_line += f"\n♻️ dern. majeure {gc[2]}% en {gc[4]:.1f}s" if gc[4] else f"\n♻️ dern. majeure {gc[2]}%"
    embed.add_field(name="🗄️ Disque (monde)", value=disk_line, inline=True)

    if alerts:
        embed.add_field(name="⚠️ Alertes", value="\n".join(alerts), inline=False)

    embed.set_footer(text=f"maj toutes les {MONITORING_INTERVAL}s")
    return embed


async def monitoring_loop():
    """Tâche de fond : poste un embed de santé toutes les MONITORING_INTERVAL s."""
    await bot.wait_until_ready()
    if MONITORING_CHANNEL_ID is None:
        return
    channel = bot.get_channel(MONITORING_CHANNEL_ID)
    if channel is None:
        try:
            channel = await bot.fetch_channel(MONITORING_CHANNEL_ID)
        except (discord.NotFound, discord.Forbidden, discord.HTTPException) as e:
            log.warning("Salon de monitoring %s inaccessible (%s) — monitoring désactivé",
                        MONITORING_CHANNEL_ID, e)
            return
    log.info("Monitoring actif : salon=%s intervalle=%ss", MONITORING_CHANNEL_ID, MONITORING_INTERVAL)

    prev = {}
    collect_stats(prev)                      # amorce le delta CPU sans poster
    await asyncio.sleep(min(MONITORING_INTERVAL, 5))
    while not bot.is_closed():
        try:
            s = collect_stats(prev)
            await channel.send(embed=_monitoring_embed(s))
        except discord.HTTPException as e:
            log.warning("Monitoring : envoi Discord échoué (%s)", e)
        except Exception:
            log.exception("Monitoring : erreur de collecte")
        await asyncio.sleep(MONITORING_INTERVAL)


@bot.event
async def setup_hook():
    if GUILD_ID.isdigit():
        guild = discord.Object(id=int(GUILD_ID))
        tree.copy_global_to(guild=guild)
        await tree.sync(guild=guild)
        log.info("Slash commands synchronisées sur le guild %s", GUILD_ID)
    else:
        await tree.sync()
        log.info("Slash commands synchronisées globalement (propagation ~1h)")
    if DEATH_CHANNEL_ID is not None:
        bot.loop.create_task(death_watcher())
    else:
        log.info("Notification des morts désactivée (DISCORD_BOT_DEATH_CHANNEL_ID vide)")
    if MONITORING_CHANNEL_ID is not None:
        bot.loop.create_task(monitoring_loop())
    else:
        log.info("Monitoring désactivé (DISCORD_BOT_MONITORING_CHANNEL_ID vide)")


@bot.event
async def on_ready():
    log.info("Connecté en tant que %s | salons=%s role=%s",
             bot.user, ALLOWED_CHANNELS or "AUCUN", ROLE_ID or "AUCUN")


@bot.event
async def on_message(message: discord.Message):
    """Batch : un membre admin colle plusieurs `pzm …` dans un salon autorisé."""
    if message.author.bot or message.guild is None:
        return
    if not ALLOWED_CHANNELS or ROLE_ID is None:
        return
    if message.channel.id not in ALLOWED_CHANNELS:
        return
    batch, bad = parse_batch(message.content)
    if batch is None and bad is None:
        return  # bavardage normal -> on ne touche à rien
    if not has_admin_role(message.author):
        log.info("REFUSÉ batch user=%s channel=%s (rôle manquant)",
                 message.author, message.channel.id)
        return
    if bad:
        await reject_batch(message, bad)
        return
    if len(batch) == 1:
        await run_single(message, batch[0])  # une seule commande -> sortie complète
        return
    await run_batch(message, batch)


def main():
    if not TOKEN:
        raise SystemExit("DISCORD_BOT_TOKEN manquant (voir scripts/.env)")
    if not PZ_MANAGER_DIR or not os.path.isfile(PZM):
        raise SystemExit(f"Dispatcher pzm introuvable: {PZM}")
    bot.run(TOKEN, log_handler=None)


if __name__ == "__main__":
    main()
