# Home — contexte pour Claude Code

## Avec qui tu travailles

Anas, sur son MacBook Air M5 (16 Go, macOS 27, sans ventilateur). Son écran de jeu principal est un moniteur AOC 1080p.
Il joue à la manette.

- Parle-lui **en français**, court et concret, étape par étape. Pas de jargon inutile, pas de suppositions : si tu ne sais
  pas, vérifie (code, journal, doc) avant de répondre.
- Tout est en français : interface de Home, commentaires du code, messages de commit, notes de version.
- Ne fouille pas son Mac au-delà de ce que la tâche demande. Pour une question pratique, donne les étapes.

## Ce qu'est Home

Un launcher de jeux façon console (style PS5) pour Mac, en Swift/SwiftUI. Tout tient dans un seul fichier, `app/main.swift`
(environ 3 500 lignes). Il affiche et lance :

- **les jeux Switch / Switch 2 recompilés en apps Mac** avec [nxnative](https://github.com/seedds/nxnative) (Ocarina of Time,
  Super Mario Odyssey…). Les apps sont dans `/Applications/Jeux` et ont une clé `DMTitleID` dans leur Info.plist ;
- **Tears of the Kingdom / Breath of the Wild** avec [MacNativeGames](https://github.com/ly05010419/MacNativeGames) (bundle id
  `org.macnativegames.*`). La copie d'Anas est `/Applications/Home/MacNativeGames`, avec ses propres commits par-dessus ;
- **les jeux PC Epic / Steam installés par Obelisk** (`com.zagrios.obelisk`). Home lit ses installations, et peut lancer
  directement les jeux Epic avec Legendary (`moteur/obelisk/`) ;
- **les apps Mac** ajoutées à la main.

Il gère aussi :
- les jaquettes, fonds et logos (NX Library, eShop, SteamGridDB, PlayStation Store, Wikipédia) ;
- les mods (GameBanana, RomFS, mods de code) ;
- la construction et la reconstruction des jeux, et la mise à jour du moteur, par des scripts lancés dans le Terminal ;
- le HUD en jeu : menu rapide, volume par jeu, capture des 15 dernières secondes, liste des joueurs en ligne ;
- l'ouverture automatique quand une manette se connecte (`app/veille.swift`).

Identifiants :
- **Home.app** : `fr.anas.salon` (exécutable `Salon`). « Salon » est son ancien nom, encore présent dans le code.
- **L'app de veille** : `fr.anas.home.veille`, avec le LaunchAgent `~/Library/LaunchAgents/fr.anas.home.veille.plist`.

## Le dépôt

Le dépôt est **amas-cd/Home**, privé : Anas et quelques amis invités.

| Chemin | Contenu |
|---|---|
| `app/main.swift` | Toute l'app Home |
| `app/veille.swift` | La petite app invisible qui ouvre Home à la connexion d'une manette |
| `app/sons/` | Sons de l'interface (Kenney, CC0) |
| `app/salon-construire.command` | Compile, signe et installe `/Applications/Home.app`. `HOME_BUILD_ONLY=<dossier>` : compile seulement. `HOME_VERSION=x.y.z` : version de l'app |
| `moteur/outils/` | Les scripts que Home lance (voir plus bas) |
| `moteur/patches/` | Les patchs d'Anas pour nxnative (`series` donne l'ordre) |
| `moteur/tools/` | `engine.py` (version figée de nxnative + patchs), notes de version, tests |
| `moteur/obelisk/` | Lancement direct Epic (Legendary), `launch.sh` du moteur Voile (repris d'Obelisk, GPL-3.0) |
| `moteur/pc/pc.py` | Jeux PC sans Obelisk : télécharge Voile, compte Epic (Legendary), bibliothèque, installation, lancement. Lancé par `outils/pc.command` |
| `moteur/compat/pc.json` | Liste de compatibilité PC, avec sources : `bloque` (jamais lancé), `verifie`, `linux`. Un jeu absent n'est jamais bloqué |
| `moteur/.upstream-ref`, `moteur/mng/` | Versions figées : commit de nxnative ; commit de MacNativeGames + les commits d'Anas en patchs |
| `scripts/installer-local.sh` | Recopie le dépôt dans `/Applications/Home/moteur`, puis compile et installe Home sur ce Mac |
| `.github/workflows/release.yml` | Compile Home.app sur `macos-26` (Swift 6.3) à chaque push. Publie une release avec `Home.zip` pour un tag `v*` ou pour « Run workflow » avec une version |
| `.claude/` | Ce contexte : le hook Stop qui te rappelle de demander l'envoi de la mise à jour |

**Jamais dans le dépôt** : jeux, ROM, NSP/XCI, clés (`prod.keys`, `title.keys`), fichiers système, clé SteamGridDB, clé SSH du
serveur (`*.pem`), jetons Epic/Legendary, recettes Obelisk propres à un Mac, journaux, sauvegardes. Le `.gitignore` en couvre
une partie : vérifie quand même `git status` avant chaque commit.

## Sur le Mac d'Anas (l'installation en service)

Tant que Home n'est pas autonome, l'app installée lit ses scripts dans **`/Applications/Home/moteur`**, pas dans le dépôt.
Le dépôt est la source : on modifie le dépôt, puis `scripts/installer-local.sh` recopie les fichiers là-bas.

| Emplacement | Rôle |
|---|---|
| `/Applications/Home.app` | L'app installée |
| `/Applications/Jeux/` | Les apps des jeux (nxnative, MacNativeGames…) |
| `/Applications/Home/moteur/` | Copie en service de `app/` (dans `moteur/salon/`) et de `moteur/` ; `engine/` = nxnative + patchs |
| `/Applications/Home/MacNativeGames/` | Le dépôt MacNativeGames d'Anas (ses commits par-dessus l'officiel) |
| `/Applications/Home/constructions/` | Les dossiers de construction des jeux (fichiers extraits : permettent de reconstruire sans ROM) |
| `/Applications/Home/registre.json` | Les jeux construits par Home et comment les refaire |
| `/Applications/Home/mods/<title id>/` | Mods de code (ex. TOTK Online) |
| `/Applications/Home/sauvegardes/<title id>/` | Sauvegardes des jeux nxnative (`DM_SAVE`) |
| `/Applications/Home/serveurs/` | `totk-adresse.txt` (adresse du serveur TOTK Online), `totk-cle.pem` (**secret**), serveur SMO |
| `/Applications/Home/log/` | `salon.log` (journal de Home), journaux des serveurs, `diag/` (« Journaux pour Claude ») |
| `~/Library/Application Support/Salon/` | Réglages de Home : `jeux.json` (struct `Config`), `media/`, `cache/`, `mods/`, `statistiques.json`, `durees.json`, `steamgriddb-api-key` (**secret**) |
| `~/Library/Application Support/nxnative/<title id>/env.txt` | Réglages d'un jeu nxnative (`DM_*`) ; `nxnative/volume.txt` = volume lu par le moteur patché |
| `~/Library/Logs/nxnative/<title id>.log`, `~/Library/Logs/MacNativeGames/totk.log` | Journaux des jeux |

## Carte de `app/main.swift`

Les sections sont marquées `// MARK:`. Cherche-les par nom, les numéros de ligne changent.

- **Modèle** : `Game` (un jeu ; `viaObelisk`, `titleID`, `storeID`), `Config` (jeux.json), `Entry`, `SalonMenu` / `SalonMenuItem` (tous les menus).
- **Sources d'images** : `EShop`, `SteamGridDB`, `PSStore`, `Wiki`.
- **`Library`** (ObservableObject, le cœur) :
  - l'état de l'interface ;
  - `launch()` / `openGame()` : lancement d'un jeu et variables d'environnement données au jeu (`TOTK_*` pour MacNativeGames) ;
  - le volume : `writeVolume`, `volumeSource` (`.engine` = volume.txt de nxnative, `.bgm` = Background Music, `.mac`) ;
  - le menu rapide (`quickItems`, `quickAct`) ;
  - le jeu en ligne : `enLigne()`, `joueursConnectes()`, `rafraichirJournalDistant()` ;
  - les menus d'options, de réglages et d'apparence.
- **`Recorder`** : capture continue (ScreenCaptureKit) pour « Enregistrer les 15 dernières secondes ».
- **`SystemVolume`, `BGM`** : volume général, volume par app via le périphérique Background Music. Échelle 0–100, 50 = normal.
- **`ObeliskDirect`** : installations Obelisk, recettes de lancement direct, `run()` pour lancer une commande.
- **Vues** : `Screen`, `MenuView`, `TacheView` (avancement des scripts lancés dans le Terminal), `HUDView` (au-dessus du jeu), `JoueursView`.
- **Manette** : `PadBattery`, `PadSeize` (saisie exclusive pendant le menu rapide).
- **`AppDelegate`, `SalonMain`** (`@main`).
- **`Atelier`** :
  - les chemins (`Atelier.home` = `/Applications/Home`, `Atelier.jeux` = `/Applications/Jeux`) ;
  - le lancement des scripts dans le Terminal (`lancer`, `terminal`) ;
  - les mods, `registre.json`, GameBanana ;
  - le moteur d'un jeu (`moteurDe`, `scriptDedie`).

Style du code : lignes denses, commentaires en français qui expliquent **pourquoi**. Garde ce style.

## Les scripts (`moteur/outils/`)

Home les lance dans le Terminal, sans le PATH du Terminal (ajoute Homebrew au PATH si besoin, comme les scripts existants) :

| Script | Rôle |
|---|---|
| `construire-jeu.command` | Construire un jeu Switch en app Mac (nxnative ou MacNativeGames) à partir de la ROM |
| `mettre-a-jour-et-rebuild.command` | Mise à jour de nuit de nxnative (avec les patchs), puis reconstruction des jeux sans ROM |
| `mng-mettre-a-jour.command`, `mng-reconstruire.command` | MacNativeGames à jour, apps reconstruites sans ROM |
| `mng-mods-appliquer.command`, `mng-combiner-mods.sh` | Mods RomFS et mods de code pour MacNativeGames |
| `totk-mng-online.command` | TotK MacNativeGames avec le mod TOTK Online |
| `installer-embarque.sh` | Installe dans `<Home>/moteur` ce que Home.app embarque (`Contents/Resources/moteur`). Lancé par Home au démarrage si l'empreinte a changé |
| `preparer-moteurs.command` | « Préparer ce Mac » : Xcode, Metal, Homebrew, .NET, Python, nxnative, MacNativeGames. `--etat` : dit seulement ce qui manque |
| `pc.command` | Lance `moteur/pc/pc.py` avec le bon Python (`etat`, `preparer`, `connexion`, `bibliotheque`, `installer`, `lancer [--essai]`) |
| `home-mettre-a-jour.command` | « Mettre à jour Home » : recompile depuis `/Applications/Home/moteur/salon` si la source a changé |
| `alleger-build.sh` | Allège un dossier de construction |
| `journaux.command` | « Journaux pour Claude » : copie les journaux dans `/Applications/Home/log/diag` |
| `totk-server.sh`, `smoo-server.sh` | Serveurs en ligne locaux (TOTK Online n'est plus local, voir plus bas) |
| `totk-moniteur.command`, `rocket-league-direct.command` | Moniteur TOTK Online, préparation du lancement direct Epic |

## Jeux en ligne

- **TOTK Online** (mod de Kirbymimi) : le serveur tourne sur une VM **Azure for Students**.
  - VM : `serveur-jeux`, Belgium Central, B2ats_v2, Ubuntu 24.04, utilisateur `azureuser`.
  - Serveur : service systemd `totk`, dans `/opt/totk/TOTK_Online_Server`, port 10014.
  - Home lit l'adresse dans `serveurs/totk-adresse.txt`. Il la donne au jeu avec `TOTK_SWKBD_FIRST`, qui répond seulement au premier clavier : le chat du mod marche normalement.
  - Home ne démarre plus de serveur local quand l'adresse n'est pas locale.
  - La liste des joueurs vient du journal du serveur, lu par SSH toutes les 5 s (`journalctl -u totk`) avec `serveurs/totk-cle.pem`.
- **Super Mario Odyssey Online** (CraftyBoss / Sanae6, pas Kirbymimi) : serveur local `smoo-server.sh`, port 1027, via Tailscale.

## Où tu tournes : deux cas

Anas t'utilise surtout depuis l'**onglet Code** de l'app Claude. Regarde d'abord où tu es (`uname -s`) :

- **Dans le cloud** (Linux, dépôt cloné depuis GitHub ; c'est le cas par défaut de l'onglet Code) :
  - pas de macOS, donc pas de `swiftc` ni de `/Applications/Home` : tu ne peux ni compiler Home toi-même, ni l'installer
    sur son Mac. **La compilation est vérifiée par GitHub Actions**, après un push ;
  - pousser un tag est refusé (erreur 403) : publie les releases avec `gh workflow run` (voir « Envoyer une mise à jour ») ;
  - `gh` marche avec l'API REST (`gh api repos/amas-cd/home/...`, `gh run list`, `gh run watch`, `gh workflow run`), mais pas
    avec GraphQL : `gh release list` et `gh pr ...` échouent. Utilise `gh api repos/amas-cd/home/releases` ;
  - si la session est reliée à son Mac (outils `mcp__remote-devices__*`), tu peux recopier des fichiers ou lancer
    `scripts/installer-local.sh` là-bas, mais seulement s'il le demande.
- **Sur son Mac** (Darwin, l'onglet Code en local ou `claude` dans le Terminal, dans son clone du dépôt) : tu peux compiler,
  installer et pousser des tags.

## Compiler et tester

- **Vérifier que ça compile, sans rien installer** (sur le Mac, après chaque changement de `app/`) :
  ```bash
  HOME_BUILD_ONLY="$TMPDIR/home-test" bash app/salon-construire.command < /dev/null
  ```
  Ça doit finir par « Home.app construit ». Sinon, lis les erreurs dans `app/compilation.log`.
  Dans le cloud, relis soigneusement ton Swift (types, optionnels, accolades), puis fie-toi au workflow après le push. S'il
  échoue, lis l'erreur (`gh run view <id> --log-failed`), corrige et repousse avant toute release.
- **Installer sur le Mac d'Anas** pour qu'il teste (demande-lui avant : Home se ferme et se relance) :
  `bash scripts/installer-local.sh`. Ajoute `--sans-compiler` si seuls des scripts ont changé. Depuis le cloud, donne-lui plutôt
  la commande à coller dans son Terminal : `cd ~/Home && git pull && bash scripts/installer-local.sh`. Ou, s'il ne veut pas de
  clone, il installe la release : `Home.zip` de la page Releases.
- **Compatibilité** : la cible est macOS 14 ; GitHub compile avec Xcode 26 / Swift 6.3. Le Mac d'Anas a un SDK plus récent :
  une API de macOS 27 compile chez lui mais casse la release. Vérifie le résultat du workflow après chaque push.
- **Signature** : avec le certificat local « Salon Dev », macOS garde les autorisations de Home (Accessibilité, Enregistrement
  d'écran) d'une version à l'autre. Les builds de GitHub sont signés ad hoc.

## Envoyer une mise à jour

**Après toute modification du dépôt, demande toujours à Anas s'il veut envoyer la mise à jour. Ne pousse et ne publie jamais
sans son accord explicite pour cette fois-ci.** Le hook Stop (`.claude/hooks/demander-envoi.py`) te le rappelle s'il reste des
modifications pas envoyées.

1. Sur le Mac, vérifie que ça compile (commande ci-dessus). Partout, relis `git status` / `git diff` (pas de secret, pas de
   fichier de jeu).
2. Commit en français, sous le nom d'Anas :
   `git -c user.name=Anas -c user.email=assosbs9@gmail.com commit`
   Le titre dit ce qui change pour lui ; le corps dit pourquoi.
3. Pose la question avec **AskUserQuestion**, en rappelant en une phrase ce qui a changé. Options :
   - **Publier la release X.Y.Z** (recommandé si l'app ou les scripts changent pour lui ou ses amis) ;
   - **Pousser sans release** ;
   - **Garder en local**.
4. Selon la réponse :
   - **Publier** :
     1. `git push origin main` (si la session travaille sur une autre branche, pousse celle-ci, puis fusionne-la dans `main`
        avec son accord, avant de publier).
     2. Lance la release : `gh workflow run "Construire Home" --ref main -f version=X.Y.Z`. Ça marche partout. Sur le Mac,
        pousser un tag (`git tag vX.Y.Z && git push origin vX.Y.Z`) fait pareil.
     3. Suis le run : `gh run list --workflow "Construire Home" --limit 1`, puis `gh run watch <id> --exit-status`.
     4. Quand il est fini, vérifie que la release existe (`gh api repos/amas-cd/home/releases --jq '.[0].tag_name'`), puis donne
        le lien : https://github.com/amas-cd/Home/releases. Si le run échoue, il n'y a pas de release : lis l'erreur, corrige,
        repousse, recommence.
   - **Pousser** : `git push origin main` (le workflow vérifie la compilation).
   - **Garder** : rien.
5. Si `app/` ou `moteur/` a changé et qu'il veut s'en servir tout de suite sur son Mac, propose `bash scripts/installer-local.sh`
   (sur le Mac), ou donne-lui la commande à coller (depuis le cloud).

Numéro de version `X.Y.Z` (dernière release : `gh api repos/amas-cd/home/releases --jq '.[0].tag_name'`, ou
`git tag --list 'v*'` après `git fetch --tags`) :
- **Z + 1** : corrections ;
- **Y + 1** : nouvelle fonction ;
- **X + 1** : gros changement (Home autonome = 1.0.0).

## Règles

- **Secrets** : ne lis jamais `steamgriddb-api-key`, `serveurs/totk-cle.pem`, `~/.ssh`, ni les jetons Epic, Legendary ou Obelisk.
  Ne les mets jamais dans un fichier du dépôt ni dans une réponse.
- **Fichiers d'Anas** :
  - Pour supprimer, passe par la Corbeille (Finder ou `mv` vers `~/.Trash`), jamais `rm`, et demande-lui d'abord.
  - Ne modifie pas les réglages système toi-même : donne-lui les étapes.
  - Ne lance jamais un jeu dans deux apps en même temps.
- **Interdit** : contourner un DRM, un anti-triche ou une protection (EA FC, Denuvo…). Ajouter des jeux, des clés ou des fichiers
  système, ou dire où en trouver. Chacun utilise les dumps de sa propre console.
- Le dépôt est la source. Si `/Applications/Home/moteur` diffère du dépôt sans raison connue, montre la différence à Anas
  avant de recopier quoi que ce soit.

## Feuille de route

Décidé avec Anas pour Home autonome (pour lui et ses amis) :

1. **Fait** : dépôt privé, compilation et releases automatiques (0.1.0).
2. **Fait en grande partie (à tester sur un Mac neuf) : Home autonome.**
   - Fait : scripts embarqués et installés au démarrage ; « Préparer ce Mac » ; dossiers configurables (`Application Support/Salon/dossiers.json`,
     `HOME_RACINE` / `HOME_JEUX` dans les scripts) ; jeux Epic sans Obelisk (moteur Linux de Voile seulement : programmes 64 bits, pas .NET) ;
     liste de compatibilité.
   - Reste : Steam et GOG sans Obelisk, moteur Rosetta de Voile (jeux 32 bits / .NET), désinstaller un jeu PC depuis Home, serveurs en ligne.
   - Règle de la liste de compatibilité : ne bloquer qu'avec une source (refus de l'éditeur ou d'Obelisk). Un anti-triche seul ne prouve rien :
     Rocket League fonctionne.

   Plan d'origine. Au premier lancement, sans dossier `/Applications/Home` :
   - installer les scripts embarqués dans l'app ;
   - vérifier les outils Xcode (`xcode-select --install`) ;
   - récupérer nxnative (version figée par `moteur/tools/engine.py` + `moteur/patches`) et MacNativeGames ;
   - compiler à la demande les jeux Switch à partir des dumps du joueur ;
   - détecter Obelisk pour Epic / Steam.
   Les chemins fixes (`Atelier.home`, `Atelier.jeux`, et les `/Applications/Home` des scripts) doivent devenir configurables.
   Première version sans les serveurs en ligne.
3. **À faire : mises à jour.** Après la compilation de toutes les bibliothèques au premier lancement, Home demande si les mises à
   jour automatiques sont activées. Sinon, une option « Mettre à jour » dans le menu. Source : la dernière release du dépôt.
   L'app téléchargée doit être re-signée sur place avec « Salon Dev » si ce certificat existe, pour garder les autorisations.
