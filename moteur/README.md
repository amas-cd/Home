# /Applications/Home/moteur — moteur des jeux et scripts

## Tout se fait depuis Home

Plus aucun script à double-cliquer : Home (/Applications/Jeux/Home.app) fait tout.
- **Options d'un jeu** → Réglages du jeu (images par seconde, MetalFX, serveur en ligne, rendu TOTK), Mods (GameBanana, fichiers),
  Mises à jour (installer une mise à jour, Reconstruire — sans NSP ni ROM), Apparence, Catégorie.
- **Case +** → ajouter un jeu (Switch avec nxnative ou MacNativeGames, PC Epic/Steam via Obelisk, app Mac).
- **Menu → Avancé** → mettre à jour le moteur nxnative, alléger les dossiers de construction, lancement direct Epic, journaux pour Claude.

`outils/` contient ce que Home lance (dans le Terminal) : construire-jeu, mng-reconstruire, totk-mng-online, mng-mods-appliquer,
mettre-a-jour-et-rebuild, alleger-build.sh, journaux, totk-moniteur, rocket-league-direct, et les serveurs en ligne
(totk-server.sh, smoo-server.sh, lancés par les jeux). Ne pas les déplacer.

## Dossiers

- `engine/` : nxnative officiel (commit dans `.upstream-ref`) + les patchs de `patches/` (online TOTK/SMO, 60 fps TOTK, mode jeu coupé, écran principal…).
  NX Library l'utilise comme dépôt moteur avec « Forcer une chaîne d'outils non testée ». Ne jamais cliquer « Switch / Back to tested » ni « Update ».
- `exefs-mods/<title id>/` : mods de code appliqués automatiquement (TOTK_Online, SMO_Online_v1).
- `tools/engine.py` : gestion du moteur (bump / sync / check).

## Salon (launcher façon PS5)
`salon/salon-construire.command` compile `salon/main.swift` en `/Applications/Jeux/Salon.app`. Réglages et médias : `~/Library/Application Support/Salon` (voir LISEZMOI.txt là-bas).
