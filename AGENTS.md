# Consignes — pzmanager

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

Après fusion : fetch prune, pull fast-forward sur main propre, suppression
locale par `git branch -d` seulement. Signaler les refus et les branches ou
modifications non intégrées avant de les reprendre sans autorisation.
