# Discord Command Bot

Run `pzm` commands from Discord with the `/pzm …` slash commands.

This is the **inbound** counterpart to the outbound `DISCORD_WEBHOOK`
notifications: a small Python bot (discord.py) connects to Discord's Gateway
(outbound only — no port to open) and runs `pzm` on your behalf. It is
**optional** and disabled until you configure it.

- [How it works](#how-it-works)
- [Setup](#setup)
- [Commands](#commands)
- [Batch: run several commands at once](#batch-run-several-commands-at-once)
- [Death & PvP notifications](#death--pvp-notifications)
- [Security](#security)
- [Managing the service](#managing-the-service)
- [Troubleshooting](#troubleshooting)

## How it works

- The bot exposes a `/pzm` slash-command **group** that mirrors the `pzm`
  dispatcher (`server`, `backup`, `whitelist`, `admin`, `install` subgroups,
  plus `rcon`, `discord`, `help`).
- Each subcommand builds a **fixed argument list** and runs `pzm` via
  `subprocess` — **never through a shell**, so no command injection is possible
  and *only* `pzm` can ever be invoked.
- It runs as a systemd **user** service (`pz-discord-bot.service`) that
  auto-restarts, exactly like the other pzmanager units.
- The bot waits for each command to finish (rcon included) and returns the
  output as **one message** — inline in a code block, or as a
  `pzm-output.txt` attachment when it is too long for one message.
- **Batch**: paste several `pzm …` lines in one message and the bot runs them
  one after another, deletes your message, and posts a single recap — see
  [Batch](#batch-run-several-commands-at-once).

## Setup

### 1. Create the Discord application + bot

1. Go to <https://discord.com/developers/applications> → **New Application**.
2. **Bot** tab → **Reset Token** → copy the token (shown once). This is your
   `DISCORD_BOT_TOKEN`.
3. Still on the **Bot** tab, enable the **Message Content** *Privileged Intent*
   (**required** — it lets the bot read the multi-line command blocks you paste,
   see [Batch](#batch-run-several-commands-at-once)). Leave **Server Members**
   **OFF** — the bot does not need it. Under 100 servers this toggle needs no
   verification.
4. Invite the bot with both the `bot` and `applications.commands` scopes and the
   *View Channels* + *Send Messages* + *Attach Files* + *Manage Messages*
   permissions (*Attach Files* lets it post long command output as a
   `pzm-output.txt` attachment; *Manage Messages* lets it delete the source
   message after running a batch). Quick link (replace `CLIENT_ID` with your
   Application ID):
   ```
   https://discord.com/oauth2/authorize?client_id=CLIENT_ID&scope=bot%20applications.commands&permissions=44032
   ```

> **Upgrading an existing bot** to the batch feature: enable the **Message
> Content** intent (step 3) **before** restarting the service, or it will crash
> on boot with `PrivilegedIntentsRequired`. Re-run the invite link above to grant
> *Manage Messages* (needed to delete the source message).

### 2. Collect the IDs

Enable **Developer Mode** (Discord *Settings → Advanced*), then right-click to
**Copy ID**:

| Variable | Where |
|----------|-------|
| `DISCORD_BOT_GUILD_ID` | Right-click the server icon → *Copy Server ID* |
| `DISCORD_BOT_CHANNEL_ID` | Right-click the dedicated channel → *Copy Channel ID* (comma-separated for several) |
| `DISCORD_BOT_ADMIN_ROLE_ID` | Server Settings → Roles → right-click the role → *Copy Role ID* |

### 3. Configure `scripts/.env`

```bash
export DISCORD_BOT_TOKEN="<bot token>"
export DISCORD_BOT_GUILD_ID="<server id>"
export DISCORD_BOT_CHANNEL_ID="<channel id>"      # comma-separated for several
export DISCORD_BOT_ADMIN_ROLE_ID="<role id>"
export DISCORD_BOT_CMD_TIMEOUT=2400               # per-command timeout (seconds)
export DISCORD_BOT_DEATH_CHANNEL_ID="<channel id>"  # optional — death/PvP feed (empty = off)
```

### 4. Install

```bash
pzm install discord
```

This creates the Python venv (`scripts/discord/.venv`), installs `discord.py`,
and enables/starts `pz-discord-bot.service`. It requires the `python3-venv`
package (already part of `pzm install system`; if missing, run
`sudo apt install python3-venv` as root).

In Discord, refresh the client (**Ctrl+R**) and type `/pzm` in the channel.

## Commands

Guild-scoped, so they appear almost instantly:

```
/pzm server start | status | stop [delai] [reason] | restart [delai] [reason]
/pzm backup create | full | list | restore <chemin> | restore-character <pseudo> <backup>
/pzm whitelist list | add <id64> [nom] | remove <cible> [ban] | resetpassword <nom> | purge [duree] [delete]
/pzm admin maintenance [delai] [reason] | reset [keep_config] [keep_whitelist]
/pzm install system | zomboid | discord
/pzm rcon <commande>
/pzm discord <message>
/pzm help
```

- `delai` is a dropdown: `30m` / `15m` / `5m` / `2m` / `30s` / `now`.
- Flags (`ban`, `delete`, `keep_config`, `keep_whitelist`) are `True`/`False`
  options.

## Batch: run several commands at once

Slash commands are one-at-a-time. To run **many** commands, just **paste a plain
message** (no slash) in the allowed channel, one `pzm …` per line:

```
pzm rcon additem "Marc Riviere" "Base.Hat_GasMask" 1
pzm rcon additem "Marc Riviere" "Base.AssaultRifle" 1
pzm rcon additem "Marc Riviere" "Base.556Box" 1
```

The bot:

1. Runs each line **in order** (same lock as the slash commands — they never
   interleave), continuing even if one line fails. If another pzm command is
   already running, the batch is **queued** (FIFO) and starts when its turn
   comes — the status message shows "en file d'attente…" until then.
2. **Deletes your source message** to keep the channel clean.
3. Posts **one recap** — `✅ Lot pzm : 3/3 OK`, or the per-line ✅/❌ with the
   output of any failing line (as a `pzm-output.txt` attachment if it is long).

If the pasted message holds a **single** `pzm …` line, it is treated like a
normal command instead of a batch: the source message is still deleted, but the
bot posts the command's **full output** (same rendering as the slash commands),
not the `1/1 OK` recap.

Rules:

- The `/pzm` and `pzm` prefixes are both accepted; a bare `rcon …` is **not** —
  every line must start with `pzm`/`/pzm` followed by a known command.
- **Blank lines** and lines starting with `#` are ignored (use `#` for comments).
- **All-or-nothing detection**: a message is treated as a batch only if *every*
  content line is a valid `pzm …` command. If one line is a typo (or normal
  chat is mixed in), the **whole batch is rejected** — nothing runs, the source
  message is **deleted**, and the bot posts which line(s) it did not recognise
  with **`pzm help` attached** as `pzm-help.txt`.
- Messages that contain no `pzm` line at all are ignored (normal chat is
  untouched).

## Death & PvP notifications

Optional. Set `DISCORD_BOT_DEATH_CHANNEL_ID` and the bot tails the server logs in
the background and posts an embed to that channel on:

- **☠️ Mort définitive** — a permanent death (from the `*_user.txt` log). The
  embed carries the character name, the account when it can be resolved
  unambiguously, the position, and a best-effort **Cause** (⚔️ PvP combat if a
  matching PvP kill happened shortly before and nearby, else 🧟 environment /
  zombie). Vanilla PZ does **not** log a cause of death, so this is inferred from
  context, never guessed from the (always "non pvp") death flag.
- **⚔️ Incapacité PvP** — a PvP knockdown (from the `*_pvp.txt` log): victim,
  killer, weapon, position. With revive mods a PvP hit is a revivable knockdown,
  not a permanent death, so the two embeds are a two-stage flow.

Notes:

- It is **live-only**: it skips history on boot, handles log rotation, and dedups
  (15 s per character for deaths, 45 s per victim for PvP).
- The bot needs **View Channel + Send Messages + Embed Links** in that channel
  (otherwise it logs `403 Missing Permissions`). Embed Links is not in the
  default command-bot invite, so grant it on the death channel.
- Leave `DISCORD_BOT_DEATH_CHANNEL_ID` empty to disable this feature entirely;
  the command bot works without it.

## Security

- **Two gates, both required**: the bot only obeys commands **in an allowed
  channel** *and* **from a member holding the admin role**. This applies to
  slash commands *and* pasted batches — a non-admin's pasted `pzm …` lines are
  silently ignored (logged, never run or deleted).
- **Every** `pzm` command is reachable, including `admin reset` (world wipe).
  The only protection is the channel + role gate — **keep that role tight**.
- No shell is ever spawned; arguments are passed as an argv list, so text like
  `; rm -rf ~` is handed to `pzm` as literal arguments and rejected.
- `pzm install …` cannot actually run from the bot (it needs interactive
  `sudo`, which is blocked); it returns an error rather than hanging.
- Every invocation is logged (who / which channel / which command / exit code)
  in the journal.

## Managing the service

```bash
systemctl --user status pz-discord-bot.service     # state
systemctl --user restart pz-discord-bot.service    # after editing scripts/.env
journalctl --user -u pz-discord-bot.service -f      # live logs
```

## Troubleshooting

- **`/pzm` doesn't appear**: refresh Discord (Ctrl+R) or restart the client;
  check the bot is a member of the server (invited with the `bot` scope) and
  can post in the channel.
- **Service keeps restarting**: usually an empty/invalid `DISCORD_BOT_TOKEN`, or
  `PrivilegedIntentsRequired` because the **Message Content** intent is not
  enabled in the Developer Portal (see [Setup](#setup) step 3) — check
  `journalctl --user -u pz-discord-bot.service`.
- **Long output missing / `pzm help` posts nothing**: the bot lacks the *Attach
  Files* permission, so it cannot post the `pzm-output.txt` attachment. It now
  falls back to splitting the output across several code-block messages, but for
  the cleaner single-file behaviour grant *Attach Files* (channel permissions, or
  re-run the invite link with `permissions=44032`).
- **Batch not running / message not deleted**: confirm the bot has the *Manage
  Messages* permission in the channel (re-run the invite link with
  `permissions=44032`); a missing permission is reported in the recap.
- **Commands rejected**: confirm you are in `DISCORD_BOT_CHANNEL_ID` and hold
  `DISCORD_BOT_ADMIN_ROLE_ID`; both are logged on refusal.
- **`python3-venv missing`** at install: `sudo apt install python3-venv` (root).
