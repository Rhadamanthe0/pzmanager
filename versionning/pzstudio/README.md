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
