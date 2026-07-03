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
  PZ_MANAGER_DIR             Racine pzmanager (contient le dispatcher `pzm`)

Sécurité : chaque sous-commande construit un argv fixe passé à `pzm` via
create_subprocess_exec (jamais shell=True). Aucune injection shell possible ;
seul `pzm` peut être invoqué.
"""

import asyncio
import functools
import io
import logging
import os
import shlex
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
KNOWN_CMDS = {"server", "backup", "whitelist", "admin", "install",
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


async def deliver(send, header: str, output: str):
    """Envoie statut + sortie en UN SEUL message via le callable `send`.
    Si tout tient dans un bloc de code -> inline ; sinon -> pièce jointe
    pzm-output.txt (Discord ne fait pas ce repli automatiquement via l'API)."""
    output = output.rstrip() or "(aucune sortie)"
    inline_limit = DISCORD_MAX - len(header) - len("\n```\n\n```") - 1
    if len(output) <= inline_limit:
        await send(f"{header}\n```\n{output}\n```")
    else:
        file = discord.File(io.BytesIO(output.encode("utf-8")), filename="pzm-output.txt")
        await send(header, file=file)


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

    header = f"✅ `{label}`" if code == 0 else f"❌ `{label}` (exit={code})"
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


async def reject_batch(message: discord.Message, bad: list[tuple[int, str]]):
    """Commande(s) collée(s) non reconnue(s) : supprime le message source, indique
    la/les ligne(s) fautive(s) et joint `pzm help` en pièce jointe. Rien n'est exécuté."""
    channel = message.channel
    author = message.author
    log.info("REJET batch user=%s channel=%s bad=%r",
             author, channel.id, [n for n, _ in bad])

    note = ""
    try:
        await message.delete()
    except discord.Forbidden:
        note = " (⚠️ permission « Gérer les messages » manquante : message non supprimé)"
    except discord.NotFound:
        pass

    detail = "\n".join(f"{n}. {txt}" for n, txt in bad)
    header = (f"⛔ Commande non reconnue ({author.mention}){note} — rien n'a été exécuté.\n"
              f"Ligne(s) invalide(s) (attendu `pzm <commande> …`) :\n```\n{detail}\n```\n"
              f"Voir l'aide `pzm help` en pièce jointe.")
    if len(header) > DISCORD_MAX:
        header = header[:DISCORD_MAX - 1] + "…"
    _, help_out = await run_pzm(["help"])
    file = discord.File(io.BytesIO((help_out.rstrip() or "(aucune sortie)").encode("utf-8")),
                        filename="pzm-help.txt")
    await channel.send(header, file=file)


async def run_batch(message: discord.Message, batch: list[list[str]]):
    """Exécute séquentiellement chaque commande, supprime le message source et
    poste un récap unique (inline, ou en pièce jointe si trop long)."""
    channel = message.channel
    author = message.author
    n = len(batch)
    log.info("EXEC BATCH user=%s channel=%s n=%d", author, channel.id, n)

    note = ""
    try:
        await message.delete()
    except discord.Forbidden:
        note = " (⚠️ permission « Gérer les messages » manquante : message non supprimé)"
    except discord.NotFound:
        pass

    # Si un pzm tourne déjà, on met en file d'attente (lock FIFO) au lieu de refuser :
    # le statut l'indique puis bascule sur « en cours… » quand c'est son tour.
    running = f"▶️ Lot de {n} commande(s) en cours… (demandé par {author.mention}){note}"
    queued = run_lock.locked()
    status = await channel.send(
        f"⏳ Lot de {n} commande(s) en file d'attente… (demandé par {author.mention}){note}"
        if queued else running)

    results = []
    async with run_lock:
        if queued:
            try:
                await status.edit(content=running)
            except discord.HTTPException:
                pass
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
    try:
        await deliver(channel.send, header, "\n".join(lines))
    finally:
        try:
            await status.delete()
        except discord.HTTPException:
            pass


# --- Commandes ---------------------------------------------------------------
# Groupe /pzm calqué sur le dispatcher : chaque sous-commande construit un argv
# fixe puis délègue à execute(). Les délais sont des menus déroulants (Literal).

Delay = Literal["30m", "15m", "5m", "2m", "30s", "now"]

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
@app_commands.describe(delai="Délai avant arrêt (défaut 2m)", reason="Raison affichée aux joueurs")
async def server_stop(interaction: discord.Interaction, delai: Optional[Delay] = None,
                      reason: Optional[str] = None):
    await _run_delayed(interaction, ["server", "stop"], delai, reason)


@server_group.command(name="restart", description="Redémarrer le serveur")
@app_commands.describe(delai="Délai avant redémarrage (défaut 2m)", reason="Raison affichée aux joueurs")
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
    await run_batch(message, batch)


def main():
    if not TOKEN:
        raise SystemExit("DISCORD_BOT_TOKEN manquant (voir scripts/.env)")
    if not PZ_MANAGER_DIR or not os.path.isfile(PZM):
        raise SystemExit(f"Dispatcher pzm introuvable: {PZM}")
    bot.run(TOKEN, log_handler=None)


if __name__ == "__main__":
    main()
