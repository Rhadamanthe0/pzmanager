# Configuration Avancée

Optimisations, RCON, et réglages experts pzmanager.

## Table des matières

- [Optimisation performances](#optimisation-performances)
- [Commandes RCON](#commandes-rcon)
- [Personnalisation scripts](#personnalisation-scripts)
- [Configuration multi-serveurs](#configuration-multi-serveurs)
- [Maintenance à distance](#maintenance-à-distance)

## Optimisation performances

Documentation officielle : [PZ Wiki - Performance](https://pzwiki.net/wiki/Dedicated_Server#Performance)

### Configuration RAM

✅ **Appliqué automatiquement à l'installation** :
- **ZGC** (`-XX:+UseZGC`) : Garbage collector optimisé
- **RAM** : 8GB par défaut (`-Xmx8g`)

**Modifier allocation RAM** :
```bash
pzm config ram 4g    # 4GB
pzm config ram 8g    # 8GB
pzm config ram 16g   # 16GB
pzm config ram 32g   # 32GB
```

**Recommandations** :
- 4GB : <10 joueurs simultanés
- 8GB : <25 joueurs (défaut)
- 16GB : <60 joueurs

**Appliquer** : Redémarrer serveur après modification

## Commandes RCON

### Utilisation via pzmanager

```bash
pzm rcon "COMMANDE"
```

### Commandes utiles

```bash
# Sauvegarder
pzm rcon "save"

# Message broadcast
pzm rcon "servermsg 'Message aux joueurs'"

# Arrêter serveur
pzm rcon "quit"

# Lister joueurs
pzm rcon "players"

# Aide
pzm rcon "help"
```

Documentation complète : [PZ Wiki - Admin Commands](https://pzwiki.net/wiki/Server_commands)

## Gestion whitelist

Whitelist avancée via SQLite : [SERVER_CONFIG.md - Whitelist](SERVER_CONFIG.md#gestion-whitelist)

Base de données : `/home/pzuser/pzmanager/Zomboid/db/servertest.db`

## Reset complet serveur

### Script resetServer.sh

**Script** : `resetServer.sh`

Reset complet du serveur avec nouveau monde. Utile pour recommencer à zéro.

**Reset complet (serveur vierge)** :
```bash
./scripts/admin/resetServer.sh
```

**Reset avec conservation whitelist et configs** :
```bash
./scripts/admin/resetServer.sh --keep-whitelist
```

### Processus

**Étape 1 - Confirmation** :
- Demande confirmation (taper `RESET` en majuscules)

**Étape 2 - Arrêt et backup** :
- Arrêt du serveur
- Backup complet dans `/home/pzuser/OLD/Zomboid_OLD_TIMESTAMP/`

**Étape 3 - Configuration initiale** :
- Démarrage setup initial interactif
- Saisir mot de passe admin (2 fois)
- Quand message "If the server hangs here, set UPnP=false" : **Ctrl+C**

**Étape 4 - Restauration (si --keep-whitelist)** :
- Restaure whitelist depuis ancien serveur (sauf admin)
- Copie `servertest.ini` et `servertest_SandboxVars.lua`

**Étape 5 - Démarrage** :
- Démarrage nouveau serveur

### Cas d'usage

**Nouveau monde** : Serveur corrompu, changement complet de règles, nouveau départ.

**Avec whitelist** : Garder joueurs autorisés et paramètres serveur.

**⚠️ Attention** : Suppression complète des données ! Backup créé automatiquement.

## Personnalisation scripts

### Messages d'avertissement personnalisés

Éditer `scripts/core/pz.sh` ligne 76 pour modifier les messages envoyés aux joueurs.

### Planification maintenance

Modifier le crontab :
```bash
crontab -e

# Maintenance quotidienne (défaut: 4h30)
30 4 * * *  /bin/bash  /home/pzuser/pzmanager/scripts/admin/performFullMaintenance.sh

# Backups horaires (défaut: :14)
14 * * * *  /bin/bash  /home/pzuser/pzmanager/scripts/backup/dataBackup.sh >> /home/pzuser/pzmanager/scripts/logs/data_backup.log 2>&1
```

## Configuration multi-serveurs

Pour exécuter plusieurs serveurs sur la même machine :

1. Cloner pzmanager dans un autre répertoire
2. Modifier les ports dans servertest.ini (16261 → 16271, etc.)
3. Créer un nouvel utilisateur ou modifier PZ_USER dans .env
4. Ajuster les horaires crontab pour éviter conflits

## Maintenance à distance

### Configuration SSH forcée

Une clé SSH spéciale permet de déclencher la maintenance à distance.

**Fichier** : `~/.ssh/authorized_keys`

```
command="/home/pzuser/pzmanager/scripts/admin/performFullMaintenance.sh $SSH_ORIGINAL_COMMAND",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA...
```

**Génération clé** (sur machine locale) :
```bash
ssh-keygen -t ed25519 -f ~/.ssh/pz_maintenance
```

**Utilisation** :
```bash
# Depuis machine locale
ssh -i ~/.ssh/pz_maintenance pzuser@SERVEUR_IP 30m
ssh -i ~/.ssh/pz_maintenance pzuser@SERVEUR_IP 5m
ssh -i ~/.ssh/pz_maintenance pzuser@SERVEUR_IP 2m
```

**Restrictions de sécurité** :
- Commande forcée (seulement performFullMaintenance.sh)
- Pas de port forwarding
- Pas de X11 forwarding
- Pas d'agent forwarding

## Monitoring avancé

### Status détaillé

```bash
pzm server status
```

Affiche :
- État service (running/stopped)
- Uptime
- Disponibilité control pipe
- Dernière sauvegarde
- 30 dernières lignes de logs

### Logs en temps réel

```bash
# Logs serveur
sudo journalctl -u zomboid.service -f

# Logs maintenance
tail -f scripts/logs/maintenance/maintenance_*.log

# Logs backups
tail -f scripts/logs/data_backup.log
```

## Ressources

- [CONFIGURATION.md](CONFIGURATION.md) - Variables .env, backups
- [SERVER_CONFIG.md](SERVER_CONFIG.md) - Configuration serveur jeu
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Résolution problèmes
- [PZ Wiki - Server](https://pzwiki.net/wiki/Dedicated_Server)
