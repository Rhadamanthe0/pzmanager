# Documentation index

`docs/` is the **single source of truth** for how PZManager works.

Each topic has **exactly one owning document**. Before writing anything, find its
owner below and add it there. If a second document needs the same fact, it links —
it does not restate. Two copies of one fact drift apart, and nothing then says
which one is stale.

[AGENTS.md](../AGENTS.md) holds instructions for agents. Keep operator
documentation in this directory.

Run `data/scripts/internal/checkDocsDuplication.sh` after editing documentation.
It checks overlap between documents and also checks a legacy `CLAUDE.md` if one
is present.

## Who owns what

| Document | Owns |
|---|---|
| [QUICKSTART.md](QUICKSTART.md) | Installing from scratch, first start, uninstall |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Code layout, dispatcher → script layers, the `.env` model, the control-FIFO design, the automation timers and what each one does |
| [WHAT_IS_INSTALLED.md](WHAT_IS_INSTALLED.md) | What lands on the machine: packages, dedicated user, sudoers, firewall, the systemd units themselves |
| [USAGE.md](USAGE.md) | Day-to-day operation: server lifecycle and its locks, backups, the SteamID whitelist model, the inactive-access purge |
| [CONFIGURATION.md](CONFIGURATION.md) | `.env` reference — every key, its default and its effect |
| [SERVER_CONFIG.md](SERVER_CONFIG.md) | Project Zomboid's own settings (`servertest.ini`, sandbox vars), ports |
| [ADVANCED.md](ADVANCED.md) | JVM and heap tuning, GraalVM, the memory-driven restart, live-JVM diagnostics, map-area wipe mechanics, full world reset |
| [MOD_UPDATES.md](MOD_UPDATES.md) | The mod-list procedure, the version ledger, load order and `Map=` precedence, map mods, Workshop pitfalls |
| [DISCORD_BOT.md](DISCORD_BOT.md) | The inbound command bot, batch mode, its security model, health monitoring and the Prometheus exporter |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Symptom → diagnosis, for failures that are not covered by a topic doc |
| [HOST_ENVIRONMENT.md](HOST_ENVIRONMENT.md) | **This machine, not the software**: RAM budget, hard freezes and the watchdog, networking (owned by `infra-deploy`), Wake-on-LAN |
| [INCIDENTS.md](INCIDENTS.md) | Post-mortems — beliefs that turned out to be wrong, and the evidence that corrected them |
| [PROCEDURE_JOUEURS.md](PROCEDURE_JOUEURS.md) | Player-facing connection guide (French) |

## Boundaries that are easy to get wrong

- **ARCHITECTURE vs WHAT_IS_INSTALLED** — ARCHITECTURE describes *the code*
  (which script does what, why the FIFO). WHAT_IS_INSTALLED describes *the
  machine state* (unit files, packages, firewall rules).
- **ADVANCED vs HOST_ENVIRONMENT** — ADVANCED holds the general rule (`-Xmx` at
  half of RAM, and why). HOST_ENVIRONMENT holds *this box's* numbers and the
  deliberate exception to that rule.
- **HOST_ENVIRONMENT vs INCIDENTS** — HOST_ENVIRONMENT states what is true now.
  INCIDENTS records how a past belief was disproved. A fact that is still
  actionable belongs in the former; the story belongs in the latter.
- **MOD_UPDATES vs ADVANCED** — the *wipe mechanics* (grid, snapshot, what gets
  deleted) are in ADVANCED. Everything about *choosing and verifying map mods*
  is in MOD_UPDATES.
