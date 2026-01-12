# Configuration Serveur Project Zomboid

Configuration des paramètres du serveur de jeu.

## Table des matières

- [Documentation officielle](#documentation-officielle)
- [Spécificités pzmanager](#spécificités-pzmanager)
  - [Fichiers de configuration](#fichiers-de-configuration)
  - [Appliquer les modifications](#appliquer-les-modifications)
  - [Paramètres importants](#paramètres-importants)
  - [Gestion whitelist](#gestion-whitelist)
  - [Mods](#mods)
  - [Ports réseau](#ports-réseau)
- [Ressources](#ressources)

## Documentation officielle

Pour la configuration complète du serveur Project Zomboid :
- [Server Settings](https://pzwiki.net/wiki/Server_Settings)
- [Sandbox Variables](https://pzwiki.net/wiki/Sandbox)
- [Dedicated Server Guide](https://pzwiki.net/wiki/Dedicated_Server)

## Spécificités pzmanager

### Fichiers de configuration

**Localisation** : `/home/pzuser/pzmanager/Zomboid/Server/`

Fichiers principaux :
- `servertest.ini` - Configuration serveur (nom, ports, joueurs, etc.)
- `servertest_SandboxVars.lua` - Règles du jeu (zombies, difficulté, loot)
- `servertest_access.txt` - Liste admins (Steam64 IDs)

### Appliquer les modifications

```bash
# Après modification, redémarrer avec avertissement joueurs
pzm server restart 5m
```

### Paramètres importants

```ini
# servertest.ini
ServerName=MyServer           # Nom interne
PublicName=My Public Name     # Nom affiché browser
Password=                     # Mot de passe (vide = public)
AdminPassword=CHANGEME        # Password RCON (⚠️ CHANGER!)
MaxPlayers=32                # Maximum joueurs
PauseEmpty=true              # Pause si vide (économise CPU)
SaveWorldEveryMinutes=30     # Fréquence auto-save
```

⚠️ **Sécurité** : Changez toujours `AdminPassword` !

### Gestion whitelist

**Script dédié** : `manageWhitelist.sh`

Gérer les utilisateurs autorisés à se connecter au serveur.

**Voir la whitelist** :
```bash
pzm whitelist list
```

**Ajouter un joueur** :
```bash
pzm whitelist add "PlayerName" "STEAM_0:1:12345678"
```

**Retirer un joueur** :
```bash
pzm whitelist remove "STEAM_0:1:12345678"
```

**Notes** :
- Steam ID requis : **Steam ID 32** (format `STEAM_0:X:YYYYYYYY`)
- Convertir Steam64 → Steam32 : [steamid.xyz](https://steamid.xyz/)
- Changements appliqués au prochain redémarrage serveur

### Mods

Documentation complète : [PZ Wiki - Modding](https://pzwiki.net/wiki/Modding)

**Installation rapide** :
1. Trouver mod sur [Steam Workshop](https://steamcommunity.com/app/108600/workshop/)
2. Noter le Workshop ID (numéro dans l'URL)
3. Éditer servertest.ini :

```ini
Mods=modname1;modname2
WorkshopItems=2992700364;111111111
```

4. Redémarrer : `pzm server restart 15m`

### Ports réseau

Ports par défaut (configurés automatiquement par pzmanager) :
- **16261/UDP** - Jeu principal
- **16262/UDP** - Jeu secondaire
- **8766/UDP** - RCON
- **27015/TCP** - Steam query

Modification (seulement si conflit) :
```ini
# servertest.ini
DefaultPort=16261
UDPPort=16262
```

⚠️ Modifier nécessite reconfigurer le firewall manuellement

## Ressources

- [CONFIGURATION.md](CONFIGURATION.md) - Variables .env, backups, Discord
- [ADVANCED.md](ADVANCED.md) - Performance, RCON, optimisations
- [Documentation officielle PZ](https://pzwiki.net/wiki/Dedicated_Server)
