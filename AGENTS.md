# Consignes — pzmanager

Exécuter les tests dans une copie Linux jetable : ils peuvent modifier
`/tmp` et `.env`, et ne doivent pas tourner sur une installation active.
Chaque scénario doit rétablir ses doubles de commande et son état simulé ;
un refus du bus systemd ne constitue pas une preuve de rejet d'une entrée SQL.

Après fusion : fetch prune, pull fast-forward sur main propre, suppression
locale par `git branch -d` seulement. Signaler les refus et les branches ou
modifications non intégrées avant de les reprendre sans autorisation.
