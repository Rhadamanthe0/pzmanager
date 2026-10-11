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

`configureWritingTextOnly.sh`, appelé par `ExecStartPre`, retire l'ancien bloc
Lua des SandboxVars et les anciens fichiers du garde sous `media/lua/server/`.
Le fichier `PZManagerWritingTextOnly.lua` conservé avec les scripts est inerte.
Aucun fichier Workshop ou client n'est modifié ; le checksum des clients reste
inchangé. Le nettoyage est exécuté par `cleanWritingDrawings.py` sur les fichiers
arrêtés du monde, avec copies de récupération et validation des formats.
Les objets modifiés sont également chargés et relus par le véritable JAR du jeu
avant toute mutation. Un JDK compatible avec la JVM du serveur est nécessaire
lorsqu'un objet doit être nettoyé. Le helper choisit la JVM réellement lancée sous
`jre64/bin/java` et son `javac` voisin ; `JAVA_PATH` peut viser un autre JDK.
`PZ_WRITING_CLEANUP_JAVA` et `PZ_WRITING_CLEANUP_JAVAC` permettent de fournir
explicitement ces deux exécutables, sans installation automatique de paquet.
Un format ambigu, une sauvegarde incohérente ou une erreur bloque le démarrage.
Le format pris en charge est celui des sauvegardes 249 de PZ 42.21. Les objets
éditables ProjectWriting connus sont pris en charge ; les types ou enveloppes
non reconnus sont refusés avant toute mutation. Ce nettoyage n'est pas un
filtrage universel des données envoyées par des clients modifiés.
Le parcours utilise huit lecteurs avec une prélecture limitée à seize fichiers ;
le traitement des documents reste séquentiel. Le parcours complet peut prendre
plusieurs minutes sur un grand monde ; l'unité réserve jusqu'à vingt minutes au
démarrage.

Les copies de récupération sont placées sous
`${BACKUP_DIR}/projectwriting-cleanups`. L'unité fournie autorise par défaut
`data/dataBackups`. Si `BACKUP_DIR` pointe ailleurs, ajouter ce chemin à
`ReadWritePaths` dans un override systemd ; ne pas retirer le confinement global.

Le nettoyage exige un verrou WORLD et une preuve que la JVM est arrêtée.
`activating` n'est accepté que par le propre processus `ExecStartPre` de l'unité,
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

Exécuter dans une copie Linux jetable du dépôt :

```sh
python3 tests/test_writing_text_only.py
python3 tests/test_writing_start_admission.py
python3 tests/test_writing_restart_cleanup.py
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
