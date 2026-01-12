# Project Zomboid Server Manager

[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey.svg)](https://creativecommons.org/licenses/by-nc-sa/4.0/)
[![Platform](https://img.shields.io/badge/platform-Debian%2012%20%7C%20Ubuntu%2022.04%2B-blue.svg)](https://www.debian.org/)

Gestionnaire de serveur Project Zomboid **out-of-the-box** : installation simplifiée, sécurisée et automatisée pour néophytes en administration système.

**🎯 Philosophie** : Zéro configuration manuelle - tout fonctionne dès l'installation avec des paramètres sécurisés par défaut.

**👋 Débutant ?** Suivez le [Quick Start Guide](docs/QUICKSTART.md) - installation en 10 minutes.

## Fonctionnalités

- **Gestion simplifiée** : Start, stop, restart avec avertissements joueurs
- **Backups automatiques** : Horaires incrémentiaux, rétention 30j
- **Maintenance quotidienne** : MAJ système/serveur, backups complets, reboot
- **Discord** (optionnel) : Notifications temps réel
- **Maintenance à distance** : Déclenchement via SSH
- **Configuration centralisée** : Fichier .env unique
- **Déploiement sûr** : Création automatique .env depuis template

## Installation rapide

⚠️ **Installation en root** - exploitation en pzuser

```bash
git clone https://github.com/YOUR_USERNAME/pzmanager.git /opt/pzmanager
cd /opt/pzmanager
./scripts/install/setupSystem.sh
visudo -cf data/setup/pzuser-sudoers && cp data/setup/pzuser-sudoers /etc/sudoers.d/pzuser
mv /opt/pzmanager /home/pzuser/
chown -R pzuser:pzuser /home/pzuser/pzmanager
sudo -u pzuser crontab /home/pzuser/pzmanager/data/setup/pzuser-crontab
/home/pzuser/pzmanager/scripts/install/configurationInitiale.sh zomboid
```

**Version installée** : Project Zomboid Build 41 (branche `legacy_41_78_7`)

**Détails installation** : [docs/WHAT_IS_INSTALLED.md](docs/WHAT_IS_INSTALLED.md) - Liste complète de tout ce qui est installé/configuré

**Exploitation** : Toutes les commandes d'exploitation se font en tant que pzuser (`su - pzuser`)

Guide complet : [docs/INSTALLATION.md](docs/INSTALLATION.md)

## Utilisation

### Interface unifiée (recommandé)

```bash
pzm server start              # Démarrer
pzm server stop [délai]       # Arrêter (défaut: 2m)
pzm server restart [délai]    # Redémarrer
pzm server status             # État + logs récents
pzm backup create             # Backup incrémental
pzm whitelist list            # Voir whitelist
pzm config ram 8g             # Configurer RAM serveur
pzm admin maintenance [délai] # Maintenance
```

**Délais disponibles** : `30m`, `15m`, `5m`, `2m`, `30s`, `now`

**Avertissements** :
- Messages in-game à tous les joueurs
- Notifications Discord (si configuré)

### Scripts directs (alternative)

```bash
./scripts/core/pz.sh start
./scripts/backup/dataBackup.sh
./scripts/admin/manageWhitelist.sh list
```

## Prérequis

**Système** :
- Debian 12 (recommandé) ou Ubuntu 22.04+
- Installation fraîche préférée

**Matériel** :
- 4GB RAM minimum (8GB recommandé)
- 20GB+ disque libre
- 2+ cores CPU recommandé

**Accès** :
- Root/sudo
- SSH (si gestion à distance)

**Réseau** :
- Ports 16261/UDP, 16262/UDP, 8766/UDP, 27015/TCP
- Ouverts automatiquement par l'installeur

## Configuration

### Variables d'environnement

Fichier `scripts/.env` centralise toutes les variables :
- Chemins (serveur, backups, logs, sync)
- Paramètres SteamCMD et Java
- Rétention backups/logs (14j)
- Webhook Discord (optionnel)

Créé automatiquement depuis `data/setup/.env.example` au premier lancement.

**Édition** : `nano scripts/.env`

### Discord (Optionnel)

1. Créer webhook Discord (Paramètres serveur → Intégrations → Webhooks)
2. Éditer `scripts/.env` : `DISCORD_WEBHOOK="URL"`
3. Laisser vide pour désactiver

## Structure

```
pzmanager/
├── pzm                       # Interface principale (dans PATH)
├── Zomboid/                  # Données serveur (saves, configs)
├── scripts/
│   ├── .env                  # Config perso (NON versionné)
│   ├── lib/
│   │   └── common.sh         # Library commune fonctions partagées
│   ├── core/
│   │   └── pz.sh             # Gestion serveur (start/stop/restart/status)
│   ├── backup/
│   │   ├── dataBackup.sh     # Backup horaire incrémental
│   │   ├── fullBackup.sh     # Backup complet avec sync
│   │   └── restoreZomboidData.sh  # Restauration données uniquement
│   ├── admin/
│   │   ├── manageWhitelist.sh     # Gestion whitelist
│   │   ├── resetServer.sh         # Reset complet serveur
│   │   └── performFullMaintenance.sh  # Maintenance quotidienne
│   ├── install/
│   │   ├── setupSystem.sh         # Config système initiale
│   │   └── configurationInitiale.sh  # Install/restore serveur
│   ├── internal/
│   │   ├── sendCommand.sh         # RCON
│   │   ├── sendDiscord.sh         # Notifications Discord
│   │   ├── captureLogs.sh         # Capture logs journald
│   │   └── notifyServerReady.sh   # Notification démarrage
│   └── logs/
└── data/
    ├── setup/                # Fichiers config système
    │   ├── .env.example      # Template config (versionné)
    │   ├── pzuser-crontab
    │   └── pzuser-sudoers
    ├── pzserver/             # Installation serveur
    ├── dataBackups/          # Backups horaires (14j)
    ├── fullBackups/          # Backups complets horodatés
    └── versionning/          # Historique versions
```

## Permissions sudo (pzuser)

Configuration dans `/etc/sudoers.d/pzuser` :

- **APT** : update, upgrade, install openjdk, autoremove, autoclean
- **Java** : Gestion symlink `/home/pzuser/pzmanager/data/pzserver/jre64`
- **Backup** : Exécution fullBackup.sh en root
- **Reboot** : `/sbin/reboot`

## Automatisations (crontab)

**Maintenance quotidienne (4h30)** :
- Arrêt serveur (avertissements)
- Rotation backups
- MAJ système (APT + Java + SteamCMD)
- Backup complet
- Reboot système

**Backup horaire (*h14)** :
- Backup incrémental avec hard links
- Rétention 14j

**Consulter** : `crontab -l`

## Maintenance à distance

Clé SSH spéciale force l'exécution de `performFullMaintenance.sh` :

```bash
# Depuis machine locale
ssh pzuser@SERVEUR 30m   # Maintenance avec 30min avertissement
ssh pzuser@SERVEUR 2m    # Maintenance avec 2min avertissement
```

**Restrictions** : Commande forcée, pas de forwarding

## Documentation

- [docs/QUICKSTART.md](docs/QUICKSTART.md) - Installation rapide (10 min)
- [docs/INSTALLATION.md](docs/INSTALLATION.md) - Installation détaillée
- [docs/WHAT_IS_INSTALLED.md](docs/WHAT_IS_INSTALLED.md) - Détails complets installation
- [docs/USAGE.md](docs/USAGE.md) - Guide complet des commandes
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) - Variables .env, backups, Discord
- [docs/SERVER_CONFIG.md](docs/SERVER_CONFIG.md) - Configuration serveur PZ
- [docs/ADVANCED.md](docs/ADVANCED.md) - Optimisations, RCON
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - Résolution problèmes

## Licence

CC BY-NC-SA 4.0 (Creative Commons Attribution-NonCommercial-ShareAlike 4.0)

**Résumé** : Usage/partage/modification pour usage personnel/non-commercial. Modifications sous même licence. Usage commercial nécessite autorisation.

## Support

Issues, questions, suggestions : Ouvrir une issue sur GitHub
