# Quick Start Guide

Installation rapide du serveur Project Zomboid en 10 minutes.

## Table des matières

- [Prérequis](#prérequis)
- [Installation](#installation)
- [Configuration serveur](#configuration-serveur)
- [Commandes](#commandes)
- [Discord (Optionnel)](#discord-optionnel)
- [Automatisations](#automatisations)
- [Problèmes courants](#problèmes-courants)
- [Ressources](#ressources)

## Prérequis

- **OS** : Debian 12 ou Ubuntu 22.04+
- **Accès** : Root/sudo
- **RAM** : 4GB minimum
- **Disque** : 20GB+ libre

**Ports** : 16261/UDP, 16262/UDP, 8766/UDP, 27015/TCP (ouverts automatiquement)

## Installation

⚠️ **Installation en tant que root** - exploitation en pzuser après installation

```bash
# Cloner
git clone https://github.com/YOUR_USERNAME/pzmanager.git /opt/pzmanager
cd /opt/pzmanager

# Si git manquant
apt install -y git

# Configuration système (crée pzuser, firewall, packages)
./scripts/install/setupSystem.sh

# Permissions sudo
visudo -cf data/setupTemplates/pzuser-sudoers && \
cp data/setupTemplates/pzuser-sudoers /etc/sudoers.d/pzuser

# Installation finale
mv /opt/pzmanager /home/pzuser/
chown -R pzuser:pzuser /home/pzuser/pzmanager
sudo -u pzuser crontab /home/pzuser/pzmanager/data/setupTemplates/pzuser-crontab
/home/pzuser/pzmanager/scripts/install/configurationInitiale.sh zomboid
```

**Durée totale** : 15-35 minutes (selon connexion)

**Version installée** : Project Zomboid Build 41 (branche `legacy_41_78_7`)

**Optimisations appliquées automatiquement** :
- ZGC (Garbage Collector Java)
- RAM 8GB par défaut

---

**Démarrage** (en tant que pzuser):
```bash
su - pzuser
cd /home/pzuser/pzmanager
pzm server start
pzm server status
```

**Attendu** :
```
Status: RUNNING
Active since: [timestamp]
Control pipe: Available
Recent logs:
[...] RCON: listening on port 27015
```

✅ Serveur opérationnel !

## Configuration serveur

```bash
nano /home/pzuser/pzmanager/Zomboid/Server/servertest.ini
```

Paramètres importants :
```ini
ServerName=MyServer
PublicName=My Public Server
Password=                    # Vide = public
AdminPassword=CHANGEME       # ⚠️ CHANGER!
MaxPlayers=32
PauseEmpty=true
```

Appliquer : `pzm server restart 5m`

Documentation complète : [SERVER_CONFIG.md](SERVER_CONFIG.md)

## Commandes

```bash
pzm server start              # Démarrer
pzm server stop [délai]       # Arrêter (défaut: 2m avertissement)
pzm server restart [délai]    # Redémarrer
pzm server status             # État + logs
```

**Délais** : `30m`, `15m`, `5m`, `2m`, `30s`, `now`

Exemples :
```bash
pzm server restart 30m    # Avertir 30min avant
pzm server stop now       # Arrêt immédiat
```

## Discord (Optionnel)

Configuration : [CONFIGURATION.md - Discord](CONFIGURATION.md#notifications-discord)

## Automatisations

**Maintenance quotidienne (4h30)** :
- Arrêt serveur (30m avertissement)
- Rotation backups
- MAJ système (apt + Java + SteamCMD)
- Backup complet
- Reboot

**Backups horaires (:14)** :
- Backup incrémental Zomboid data
- Rétention 14j (configurable .env)

## Problèmes courants

**Serveur ne démarre pas**
```bash
sudo -u pzuser systemctl --user status zomboid.service
sudo -u pzuser journalctl --user -u zomboid.service -n 50
```

**Impossible de se connecter**
```bash
sudo ufw status    # Vérifier firewall
pzm server status    # Vérifier serveur actif
```

**Backups ne marchent pas**
```bash
crontab -l    # Vérifier planification
pzm backup create  # Test manuel
```

Documentation complète : [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## Ressources

- [INSTALLATION.md](INSTALLATION.md) - Installation détaillée
- [CONFIGURATION.md](CONFIGURATION.md) - Variables .env, backups
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Configuration serveur PZ
- [ADVANCED.md](ADVANCED.md) - Optimisations, RCON
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Résolution problèmes
- [PZ Wiki](https://pzwiki.net/wiki/Dedicated_Server) - Documentation officielle
