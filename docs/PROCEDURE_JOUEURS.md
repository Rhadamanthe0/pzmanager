# Procédure de connexion — Les Terres Grises (Build 42)

> Texte à copier/coller pour les nouveaux joueurs (ex. sur Discord).
> Le serveur est en liste blanche **par SteamID** : un membre du staff doit
> autoriser votre compte Steam avant votre première connexion.

---

## Étape 1 — Installer la bonne version du jeu (Build 42 / unstable)

1. Dans Steam, **clic droit sur Project Zomboid → Propriétés**.
2. Onglet **« Versions et bêtas »** → sélectionnez **`unstable`** (Build 42).
3. Fermez les propriétés et **laissez le jeu se mettre à jour** complètement.

## Étape 2 — Récupérer votre SteamID64 et l'envoyer au staff

Avant de pouvoir vous connecter, le staff doit autoriser votre compte Steam.

1. Récupérez votre **SteamID64** : c'est un nombre de 17 chiffres commençant par
   `7656119…`. Le plus simple : allez sur **https://steamid.xyz/**, connectez-vous,
   et copiez la ligne **`steamID64`**.
   *(Sinon, il se trouve aussi à la fin de l'URL de votre profil Steam.)*
2. **Envoyez ce SteamID64 au membre du staff qui vous a accueilli.**
3. **Attendez sa confirmation** que votre SteamID a été autorisé.
   ⚠️ Tant que ce n'est pas fait, le serveur **refusera** votre connexion.

> Vous n'avez **pas** besoin d'envoyer de mot de passe : vous le choisirez
> vous-même à l'étape suivante.

## Étape 3 — Ajouter le serveur dans le jeu

Lancez le jeu, cliquez sur **« En ligne »**, puis en haut à droite **« Ajouter un serveur »**
et renseignez (sans les guillemets) :

| Champ | Valeur |
|---|---|
| Nom du serveur | `Les Terres Grises` |
| IP | `pz.rhada.net` |
| Port | `16261` |
| Mot de passe du serveur | `TerraeGriseae` |
| Nom d'utilisateur | **votre pseudo Discord** (ex. `Rhadamanthe`) |
| Mot de passe | **un mot de passe que VOUS choisissez** — notez-le bien ! |

> 🔐 **Le « Mot de passe » ici est votre mot de passe de compte personnel**, que
> vous inventez maintenant. Notez-le précieusement : **le perdre = perdre l'accès
> à votre personnage.** (En cas d'oubli, le staff peut le réinitialiser.)

Cliquez sur **« Ajouter »**.

## Étape 4 — Se connecter

1. Sélectionnez **« Les Terres Grises »** dans la liste.
2. Cliquez sur **« Connexion au serveur »**.
3. À la **première connexion**, votre compte est créé automatiquement avec le
   mot de passe que vous avez choisi, et **lié à votre compte Steam**.
4. Créez votre personnage. 🎉

Aux connexions suivantes, il suffira de sélectionner le serveur et de cliquer sur
**« Connexion au serveur »**.

---

## En cas de problème

- **« Connexion refusée » / kické tout de suite à la connexion** → votre SteamID
  n'est probablement pas encore autorisé. Vérifiez auprès du staff que votre
  **SteamID64** a bien été ajouté (et que vous l'avez transmis correctement).
- **Mot de passe de compte oublié** → demandez au staff une réinitialisation,
  puis vous en choisirez un nouveau à la connexion suivante.
- **« Invalid username »** → reconnectez-vous avec **exactement** le même pseudo
  qu'à votre première connexion (sensible à la casse).

---

### Mémo staff (pas pour les joueurs)

```bash
pzm whitelist add "<SteamID64>" "<pseudo>"   # autoriser un joueur (serveur démarré)
pzm whitelist list                            # voir SteamID autorisés / comptes / bannis
pzm whitelist remove "<pseudo ou SteamID64>"          # retrait amiable
pzm whitelist remove "<SteamID64>" --ban              # retrait + bannissement définitif
pzm whitelist resetpassword "<pseudo>"        # reset mot de passe d'un joueur
```
