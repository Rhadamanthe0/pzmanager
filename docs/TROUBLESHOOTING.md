# Troubleshooting Guide

Guide de résolution des problèmes courants pour pzmanager.

## Table des matières

- [Serveur ne démarre pas](#serveur-ne-démarre-pas)
- [Impossible de se connecter](#impossible-de-se-connecter)
- [Serveur plante régulièrement](#serveur-plante-régulièrement)
- [Reset complet du serveur](#reset-complet-du-serveur)
- [Backups ne fonctionnent pas](#backups-ne-fonctionnent-pas)
- [Restaurer données Zomboid](#restaurer-données-zomboid)
- [Notifications Discord défaillantes](#notifications-discord-défaillantes)
- [Erreurs de permissions](#erreurs-de-permissions)
- [Espace disque insuffisant](#espace-disque-insuffisant)
- [Problèmes de performances](#problèmes-de-performances)
- [Obtenir de l'aide](#obtenir-de-laide)

## Serveur ne démarre pas

### Vérifier le statut du service

```bash
sudo -u pzuser systemctl --user status zomboid.service
sudo -u pzuser journalctl --user -u zomboid.service -n 100
```

### Causes fréquentes

**Java introuvable**
```bash
# Vérifier le symlink Java
ls -la /home/pzuser/pzmanager/data/pzserver/jre64

# Si manquant, recréer
sudo rm -f /home/pzuser/pzmanager/data/pzserver/jre64
sudo ln -s /usr/lib/jvm/java-25-openjdk-amd64 /home/pzuser/pzmanager/data/pzserver/jre64
```

**Permission refusée**
```bash
# Vérifier les permissions
ls -la /home/pzuser/pzmanager/data/pzserver/

# Corriger si nécessaire
sudo chown -R pzuser:pzuser /home/pzuser/pzmanager
```

**Port déjà utilisé**
```bash
# Vérifier les ports
sudo netstat -tulpn | grep 16261

# Si occupé, tuer le processus concurrent
sudo kill <PID>
```

## Impossible de se connecter

### Vérifier le firewall

```bash
sudo ufw status verbose
# Doit afficher: 16261/udp, 16262/udp, 8766/udp, 27015/tcp ALLOW
```

**Ouvrir les ports manuellement**
```bash
sudo ufw allow 16261/udp
sudo ufw allow 16262/udp
sudo ufw allow 8766/udp
sudo ufw allow 27015/tcp
```

### Vérifier que le serveur écoute

```bash
sudo netstat -tulpn | grep java
# Devrait afficher java sur les ports 16261, 8766, 27015
```

### Test réseau externe

Depuis un autre ordinateur :
```bash
nc -vuz VOTRE_IP_SERVEUR 16261
```

### Serveur public

- Vérifier le NAT/port forwarding sur votre routeur
- Vérifier les règles firewall de votre hébergeur (AWS, OVH, etc.)

### Serveur privé

- Utiliser l'IP directe dans Project Zomboid
- Pas besoin d'être dans le browser de serveurs

## Serveur plante régulièrement

### Vérifier les ressources

```bash
# RAM disponible
free -h

# Espace disque
df -h

# Charge CPU
top
```

### Causes fréquentes

**RAM insuffisante** (< 4GB)
- Réduire MaxPlayers dans servertest.ini
- Augmenter la RAM du serveur
- Désactiver des mods

**Disque plein** (< 10GB libre)
- Réduire la rétention des backups
- Nettoyer les anciens backups manuellement

**Trop de mods**
- Désactiver les mods un par un pour identifier le problème
- Vérifier la compatibilité des mods entre eux

### Analyser les crashs

```bash
# Logs complets du dernier crash
pzm server status

# Logs system
sudo journalctl -xe
```

## Reset complet du serveur

### Quand utiliser

Solution ultime quand :
- Monde corrompu irréparable
- Changement complet de règles/mods
- Performance dégradée persistante
- Recommencer à zéro

### Reset complet (nouveau monde)

```bash
./scripts/admin/resetServer.sh
```

Crée serveur complètement vierge, nouveau monde.

### Reset avec conservation données

```bash
./scripts/admin/resetServer.sh --keep-whitelist
```

Nouveau monde mais conserve :
- Whitelist joueurs (sauf admin)
- Configuration serveur (servertest.ini)
- Règles du jeu (servertest_SandboxVars.lua)

### Processus automatique

1. **Confirmation** : Taper `RESET` en majuscules
2. **Backup** : Sauvegarde dans `/home/pzuser/OLD/Zomboid_OLD_TIMESTAMP/`
3. **Setup initial** :
   - Saisir mot de passe admin (2 fois)
   - Quand "If the server hangs here, set UPnP=false" → **Ctrl+C**
4. **Restauration** (si --keep-whitelist) : Whitelist et configs
5. **Démarrage** : Nouveau serveur prêt

**⚠️ Attention** : Supprime toutes les données actuelles ! Backup automatique créé.

Documentation complète : [ADVANCED.md - Reset complet serveur](ADVANCED.md#reset-complet-serveur)

## Backups ne fonctionnent pas

### Vérifier le crontab

```bash
crontab -l
# Doit afficher les 2 tâches programmées
```

**Réinstaller le crontab**
```bash
crontab /home/pzuser/pzmanager/data/setupTemplates/pzuser-crontab
```

### Vérifier les logs cron

```bash
grep CRON /var/log/syslog | tail -20
```

### Test manuel

```bash
# Test backup horaire
pzm backup create

# Vérifier le résultat
ls -la /home/pzuser/pzmanager/data/dataBackups/
```

### Espace disque

```bash
du -sh /home/pzuser/pzmanager/data/dataBackups/*
```

Si trop volumineux, réduire BACKUP_RETENTION_DAYS dans .env.

## Restaurer données Zomboid

### Restauration ciblée (données jeu uniquement)

**Quand utiliser** : Monde corrompu, rollback vers ancienne save, test d'ancienne version.

```bash
# Lister backups disponibles
./scripts/backup/restoreZomboidData.sh

# Restaurer backup spécifique
./scripts/backup/restoreZomboidData.sh data/dataBackups/backup_2026-01-11_14h15m00s

# Restaurer dernier backup
./scripts/backup/restoreZomboidData.sh data/dataBackups/latest
```

**Fonctionnement** :
- Crée backup de sécurité du Zomboid actuel (`ZomboidBROKEN_TIMESTAMP`)
- Restaure uniquement données Zomboid (Saves, db, Server)
- Conserve configuration système et scripts

**Appliquer** :
```bash
pzm server restart 2m
```

### Restauration complète (système + données)

**Quand utiliser** : Crash système, migration serveur, reconfiguration complète.

```bash
# Lister backups complets
ls -lt /home/pzuser/pzmanager/data/fullBackups/

# Restaurer tout
sudo ./scripts/install/configurationInitiale.sh restore /home/pzuser/pzmanager/data/fullBackups/2026-01-11_04-30
```

**Restaure** : Crontab, sudoers, SSH, systemd, scripts, .env, données Zomboid.

### Comparaison

| Type | Scope | Backup sécurité | Usage |
|------|-------|-----------------|-------|
| `restoreZomboidData.sh` | Données jeu | ✅ Oui | Problème monde/save |
| `configurationInitiale.sh restore` | Système complet | ❌ Non | Crash système, migration |

## Notifications Discord défaillantes

### Test manuel

```bash
./scripts/internal/sendDiscord.sh "Test message"
```

**Si aucun message reçu** :
1. Vérifier l'URL du webhook dans .env
2. Vérifier que le webhook existe toujours dans Discord
3. Vérifier que le canal n'a pas été supprimé

### Vérifier la configuration

```bash
cat scripts/.env | grep DISCORD_WEBHOOK
# Ne doit pas être vide si Discord activé
```

### Webhook invalide

- Recréer le webhook dans Discord (Server Settings → Integrations → Webhooks)
- Copier la nouvelle URL dans .env

## Erreurs de permissions

### Réinitialiser les permissions

```bash
# Tout le projet
sudo chown -R pzuser:pzuser /home/pzuser/pzmanager

# Scripts exécutables
chmod +x /home/pzuser/pzmanager/scripts/*.sh

# SSH (si configuré)
chmod 700 /home/pzuser/.ssh
chmod 600 /home/pzuser/.ssh/* 2>/dev/null
```

### Sudoers invalide

```bash
# Vérifier le fichier
sudo visudo -cf /home/pzuser/pzmanager/data/setupTemplates/pzuser-sudoers

# Réinstaller si OK
sudo cp /home/pzuser/pzmanager/data/setupTemplates/pzuser-sudoers /etc/sudoers.d/pzuser
sudo chmod 440 /etc/sudoers.d/pzuser
```

## Espace disque insuffisant

### Identifier l'utilisation

```bash
du -sh /home/pzuser/pzmanager/*
du -sh /home/pzuser/pzmanager/data/*
```

### Nettoyer les backups

```bash
# Supprimer manuellement les vieux backups
rm -rf /home/pzuser/pzmanager/data/dataBackups/backup_YYYY-MM-DD*
rm -rf /home/pzuser/pzmanager/data/fullBackups/YYYY-MM-DD*

# Ou réduire la rétention
nano scripts/.env
# Modifier: BACKUP_RETENTION_DAYS=7
```

### Nettoyer les logs

```bash
# Supprimer les vieux logs
find /home/pzuser/pzmanager/scripts/logs -type f -mtime +7 -delete
```

### Purger APT

```bash
sudo apt-get autoclean
sudo apt-get autoremove
```

## Problèmes de performances

### Lag important

**Réduire la fréquence de sauvegarde**
```ini
# Dans Zomboid/Server/servertest.ini
SaveWorldEveryMinutes=60  # Au lieu de 30
```

**Limiter les joueurs**
```ini
MaxPlayers=16  # Au lieu de 32
```

**Activer pause si vide**
```ini
PauseEmpty=true
```

### Java Heap trop petit

```bash
# Éditer le service
nano ~/.config/systemd/user/zomboid.service

# Modifier sous [Service]:
Environment="JAVA_OPTS=-Xms4g -Xmx8g -XX:+UseZGC"

# Recharger
systemctl --user daemon-reload
pzm server restart 5m
```

### Optimiser le Garbage Collector

Pour serveurs > 16 joueurs, utiliser ZGC :
```bash
Environment="JAVA_OPTS=-Xms4g -Xmx8g -XX:+UseZGC -XX:ZCollectionInterval=30"
```

## Obtenir de l'aide

Si le problème persiste :

1. **Vérifier les logs** : `pzm server status`
2. **Consulter les docs** : [INSTALLATION.md](INSTALLATION.md), [CONFIGURATION.md](CONFIGURATION.md)
3. **Ouvrir une issue** sur GitHub avec :
   - Version OS (Debian/Ubuntu)
   - Logs pertinents
   - Configuration (.env sans secrets)
   - Étapes pour reproduire le problème
