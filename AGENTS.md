# Consignes — pzmanager

ProjectWriting : un monde propre ne requiert pas de compilateur. Un monde avec
dessins exige un JDK compatible, distinct de la JRE Steam ; voir
`docs/WRITING_TEXT_ONLY.md`. Préserver `--release` pour la JVM choisie, les
refus avant mutation du monde et les copies de récupération. Ne pas installer
de paquet ni désactiver le nettoyage pour faire passer une validation.

Exécuter les tests dans une copie Linux jetable : ils peuvent modifier
`/tmp` et `.env`, et ne doivent pas tourner sur une installation active.
Chaque scénario doit rétablir ses doubles de commande et son état simulé ;
un refus du bus systemd ne constitue pas une preuve de rejet d'une entrée SQL.

Le verrou serverctl est résolu à l'acquisition, jamais au sourçage de
`common.sh` : les lectures et l'ExecStartPre confiné n'en ont pas besoin.
Préserver l'ordre WORLD → SERVERCTL et l'héritage du FD par les descendants.
Ne pas supprimer un verrou vivant ni accepter un chemin remplaçable par
un autre utilisateur. Vérifier `tests/test_sec_serverctl.sh`, C1, C5 et la
suite des répertoires privés dans une copie Linux jetable.

Après fusion : fetch prune, puis pull fast-forward sur main propre.
Supprimer les branches locales par `git branch -d` ; `git branch -D` est autorisé
si leur fusion est vérifiée (y compris squash/rebase), si leur PR est fermée
sans fusion ou si le directeur a explicitement confirmé leur abandon.
Vérifier la pointe locale et la PR avant suppression : tout commit ajouté
après la PR et toute modification locale de worktree doivent être préservés
ou explicitement abandonnés. Conserver et signaler les cas non établis.
