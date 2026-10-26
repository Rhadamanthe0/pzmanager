# ProjectWriting : nettoyage aux redémarrages

Lorsque `ProjectWriting` figure dans `Mods` et que `PZ_WRITING_TEXT_ONLY=1`
(valeur par défaut), les dessins `ink` et symboles `sym` des documents enregistrés
sont nettoyés **avant chaque démarrage de la JVM**, serveur arrêté. Les joueurs
hors ligne et les cases du monde non chargées sont concernés. Aucun hook Lua ne
supprime de contenu pendant la session : un symbole ajouté reste jusqu'au prochain
redémarrage. Les pages texte, notes, couleurs et positions du texte sont conservées.

Les options natives `ProjectWriting.Freehand=false` et
`ProjectWriting.VanillaMap=true` restent appliquées. Le dessin libre demeure donc
désactivé et les cartes utilisent l'interface du jeu. Réactiver l'outil de dessin
est une décision distincte : nettoyer seulement au redémarrage ne protège pas
d'une croissance mémoire pendant une longue session.

Une admission WORLD authentifiée unique couvre `Open=false`, le nettoyage Writing
puis la purge des accès inactifs, dans cet ordre, via `prepareWorldStart.sh`. Les
deux premières étapes bloquent le démarrage en cas d'échec ; la purge reste non
bloquante. Dans cette chaîne `ExecStartPre`, `configureWritingTextOnly.sh` retire
l'ancien bloc Lua des SandboxVars et les anciens fichiers du garde sous `media/lua/server/`.
Le fichier `PZManagerWritingTextOnly.lua` conservé avec les scripts est inerte.
Aucun fichier Workshop ou client n'est modifié ; le checksum des clients reste
inchangé. Le nettoyage est exécuté par `cleanWritingDrawings.py` sur les fichiers
arrêtés du monde, avec copies de récupération et validation des formats.
Les objets modifiés sont également chargés et relus par le véritable JAR du jeu
avant toute mutation. Un JDK compatible avec la JVM du serveur est nécessaire
lorsqu'un objet doit être nettoyé. Le helper choisit la JVM réellement lancée sous
`jre64/bin/java`. Le compilateur est choisi séparément : override explicite,
`JAVA_PATH/bin/javac`, voisin de la JVM, puis `javac` du PATH du service.
`PZ_WRITING_CLEANUP_JAVA` et `PZ_WRITING_CLEANUP_JAVAC` permettent de fournir
explicitement ces deux exécutables, sans installation automatique de paquet.
La JRE Steam et `openjdk-*-jre-headless` **ne fournissent pas** ce compilateur.
Avant le nettoyage d'un monde avec dessins, installer un JDK adapté à la majeure
annoncée par `jre64/bin/java -version` (par exemple `openjdk-25-jdk-headless`
lorsque la JVM est 25 et ce paquet est disponible), ou fournir un JDK compatible
déjà installé. Renseigner son chemin absolu dans `PZ_WRITING_CLEANUP_JAVAC`
du `.env`, sans remplacer le runtime Steam. La compilation utilise `--release`
avec la majeure de la JVM sélectionnée ; un compilateur trop ancien ou incapable
de lire le JAR du jeu est refusé. Un override invalide n'est jamais remplacé.
Un monde absent, vide ou sans dessins ne demande aucun JDK. Avec dessins, une
dépendance absente produit un diagnostic explicite et bloque le démarrage avant
toute mutation du monde ; l'échec du nettoyage n'est jamais ignoré. La politique
native peut déjà avoir été appliquée aux fichiers de configuration.
Un format ambigu, une sauvegarde incohérente ou une erreur bloque le démarrage.
Le format pris en charge est celui des sauvegardes 249 de PZ 42.21. Les objets
éditables ProjectWriting connus sont pris en charge ; les types ou enveloppes
non reconnus sont refusés avant toute mutation. Ce nettoyage n'est pas un
filtrage universel des données envoyées par des clients modifiés.
Les limites, identités et ancêtres des objets proviennent des appels du lecteur
natif du JAR et de son dictionnaire binaire, liés aux empreintes des fichiers.
Une copie privée de la classe de lecture est instrumentée ; le JAR installé
n'est jamais modifié. Les fichiers entiers sont relus, y compris les blobs des
personnages et `reanimated.bin`. Un objet ignoré, absent ou tronqué par le lecteur
tolérant du jeu est un refus, même si le chargement normal ne lève aucune erreur.
La compatibilité exacte avec le JAR reste nécessaire ; une instrumentation
incompatible bloque avant mutation, sans repli sur les motifs binaires.
Le lecteur suit la réconciliation native du dictionnaire avec le profil de mods
sélectionné : un mod effectivement réactivé retrouve ses identifiants existants.
Les objets d'un mod toujours inactif ou obsolète restent refusés. Cette lecture
ne réactive aucun mod dans la configuration du serveur.
Le parcours utilise huit lecteurs avec une prélecture limitée à seize fichiers ;
le traitement des documents reste séquentiel. Le parcours complet peut prendre
plusieurs minutes sur un grand monde ; l'unité réserve jusqu'à vingt minutes au
démarrage.

Les copies de récupération sont placées sous
`${BACKUP_DIR}/projectwriting-cleanups`. L'unité fournie autorise par défaut
`data/dataBackups`. Si `BACKUP_DIR` pointe ailleurs, ajouter ce chemin à
`ReadWritePaths` dans un override systemd ; ne pas retirer le confinement global.

Un journal durable privé reste à côté de la racine Zomboid :
`.Zomboid.pzm-transactions`. Il survit au déplacement de cette racine pendant une
restauration complète. L'installateur le crée ; lors d'une mise à niveau, préparer
ce dossier sous l'identité du manager avec `world_transaction.py init --world
<racine-Zomboid>`, puis appliquer le chemin `ReadWritePaths` du nouveau template.
Pour une racine personnalisée, adapter ce chemin exact. Aucun déploiement de ces
changements n'est automatique.

Une intention inachevée bloque tous les démarrages, même si Writing est désactivé.
Le démarrage ne reprend ni ne restaure de données. Après examen des copies,
`pzm backup resume-writing <copie-de-récupération>` permet une reprise explicite
avec validation complète, serveur arrêté. Pour les autres récupérations, restaurer
explicitement l'image choisie, puis `pzm backup verify-recovery <id>
--restored|--reverted` : cette commande ne réécrit rien et ne clôture que si les
empreintes attendues correspondent. Les journaux et copies Writing sont conservés.
Les restaurations de dossiers et de zones gardent leurs copies temporaires tant
que l'opération reste inachevée ; après résultat complet ou rollback vérifié et
journal synchronisé, ces copies temporaires sont supprimées. Les sauvegardes et
récupérations historiques ne sont pas nettoyées par cette opération.
La restauration de dossiers conserve les autres données présentes (Logs, options,
dossiers absents du backup) ; les empreintes du journal portent sur chaque dossier
sélectionné, y compris Lua quand il est présent.

Le nettoyage exige un verrou WORLD et une preuve que la JVM est arrêtée.
`activating` n'est accepté que dans la chaîne `ExecStartPre` authentifiée de l'unité,
avec `MainPID=0` et `SubState=start-pre`. Les opérations manuelles exigent un état
`inactive`. Un refus du bus systemd refuse également le nettoyage.
Lorsque `pzm server start/restart` tient déjà WORLD, un broker privé transmet le
même descripteur au processus de démarrage. Le verrou reste détenu si le parent
meurt pendant le nettoyage. Le répertoire runtime privé est conservé par systemd ;
ni le fichier du verrou ni son répertoire ne sont supprimés au stop.
Le broker vérifie les descripteurs du propriétaire et son propre verrou avant
publication et transfert. Le processus confiné authentifie le socket avec les
PID/UID du noyau, la naissance du broker et le jeton privé, puis vérifie l'inode
et le verrou du descripteur réellement reçu. Il ne lit pas les descripteurs
d'un processus extérieur via `/proc/PID/fd`, accès interdit dans son namespace.

`PZ_WRITING_TEXT_ONLY=0` ou le retrait du mod de `Mods` désactive le nettoyage au
prochain démarrage et retire les anciens hooks. Les options natives ne sont pas
rétablies et les dessins précédemment supprimés ne sont pas restaurés.

## Vérification

Depuis la racine d’un clone Git Linux jetable, exécuter les suites avec le runner isolé :

```sh
writing_results="$(mktemp -d /var/tmp/pz-writing-results.XXXXXXXX)"
python3 tests/run-isolated.py --results "$writing_results" \
    --only test_writing_text_only.py \
    --only test_writing_start_admission.py \
    --only test_writing_restart_cleanup.py
```

La sonde native suivante est facultative et se lance séparément dans une copie Linux jetable, avec un JDK compatible et des copies du JAR et de `stdlib.lua` :

```sh
tests/writing_text_only/run.sh --jar /chemin/copie/projectzomboid.jar \
    --stdlib /chemin/copie/stdlib.lua --jdk-bin /chemin/jdk/bin
```

Les fixtures vérifient l'absence de hooks continus, le checksum, la conservation
du texte, les refus sans mutation et l'héritage réel du verrou entre processus.
Une fixture de namespace utilisateur reproduit ce refus de `/proc/PID/fd` et
vérifie que le transfert authentifié fonctionne malgré lui ; elle est sautée
si le noyau interdit les namespaces, et doit alors être validée sur l'hôte cible.
Les tests du nettoyeur vérifient séparément les sauvegardes arrêtées et les copies
de récupération.

`tests/native_context_reinstatement.py` est une régression native facultative,
à exécuter dans un espace de noms Linux isolé avec des copies de l'installation
et du monde. Elle exige deux profils explicites (actif et restauré), un chunk et
un identifiant d'objet : le premier doit atteindre le refus natif de cet objet,
le second doit réellement le charger. Une panne de compilation ou une autre
erreur de lecture ne satisfait pas le témoin de refus. Les sources restent
inchangées et aucun serveur n'est démarré.
