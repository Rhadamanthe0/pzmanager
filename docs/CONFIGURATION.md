# Configuration Guide

Configuration des variables d'environnement, backups et Discord.

## Table des matières

- [Fichier .env](#fichier-env)
- [Configuration Backups](#configuration-backups)
- [Intégration Discord](#intégration-discord)
- [Configuration Logs](#configuration-logs)

Pour les paramètres du serveur de jeu, voir [SERVER_CONFIG.md](SERVER_CONFIG.md).
Pour les réglages avancés, voir [ADVANCED.md](ADVANCED.md).

## Fichier .env

**Localisation** : `scripts/.env`

Le fichier .env est créé automatiquement depuis .env.example au premier lancement.

**Éditer** : `nano /home/pzuser/pzmanager/scripts/.env`

### Chemins principaux

⚠️ Ne modifier que si installation personnalisée

```bash
export PZ_USER="pzuser"
export PZ_HOME="/home/${PZ_USER}"
export PZ_MANAGER_DIR="${PZ_HOME}/pzmanager"
export PZ_SCRIPTS_DIR="${PZ_MANAGER_DIR}/scripts"
export PZ_DATA_DIR="${PZ_MANAGER_DIR}/data"
```

### Serveur Project Zomboid

```bash
export PZ_INSTALL_DIR="${PZ_DATA_DIR}/pzserver"
export PZ_CONTROL_PIPE="${PZ_INSTALL_DIR}/zomboid.control"
export PZ_JRE_LINK="${PZ_INSTALL_DIR}/jre64"
export PZ_SERVICE_NAME="zomboid.service"
export PZ_SOURCE_DIR="${PZ_MANAGER_DIR}/Zomboid"
```

### SteamCMD

```bash
export STEAMCMD_PATH="/usr/games/steamcmd"
export STEAM_APP_ID="380870"
export STEAM_BETA_BRANCH="legacy_41_78_7"
```

**Branches disponibles** :
- `legacy_41_78_7` : Build 41.78.7 (stable, recommandé)
- `public` : Dernière version stable
- Voir [SteamDB](https://steamdb.info/app/380870/depots/) pour autres branches

### Java Runtime

```bash
export JAVA_VERSION="25"
export JAVA_PACKAGE="openjdk-${JAVA_VERSION}-jre-headless"
export JAVA_PATH="/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64"
```

**Versions compatibles** : 17, 21, 25
**Recommandé** : 25 (performances optimales)

**Changer de version** :
1. Modifier `JAVA_VERSION` dans .env
2. Lancer maintenance : `./scripts/admin/performFullMaintenance.sh now`

### Backups

```bash
export BACKUP_DIR="${PZ_DATA_DIR}/dataBackups"
export BACKUP_LATEST_LINK="${BACKUP_DIR}/latest"
export BACKUP_RETENTION_DAYS=30
```

**BACKUP_RETENTION_DAYS** : Nombre de jours de conservation (défaut: 30)

### Synchronisation externe

```bash
export SYNC_BACKUPS_DIR="${PZ_DATA_DIR}/fullBackups"
```

Backups complets horodatés (YYYY-MM-DD_HH-MM) créés par fullBackup.sh.

### Logs

```bash
export LOG_BASE_DIR="${PZ_SCRIPTS_DIR}/logs"
export LOG_ZOMBOID_DIR="${LOG_BASE_DIR}/zomboid"
export LOG_MAINTENANCE_DIR="${LOG_BASE_DIR}/maintenance"
export LOG_RETENTION_DAYS=30
```

### Discord (Optionnel)

```bash
export DISCORD_WEBHOOK=""
```

Laisser vide pour désactiver. Voir [Intégration Discord](#intégration-discord).

## Configuration Backups

### Backups horaires

**Script** : `scripts/backup/dataBackup.sh`
**Planification** : Chaque heure à :14
**Méthode** : Incrémentale avec hard links (rsync)
**Rétention** : Configurable via `BACKUP_RETENTION_DAYS`

**Contenu** :
- `Zomboid/Saves/` - Sauvegardes mondes
- `Zomboid/db/` - Base de données serveur
- `Zomboid/Server/` - Configuration serveur

**Emplacement** : `/home/pzuser/pzmanager/data/dataBackups/backup_YYYY-MM-DD_HHhMMmSSs/`

### Backups complets

**Script** : `scripts/backup/fullBackup.sh`
**Planification** : Quotidien à 4h30 (durant maintenance)
**Méthode** : Snapshot complet + archive ZIP

**Contenu** :
- Configuration système (crontab, sudoers)
- Clés SSH
- Services systemd
- Tous les scripts
- Archive ZIP du dernier backup Zomboid

**Emplacement** : `/home/pzuser/pzmanager/data/fullBackups/YYYY-MM-DD_HH-MM/`

### Backup manuel

```bash
# Backup horaire
pzm backup create

# Backup complet
sudo ./scripts/backup/fullBackup.sh
```

### Restaurer depuis backup

```bash
sudo ./scripts/install/configurationInitiale.sh restore /home/pzuser/pzmanager/data/fullBackups/2026-01-10_04-30
```

### Ajuster la rétention

```bash
nano /home/pzuser/pzmanager/scripts/.env

# Modifier
export BACKUP_RETENTION_DAYS=14    # 14 jours au lieu de 30
export LOG_RETENTION_DAYS=14        # Logs 14 jours
```

**Estimation espace disque** :
- Petit serveur (1-2 joueurs) : ~500MB par backup
- Serveur moyen (5-10 joueurs) : ~1GB par backup
- Grand serveur (20+ joueurs) : ~2GB+ par backup

Avec rétention 14j et backups horaires : ~15-30GB

## Intégration Discord

Notifications optionnelles des événements serveur.

### Configuration

**1. Créer webhook Discord**
- Paramètres serveur → Intégrations → Webhooks
- Nouveau Webhook
- Nommer (ex: "PZ Server")
- Choisir le canal
- Copier l'URL

**2. Configurer .env**
```bash
nano /home/pzuser/pzmanager/scripts/.env

# Coller l'URL
export DISCORD_WEBHOOK="https://discord.com/api/webhooks/1234567890/abcdefghijklmnopqrstuvwxyz"
```

**3. Tester**
```bash
./scripts/internal/sendDiscord.sh "Test notification serveur PZ"
```

### Désactiver notifications

```bash
# Dans .env, vider la variable
export DISCORD_WEBHOOK=""
```

### Événements notifiés

- Démarrage serveur
- Serveur en ligne (RCON prêt)
- Arrêt serveur (avec délai)
- Début maintenance quotidienne
- Redémarrage système

## Configuration Logs

### Logs Zomboid

**Emplacement** : `scripts/logs/zomboid/`
**Format** : `zomboid_YYYY-MM-DD_HHhMMmSS.log`
**Source** : journald (via captureLogs.sh)
**Rétention** : `LOG_RETENTION_DAYS` (défaut: 30j)

### Logs Maintenance

**Emplacement** : `scripts/logs/maintenance/`
**Format** : `maintenance_YYYY-MM-DD_HHhMMmSS.log`
**Contenu** : Logs de performFullMaintenance.sh
**Rétention** : `LOG_RETENTION_DAYS`

### Consulter les logs

```bash
# Status + derniers logs
pzm server status

# Logs temps réel
sudo journalctl -u zomboid.service -f

# Logs maintenance
ls -lt scripts/logs/maintenance/
cat scripts/logs/maintenance/maintenance_YYYY-MM-DD_HHhMMmSS.log
```

## Validation configuration

### Vérifier syntaxe .env

```bash
bash -n /home/pzuser/pzmanager/scripts/.env
```

### Vérifier sudoers

```bash
sudo visudo -cf /home/pzuser/pzmanager/data/setup/pzuser-sudoers
```

### Vérifier crontab

```bash
crontab -l
```

### Tester backups

```bash
pzm backup create
ls -la /home/pzuser/pzmanager/data/dataBackups/
```

### Tester Discord

```bash
./scripts/internal/sendDiscord.sh "Test configuration"
```

## Ressources

- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Configuration serveur de jeu
- [ADVANCED.md](ADVANCED.md) - Réglages avancés et optimisations
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Résolution problèmes
