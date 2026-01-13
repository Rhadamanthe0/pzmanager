# Ce Qui Est Installé et Configuré

Documentation exhaustive de tous les changements effectués par pzmanager sur le système.

## Philosophie du Projet

**pzmanager** est conçu pour être **out-of-the-box** : installation en une commande avec configuration optimale et sécurisée par défaut.

**Objectifs** :
- ✅ **Zéro configuration manuelle** : Tout fonctionne immédiatement après installation
- ✅ **Sécurité par défaut** : Firewall, utilisateur dédié, permissions minimales
- ✅ **Automatisations** : Backups, maintenance, mises à jour automatiques
- ✅ **Simplicité** : Interface CLI unifiée, commandes intuitives
- ✅ **Pour néophytes** : Aucune expertise système requise

Ce document détaille **tout** ce qui est modifié sur votre système pour garantir transparence et confiance.

## Table des matières

- [Packages Système](#packages-système)
- [Utilisateur et Permissions](#utilisateur-et-permissions)
- [Configuration Réseau](#configuration-réseau)
- [Project Zomboid](#project-zomboid)
- [Services Systemd](#services-systemd)
- [Automatisations](#automatisations)
- [Structure Fichiers](#structure-fichiers)

---

## Packages Système

### Installés par setupSystem.sh

**Packages de base** :
- `rsync` : Backups incrémentiaux avec hard links
- `unzip` : Décompression archives
- `ufw` : Firewall simplifié

**Installés par configurationInitiale.sh** :

**Architecture 32-bit** (requis par SteamCMD) :
- `dpkg --add-architecture i386`
- `lib32gcc-s1`
- `lib32stdc++6`

**SteamCMD et dépendances** :
- `steamcmd`
- `ca-certificates`
- `software-properties-common`
- `apt-transport-https`
- `dirmngr`
- `curl`
- `wget`

**Java** (version configurable via `.env`) :
- `openjdk-25-jre-headless` (par défaut)
- OU `openjdk-17-jre-headless`
- OU `openjdk-21-jre-headless`

**Emplacement** : `/usr/lib/jvm/java-25-openjdk-amd64` (selon version)

---

## Utilisateur et Permissions

### Utilisateur pzuser

**Créé par** : `setupSystem.sh`

**Propriétés** :
- Home : `/home/pzuser/`
- Shell : `/bin/bash`
- Groupes : `pzuser` (groupe primaire)

### Permissions sudo

**Fichier** : `/etc/sudoers.d/pzuser`

**Commandes autorisées** (NOPASSWD) :

**APT (gestion packages)** :
```
/usr/bin/apt-get update
/usr/bin/apt-get upgrade
/usr/bin/apt-get install openjdk-*-jre-headless
/usr/bin/apt-get autoremove
/usr/bin/apt-get autoclean
```

**Java (symlink)** :
```
/usr/bin/rm -rf /home/pzuser/pzmanager/data/pzserver/jre64
/usr/bin/ln -s /usr/lib/jvm/java-*-openjdk-amd64 /home/pzuser/pzmanager/data/pzserver/jre64
```

**Backups** :
```
/home/pzuser/pzmanager/scripts/backup/fullBackup.sh
```

**Système** :
```
/sbin/reboot
```

---

## Configuration Réseau

### Firewall (UFW)

**Configuré par** : `setupSystem.sh`

**Règles par défaut** :
- Incoming : DENY
- Outgoing : ALLOW

**Ports ouverts** :

| Port | Protocole | Usage |
|------|-----------|-------|
| 22/TCP | SSH | Administration serveur |
| 16261/UDP | Jeu | Port principal Project Zomboid |
| 16262/UDP | Jeu | Port secondaire Project Zomboid |
| 8766/UDP | RCON | Commandes administratives |
| 27015/TCP | Steam | Steam query port |

**Vérifier** : `sudo ufw status`

---

## Project Zomboid

### Serveur

**Installé par** : `configurationInitiale.sh zomboid`

**Version** : Build 41.78.7 (branche `legacy_41_78_7`)

**Méthode installation** :
```bash
/usr/games/steamcmd +login anonymous \
    +force_install_dir /home/pzuser/pzmanager/data/pzserver \
    +app_update 380870 -beta legacy_41_78_7 validate \
    +quit
```

**Emplacement** : `/home/pzuser/pzmanager/data/pzserver/`

**Taille** : ~1-2GB

### Configuration JVM

**Fichier** : `/home/pzuser/pzmanager/data/pzserver/ProjectZomboid64.json`

**Paramètres appliqués automatiquement** :

```json
{
  "vmArgs": [
    "-Djava.awt.headless=true",
    "-Xmx8g",
    "-Dzomboid.steam=1",
    "-Dzomboid.znetlog=1",
    "-Djava.library.path=linux64/:natives/",
    "-Djava.security.egd=file:/dev/urandom",
    "-XX:+UseZGC",
    "-XX:-OmitStackTraceInFastThrow"
  ]
}
```

**Optimisations** :
- **RAM** : 8GB par défaut (`-Xmx8g`)
- **ZGC** : Garbage Collector moderne (`-XX:+UseZGC`)
- **Headless** : Pas d'interface graphique
- **Steam** : Intégration Steam activée

**Modifier RAM** : `pzm config ram <valeur>`

### Données Serveur

**Emplacement** : `/home/pzuser/pzmanager/Zomboid/`

**Structure** :
```
Zomboid/
├── Server/
│   ├── servertest.ini          # Configuration serveur
│   ├── servertest_access.txt   # Admins
│   ├── servertest_SandboxVars.lua  # Paramètres gameplay
│   └── servertest_spawnregions.lua
├── Saves/
│   └── Multiplayer/
│       └── servertest/         # Sauvegardes mondes
├── db/
│   └── servertest.db           # Base SQLite (whitelist, bans)
├── Logs/
└── mods/
```

**Taille typique** : 500MB - 5GB (selon utilisation)

---

## Services Systemd

**Installation** : Les services systemd sont automatiquement installés depuis les templates dans `data/setupTemplates/` lors de l'installation du serveur.

### Service zomboid.service

**Type** : Service utilisateur (systemd user)

**Fichier template** : `~/pzmanager/data/setupTemplates/zomboid.service`
**Fichier installé** : `~/.config/systemd/user/zomboid.service`

**Configuration** :
```ini
[Unit]
Description=Project Zomboid Server
After=network.target zomboid.socket
Requires=zomboid.socket
Wants=zomboid_logger.service

[Service]
Type=simple
PrivateTmp=true
WorkingDirectory=/home/pzuser/pzmanager/data/pzserver/
ExecStart=/bin/sh -c "exec /home/pzuser/pzmanager/data/pzserver/start-server.sh -cachedir=/home/pzuser/pzmanager/Zomboid <> /home/pzuser/pzmanager/data/pzserver/zomboid.control"
ExecStartPost=-/bin/sh -c "/home/pzuser/pzmanager/scripts/internal/notifyServerReady.sh &"
ExecStop=/bin/sh -c "echo 'quit' > /home/pzuser/pzmanager/data/pzserver/zomboid.control"
KillSignal=SIGCONT
TimeoutStopSec=30

[Install]
WantedBy=default.target
```

**Fonctionnalités** :
- Démarrage automatique au boot
- Utilise un socket systemd pour le control pipe
- Notification Discord au démarrage (via notifyServerReady.sh)
- Logger dédié (zomboid_logger.service)
- Arrêt propre via commande 'quit'

**Commandes** :
```bash
systemctl --user status zomboid.service
systemctl --user start zomboid.service
systemctl --user stop zomboid.service
systemctl --user restart zomboid.service
```

### Socket zomboid.socket

**Type** : Socket systemd pour control pipe

**Fichier template** : `~/pzmanager/data/setupTemplates/zomboid.socket`
**Fichier installé** : `~/.config/systemd/user/zomboid.socket`

**Configuration** :
```ini
[Unit]
Description=Project Zomboid Server Control Socket
PartOf=zomboid.service
Before=zomboid.service

[Socket]
ListenFIFO=/home/pzuser/pzmanager/data/pzserver/zomboid.control
FileDescriptorName=control
SocketMode=0660
SocketUser=pzuser
ExecStartPre=/bin/rm -f /home/pzuser/pzmanager/data/pzserver/zomboid.control
RemoveOnStop=true
```

**Fonction** : Gère le FIFO (named pipe) utilisé pour envoyer des commandes au serveur via RCON.

### Service zomboid_logger.service

**Type** : Service de capture de logs

**Fichier template** : `~/pzmanager/data/setupTemplates/zomboid_logger.service`
**Fichier installé** : `~/.config/systemd/user/zomboid_logger.service`

**Configuration** :
```ini
[Unit]
Description=Logger pour Project Zomboid
PartOf=zomboid.service
After=zomboid.service

[Service]
Type=simple
ExecStart=/home/pzuser/pzmanager/scripts/internal/captureLogs.sh
Restart=always
RestartSec=5
```

**Fonction** : Capture les logs du serveur depuis journald et les sauvegarde dans des fichiers horodatés.

### Systemd Lingering

**Activé pour** : `pzuser`

**Effet** : Services utilisateur démarrent au boot, même si pzuser non connecté

**Commande** : `loginctl enable-linger pzuser`

**Vérifier** : `ls /var/lib/systemd/linger/` (doit contenir `pzuser`)

---

## Automatisations

### Crontab pzuser

**Fichier source** : `/home/pzuser/pzmanager/data/setupTemplates/pzuser-crontab`

**Tâches configurées** :

#### Backup horaire (tous les jours à :14)
```cron
14 * * * *  /bin/bash  /home/pzuser/pzmanager/scripts/backup/dataBackup.sh >> /home/pzuser/pzmanager/scripts/logs/data_backup.log 2>&1
```

**Fonction** :
- Backup incrémental avec hard links
- Rétention : 14 jours (configurable via `.env`)
- Destination : `/home/pzuser/pzmanager/data/dataBackups/`

#### Maintenance quotidienne (4h30 du matin)
```cron
30 4 * * *  /bin/bash  /home/pzuser/pzmanager/scripts/admin/performFullMaintenance.sh
```

**Étapes** :
1. Arrêt serveur avec avertissements (30min défaut)
2. Rotation backups (suppression > 14 jours)
3. Mise à jour système (`apt upgrade`)
4. Mise à jour Java
5. Mise à jour serveur PZ (SteamCMD)
6. Restauration symlink Java
7. Backup complet externe
8. Reboot système

**Logs** : `/home/pzuser/pzmanager/scripts/logs/maintenance/`

**Vérifier crontab** : `crontab -l`

---

## Structure Fichiers

### Arborescence complète

```
/home/pzuser/pzmanager/
├── Zomboid/                          # Données serveur PZ
│   ├── Server/                       # Config serveur
│   │   ├── servertest.ini
│   │   ├── servertest_access.txt
│   │   ├── servertest_SandboxVars.lua
│   │   └── servertest_spawnregions.lua
│   ├── Saves/Multiplayer/servertest/ # Sauvegardes mondes
│   ├── db/servertest.db              # Base SQLite
│   ├── Logs/
│   └── mods/
│
├── scripts/
│   ├── .env.example                  # Template variables
│   ├── .env                          # Variables config (créé auto)
│   ├── pzm                           # Interface CLI unifiée
│   │
│   ├── core/
│   │   └── pz.sh                     # Gestion serveur (start/stop/restart/status)
│   │
│   ├── backup/
│   │   ├── dataBackup.sh             # Backup horaire incrémental
│   │   ├── fullBackup.sh             # Backup complet avec sync externe
│   │   └── restoreZomboidData.sh     # Restauration données uniquement
│   │
│   ├── admin/
│   │   ├── manageWhitelist.sh        # Gestion whitelist SQLite
│   │   ├── resetServer.sh            # Reset complet serveur
│   │   ├── setram.sh                 # Configuration RAM serveur
│   │   └── performFullMaintenance.sh # Maintenance automatique
│   │
│   ├── install/
│   │   ├── setupSystem.sh            # Config système (user, firewall, packages)
│   │   └── configurationInitiale.sh  # Install serveur PZ
│   │
│   ├── internal/
│   │   ├── sendCommand.sh            # Envoi commandes RCON
│   │   ├── sendDiscord.sh            # Notifications Discord
│   │   ├── captureLogs.sh            # Capture logs journald
│   │   └── notifyServerReady.sh      # Notification démarrage serveur
│   │
│   └── logs/
│       ├── zomboid/                  # Logs serveur capturés
│       ├── maintenance/              # Logs maintenance
│       └── data_backup.log           # Logs backups horaires
│
├── data/
│   ├── setupTemplates/
│   │   ├── pzuser-crontab            # Crontab à installer
│   │   ├── pzuser-sudoers            # Permissions sudo
│   │   ├── zomboid.service           # Template service systemd
│   │   ├── zomboid.socket            # Template socket systemd
│   │   ├── zomboid_logger.service    # Template logger systemd
│   │   └── .env.example              # Template variables d'environnement
│   │
│   ├── pzserver/                     # Installation serveur PZ (~1-2GB)
│   │   ├── start-server.sh
│   │   ├── ProjectZomboid64.json
│   │   ├── java/
│   │   ├── linux64/
│   │   ├── natives/
│   │   └── jre64 -> /usr/lib/jvm/java-25-openjdk-amd64  (symlink)
│   │
│   ├── dataBackups/                  # Backups horaires (14j rétention)
│   │   ├── backup_2026-01-12_14h14m00s/
│   │   ├── backup_2026-01-12_15h14m00s/
│   │   └── latest -> backup_2026-01-12_15h14m00s  (symlink)
│   │
│   ├── fullBackups/                  # Backups complets horodatés
│   │   └── 2026-01-12_04-30/
│   │
│   └── versionning/                  # Historique versions installées
│       └── pz_version_*.txt
│
├── docs/                             # Documentation
│   ├── QUICKSTART.md
│   ├── INSTALLATION.md
│   ├── CONFIGURATION.md
│   ├── SERVER_CONFIG.md
│   ├── ADVANCED.md
│   ├── TROUBLESHOOTING.md
│   ├── MIGRATION.md
│   └── WHAT_IS_INSTALLED.md          # Ce fichier
│
├── README.md
└── LICENSE
```

### Espace disque utilisé

**Installation minimale** :
- Système : ~100MB (packages)
- Serveur PZ : ~1-2GB
- Java : ~300MB

**Total initial** : ~2-2.5GB

**Utilisation typique après 1 mois** :
- Données serveur : 500MB - 5GB
- Backups horaires : 5-15GB (14 jours)
- Backups complets : 5-10GB par backup
- Logs : 100-500MB

**Total recommandé** : 50-100GB disque libre

---

## Variables d'Environnement

### Fichier .env

**Emplacement** : `/home/pzuser/pzmanager/scripts/.env`

**Créé automatiquement** depuis `.env.example` au premier lancement

**Variables principales** :

#### Utilisateur et Chemins
```bash
PZ_USER="pzuser"
PZ_HOME="/home/pzuser/pzmanager"
PZ_SOURCE_DIR="${PZ_HOME}/Zomboid"
PZ_INSTALL_DIR="${PZ_HOME}/data/pzserver"
```

#### Java
```bash
JAVA_VERSION="25"
JAVA_PACKAGE="openjdk-25-jre-headless"
JAVA_PATH="/usr/lib/jvm/java-25-openjdk-amd64"
PZ_JRE_LINK="${PZ_INSTALL_DIR}/jre64"
```

#### SteamCMD
```bash
STEAMCMD_PATH="/usr/games/steamcmd"
STEAM_APP_ID="380870"
STEAM_BETA_BRANCH="legacy_41_78_7"
```

#### Backups
```bash
BACKUP_DIR="${PZ_HOME}/data/dataBackups"
BACKUP_LATEST_LINK="${BACKUP_DIR}/latest"
BACKUP_RETENTION_DAYS="30"
FULL_BACKUP_DIR="${PZ_HOME}/data/fullBackups"
```

#### Logs
```bash
LOG_ZOMBOID_DIR="${PZ_HOME}/scripts/logs/zomboid"
LOG_MAINTENANCE_DIR="${PZ_HOME}/scripts/logs/maintenance"
LOG_RETENTION_DAYS="30"
```

#### Service
```bash
PZ_SERVICE_NAME="zomboid.service"
```

#### Discord (optionnel)
```bash
DISCORD_WEBHOOK=""  # Vide = désactivé
```

**Modifier** : `nano /home/pzuser/pzmanager/scripts/.env`

---

## Configuration par Défaut

### Serveur Project Zomboid

**Fichier** : `/home/pzuser/pzmanager/Zomboid/Server/servertest.ini`

**Paramètres par défaut (première installation)** :

```ini
# Général
ServerName=servertest
PublicName=My PZ Server
Password=                    # Vide = serveur public
AdminPassword=changeme       # ⚠️ À CHANGER !
MaxPlayers=32

# Gameplay
PauseEmpty=true              # Pause si aucun joueur
Open=true                    # Serveur public
Public=true                  # Visible dans liste serveurs
PublicPort=16261
PublicDescription=

# Sauvegarde
SaveWorldEveryMinutes=20
BackupsCount=5
BackupsOnStart=true
BackupsOnVersionChange=true

# Sécurité
AllowCoop=true
SteamAuthenticationRequired=true
ResetID=0
```

**Documentation complète** : [docs/SERVER_CONFIG.md](SERVER_CONFIG.md)

---

## Modifications Système

### Fichiers créés/modifiés

**Système global** :
- `/etc/sudoers.d/pzuser` (permissions sudo)
- `/var/lib/systemd/linger/pzuser` (systemd lingering)
- `/etc/apt/sources.list.d/steam.list` (dépôt SteamCMD)

**Utilisateur pzuser** :
- `~/.config/systemd/user/zomboid.service` (service)
- Crontab personnel (`crontab -l` pour voir)

**Aucune modification de** :
- Configuration SSH (`/etc/ssh/sshd_config`)
- Configuration réseau (`/etc/network/`)
- Services système globaux

### Sécurité

**Principe** : Isolation maximale via utilisateur dédié

**Restrictions** :
- pzuser ne peut pas `su` vers root
- Commandes sudo limitées strictement (voir sudoers)
- Service tourne en user mode (pas root)
- Pas d'accès aux fichiers système sensibles

**Firewall** : Actif par défaut avec whitelist stricte

---

## Désinstallation

Pour supprimer complètement pzmanager :

```bash
# En tant que root

# 1. Arrêter et désactiver service
sudo -u pzuser systemctl --user stop zomboid.service
sudo -u pzuser systemctl --user disable zomboid.service
loginctl disable-linger pzuser

# 2. Supprimer crontab
sudo -u pzuser crontab -r

# 3. Supprimer fichiers
rm -rf /home/pzuser/pzmanager

# 4. Supprimer utilisateur
userdel -r pzuser

# 5. Supprimer configuration système
rm /etc/sudoers.d/pzuser
rm /var/lib/systemd/linger/pzuser

# 6. (Optionnel) Supprimer packages
apt remove --purge steamcmd openjdk-25-jre-headless
apt autoremove
```

**Note** : Les règles firewall UFW restent actives (à supprimer manuellement si désiré)

---

## Références

- **Installation** : [INSTALLATION.md](INSTALLATION.md)
- **Configuration** : [CONFIGURATION.md](CONFIGURATION.md)
- **Serveur PZ** : [SERVER_CONFIG.md](SERVER_CONFIG.md)
- **Avancé** : [ADVANCED.md](ADVANCED.md)
- **Dépannage** : [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
