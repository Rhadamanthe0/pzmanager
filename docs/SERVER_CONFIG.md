# Project Zomboid Server Configuration

Configuration of game server parameters.

## Table of Contents

- [Official Documentation](#official-documentation)
- [pzmanager Specifics](#pzmanager-specifics)
  - [Configuration Files](#configuration-files)
  - [Apply Changes](#apply-changes)
  - [Options Present in Both Files](#options-present-in-both-files)
  - [Important Parameters](#important-parameters)
  - [Whitelist Management](#whitelist-management)
  - [Mods](#mods)
  - [Network Ports](#network-ports)
- [Resources](#resources)

## Official Documentation

For complete Project Zomboid server configuration:
- [Server Settings](https://pzwiki.net/wiki/Server_Settings)
- [Sandbox Variables](https://pzwiki.net/wiki/Sandbox)
- [Dedicated Server Guide](https://pzwiki.net/wiki/Dedicated_Server)

## pzmanager Specifics

### Configuration Files

**Location**: `~/pzmanager/Zomboid/Server/`

Main files:
- `servertest.ini` - Server configuration (name, ports, players, etc.)
- `servertest_SandboxVars.lua` - Game rules (zombies, difficulty, loot)
- `servertest_access.txt` - Admin list (Steam64 IDs)

### Apply Changes

```bash
# After modification, restart with player warning
pzm server restart 5m
```

### Options Present in Both Files

One option name exists in **both** `servertest.ini` (as a server option) and
`servertest_SandboxVars.lua` (as a sandbox option): `BloodSplatLifespanDays`.

**The sandbox value wins — the `.ini` copy is dead config.** The removal code
(`IsoObject`, `IsoChunk`) reads `SandboxOptions.bloodSplatLifespanDays`, and
`ServerOptions` never references `SandboxOptions`, so nothing propagates the
`.ini` value into the sandbox. The `.ini` entry is a B41 leftover the B42 server
parses and ignores.

Keep the two values identical anyway, so a future reader is not misled. Do not
just delete the `.ini` line: the server rewrites `servertest.ini` in full at
boot and the key would come back at its server-option default (`0` = blood never
disappears), which reads as an even more misleading value. Custom comments added
to the `.ini` are wiped by that same rewrite.

Checked on build 42.20.4: this is the only name shared by the two files, every
key in our `.ini` is a valid server option, and our sandbox file carries every
vanilla var of its `VERSION` (6).

### Important Parameters

```ini
# servertest.ini
ServerName=MyServer           # Internal name
PublicName=My Public Name     # Browser display name
Password=                     # Password (empty = public)
AdminPassword=CHANGEME        # RCON password (⚠️ CHANGE IT!)
MaxPlayers=32                # Maximum players
PauseEmpty=true              # Pause if empty (saves CPU)
SaveWorldEveryMinutes=30     # Auto-save frequency
```

⚠️ **Security**: Always change `AdminPassword`!

### Whitelist Management

**Dedicated script**: `manageWhitelist.sh`

Manage users authorized to connect to the server.

**Admin user**: Created automatically during installation with a random password. Never deleted by purge.

**View whitelist**:
```bash
pzm whitelist list
```

**Add player** (SteamID64 first, name optional):
```bash
pzm whitelist add "76561198012345678" "PlayerName"
```

**Remove player**:
```bash
pzm whitelist remove "PlayerName"
```

**Purge inactive accounts**:
```bash
pzm whitelist purge              # Default: WHITELIST_PURGE_DAYS (90j)
pzm whitelist purge 3m           # List inactive 3+ months
pzm whitelist purge 3m --delete  # Delete after confirmation
```

**Notes**:
- Steam ID 64 required for add: 17 digits, starts with `7656119...`
- Find Steam ID via [steamid.xyz](https://steamid.xyz/)
- Each username must be unique
- Max 2 accounts per Steam ID
- Purge delay: Xm (months) or Xd (days), default in .env
- Purge exclut toujours l'utilisateur `admin`
- Changes applied immediately (no restart needed)

### Mods

Two lines drive the mod list — `Mods=` holds Mod IDs **in load order**,
`WorkshopItems=` holds the matching Workshop IDs:

```ini
Mods=modname1;modname2
WorkshopItems=2992700364;111111111
```

Do not edit them ad hoc. Adding or removing a mod without pre-downloading it
puts the server in a boot crash-loop: follow
**[MOD_UPDATES.md](MOD_UPDATES.md)**, which covers resolving Mod IDs and
dependencies, load order, pre-download, deploy, verification and rollback.

### Network Ports

Default ports (automatically configured by pzmanager):
- **16261/UDP** - Main game
- **16262/UDP** - Secondary game

These are the only two ports PZ B42 listens on, and the only two `setupSystem.sh`
opens. The old 8766 (RCON) and 27015 (Steam query) entries were B41 leftovers: no
socket uses them in B42, so they are deliberately left closed.

Modification (only if conflict):
```ini
# servertest.ini
DefaultPort=16261
UDPPort=16262
```

⚠️ Modification requires reconfiguring firewall manually

## Resources

- [CONFIGURATION.md](CONFIGURATION.md) - .env variables, backups, Discord
- [ADVANCED.md](ADVANCED.md) - Performance, RCON, optimizations
- [Official PZ Documentation](https://pzwiki.net/wiki/Dedicated_Server)
