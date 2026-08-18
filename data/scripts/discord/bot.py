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
  DISCORD_BOT_ADMIN_ROLE_ID  ID(s) du/des rôle(s) autorisé(s) (séparés par virgule)
  DISCORD_BOT_CMD_TIMEOUT    Timeout d'exécution d'une commande, secondes (défaut 2400)
  DISCORD_BOT_MONITORING_CHANNEL_ID  Salon de télémétrie périodique (optionnel)
  DISCORD_BOT_MONITORING_INTERVAL    Intervalle du monitoring, secondes (défaut 60)
  DISCORD_BOT_MONITORING_CSV_DAYS    Rétention du journal CSV des métriques, jours (défaut 7)
  PZ_PROMETHEUS_PORT         Port de l'exporteur métriques interne de PZ (localhost) ;
                             source exacte des paquets/s du serveur de jeu (optionnel)
  PZ_MANAGER_DIR             Racine pzmanager (contient le dispatcher `pzm`)
  PZ_SOURCE_DIR              Racine Zomboid (contient Logs/ ; comptage joueurs → monitoring)

Sécurité : chaque sous-commande construit un argv fixe passé à `pzm` via
create_subprocess_exec (jamais shell=True). Aucune injection shell possible ;
seul `pzm` peut être invoqué.
"""

import asyncio
import csv
import functools
import glob
import io
import logging
import os
import re
import shlex
import shutil
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Literal, Optional

import discord
from discord import app_commands

# --- Configuration -----------------------------------------------------------

TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "")
GUILD_ID = os.environ.get("DISCORD_BOT_GUILD_ID", "").strip()
CMD_TIMEOUT = int(os.environ.get("DISCORD_BOT_CMD_TIMEOUT", "2400") or "2400")
PZ_MANAGER_DIR = os.environ.get("PZ_MANAGER_DIR", "").rstrip("/")
PZM = f"{PZ_MANAGER_DIR}/pzm"

# Salons autorisés (liste d'IDs séparés par des virgules)
ALLOWED_CHANNELS = {
    int(c) for c in os.environ.get("DISCORD_BOT_CHANNEL_ID", "").replace(" ", "").split(",") if c
}
# Rôles autorisés (liste d'IDs séparés par des virgules — un membre en possédant
# au moins un peut piloter le serveur).
ROLE_IDS = {
    int(r) for r in os.environ.get("DISCORD_BOT_ADMIN_ROLE_ID", "").replace(" ", "").split(",")
    if r.isdigit()
}

# Limite d'un message Discord. Dès que la sortie ne tient pas dans un seul bloc
# de code, on la joint en fichier plutôt que d'empiler plusieurs messages.
DISCORD_MAX = 2000

PZ_SOURCE_DIR = os.environ.get("PZ_SOURCE_DIR", "").rstrip("/")
# Répertoire des logs PZ (Zomboid/Logs/<session>_*.txt, fichiers TOURNANTS) — lu par le
# monitoring pour compter les joueurs connectés (voir _Tail / CONNECT_RE plus bas).
PZ_LOGS_DIR = f"{PZ_SOURCE_DIR}/Logs" if PZ_SOURCE_DIR else ""

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
# Journal CSV des métriques (« boîte noire » relisible hors Discord) : une ligne
# par cycle de monitoring, dans logs/zomboid/ (gitignoré), purgé au-delà
# de DISCORD_BOT_MONITORING_CSV_DAYS jours.
MONITORING_CSV_PATH = f"{LOG_ZOMBOID_DIR}/monitoring.csv" if LOG_ZOMBOID_DIR else ""
MONITORING_CSV_DAYS = max(1, int(os.environ.get("DISCORD_BOT_MONITORING_CSV_DAYS", "7") or "7"))
# Exporteur de métriques réseau INTERNE de PZ (client Prometheus embarqué, activé
# par -DprometheusEnabled/-DprometheusPort via configureJvm.sh quand PZ_PROMETHEUS_PORT
# est défini). Source EXACTE des paquets/s du SEUL serveur de jeu (tous clients), du
# tick serveur (fps), de la perte de paquets et du trafic VOIP — bien plus propre que
# la mesure au niveau de la carte réseau. Vide = non exposé -> on retombe sur le NIC.
PZ_PROMETHEUS_PORT = os.environ.get("PZ_PROMETHEUS_PORT", "").strip()
PROMETHEUS_URL = f"http://127.0.0.1:{PZ_PROMETHEUS_PORT}/metrics" if PZ_PROMETHEUS_PORT else ""
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
    """True si l'utilisateur (Member) possède au moins un rôle admin configuré."""
    roles = getattr(user, "roles", None)
    return bool(ROLE_IDS) and bool(roles) and any(r.id in ROLE_IDS for r in roles)


def authz_error(interaction: discord.Interaction) -> str | None:
    """Retourne un message d'erreur si l'appelant n'est pas autorisé, sinon None."""
    if not ALLOWED_CHANNELS or not ROLE_IDS:
        return ("⚠️ Bot mal configuré : renseigne `DISCORD_BOT_CHANNEL_ID` et "
                "`DISCORD_BOT_ADMIN_ROLE_ID` dans `.env`.")
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


@whitelist_group.command(name="remove", description="Retirer l'accès d'un SteamID (tous ses comptes ; --ban)")
@app_commands.describe(steamid64="SteamID64 (17 chiffres) — retire TOUS ses comptes",
                       ban="Bannir définitivement")
async def whitelist_remove(interaction: discord.Interaction, steamid64: str, ban: bool = False):
    args = ["whitelist", "remove", steamid64]
    if ban:
        args.append("--ban")
    await execute(interaction, args)


@whitelist_group.command(name="remove-account", description="Supprimer UN compte (garde les autres du même SteamID)")
@app_commands.describe(nom="Pseudo ou SteamID64 du compte à supprimer",
                       dry_run="Afficher le plan sans rien modifier")
async def whitelist_remove_account(interaction: discord.Interaction, nom: str, dry_run: bool = False):
    args = ["whitelist", "remove-account", nom]
    if dry_run:
        args.append("--dry-run")
    await execute(interaction, args)


@whitelist_group.command(name="rename-account", description="Renommer un compte (garde perso et mot de passe)")
@app_commands.describe(ancien="Pseudo actuel", nouveau="Nouveau pseudo",
                       dry_run="Afficher le plan sans rien modifier")
async def whitelist_rename_account(interaction: discord.Interaction, ancien: str, nouveau: str,
                                   dry_run: bool = False):
    args = ["whitelist", "rename-account", ancien, nouveau]
    if dry_run:
        args.append("--dry-run")
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
@app_commands.describe(keep_config="Restaurer les configs (.ini du monde, SandboxVars, spawns)",
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


# --- Lecture des logs PZ (tail de session) -----------------------------------
# Le monitoring compte les joueurs connectés en rejouant Zomboid/Logs/<session>_user.txt
# (fichier TOURNANT, recréé à chaque session ; absent de journald) : lignes connect /
# disconnect ci-dessous, via la classe _Tail (rotation, troncature, ligne partielle).
CONNECT_RE = re.compile(r'(?P<sid>\d{17}) "(?P<user>.+?)" fully connected \(')
DISCONNECT_RE = re.compile(r'(?P<sid>\d{17}) "(?P<user>.+?)" disconnected player \(')


class _Tail:
    """Suit un fichier de log tournant (glob), en gérant rotation de session,
    troncature et reliquat de ligne partielle. read() renvoie les lignes complètes
    lues depuis le dernier appel, et expose le fichier courant via `path`.

    Le drapeau `emit` d'autrefois (sauter l'historique au premier read) servait au
    death-watcher, retiré en août 2026 ; l'unique appelant restant — le comptage de
    joueurs — le jetait. Supprimé avec `_initialized`."""

    def __init__(self, pattern: str):
        self._pattern = pattern
        self._path: Optional[str] = None
        self._offset = 0
        self._buffer = b""

    @property
    def path(self) -> Optional[str]:
        """Fichier actuellement suivi (None tant qu'aucun read n'a abouti)."""
        return self._path

    def _newest(self) -> Optional[str]:
        try:
            files = glob.glob(self._pattern)
            return max(files, key=os.path.getmtime) if files else None
        except OSError:
            return None

    def _decode(self, data: bytes) -> list[str]:
        *lines, self._buffer = (self._buffer + data).split(b"\n")
        return [ln.decode("utf-8", "replace") for ln in lines]

    def read(self) -> list[str]:
        newest = self._newest()
        if newest is None:
            return []
        if newest != self._path:               # boot ou rotation -> relire tout
            self._path, self._buffer = newest, b""
            try:
                with open(newest, "rb") as f:
                    data = f.read()
            except OSError:
                data = b""
            self._offset = len(data)
            return self._decode(data)
        try:
            fsize = os.path.getsize(self._path)
        except OSError:
            return []
        if fsize < self._offset:               # tronqué/remplacé en place
            self._offset, self._buffer = 0, b""
        if fsize <= self._offset:
            return []
        try:
            with open(self._path, "rb") as f:
                f.seek(self._offset)
                data = f.read()
        except OSError:
            return []
        self._offset += len(data)
        return self._decode(data)


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


def _percpu_stat():
    """Compteurs cumulés (total, idle) par cœur, lus dans /proc/stat (lignes
    cpu0, cpu1, ...). idle inclut iowait. Sert à calculer, par delta entre deux
    cycles, l'utilisation de CHAQUE cœur -> moyenne + cœur le plus chargé."""
    try:
        out = []
        with open("/proc/stat") as f:
            for line in f:
                if not line.startswith("cpu"):
                    continue
                parts = line.split()
                # 'cpu' seul = agrégat (ignoré) ; 'cpuN' = un cœur.
                if not parts[0][3:].isdigit():
                    continue
                vals = list(map(int, parts[1:]))
                idle = vals[3] + (vals[4] if len(vals) > 4 else 0)   # idle + iowait
                out.append((sum(vals), idle))
        return out or None
    except (OSError, ValueError, IndexError):
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


def _default_iface():
    """Interface de la route par défaut (destination 00000000 dans /proc/net/route)."""
    try:
        with open("/proc/net/route") as f:
            next(f)
            for line in f:
                p = line.split()
                if len(p) > 1 and p[1] == "00000000":
                    return p[0]
    except (OSError, IndexError, StopIteration):
        pass
    return None


def _net_counters(iface):
    """(rx_bytes, rx_packets, tx_bytes, tx_packets) de `iface` depuis /proc/net/dev."""
    try:
        with open("/proc/net/dev") as f:
            for line in f:
                name, _, rest = line.partition(":")
                if name.strip() != iface:
                    continue
                v = rest.split()
                return int(v[0]), int(v[1]), int(v[8]), int(v[9])
    except (OSError, ValueError, IndexError):
        pass
    return None


def _server_ini_path(prev: dict):
    """Chemin du .ini serveur (servertest.ini par défaut), mis en cache dans prev."""
    if "ini_path" in prev:
        return prev["ini_path"]
    # PZ_INI_PATH est exporté par source_env (run-bot.sh source le .env) pour que
    # personne n'ait à recomposer le nom du monde ; on ne recompose qu'à défaut.
    path = ""
    env_ini = os.environ.get("PZ_INI_PATH", "")
    if env_ini and os.path.isfile(env_ini):
        prev["ini_path"] = env_ini
        return env_ini
    if PZ_SOURCE_DIR:
        cand = f"{PZ_SOURCE_DIR}/Server/servertest.ini"
        if os.path.isfile(cand):
            path = cand
        else:
            inis = glob.glob(f"{PZ_SOURCE_DIR}/Server/*.ini")
            path = inis[0] if inis else ""
    prev["ini_path"] = path
    return path


def _ini_ints(path, keys):
    """Valeurs entières de `keys` (clé=valeur) dans un .ini PZ ; None si absent."""
    out = {k: None for k in keys}
    if not path:
        return out
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line[0] == "#" or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                k = k.strip()
                if k in out:
                    try:
                        out[k] = int(v.strip())
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


def _prom_val(line: str):
    """Dernier champ (valeur) d'une ligne exposition Prometheus, en float."""
    try:
        return float(line.rsplit(" ", 1)[1])
    except (ValueError, IndexError):
        return 0.0


def _prom_snapshot():
    """Lit l'exporteur Prometheus interne de PZ (localhost). Retourne les compteurs
    CUMULÉS paquets/octets (histogrammes packet_send/receive_bytes, sommés sur TOUS
    les clients et types de paquets -> à dériver par delta) plus des jauges
    instantanées (fps serveur, perte de paquets, VOIP). None si non exposé/injoignable."""
    if not PROMETHEUS_URL:
        return None
    try:
        with urllib.request.urlopen(PROMETHEUS_URL, timeout=4) as r:
            text = r.read().decode("utf-8", "replace")
    except Exception:
        return None
    out = {"send_c": 0.0, "recv_c": 0.0, "send_b": 0.0, "recv_b": 0.0,
           "fps": None, "ploss": None, "voip_s": None, "voip_r": None,
           # compteur reçu CUMULÉ par client : MaxPacketsPerSecond est un anti-flood
           # PAR CLIENT sur l'ENTRANT (PacketsCache.isLimitExceeded) -> on suit chaque
           # client pour comparer le plus actif au cap (le vrai « % du max »).
           "recv_by_client": {}}
    for line in text.splitlines():
        if not line or line[0] == "#":
            continue
        if line.startswith("packet_send_bytes_count"):
            out["send_c"] += _prom_val(line)
        elif line.startswith("packet_send_bytes_sum"):
            out["send_b"] += _prom_val(line)
        elif line.startswith("packet_receive_bytes_count"):
            v = _prom_val(line)
            out["recv_c"] += v
            m = re.search(r'client="([^"]*)"', line)
            cl = m.group(1) if m else ""
            out["recv_by_client"][cl] = out["recv_by_client"].get(cl, 0.0) + v
        elif line.startswith("packet_receive_bytes_sum"):
            out["recv_b"] += _prom_val(line)
        elif line.startswith('performance{parameter="fps"}'):
            out["fps"] = _prom_val(line)
        elif line.startswith('network{parameter="packet-loss-last-second"}'):
            out["ploss"] = _prom_val(line)
        elif line.startswith('network{parameter="voip-sent"}'):
            out["voip_s"] = _prom_val(line)
        elif line.startswith('network{parameter="voip-received"}'):
            out["voip_r"] = _prom_val(line)
    return out


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
    # Utilisation par cœur sur l'intervalle (delta de /proc/stat). None au 1er
    # cycle (pas de référence) — le loop amorce prev avant de poster.
    s["cpu_cores"] = None
    cur_cpu = _percpu_stat()
    if cur_cpu and prev.get("percpu") and len(cur_cpu) == len(prev["percpu"]):
        pcts = []
        for (tot, idle), (ptot, pidle) in zip(cur_cpu, prev["percpu"]):
            d_tot = tot - ptot
            if d_tot > 0:
                pcts.append(max(0.0, min(100.0, (d_tot - (idle - pidle)) / d_tot * 100.0)))
        if pcts:
            s["cpu_cores"] = pcts
    prev["percpu"] = cur_cpu
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
    # Débit réseau sur l'interface de la route par défaut (delta entre cycles).
    # C'est le REPLI : PZ expose ses propres compteurs via son exporteur Prometheus
    # (lu plus bas, et préféré par l'embed) ; le NIC ne sert que si l'exporteur
    # n'est pas exposé. Il inclut tout le trafic de la box (Docker, Pi-hole...),
    # donc c'est une approximation, pas la mesure du serveur de jeu.
    s["net"] = None
    iface = prev.get("iface")
    if not iface:
        iface = prev["iface"] = _default_iface()
    if iface:
        cur = _net_counters(iface)
        pc, pts = prev.get("net_ctr"), prev.get("net_ts")
        if cur and pc and pts is not None and now - pts > 0:
            dt = now - pts
            s["net"] = {
                "rx_kbs": max(0, cur[0] - pc[0]) / dt / 1024,
                "tx_kbs": max(0, cur[2] - pc[2]) / dt / 1024,
                "pps": (max(0, cur[1] - pc[1]) + max(0, cur[3] - pc[3])) / dt,
            }
        prev["net_ctr"], prev["net_ts"] = cur, now
    # Réseau INTERNE du serveur de jeu (exporteur Prometheus PZ, localhost) : paquets/s
    # et débit du SEUL PZ, tous clients agrégés (delta des compteurs cumulés) — exact,
    # sans le bruit Docker/Pi-hole/WG de la mesure NIC. Plus fps serveur / perte / VOIP.
    s["game_net"] = None
    s["srv_fps"] = s["packet_loss"] = s["voip_sent"] = s["voip_recv"] = None
    ps = _prom_snapshot()
    if ps:
        s["srv_fps"], s["packet_loss"] = ps["fps"], ps["ploss"]
        s["voip_sent"], s["voip_recv"] = ps["voip_s"], ps["voip_r"]
        pp, ppts = prev.get("prom_ctr"), prev.get("prom_ts")
        if pp and ppts is not None and now - ppts > 0:
            dt = now - ppts
            s["game_net"] = {
                "pps_sent": max(0.0, ps["send_c"] - pp[0]) / dt,
                "pps_recv": max(0.0, ps["recv_c"] - pp[1]) / dt,
                "kbs_sent": max(0.0, ps["send_b"] - pp[2]) / dt / 1024,
                "kbs_recv": max(0.0, ps["recv_b"] - pp[3]) / dt / 1024,
            }
            # paquets/s ENTRANTS du client le plus actif (+ son nom) -> à comparer à
            # MaxPacketsPerSecond (cap anti-flood par client). Un client absent du
            # relevé précédent -> delta 0 (pas de faux pic à la connexion).
            prc = prev.get("prom_rbc") or {}
            best_cl, best_rate = None, 0.0
            for cl, c in ps["recv_by_client"].items():
                r = (c - prc.get(cl, c)) / dt
                if r > best_rate:
                    best_rate, best_cl = r, cl
            s["game_net"]["recv_pps_max_client"] = best_rate
            # client="" = trafic pré-auth/serveur, pas un joueur -> pas de nom affiché
            s["game_net"]["recv_pps_max_name"] = best_cl or None
        prev["prom_ctr"] = (ps["send_c"], ps["recv_c"], ps["send_b"], ps["recv_b"])
        prev["prom_rbc"] = ps["recv_by_client"]
        prev["prom_ts"] = now
    # Plafonds configurés (servertest.ini) pour les ratios « par rapport au max ».
    caps = _ini_ints(_server_ini_path(prev), ("MaxPlayers", "MaxPacketsPerSecond"))
    s["max_players"] = caps.get("MaxPlayers")
    s["max_pps"] = caps.get("MaxPacketsPerSecond")
    return s


def _online_players(prev: dict):
    """Nombre de joueurs connectés, sans RCON : on rejoue user.txt (connexions/
    déconnexions) via un _Tail dédié. État porté par `prev` entre les cycles.
    None si le dossier de logs est inconnu. Remis à zéro sur rotation de session."""
    if not PZ_LOGS_DIR:
        return None
    tail = prev.get("user_tail")
    if tail is None:
        tail = prev["user_tail"] = _Tail(os.path.join(PZ_LOGS_DIR, "*_user.txt"))
        prev["online"], prev["user_path"] = set(), None
    online = prev["online"]
    # Nouvelle session (restart serveur) -> le fichier change : on repart de zéro
    # (le _Tail rejoue alors tout le nouveau fichier).
    # On lit le fichier retenu par _Tail au lieu de refaire ici le même
    # glob + max(getmtime) : les deux devaient rester d'accord, sans quoi le set
    # des connectés était vidé au mauvais cycle.
    lines = tail.read()
    if tail.path != prev["user_path"]:
        online.clear()
        prev["user_path"] = tail.path
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
    elif total and (1 - avail / total) * 100 >= 90:
        alerts.append(f"🟠 RAM système util {(1 - avail / total) * 100:.0f}% — marge basse")
        warn = True
    if s["pswap_kb"]:
        alerts.append(f"🟠 Le process a swappé ({s['pswap_kb']/1024:.0f} Mo) — anormal (MemorySwapMax=0)")
        warn = True
    if gc and gc[4] and gc[4] > 10:
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
    xmx = _xmx_gb()
    gc = s["gc"]

    embed = discord.Embed(title="📊 Monitoring serveur", color=color,
                          timestamp=datetime.now(timezone.utc))

    state = "🟢 actif" if s["pid"] else "🔴 inactif"
    players = s.get("players")
    players_txt = (f" · 👥 **{players}** joueur{'s' if players != 1 else ''}"
                   if players is not None else "")
    # Réseau : priorité aux paquets/s INTERNES exacts de PZ (exporteur Prometheus,
    # émis↑ / reçus↓, tous clients) ; repli sur la mesure NIC (proxy) sinon.
    gnet, net = s.get("game_net"), s.get("net")
    if gnet:
        net_txt = f" · 📡 **{gnet['pps_sent']:.0f}**↑/**{gnet['pps_recv']:.0f}**↓ paq/s"
        # % du cap = client entrant le plus actif vs MaxPacketsPerSecond (par client).
        mc, max_pps = gnet.get("recv_pps_max_client"), s.get("max_pps")
        if mc is not None and max_pps:
            name = gnet.get("recv_pps_max_name")
            who = f"**{name}** " if name else "client "
            net_txt += f" ({who}max **{mc / max_pps * 100:.0f}%** du cap)"
    elif net:
        max_pps = s.get("max_pps")
        ratio = f" ({net['pps'] / max_pps * 100:.0f}% du max)" if max_pps else ""
        net_txt = f" · 📡 **{net['pps']:.0f}** paq/s (NIC){ratio}"
    else:
        net_txt = ""
    fps = s.get("srv_fps")
    fps_txt = f" · ⚙️ **{fps:.0f}** fps" if fps is not None else ""
    embed.add_field(
        name="Serveur",
        value=f"{state}{players_txt}{net_txt}{fps_txt} · uptime **{_fmt_dur(s['uptime'])}**",
        inline=False)

    # Mémoire du jeu (heap) : le nerf de la guerre — c'est ce qui se remplit à
    # mesure que la carte est explorée et déclenche le restart auto quand c'est plein.
    # Un seul bloc mémoire : le heap (ce qui se remplit et déclenche le restart
    # auto) ET la RAM totale du process (heap + moteur/réseau/JVM). On ne détaille
    # pas heap vs natif : avec AlwaysPreTouch le heap réservé fausse le découpage.
    if gc:
        used_g, pct = gc[0] / 1024, gc[1]
        heap_line = f"Jeu (heap) **{used_g:.1f} / {xmx} Go**  `{_bar(pct)}`  **{pct}%**"
    else:
        heap_line = "Jeu (heap) —"
    if s["rss_kb"]:
        rss_g = s["rss_kb"] / 1048576
        hwm_g = s["hwm_kb"] / 1048576 if s["hwm_kb"] else 0
        total_line = f"Total en RAM **{rss_g:.1f} Go** · pic **{hwm_g:.1f} Go**"
    else:
        total_line = "Total en RAM —"
    embed.add_field(name="🧠 RAM de PZ",
                    value=f"{heap_line}\n{total_line}", inline=False)

    # RAM de la machine : la vraie marge anti OOM-kill OS. Le cache est
    # récupérable à tout moment, donc un % élevé n'alarme pas tant qu'il reste du libre.
    # « dispo » = MemAvailable (inclut déjà tout le cache réellement récupérable).
    # On n'affiche PAS le « cache » brut : il contient la shmem = le heap ZGC de
    # PZ, qui n'est pas récupérable — l'inclure induisait en erreur.
    embed.add_field(
        name="🖥️ RAM de la machine",
        value=f"**{used_pct:.0f}%** utilisée `{_bar(used_pct)}` · **{avail/1048576:.1f} Go** dispo / {total/1048576:.1f}",
        inline=False)

    # Températures (le mobile initial : chauffe du mini-PC), sur 2 lignes :
    # CPU + GPU en 1re, NVMe + RAM en 2de.
    t = s["temps"]
    def _temp_row(keys):
        return " · ".join(f"{lbl} **{t[k]:.0f}°C**" for k, lbl in keys if k in t)
    temp_rows = [_temp_row((("cpu", "CPU"), ("gpu", "GPU"))),
                 _temp_row((("nvme", "NVMe"), ("ram", "RAM")))]
    embed.add_field(
        name="🌡️ Températures",
        value="\n".join(r for r in temp_rows if r) or "—",
        inline=True)

    # CPU : moyenne des cœurs (= charge réelle machine) + cœur le plus chargé
    # (= saturation mono-thread), sur le dernier intervalle de mesure.
    cores_stat = s.get("cpu_cores")
    cpu_title = "⚙️ CPU"
    if cores_stat:
        avg = sum(cores_stat) / len(cores_stat)
        mx = max(cores_stat)
        iv = int(MONITORING_INTERVAL)
        window = f"{iv // 60} min" if iv >= 60 and iv % 60 == 0 else f"{iv}s"
        cpu_title = f"⚙️ CPU (sur {window})"
        cpu_line = f"moyenne coeurs **{avg:.0f}%** · coeur le plus utilisé **{mx:.0f}%**"
    elif s["load"]:
        cores = os.cpu_count() or 1
        cpu_line = f"charge **{s['load'][0] / cores * 100:.0f}%** (1 min)"
    else:
        cpu_line = "—"
    embed.add_field(name=cpu_title, value=cpu_line, inline=True)

    # Disque + GC
    if s["disk"]:
        free_pct = s["disk"].free / s["disk"].total * 100
        disk_line = f"**{s['disk'].free / 1e9:.0f} Go** ({free_pct:.0f}%)"
    else:
        disk_line = "—"
    # Détail de la dernière collecte majeure : uniquement en cas d'alerte
    # (info de diagnostic, inutile quand tout est vert).
    if alerts and gc and gc[2] is not None:
        disk_line += f"\n♻️ dern. majeure {gc[2]}% en {gc[4]:.1f}s" if gc[4] else f"\n♻️ dern. majeure {gc[2]}%"
    embed.add_field(name="🗄️ Disque libre", value=disk_line, inline=True)

    if alerts:
        embed.add_field(name="⚠️ Alertes", value="\n".join(alerts), inline=False)

    embed.set_footer(text=f"maj toutes les {MONITORING_INTERVAL}s")
    return embed


# --- Monitoring : journal CSV (boîte noire relisible) ------------------------
# Une ligne par cycle. Colonnes stables (ordre figé) pour rester traçable dans
# un tableur / une courbe. Purge time-based au-delà de MONITORING_CSV_DAYS.
_CSV_HEADER = [
    "timestamp", "uptime_s", "players", "max_players", "players_pct",
    "net_pps", "max_pps", "pps_pct", "net_rx_kbs", "net_tx_kbs",
    "heap_used_mb", "heap_pct", "heap_major_pct", "gc_pause_s",
    "rss_mb", "ram_avail_mb", "ram_used_pct", "swap_mb",
    "cpu_proc_pct", "cpu_sys_pct", "load1",
    "temp_cpu", "temp_nvme", "disk_free_pct",
    # Métriques réseau INTERNES exactes de PZ (exporteur Prometheus) — vides si non exposé.
    # recv_pps_max_client = paquets/s entrants du client le plus actif ; recv_cap_pct =
    # son % de MaxPacketsPerSecond (le cap anti-flood, par client, sur l'entrant).
    "game_pps_sent", "game_pps_recv", "game_kbs_sent", "game_kbs_recv",
    "srv_fps", "packet_loss", "voip_sent", "voip_recv",
    "recv_pps_max_client", "recv_cap_pct",
]
_last_csv_prune = 0.0


def _csv_row(s: dict) -> list:
    def f(x, nd=1):
        if x is None:
            return ""
        return f"{x:.{nd}f}" if isinstance(x, float) else str(x)

    mem = s.get("mem") or {}
    total_kb, avail_kb = mem.get("MemTotal") or 0, mem.get("MemAvailable")
    ram_used_pct = 100.0 * (1 - avail_kb / total_kb) if (avail_kb and total_kb) else None
    gc = s.get("gc")                        # (used, pct, maj_pct, maj_used, pause)
    net = s.get("net") or {}
    gnet = s.get("game_net") or {}
    players, maxp = s.get("players"), s.get("max_players")
    pps, maxpps = net.get("pps"), s.get("max_pps")
    cores = s.get("cpu_cores")
    cpu_sys = sum(cores) / len(cores) if cores else None
    temps = s.get("temps") or {}
    disk = s.get("disk")
    disk_free_pct = 100.0 * disk.free / disk.total if disk and disk.total else None
    return [
        datetime.now().replace(microsecond=0).isoformat(),
        f(s.get("uptime"), 0),
        f(players), f(maxp),
        f(100.0 * players / maxp) if players is not None and maxp else "",
        f(pps, 0), f(maxpps),
        f(100.0 * pps / maxpps) if pps is not None and maxpps else "",
        f(net.get("rx_kbs")), f(net.get("tx_kbs")),
        f(gc[0]) if gc else "", f(gc[1]) if gc and gc[1] is not None else "",
        f(gc[2]) if gc and gc[2] is not None else "",
        f(gc[4], 3) if gc and gc[4] is not None else "",
        f(s["rss_kb"] / 1024, 0) if s.get("rss_kb") else "",
        f(avail_kb / 1024, 0) if avail_kb else "",
        f(ram_used_pct),
        f(s["pswap_kb"] / 1024, 0) if s.get("pswap_kb") is not None else "",
        f(s.get("cpu_pct")), f(cpu_sys),
        f(s["load"][0], 2) if s.get("load") else "",
        f(temps.get("cpu")), f(temps.get("nvme")), f(disk_free_pct),
        f(gnet.get("pps_sent"), 0), f(gnet.get("pps_recv"), 0),
        f(gnet.get("kbs_sent")), f(gnet.get("kbs_recv")),
        f(s.get("srv_fps"), 0), f(s.get("packet_loss"), 3),
        f(s.get("voip_sent"), 0), f(s.get("voip_recv"), 0),
        f(gnet.get("recv_pps_max_client"), 0),
        f(100.0 * gnet["recv_pps_max_client"] / maxpps)
        if gnet.get("recv_pps_max_client") is not None and maxpps else "",
    ]


def _csv_prune():
    """Réécrit le CSV sans les lignes plus vieilles que MONITORING_CSV_DAYS jours."""
    cutoff = datetime.now() - timedelta(days=MONITORING_CSV_DAYS)
    try:
        with open(MONITORING_CSV_PATH, newline="") as fh:
            rows = list(csv.reader(fh))
    except OSError:
        return
    if len(rows) < 2:
        return
    header, kept = rows[0], []
    for row in rows[1:]:
        if not row:
            continue
        try:
            recent = datetime.fromisoformat(row[0]) >= cutoff
        except ValueError:
            recent = True                   # ligne non datable : on la garde
        if recent:
            kept.append(row)
    if len(kept) == len(rows) - 1:
        return
    tmp = MONITORING_CSV_PATH + ".tmp"
    try:
        with open(tmp, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(header)
            w.writerows(kept)
        os.replace(tmp, MONITORING_CSV_PATH)
    except OSError as e:
        log.warning("Monitoring CSV : purge échouée (%s)", e)


def _csv_log(s: dict):
    """Ajoute une ligne au CSV (crée l'entête au 1er passage) puis purge ~1×/h."""
    global _last_csv_prune
    if not MONITORING_CSV_PATH:
        return
    try:
        fresh = not os.path.exists(MONITORING_CSV_PATH)
        with open(MONITORING_CSV_PATH, "a", newline="") as fh:
            w = csv.writer(fh)
            if fresh:
                w.writerow(_CSV_HEADER)
            w.writerow(_csv_row(s))
    except OSError as e:
        log.warning("Monitoring CSV : écriture échouée (%s)", e)
        return
    now = time.time()
    if now - _last_csv_prune > 3600:
        _last_csv_prune = now
        _csv_prune()


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
    # Amorce le delta CPU sans poster — dans un thread, comme les cycles suivants.
    await asyncio.get_running_loop().run_in_executor(None, collect_stats, prev)
    await asyncio.sleep(min(MONITORING_INTERVAL, 5))
    while not bot.is_closed():
        try:
            # Exécuté dans un thread : collect_stats fait de l'I/O BLOQUANTE
            # (urlopen sur l'exporteur avec timeout 4 s, scan complet de /proc,
            # lecture de gc.log, et une réécriture intégrale du CSV une fois par
            # heure). Sur la boucle, tout le bot gelait pendant ce temps —
            # commandes slash, batch et heartbeat Discord compris — précisément
            # quand l'exporteur ne répond plus, c'est-à-dire pendant un gel du
            # serveur : le moment où un admin tape justement /pzm server restart.
            loop = asyncio.get_running_loop()
            s = await loop.run_in_executor(None, collect_stats, prev)
            await loop.run_in_executor(None, _csv_log, s)
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
    if MONITORING_CHANNEL_ID is not None:
        bot.loop.create_task(monitoring_loop())
    else:
        log.info("Monitoring désactivé (DISCORD_BOT_MONITORING_CHANNEL_ID vide)")


@bot.event
async def on_ready():
    log.info("Connecté en tant que %s | salons=%s roles=%s",
             bot.user, ALLOWED_CHANNELS or "AUCUN", ROLE_IDS or "AUCUN")


@bot.event
async def on_message(message: discord.Message):
    """Batch : un membre admin colle plusieurs `pzm …` dans un salon autorisé."""
    if message.author.bot or message.guild is None:
        return
    if not ALLOWED_CHANNELS or not ROLE_IDS:
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
        raise SystemExit("DISCORD_BOT_TOKEN manquant (voir .env)")
    if not PZ_MANAGER_DIR or not os.path.isfile(PZM):
        raise SystemExit(f"Dispatcher pzm introuvable: {PZM}")
    bot.run(TOKEN, log_handler=None)


if __name__ == "__main__":
    main()
