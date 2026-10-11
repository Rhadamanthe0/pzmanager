# ProjectWriting en mode texte

Lorsque `ProjectWriting` figure dans `Mods`, le démarrage applique par défaut
`ProjectWriting.Freehand=false` et `ProjectWriting.VanillaMap=true` dans les
SandboxVars. L'outil de dessin libre disparaît pour les clients du mod et les
cartes utilisent l'interface du jeu.

Le script `configureWritingTextOnly.sh`, appelé par `ExecStartPre`, ajoute le
garde de `data/scripts/internal/PZManagerWritingTextOnly.lua` après la table du fichier
`Server/<serveur>_SandboxVars.lua`, dans un bloc marqué. Ce fichier de
configuration serveur est exécuté après le calcul du checksum Lua commun avec
les clients. Le contrôle des scripts reste activé et les fichiers Workshop et
clients ne sont pas modifiés. Une configuration ambiguë, un garde absent ou un
chemin cible non sûr refuse le démarrage.

Le jeu réécrit ensuite les SandboxVars et retire le bloc du disque, tout en
conservant le garde en mémoire. `ExecStartPre` réinjecte le bloc à chaque
démarrage. Les anciens fichiers du garde sous `media/lua/server/` sont retirés,
car ces fichiers participaient au checksum et empêchaient les connexions.

Le garde enlève les listes `ink` et `sym` des documents NeatWriting des objets
`Literature`, y compris ceux rangés dans des sacs. Il conserve les pages texte
du jeu, `t`, les notes `note`, les couleurs et les positions du texte. Il traite
les inventaires des joueurs à chaque tick, les objets au chargement des cases
et un balayage amorti de neuf colonnes autour des joueurs. Les annotations des
cartes vanilla restent disponibles.

Le bouton des symboles peut rester visible dans un livre ; le serveur supprime
ensuite les symboles ajoutés. Un dessin retiré d'un objet au sol peut rester
affiché chez un client jusqu'à la resynchronisation ou au rechargement de l'objet.
Les hooks Lua précèdent la sauvegarde ordinaire des inventaires, mais ne peuvent
pas intercepter tous les paquets de modification ni toutes les sauvegardes
globales. La désactivation native du dessin libre est donc essentielle ; le
garde ne garantit pas le rejet d'un client modifié envoyant de gros documents.

`PZ_WRITING_TEXT_ONLY=0` désinstalle le garde au démarrage. Les options natives
ne sont pas rétablies et les dessins déjà supprimés ne sont pas restaurés.
Si le mod est retiré de `Mods`, son garde est également désinstallé.

## Vérification

Dans une copie Linux jetable du dépôt, lancer :

```sh
python3 tests/test_writing_text_only.py
tests/writing_text_only/run.sh --jar /chemin/copie/projectzomboid.jar \
    --stdlib /chemin/copie/stdlib.lua --jdk-bin /chemin/jdk/bin
```

Les tests Python vérifient les modifications de configuration et les refus sans
mutation. Les fixtures Lua tournent sur le compilateur et le runtime Kahlua du
jeu, dans une copie temporaire, et vérifient la conservation du texte ainsi que
le nettoyage des sacs, des objets du monde et des modifications répétées.
