# Mise à jour des mods PZ — spécificités de CE serveur

> **La procédure elle-même est versionnée : `docs/MOD_UPDATES.md`.**
> Lis-la EN ENTIER d'abord — étapes, ordre de chargement, pré-téléchargement,
> pièges (bandeau Steam mensonger, `result=3`), déploiement, rollback.
>
> Ce fichier-ci ne contient QUE ce qui est propre à ce serveur et qui n'a pas sa
> place dans le dépôt public. Ne duplique rien ici.

## Fichiers locaux

- `V[N].txt` — une version par fichier (voir format ci-dessous).
- `Mods bugués à intégrer plus tard.csv` — mods écartés après échec de la
  vérification en jeu, avec le symptôme observé.

## Format de V[N].txt — ALLÉGÉ (modèle ci-dessous), identique à chaque version

Format **lean** voulu par l'admin (2026-07-23) : **PAS** de gros bloc de
commentaires d'analyse (`# !!! STATUT / DECOUVERTE / OVERLAPS / NB …`). Les notes
d'analyse (conflits de cartes, bugs amont, périmètre réel du mod, options sandbox,
compat `versionMin`/`versionMax`, pré-téléchargement) vont dans la **réponse à
l'admin**, pas dans le fichier. **Labels GÉNÉRIQUES — jamais de numéro de version
dedans.** Un `V[N].txt` contient, dans cet ordre :

1. Une **seule** ligne de sauvegarde : `# Derniere sauvegarde avant déploiement : backup_YYYY-MM-DD_HHhMMmSSs (creee par le stop lui-meme).`
2. Les trois lignes `Mods=` / `WorkshopItems=` / `Map=`.
3. La table des changements sous `# Ajout par rapport à la version précédente :` (lignes `AJOUT` / `RETRAIT` / `MODIF`).
4. **La table finale sous `# Liste complète des mods :`, numérotée, listant TOUS les mods de la version.**

Le point 4 est celui qu'on oublie (V19/V20 l'avaient perdu) : ne le redrope pas.
Les deux tables (3 et 4) DOIVENT utiliser de vraies **TABULATIONS** entre colonnes
— `sheetVersionning.sh load` splitte sur `\t` pour remplir les colonnes du Sheet.

### Modèle (à copier)

```
# Derniere sauvegarde avant déploiement : backup_2026-07-23_12h18m50s (creee par le stop lui-meme).

Mods=\Mod1;\Mod2;…
WorkshopItems=111;222;…
Map=CarteCustom;…;Muldraugh, KY

# Ajout par rapport à la version précédente :
#⇥Categorie⇥Nom du Mod⇥Workshop ID⇥Mod ID⇥Motif
AJOUT⇥Armes⇥Nom lisible⇥123456⇥ModID⇥Ce que ça fait / pourquoi.

# Liste complète des mods :
#⇥Catégorie⇥Nom du Mod⇥Workshop ID⇥Mod ID⇥Utilité
1⇥Tech⇥Nom⇥111⇥ModID⇥Utilité
```
(⇥ = une TABULATION réelle, pas des espaces.)

## Étape de traçabilité propre au site

Le Google Sheet « Versionning des mods » est la restitution de l'étape 6 de
`docs/MOD_UPDATES.md`. Après le déploiement, **deux commandes** :

```bash
# 1. Créer l'onglet V[N] (cloné du précédent, masque les anciens)
versionning/sheetVersionning.sh new [N]        # sans N → max+1 ; variantes : list / hide-old

# 2. Le PEUPLER avec le vrai contenu de V[N].txt (sinon l'onglet reste un clone figé).
#    V[N].txt EST déjà le TSV (les tables utilisent de vraies tabulations) -> on le
#    charge directement, pas besoin de générer un fichier .tsv séparé :
versionning/sheetVersionning.sh load V[N] versionning/V[N].txt
```

⚠️ **`new` seul NE SUFFIT PAS** : il *clone* l'onglet précédent, il ne recopie
pas V[N].txt. Sauter l'étape 2 est ce qui a gelé les onglets V11→V28 sur le
contenu de V10 (noms d'onglets qui avancent, données figées). **Toujours faire
`load` après `new`.** Vérifier avec `show V[N] A1:B6` que l'en-tête affiche bien
la bonne version. (`show`/`setcell`/`load` sont des sous-commandes utilitaires du
script ; compte de service ; clé en base64 dans le `.env` de la racine (`GOOGLE_SERVICE_ACCOUNT_JSON_B64`).)

**Un `V[N].txt` sans son onglet Sheet peuplé = process non terminé.**
