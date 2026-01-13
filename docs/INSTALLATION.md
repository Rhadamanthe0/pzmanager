# Installation Guide

Installation détaillée de pzmanager - Project Zomboid Server Manager.

## Table des matières

- [Prérequis](#prérequis)
- [Installation rapide](#installation-rapide)
- [Installation détaillée](#installation-détaillée)
- [Post-installation](#post-installation)
- [Restauration depuis backup](#restauration-depuis-backup)
- [Résolution problèmes](#résolution-problèmes)
- [Désinstallation](#désinstallation)
- [Ressources](#ressources)

## Prérequis

### Système
- **Debian 12** (Bookworm) ou **Ubuntu 22.04 LTS+**
- Installation fraîche recommandée

### Matériel
- **CPU** : 2+ cores
- **RAM** : 4GB minimum, 8GB recommandé
- **Disque** : 20GB+ libre (SSD recommandé)

### Réseau
Ports requis (ouverts automatiquement) :
- **16261/UDP** - Jeu principal
- **16262/UDP** - Jeu secondaire
- **8766/UDP** - RCON
- **27015/TCP** - Steam query
- **22/TCP** - SSH (gestion)

### Dépendances
Installées automatiquement :
- rsync, unzip, ufw
- steamcmd
- openjdk-*-jre-headless

## Installation rapide

Voir [QUICKSTART.md](QUICKSTART.md) pour version condensée.

## Installation détaillée

⚠️ **Installation en root** - exploitation en pzuser après installation

### 1. Mise à jour système

```bash
apt update && apt upgrade -y
```

### 2. Cloner et configurer

```bash
git clone https://github.com/YOUR_USERNAME/pzmanager.git /opt/pzmanager
cd /opt/pzmanager

# Si git absent
apt install -y git
```

### 3. Configuration système

```bash
./scripts/install/setupSystem.sh
```

**Actions** :
- Crée utilisateur pzuser
- Installe rsync, unzip, ufw
- Configure firewall (ports + règles par défaut)
- Active firewall

**Vérification** :
```bash
id pzuser       # Utilisateur existe
ufw status      # Firewall actif
```

### 4. Permissions sudo

```bash
visudo -cf data/setupTemplates/pzuser-sudoers && \
cp data/setupTemplates/pzuser-sudoers /etc/sudoers.d/pzuser

# Vérifier
sudo -u pzuser sudo -l
```

### 5. Installation finale

```bash
mv /opt/pzmanager /home/pzuser/
chown -R pzuser:pzuser /home/pzuser/pzmanager
sudo -u pzuser crontab /home/pzuser/pzmanager/data/setupTemplates/pzuser-crontab
/home/pzuser/pzmanager/scripts/install/configurationInitiale.sh zomboid
```

**Durée** : 10-30 minutes (téléchargement ~1-2GB)

**Version installée** : Project Zomboid Build 41 (branche `legacy_41_78_7`)

**Optimisations appliquées automatiquement** :
- ZGC (Garbage Collector Java)
- RAM 8GB par défaut (modifiable via `pzm config ram <valeur>`)

**Vérification** :
```bash
ls -la /home/pzuser/pzmanager/data/pzserver/
sudo -u pzuser systemctl --user status zomboid.service
```

### 6. Démarrage serveur

⚠️ **En tant que pzuser pour l'exploitation**

```bash
su - pzuser
cd /home/pzuser/pzmanager
pzm server start
pzm server status
```

Premier démarrage : 2-5 minutes (génération monde).

**Attendu** :
```
Status: RUNNING
Active since: [timestamp]
Control pipe: Available
Recent logs:
[...] RCON: listening on port 27015
```

## Post-installation

Toutes les commandes post-installation s'exécutent en tant que **pzuser** (`su - pzuser`).

### Configuration .env (optionnel)

Fichier `.env` créé automatiquement depuis `.env.example` au premier lancement.

Pour personnaliser : `nano /home/pzuser/pzmanager/scripts/.env`

Variables utiles :
- `JAVA_VERSION` : Version Java (défaut: 25)
- `STEAM_BETA_BRANCH` : Branche PZ (défaut: legacy_41_78_7)
- `BACKUP_RETENTION_DAYS` : Rétention backups (défaut: 30)
- `DISCORD_WEBHOOK` : Notifications Discord

Documentation : [CONFIGURATION.md](CONFIGURATION.md)

### Configuration serveur

Fichier : `/home/pzuser/pzmanager/Zomboid/Server/servertest.ini`

Paramètres à modifier :
- `AdminPassword` : ⚠️ CHANGER impérativement !
- `PublicName` : Nom affiché dans liste serveurs
- `Password` : Mot de passe serveur (vide = public)

**Appliquer** : `pzm server restart 2m`

Documentation : [SERVER_CONFIG.md](SERVER_CONFIG.md)

### Admins et whitelist

- **Admins** : [SERVER_CONFIG.md - Admins](SERVER_CONFIG.md#gestion-admins)
- **Whitelist** : [SERVER_CONFIG.md - Whitelist](SERVER_CONFIG.md#gestion-whitelist)

### Discord (optionnel)

Configuration : [CONFIGURATION.md - Discord](CONFIGURATION.md#notifications-discord)

### Maintenance à distance (Optionnel)

**Générer clé (machine locale)** :
```bash
ssh-keygen -t ed25519 -f ~/.ssh/pz_maintenance
```

**Ajouter au serveur** :
```bash
nano ~/.ssh/authorized_keys

# Ajouter
command="/home/pzuser/pzmanager/scripts/admin/performFullMaintenance.sh $SSH_ORIGINAL_COMMAND",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA...
```

**Utiliser** :
```bash
ssh -i ~/.ssh/pz_maintenance pzuser@SERVEUR_IP 30m
```

Documentation : [ADVANCED.md](ADVANCED.md)

## Restauration depuis backup

### Restauration complète (système + données)

```bash
sudo ./scripts/install/configurationInitiale.sh restore /home/pzuser/pzmanager/data/fullBackups/YYYY-MM-DD_HH-MM
```

Restaure :
- Configuration système (crontab, sudoers)
- Clés SSH, services systemd
- Scripts et .env
- Dernière sauvegarde Zomboid (auto-décompressée)

### Restauration données Zomboid uniquement

```bash
./scripts/backup/restoreZomboidData.sh data/dataBackups/backup_YYYY-MM-DD_HHhMMmSSs
```

Restaure uniquement les données du jeu (Saves, db, Server).
Crée backup de sécurité avant écrasement.

Documentation : [TROUBLESHOOTING.md - Restaurer données Zomboid](TROUBLESHOOTING.md#restaurer-données-zomboid)

## Résolution problèmes

Voir [TROUBLESHOOTING.md](TROUBLESHOOTING.md) pour guide complet.

**Problèmes fréquents** :

**Serveur ne démarre pas**
```bash
sudo -u pzuser systemctl --user status zomboid.service
sudo -u pzuser journalctl --user -u zomboid.service -n 100
```

**Connexion impossible**
```bash
sudo ufw status                    # Vérifier firewall
sudo netstat -tulpn | grep java    # Vérifier écoute ports
```

**Backups non fonctionnels**
```bash
crontab -l                   # Vérifier planification
pzm backup create  # Test manuel
```

## Désinstallation

```bash
# 1. Arrêter serveur
sudo su - pzuser
pzm server stop now
exit

# 2. Désactiver service
sudo -u pzuser systemctl --user disable zomboid.service
sudo -u pzuser systemctl --user stop zomboid.service

# 3. Supprimer crontab
sudo -u pzuser crontab -r

# 4. Supprimer sudoers
sudo rm /etc/sudoers.d/pzuser

# 5. Supprimer installation (⚠️ supprime toutes données!)
sudo rm -rf /home/pzuser/pzmanager

# 6. (Optionnel) Supprimer utilisateur
sudo userdel -r pzuser
```

## Ressources

- [QUICKSTART.md](QUICKSTART.md) - Installation rapide
- [CONFIGURATION.md](CONFIGURATION.md) - Configuration .env, backups
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Configuration serveur PZ
- [ADVANCED.md](ADVANCED.md) - Optimisations, RCON
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Résolution problèmes
- [PZ Wiki](https://pzwiki.net/wiki/Dedicated_Server) - Documentation officielle
