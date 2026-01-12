# Guide d'Utilisation

Documentation complète de toutes les commandes et opérations pzmanager.

## Prérequis

⚠️ **Toutes les commandes d'exploitation doivent être exécutées en tant que pzuser**

```bash
su - pzuser
cd /home/pzuser/pzmanager
```

## Table des matières

- [Interface pzm](#interface-pzm)
- [Gestion Serveur](#gestion-serveur)
- [Backups](#backups)
- [Whitelist](#whitelist)
- [Administration](#administration)
- [Configuration](#configuration)
- [RCON](#rcon)
- [Scripts Directs](#scripts-directs)
- [Cas d'Usage](#cas-dusage)

---

## Interface pzm

**Commande principale** : `pzm`

**Aide** : `pzm --help`

**Syntaxe générale** :
```bash
pzm <commande> <sous-commande> [arguments]
```

---

## Gestion Serveur

### Démarrer

```bash
pzm server start
```

**Effet** :
- Démarre le service zomboid
- Notification Discord (si configuré)
- Logs disponibles via `status`

**Durée** : 2-5 minutes (premier démarrage génère le monde)

### Arrêter

```bash
pzm server stop [délai]
```

**Délais disponibles** :
- `30m` : Avertissement 30 minutes avant
- `15m` : Avertissement 15 minutes avant
- `5m` : Avertissement 5 minutes avant
- `2m` : Avertissement 2 minutes avant (défaut)
- `30s` : Avertissement 30 secondes avant
- `now` : Arrêt immédiat sans avertissement

**Effet** :
- Messages in-game à tous les joueurs
- Notifications Discord (si configuré)
- Arrêt propre du serveur

**Exemples** :
```bash
pzm server stop           # Arrêt dans 2 minutes
pzm server stop 30m       # Arrêt dans 30 minutes
pzm server stop now       # Arrêt immédiat
```

### Redémarrer

```bash
pzm server restart [délai]
```

**Identique à `stop`** : Mêmes délais, puis redémarrage automatique

**Exemples** :
```bash
pzm server restart        # Redémarrage dans 2 minutes
pzm server restart 5m     # Redémarrage dans 5 minutes
```

**Cas d'usage** : Appliquer modifications configuration serveur

### Statut

```bash
pzm server status
```

**Affiche** :
- État service (RUNNING / STOPPED)
- Durée uptime
- Dernière sauvegarde
- 30 dernières lignes de logs

**Exemple sortie** :
```
===== STATUT SERVEUR PROJECT ZOMBOID =====
Status: RUNNING
Active since: Sun 2026-01-12 10:30:00 UTC (5h ago)
Control pipe: Available

===== DERNIERE SAUVEGARDE =====
Last save: 2026-01-12 15:20:15

===== LOGS RÉCENTS (30 dernières lignes) =====
[...] RCON: listening on port 27015
[...] SERVER STARTED
```

---

## Backups

### Backup Incrémental

```bash
pzm backup create
```

**Effet** :
- Backup des données Zomboid uniquement
- Hard links (espace optimisé)
- Rétention : 14 jours (configurable)

**Destination** : `data/dataBackups/backup_YYYY-MM-DD_HHhMMmSSs/`

**Automatique** : Toutes les heures à :14 (crontab)

**Durée** : 10-60 secondes

### Backup Complet

```bash
pzm backup full
```

**Effet** :
- Backup système complet (Zomboid + pzserver)
- Synchronisation externe (si configuré)
- Utilisé par maintenance quotidienne

**Destination** : `data/fullBackups/YYYY-MM-DD_HH-MM/`

**Durée** : 2-10 minutes (selon taille)

### Restaurer

```bash
pzm backup restore <chemin>
```

**Paramètres** :
- `<chemin>` : Chemin relatif ou absolu du backup

**Effet** :
- Arrêt serveur
- Backup sécurité de l'état actuel
- Restauration données depuis backup
- Permissions corrigées

**Exemples** :
```bash
# Chemin relatif
pzm backup restore data/dataBackups/backup_2026-01-12_14h14m00s

# Chemin absolu
pzm backup restore /home/pzuser/pzmanager/data/dataBackups/backup_2026-01-12_14h14m00s
```

**⚠️ Attention** : Backup sécurité créé dans `OLD/ZomboidBROKEN_TIMESTAMP/`

### Lister Backups

```bash
pzm backup list
```

**Affiche** :
- 20 backups incrémentiaux les plus récents
- 10 backups complets les plus récents
- Taille et date

---

## Whitelist

### Lister

```bash
pzm whitelist list
```

**Affiche** :
- Username
- Steam ID 32
- Dernière connexion
- Tri par dernière connexion

**Exemple sortie** :
```
Username       | Steam ID           | Last Connection
---------------|--------------------|-----------------
PlayerOne      | STEAM_0:1:12345678 | 2026-01-12 14:30
PlayerTwo      | STEAM_0:0:87654321 | 2026-01-10 18:45
```

### Ajouter

```bash
pzm whitelist add "<nom>" "<steam_id_32>"
```

**Paramètres** :
- `<nom>` : Nom du joueur (guillemets si espaces)
- `<steam_id_32>` : Steam ID format `STEAM_0:X:YYYYYYYY`

**Validation** : Format Steam ID 32 vérifié automatiquement

**Conversion** : Steam64 ID → Steam ID 32 via https://steamid.xyz/

**Exemples** :
```bash
pzm whitelist add "John Doe" "STEAM_0:1:12345678"
pzm whitelist add PlayerOne "STEAM_0:0:87654321"
```

**Effet immédiat** : Pas besoin de redémarrer le serveur

### Retirer

```bash
pzm whitelist remove "<steam_id_32>"
```

**Paramètres** :
- `<steam_id_32>` : Steam ID à retirer

**Confirmation** : Demandée avant suppression

**Exemples** :
```bash
pzm whitelist remove "STEAM_0:1:12345678"
```

---

## Administration

### Reset Serveur

```bash
pzm admin reset [--keep-whitelist]
```

**Options** :
- Sans option : Reset complet (nouveau monde, whitelist effacée)
- `--keep-whitelist` : Conservation whitelist et fichiers `.ini`

**Effet** :
- Arrêt serveur
- Backup automatique dans `OLD/Zomboid_OLD_TIMESTAMP/`
- Suppression données serveur
- Configuration initiale interactive
- Restauration whitelist (si `--keep-whitelist`)

**⚠️ ATTENTION** : Opération destructive ! Backup créé automatiquement.

**Confirmation** : Tapez "RESET" pour confirmer

**Exemples** :
```bash
# Reset complet (nouveau monde vierge)
pzm admin reset

# Reset avec conservation whitelist
pzm admin reset --keep-whitelist
```

**Cas d'usage** :
- Nouveau monde (wipe)
- Changement paramètres fondamentaux
- Corruption données

### Maintenance

```bash
pzm admin maintenance [délai]
```

**Délai défaut** : `30m`

**Étapes** :
1. Arrêt serveur avec avertissements
2. Rotation backups (suppression > 14 jours)
3. Mise à jour système (`apt upgrade`)
4. Mise à jour Java
5. Mise à jour serveur PZ (SteamCMD)
6. Restauration symlink Java
7. Backup complet externe
8. Reboot système

**Automatique** : Tous les jours à 4h30 (crontab)

**Logs** : `scripts/logs/maintenance/maintenance_YYYY-MM-DD_HHhMMmSSs.log`

**Durée** : 15-45 minutes

**Exemples** :
```bash
pzm admin maintenance        # Maintenance dans 30 minutes
pzm admin maintenance 15m    # Maintenance dans 15 minutes
pzm admin maintenance 2m     # Maintenance dans 2 minutes
```

**Déclenchement à distance** :
```bash
# Depuis machine locale
ssh pzuser@SERVEUR 30m
```

---

## Configuration

### RAM Serveur

```bash
pzm config ram <valeur>
```

**Valeurs acceptées** : `2g`, `4g`, `6g`, `8g`, `12g`, `16g`, `20g`, `24g`, `32g`

**Effet** :
- Modification `ProjectZomboid64.json`
- Backup automatique avant modification
- Détection si valeur déjà configurée

**⚠️ Important** : Redémarrer serveur pour appliquer

**Exemples** :
```bash
pzm config ram 4g    # 4GB RAM
pzm config ram 8g    # 8GB RAM (défaut)
pzm config ram 16g   # 16GB RAM
pzm config ram 32g   # 32GB RAM
```

**Recommandations** :
- **4GB** : 1-10 joueurs
- **8GB** : 10-20 joueurs (défaut)
- **16GB** : 20-50 joueurs
- **32GB** : 50+ joueurs ou gros mods

**Appliquer** :
```bash
pzm config ram 16g
pzm server restart 5m
```

---

## RCON

### Envoyer Commande

```bash
pzm rcon "<commande>"
```

**Commandes utiles** :

#### Sauvegarder
```bash
pzm rcon "save"
```

#### Message Broadcast
```bash
pzm rcon "servermsg 'Redémarrage dans 5 minutes'"
```

#### Arrêter Serveur
```bash
pzm rcon "quit"
```

#### Lister Joueurs
```bash
pzm rcon "players"
```

#### Téléporter Joueur
```bash
pzm rcon "teleport PlayerName 1000 1000 0"
```

#### Ajouter Item
```bash
pzm rcon "giveitem PlayerName Base.Axe"
```

#### Bannir/Débannir
```bash
pzm rcon "banuser PlayerName"
pzm rcon "unbanuser PlayerName"
```

#### Kick Joueur
```bash
pzm rcon "kickuser PlayerName"
```

#### God Mode
```bash
pzm rcon "godmode PlayerName"
```

#### Invisible
```bash
pzm rcon "invisible PlayerName"
```

#### Changer Météo
```bash
pzm rcon "setweather rain"
pzm rcon "setweather sunny"
```

#### Aide Complète
```bash
pzm rcon "help"
```

**Documentation officielle** : [PZ Wiki - Server Commands](https://pzwiki.net/wiki/Server_commands)

---

## Scripts Directs

Alternative à `pzm` : scripts directs avec nouveaux chemins.

### Serveur

```bash
./scripts/core/pz.sh start
./scripts/core/pz.sh stop [délai]
./scripts/core/pz.sh restart [délai]
./scripts/core/pz.sh status
```

### Backups

```bash
./scripts/backup/dataBackup.sh
./scripts/backup/fullBackup.sh
./scripts/backup/restoreZomboidData.sh <chemin>
```

### Administration

```bash
./scripts/admin/manageWhitelist.sh list
./scripts/admin/manageWhitelist.sh add "<nom>" "<steam_id>"
./scripts/admin/manageWhitelist.sh remove "<steam_id>"
./scripts/admin/resetServer.sh [--keep-whitelist]
./scripts/admin/setram.sh <valeur>
./scripts/admin/performFullMaintenance.sh [délai]
```

### RCON

```bash
./scripts/internal/sendCommand.sh "<commande>"
./scripts/internal/sendDiscord.sh "<message>"
```

**Recommandation** : Utiliser `pzm` pour interface unifiée

---

## Cas d'Usage

### Démarrage Quotidien

```bash
su - pzuser
cd /home/pzuser/pzmanager
pzm server status
# Si arrêté :
pzm server start
```

### Appliquer Configuration Serveur

```bash
# 1. Éditer configuration
nano /home/pzuser/pzmanager/Zomboid/Server/servertest.ini

# 2. Redémarrer avec avertissement
pzm server restart 5m
```

### Mise à Jour Manuelle

```bash
# Maintenance complète (MAJ système + serveur)
pzm admin maintenance 30m
```

### Ajouter Joueur Whitelist

```bash
# 1. Obtenir Steam ID 32 depuis Steam64 ID
# https://steamid.xyz/ → Convertir 76561198XXXXXXXXX

# 2. Ajouter à whitelist
pzm whitelist add "NomJoueur" "STEAM_0:1:12345678"

# 3. Vérifier
pzm whitelist list
```

### Restaurer Backup

```bash
# 1. Lister backups disponibles
pzm backup list

# 2. Restaurer backup spécifique
pzm backup restore data/dataBackups/backup_2026-01-12_14h14m00s

# 3. Démarrer serveur
pzm server start
```

### Nouveau Monde (Wipe)

```bash
# Avec conservation whitelist
pzm admin reset --keep-whitelist
# Confirmer en tapant "RESET"

# Démarrer nouveau monde
pzm server start
```

### Augmenter RAM Serveur

```bash
# 1. Configurer RAM
pzm config ram 16g

# 2. Appliquer avec redémarrage
pzm server restart 5m
```

### Envoyer Message aux Joueurs

```bash
pzm rcon "servermsg 'Maintenance dans 10 minutes'"
```

### Sauvegarder Manuellement

```bash
# Via RCON
pzm rcon "save"

# Via backup incrémental
pzm backup create
```

### Vérifier Logs

```bash
# Logs récents
pzm server status

# Logs complets serveur
ls -lh scripts/logs/zomboid/
cat scripts/logs/zomboid/zomboid_2026-01-12_10h30m00s.log

# Logs maintenance
ls -lh scripts/logs/maintenance/
cat scripts/logs/maintenance/maintenance_2026-01-12_04h30m00s.log

# Logs backups
cat scripts/logs/data_backup.log
```

### Test Discord

```bash
# Via script direct
./scripts/internal/sendDiscord.sh "Test notification"

# Via RCON (déclenche notification)
pzm rcon "save"
```

### Surveillance Serveur

```bash
# Statut service systemd
systemctl --user status zomboid.service

# Logs temps réel journald
journalctl --user -u zomboid.service -f

# Ressources système
htop
# Chercher processus "java"
```

### Modification Massive Whitelist

```bash
# Via SQLite direct
sqlite3 /home/pzuser/pzmanager/Zomboid/db/servertest.db

# Lister tous
SELECT username, steamid FROM whitelist;

# Supprimer tous (sauf admin)
DELETE FROM whitelist WHERE username != 'admin';

# Quitter
.quit
```

### Backup Avant Maintenance

```bash
# 1. Backup complet manuel
pzm backup full

# 2. Vérifier création
ls -lh data/fullBackups/

# 3. Maintenance
pzm admin maintenance 30m
```

---

## Dépannage Rapide

### Serveur Ne Démarre Pas

```bash
# Vérifier logs
pzm server status
journalctl --user -u zomboid.service -n 100

# Vérifier service
systemctl --user status zomboid.service

# Redémarrer service
systemctl --user restart zomboid.service
```

### Serveur Lent / Lag

```bash
# Augmenter RAM
pzm config ram 16g
pzm server restart 5m

# Vérifier ressources
htop
```

### Corruption Données

```bash
# Restaurer backup récent
pzm backup list
pzm backup restore data/dataBackups/backup_RECENT

# Ou reset complet
pzm admin reset --keep-whitelist
```

### Backup Échoue

```bash
# Vérifier espace disque
df -h

# Vérifier logs
cat scripts/logs/data_backup.log

# Nettoyage backups anciens
# (automatique via maintenance quotidienne)
```

---

## Variables d'Environnement

**Fichier** : `scripts/.env`

**Modifier** :
```bash
nano scripts/.env
```

**Variables utiles** :

```bash
# RAM / Java
JAVA_VERSION="25"

# Backups
BACKUP_RETENTION_DAYS="30"

# Discord (optionnel)
DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."

# Serveur PZ
STEAM_BETA_BRANCH="legacy_41_78_7"
```

**Appliquer** : Redémarrer services concernés

**Documentation** : [CONFIGURATION.md](CONFIGURATION.md)

---

## Automatisations

### Crontab

**Voir tâches** :
```bash
crontab -l
```

**Tâches configurées** :

#### Backup Horaire (:14)
```
14 * * * *  /bin/bash  /home/pzuser/pzmanager/scripts/backup/dataBackup.sh >> /home/pzuser/pzmanager/scripts/logs/data_backup.log 2>&1
```

#### Maintenance Quotidienne (4h30)
```
30 4 * * *  /bin/bash  /home/pzuser/pzmanager/scripts/admin/performFullMaintenance.sh
```

**Modifier crontab** :
```bash
crontab -e
```

---

## Aide et Support

**Aide pzm** :
```bash
pzm --help
```

**Aide script spécifique** :
```bash
./scripts/admin/setram.sh --help
```

**Documentation** :
- [INSTALLATION.md](INSTALLATION.md) - Installation détaillée
- [CONFIGURATION.md](CONFIGURATION.md) - Variables .env
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Config serveur PZ
- [ADVANCED.md](ADVANCED.md) - Optimisations
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Résolution problèmes
- [WHAT_IS_INSTALLED.md](WHAT_IS_INSTALLED.md) - Détails installation

**Support** : Ouvrir issue sur GitHub
