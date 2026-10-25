# Référentiel du projet PZManager

Statut : **VALIDÉ — 2026-10-24**.
Responsable : directeur.

Les propositions restent à valider ; les documents liés ne sont pas approuvés implicitement.

## 1. Présentation du projet

**Existant.** PZManager administre Project Zomboid Build 42 sous Linux par CLI `pzm`, interface Discord facultative et annonces aux joueurs.

**Périmètre proposé.** Code, tests, modèles, CI, documentation, versionnement. Exclus : données locales ignorées, exploitation active, administration externe, modification du jeu ; exports sans régénération imposée.

## 2. Spécifications fonctionnelles

**Critères proposés.**

- Installation : chemins, identités, unités, paramètres ; prérequis manquants explicités ; disponibilité réelle du jeu avant « prêt ».
- Cycle de vie : sérialisation, contrôles avant JVM, délais et annonces respectés ; arrêt permettant la sauvegarde ; échecs remontés.
- Console : commande validée vers FIFO, réponse attribuable distincte du silence ; « rcon » ne signifie pas RCON TCP.
- Sauvegarde : publication après copie complète ; dernier résultat valable préservé après interruption ; snapshot à chaud sans garantie applicative ; rétention par classes préservant les récupérations nécessaires.
- Restauration complète, personnage ou zone : source et périmètre validés avant mutation ; application serveur prouvé arrêté ; aperçus sans modification du monde ; remplacement limité, récupération vérifiable après échec/interruption ; carte aux tuiles demandées, toutes hauteurs.
- Reset/wipe : suppressions explicites, arrêt prouvé et sauvegarde réussie avant destruction ; options de conservation respectées ; wipe des chunks couvrant la sélection et métadonnées de cellule.
- Accès : fermé par défaut ; validation SteamID, comptes et mots de passe ; retrait d’accès sans suppression implicite du personnage ; ancienneté inconnue ne justifiant pas une purge.
- Maintenance : distinguer jeu/mods et source indisponible/absence de mise à jour ; respecter verrous, délais, annonces et redémarrage demandé.
- Writing : avant la JVM, serveur arrêté, conserver le texte, retirer les dessins visés avec validation native ; format/prérequis invalides refusés avant mutation.
- Discord : appelants autorisés et espaces configurés ; arguments `pzm` sans shell ; erreurs, délais dépassés et résultats partiels explicites.
- Supervision : disponibilité, mémoire, blocages et notifications selon leur source ; mesure absente sans valeur inventée.

Détails : [USAGE](USAGE.md), [Writing](WRITING_TEXT_ONLY.md), [Discord](DISCORD_BOT.md).

## 3. Architecture technique — DAT

**Existant.** Bash orchestre, Python traite données/Discord, Java lit formats natifs ; SQLite et binaires du jeu persistent. Bibliothèques communes : configuration, verrous, état. Adaptateurs Discord → argv CLI → métier → helpers → services/fichiers ; FIFO → jeu, journaux/état → réponses/disponibilité. systemd pilote serveur, tâches et bot ; SteamCMD/Workshop fournissent jeu/mods ; Google Sheets reçoit le versionnement.

Racine Zomboid : mondes, comptes, configuration ; sauvegardes, ancienneté, récupération : cycles distincts. Journal transactionnel hors racine, survivant à son déplacement. `.env` porte configuration/secrets ; compte dédié et sudo ciblé. Modifier un modèle n’actualise pas les installations existantes.

**Cible proposée.** Contrôles dans le composant responsable, erreurs jusqu’à l’appelant, données externes/sauvegardées validées avant commande/chemin/SQL/écriture. Secrets/états privés réservés au propriétaire, chemins non fiables refusés, protections systemd préservées ; paramètres appelant sans preuve d’autorisation/verrou. Transaction inachevée : démarrage interdit jusqu’à récupération choisie et vérifiée, sans effacer les preuves ni reprendre automatiquement l’écriture.

**Exécution existante.** Debian/Ubuntu, systemd, cgroup v2 ; budget `pz.slice` partagé jeu/gestion, sans swap ; UID jeu/manager distincts refusés. Compatibilité des outils multi-utilisateurs non établie. **Cible proposée.** Préserver ce budget et ses refus. [ARCHITECTURE](ARCHITECTURE.md).

## 4. Contraintes et invariants

**Approuvés.** Verrou SERVERCTL résolu à l’acquisition, inutile aux lectures/ExecStartPre confiné ; ordre WORLD → SERVERCTL, FD hérité, aucun verrou vivant supprimé ni chemin remplaçable par un tiers. Writing : monde propre sans compilateur ; dessins avec JDK compatible distinct de la JRE Steam, `--release` préservé et copies de récupération.

Tests isolés et règles Git : [consignes du dépôt](../AGENTS.md). Une simulation ne valide ni le vrai jeu ni l’hôte systemd ; un contrôle indisponible reste non vérifié. Une passe propre exige la réussite de tous les contrôles requis ; les contrôles facultatifs non exécutés restent signalés. Fusion après CI verte, branche à jour, revues achevées et discussions résolues ; vérification finale des conversations par API paginée et utilisation du SHA attendu.

## 5. Décisions structurantes

**Limites proposées.** Corrections sans refonte ni dépendance nouvelle. Besoin, contrat public, frontières de sécurité, migration/compatibilité des données et production : décision du directeur. Travaux préexistants préservés, sans publication implicite.

## 6. Règles de maintien du référentiel

Toute modification de ce référentiel, règles comprises, exige l’accord explicite du responsable du projet sur les changements précis proposés. Prépare les changements hors du fichier jusqu’à cet accord.

Conserve une seule source par fait, exigence ou décision. À chaque révision, élimine les doublons, références périmées, détails volatils et phrases peu utiles. Résous les contradictions à partir des décisions approuvées ; sinon, signale-les au directeur. Reformule avec précision et concision sans perdre de nuance nécessaire, d’invariant ou de décision approuvée. Privilégie les responsabilités, interfaces, contrats et choix durables à l’inventaire du code. Distingue faits observés, décisions approuvées, propositions et inconnues. Vérifie les liens relatifs ; ne change jamais une exigence pour masquer un écart du code.

Avant toute création ou modification, relis chaque phrase ajoutée ou modifiée isolément, mot par mot, puis dans son contexte. Chaque phrase doit apporter une information nécessaire, exacte et non redondante ; chaque mot doit contribuer au sens. Répète la relecture de toutes les modifications jusqu’à deux passes locales complètes consécutives sans amélioration sur le même texte.

Relis ensuite le document entier, de la première à la dernière section : cohérence, répétitions, lacunes, contradictions, obsolescence, liens et compréhension sans historique. Exige deux passes globales complètes consécutives sans amélioration sur le même texte. Toute correction annule la passe et remet à zéro son compteur ; si elle survient pendant une revue globale, recommence les passes locales sur les phrases touchées, puis les passes globales. Une variante de style sans gain de précision, utilité, exactitude, clarté ou concision n’est pas une amélioration.

N’écris que les modifications approuvées. Vérifie que le fichier enregistré correspond au texte autorisé.
