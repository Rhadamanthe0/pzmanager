# Discord Command Bot

Run `pzm` commands from Discord with the `/pzm …` slash commands.

This is the **inbound** counterpart to the outbound `DISCORD_WEBHOOK`
notifications: a small Python bot (discord.py) connects to Discord's Gateway
(outbound only — no port to open) and runs `pzm` on your behalf. It is
**optional** and disabled until you configure it.

- [How it works](#how-it-works)
- [Setup](#setup)
- [Commands](#commands)
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

## Setup

### 1. Create the Discord application + bot

1. Go to <https://discord.com/developers/applications> → **New Application**.
2. **Bot** tab → **Reset Token** → copy the token (shown once). This is your
   `DISCORD_BOT_TOKEN`.
3. Still on the **Bot** tab, leave **Message Content** and **Server Members**
   *Privileged Intents* **OFF** — the bot does not need them.
4. Invite the bot with both the `bot` and `applications.commands` scopes and
   the *View Channels* + *Send Messages* permissions. Quick link (replace
   `CLIENT_ID` with your Application ID):
   ```
   https://discord.com/oauth2/authorize?client_id=CLIENT_ID&scope=bot%20applications.commands&permissions=3072
   ```

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

## Security

- **Two gates, both required**: the bot only obeys messages **in an allowed
  channel** *and* **from a member holding the admin role**. Everything else
  gets an ephemeral "not authorized" reply and nothing runs.
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
- **Service keeps restarting**: usually an empty/invalid `DISCORD_BOT_TOKEN` —
  check `journalctl --user -u pz-discord-bot.service`.
- **Commands rejected**: confirm you are in `DISCORD_BOT_CHANNEL_ID` and hold
  `DISCORD_BOT_ADMIN_ROLE_ID`; both are logged on refusal.
- **`python3-venv missing`** at install: `sudo apt install python3-venv` (root).
