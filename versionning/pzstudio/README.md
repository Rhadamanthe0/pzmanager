# Sauvegardes PZ Studio (mod DrSuppo, Workshop 3790437913)

## Pourquoi

PZ Studio écrit sa configuration **dans le dossier du mod**, sous
`data/pzserver/steamapps/workshop/content/108600/3790437913/mods/PZStudio/common/generated/contexts/<module>.json`.

Ce chemin est dans l'arborescence SteamCMD : **toute mise à jour Workshop du mod — ou un
`steamcmd +app_update … validate` (maintenance nocturne) — peut l'écraser**. Il n'est couvert
par aucune sauvegarde de PZManager (`data/pzserver/` est exclu des snapshots comme du ZIP
hors-site : tout y est re-téléchargeable… sauf ce fichier).

D'où ce dossier : il est versionné dans git **et** embarqué dans le ZIP hors-site
(`versionning/` fait partie de `DIRS_TO_SYNC` de `fullBackup.sh`).

## Contenu

- `professions-contexts-<date>.json` — copie **à l'identique** du fichier du mod
  (`contexts/professions.json`), tous contextes confondus. Format : `{version, contexts:{<clé>:{id,data}}}`.
- `professions-export-<date>.txt` — le seul `data` du contexte serveur
  (`server_servertest_48cac242`, `id={name:servertest,type:server}`), mis en forme comme la
  fenêtre **Import / Export** du mod (une clé par ligne). C'est la chaîne à coller dans le
  champ Import.

La date du nom de fichier est la **mtime du fichier source** (dernière modification de la config
en jeu), pas la date de la copie.

## Restaurer

Deux voies, au choix :

1. **En jeu (recommandé)** : PZ Studio → module Professions → `Import / Export` → coller le
   contenu de `professions-export-<date>.txt` → Import, puis sauvegarder.
2. **Fichier** : serveur arrêté, recopier `professions-contexts-<date>.json` par-dessus
   `…/mods/PZStudio/common/generated/contexts/professions.json`.

## Refaire une sauvegarde

```bash
SRC=data/pzserver/steamapps/workshop/content/108600/3790437913/mods/PZStudio/common/generated/contexts/professions.json
cp -p "$SRC" "versionning/pzstudio/professions-contexts-$(date -r "$SRC" +%F).json"
```
(puis régénérer le `.txt` si besoin — c'est juste le sous-objet `data` du contexte serveur.)

## Incident du 2026-09-01 : limite de 32 767 octets

Le 01/09 à 14:40, l'ajout de `profession_29` a porté le payload publié par PZ Studio à
**32 774 octets**, soit **7 de trop**.

Le moteur PZ (`zombie.GameWindow$StringUTF.save`) écrit la longueur d'une chaîne sur un
**short signé** (`i2s` puis `putShort`) tout en écrivant le contenu en entier : au-delà de
**32 767 octets**, la longueur déborde en négatif, le lecteur se désynchronise et
`global_mod_data.bin` devient illisible. Résultat : `invalid lua table type 83` au boot,
serveur en boucle de crash.

Attention, **les caractères non-ASCII comptent double** : la chaîne Lua est convertie
octet → char, donc chaque octet ≥ 0x80 est ré-encodé sur 2 octets en UTF-8 modifié. Ici
`#payload` valait 32 754 mais 32 774 octets étaient écrits.

Correctif amont : DrSuppo a publié le 01/09 à 17:28 un garde-fou
(`ContextSyncService.MAX_STRING_BYTES = 32767` + `fitsOnTheWire`) qui **refuse** de publier
un payload trop gros au lieu de corrompre la sauvegarde. Les professions ne s'appliquent
alors plus (clients en vanilla), en attendant son correctif définitif (découpage du payload).

La maj Workshop de 17:36 a **effacé** `contexts/professions.json` — le risque décrit plus haut.
`professions-contexts-2026-09-01.json` a donc été **reconstruit** en extrayant le payload du
`global_mod_data.bin` corrompu (décodage UTF-8 modifié → latin-1). Il contient les 296 clés,
`profession_29` comprise, et est identique au 30/08 à cette profession près.
