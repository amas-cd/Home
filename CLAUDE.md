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
  `org.macnativegames.*`). La copie d'Anas est `~/Library/Application Support/Home/MacNativeGames`, avec ses propres commits par-dessus ;
- **les jeux PC Epic / Steam**, installés, lancés et mis à jour par Home lui-même (`moteur/pc/pc.py` avec Legendary pour Epic,
  `moteur/steam` pour Steam, moteur Windows Voile dans `<Home>/voile`). Home ne lit et n'ouvre jamais l'app Obelisk ;
  `pc.command importer` reprend une fois ce qu'Obelisk avait installé (moteur et jeux déplacés, rien n'est retéléchargé) ;
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

Le dépôt est **amas-cd/Home**, **public** : tout ce qui y entre (code, commentaires, messages de commit, patchs) est lisible par tous.
Il n'y a qu'un dépôt : le code, et les releases que Home lit sans jeton pour se mettre à jour.

| Chemin | Contenu |
|---|---|
| `app/main.swift` | Toute l'app Home |
| `app/veille.swift` | La petite app invisible qui ouvre Home à la connexion d'une manette |
| `windows/` | Home pour Windows (C# / Avalonia) : la même interface, pour les jeux Steam, Epic et les jeux Switch construits avec ScarletNX. Voir « Home pour Windows » |
| `app/sons/` | Les six sons de l'interface, originaux, créés pour Home (`lancer` = le jingle de l'ouverture) ; `banque/` = Kenney, CC0, en rechange |
| `app/salon-construire.command` | Compile, signe et installe `/Applications/Home.app`. `HOME_BUILD_ONLY=<dossier>` : compile seulement. `HOME_VERSION=x.y.z` : version de l'app |
| `moteur/outils/` | Les scripts que Home lance (voir plus bas) |
| `moteur/patches/` | Les patchs d'Anas pour nxnative (`series` donne l'ordre) |
| `moteur/tools/` | `engine.py` (version figée de nxnative + patchs), `serie.py` (rejoue les patchs d'Anas sur une nouvelle version, avec réparations sûres : voir « Mises à jour des moteurs »), notes de version, tests |
| `moteur/obelisk/` | `launch.sh`, le lanceur du moteur Voile (repris d'Obelisk, GPL-3.0) |
| `moteur/pc/pc.py` | Jeux PC sans Obelisk : télécharge Voile, compte Epic (Legendary), bibliothèque, installation, lancement. Lancé par `outils/pc.command` |
| `moteur/compat/pc.json` | Liste de compatibilité PC, avec sources : `bloque` (jamais lancé), `verifie`, `linux`. Un jeu absent n'est jamais bloqué |
| `moteur/.upstream-ref`, `moteur/mng/` | Versions figées : commit de nxnative ; commit de MacNativeGames + les commits d'Anas en patchs |
| `serveur/totk-etat.py` | À poser sur un serveur TOTK Online : publie en lecture seule les pseudos des joueurs connectés (pour Home sur Windows). Aucune adresse dedans |
| `scripts/installer-local.sh` | Recopie le dépôt dans `~/Library/Application Support/Home/moteur`, puis compile et installe Home sur ce Mac |
| `.github/workflows/release.yml` | Compile Home.app sur `macos-26` (Swift 6.3) à chaque push. Publie une release avec `Home-macSilicon.dmg` et `Home-win64-setup.exe` (chacun avec son `.sha256`) pour un tag `v*` ou pour « Run workflow » avec une version |
| `.claude/` | Ce contexte : le hook Stop qui te rappelle de demander l'envoi de la mise à jour |

**Jamais dans le dépôt** (il est public, et l'historique git ne s'efface pas) : adresse IP ou nom d'hôte d'un serveur, pseudo d'un
compte, chemin personnel, et aussi jeux, ROM, NSP/XCI, clés (`prod.keys`, `title.keys`), fichiers système, clé SteamGridDB, clé SSH du
serveur (`*.pem`), jetons Epic/Legendary, recettes Obelisk propres à un Mac, journaux, sauvegardes. Le `.gitignore` en couvre
une partie : vérifie quand même `git status` avant chaque commit.

## Sur le Mac d'Anas (l'installation en service)

Le dossier de Home est **`~/Library/Application Support/Home`** (noté `<Home>` ; `HOME_RACINE` dans les scripts, `Dossiers.home` dans
l'app). Il était dans `/Applications/Home` jusqu'en novembre 2026 : sur le Mac d'Anas un lien y reste, parce que des chemins
enregistrés (réglages des jeux, environnements Python) passent encore par là. Le chemin contient une espace : toujours entre guillemets.
L'app installée lit ses scripts dans **`<Home>/moteur`**, pas dans le dépôt.
Le dépôt est la source : on modifie le dépôt, puis `scripts/installer-local.sh` recopie les fichiers là-bas.

| Emplacement | Rôle |
|---|---|
| `/Applications/Home.app` | L'app installée |
| `/Applications/Jeux/` | Les apps des jeux (nxnative, MacNativeGames…) |
| `~/Library/Application Support/Home/moteur/` | Copie en service de `app/` (dans `moteur/salon/`) et de `moteur/` ; `engine/` = nxnative + patchs |
| `~/Library/Application Support/Home/MacNativeGames/` | Le dépôt MacNativeGames d'Anas (ses commits par-dessus l'officiel) |
| `~/Library/Application Support/Home/constructions/` | Les dossiers de construction des jeux (fichiers extraits : permettent de reconstruire sans ROM) |
| `~/Library/Application Support/Home/registre.json` | Les jeux construits par Home et comment les refaire |
| `~/Library/Application Support/Home/mods/<title id>/` | Mods de code (ex. TOTK Online) |
| `~/Library/Application Support/Home/sauvegardes/<title id>/` | Sauvegardes des jeux nxnative (`DM_SAVE`) |
| `~/Library/Application Support/Home/serveurs/` | `totk-adresse.txt` (adresse du serveur TOTK Online), `totk-cle.pem` (**secret**), serveur SMO |
| `~/Library/Application Support/Home/log/` | `salon.log` (journal de Home), journaux des serveurs, `diag/` (« Journaux pour Claude ») |
| `~/Library/Application Support/Salon/` | Réglages de Home : `jeux.json` (struct `Config`), `media/`, `cache/`, `mods/`, `statistiques.json`, `durees.json`, `steamgriddb-api-key` (**secret**) |
| `~/Library/Application Support/nxnative/<title id>/env.txt` | Réglages d'un jeu nxnative (`DM_*`) ; `nxnative/volume.txt` = volume lu par le moteur patché |
| `~/Library/Logs/nxnative/<title id>.log`, `~/Library/Logs/MacNativeGames/totk.log` | Journaux des jeux |

## Carte de `app/main.swift`

Les sections sont marquées `// MARK:`. Cherche-les par nom, les numéros de ligne changent.

- **Modèle** : `Game` (un jeu ; `viaHome` pour un jeu PC, `titleID`, `storeID`), `Config` (jeux.json), `Entry`, `SalonMenu` / `SalonMenuItem` (tous les menus).
- **Sources d'images** : `EShop`, `SteamGridDB`, `PSStore`, `Wiki`.
- **`Library`** (ObservableObject, le cœur) :
  - l'état de l'interface ;
  - `launch()` / `openGame()` : lancement d'un jeu et variables d'environnement données au jeu (`TOTK_*` pour MacNativeGames) ;
  - le volume : un seul, celui de Home et de ses jeux (jamais celui du Mac). `writeVolume`, `volumeSource` : `.engine` = volume.txt de
    nxnative, `.mixeur` = le mélangeur de Home (macOS 14.2+), `.bgm` = Background Music sur un macOS plus ancien, `.mac` = rien à régler ;
  - le menu rapide (`quickItems`, `quickAct`) ;
  - le jeu en ligne : `enLigne()`, `joueursConnectes()`, `rafraichirJournalDistant()` ;
  - les menus d'options, de réglages et d'apparence.
- **`Recorder`** : capture continue (ScreenCaptureKit) pour « Enregistrer les 15 dernières secondes ».
- **`Mixeur`** : le mélangeur audio de Home. Il capte le son des processus du jeu (process tap de Core Audio), le coupe à la source et le
  rejoue au volume voulu. Il écoute d'abord sans rien couper, et ne prend la main qu'après avoir reçu du son : un jeu n'est jamais muet
  par erreur. Demande l'autorisation « enregistrement audio du système » (`NSAudioCaptureUsageDescription`).
- **`SystemVolume`, `BGM`** : anciens chemins (volume du Mac, Background Music) ; `BGM` ne sert plus que sous macOS 14.0 et 14.1.
- **`Commande`** : `run()` pour lancer une commande et lire ce qu'elle écrit.
- **Vues** : `Screen`, `MenuView`, `TacheView` (avancement des scripts lancés dans le Terminal), `HUDView` (au-dessus du jeu), `JoueursView`.
- **Manette** : `PadBattery`, `PadSeize` (saisie exclusive pendant le menu rapide).
- **`ClavierJeu`** : le moteur Linux de Voile (Rocket League) ne connaît que le clavier américain ; tant qu'un de ses jeux est devant
  (`com.zagrios.obelisk.game.*`), Home échange les codes des touches pour suivre le clavier du Mac. Réglage dans Avancé → Système.
- **`Discord`** : la présence Discord (« Joue à Home »), par le socket local de l'app Discord (`$TMPDIR/discord-ipc-0`). « Dans le
  menu », ou le jeu en cours avec sa console et sa jaquette. Discord ne montre qu'une image publique : Home garde l'adresse d'où il a
  téléchargé chaque jaquette (fichier `.url` à côté), sinon celle de la boutique du jeu, sinon le logo de Home (image « home » de
  l'application Discord). `Discord.appID` est l'identifiant de l'application créée par Anas sur discord.com/developers : public, pas
  un secret ; vide = rien n'est envoyé. Réglage dans Avancé → Système.
- **`AppDelegate`, `SalonMain`** (`@main`).
- **`Atelier`** :
  - les chemins (`Atelier.home` = `~/Library/Application Support/Home`, `Atelier.jeux` = `/Applications/Jeux`) ;
  - le lancement des scripts dans le Terminal (`lancer`, `terminal`) ;
  - les mods, `registre.json`, GameBanana ;
  - le moteur d'un jeu (`moteurDe`, `scriptDedie`).

Style du code : lignes denses, commentaires en français qui expliquent **pourquoi**. Garde ce style.

## Home pour Windows (`windows/`)

SwiftUI n'existe pas sur Windows : `windows/` est une deuxième app, en C# avec Avalonia 11, qui recopie l'interface de
`app/main.swift` (mêmes tailles, marges, couleurs, mêmes noms de symboles dans les menus, traduits par `Icones`).

- **Ce qu'elle lance** : les jeux Steam et Epic Games installés (détectés seuls), les apps ajoutées à la main, et les **jeux Switch
  qu'elle construit elle-même**.
- **Jeux Switch** (`Switch.cs`) : sur Windows, nxnative et MacNativeGames n'existent pas (Apple et Metal seulement). À leur place,
  Home construit le jeu avec [ScarletNX](https://github.com/scarletnx/ScarletNX) (GPL-3.0-or-later), un recompilateur général : on
  donne une fois le dump (.xci, .nsp) et `prod.keys` tirés de sa console, Home lance `scarletnx -r --extract-container` et crée la tuile.
  - ScarletNX est un programme à part : Home le télécharge depuis `github.com/scarletnx/nightly/releases/download/`, à la version
    figée dans `windows/SCARLETNX-REF` (avec son empreinte SHA-256), et le lance. On ne recopie jamais son code ; s'il faut le
    modifier, c'est dans un fork en GPL, après l'avoir dit à Anas. ScarletNX ne garde que ses 30 dernières nightlies : si la version
    figée a disparu, Home prend la dernière et vérifie l'empreinte que GitHub publie. Mets `SCARLETNX-REF` à jour de temps en temps.
  - Tout est dans `%LOCALAPPDATA%\Home\scarletnx` (le `--data` de ScarletNX) : `moteur/`, `prod.keys` et `title.keys` copiés (**secrets**,
    jamais ailleurs), `recompiled/<title id>/` = un jeu construit (`<id>.exe`, `<id>.abi` écrit à la fin, `<id>.ini`, `<id>_data/`).
    Le jeu se suffit à lui-même : le dump d'origine ne sert plus. Il se lance par `scarletnx --data D --extract-container -f <dossier>` (le dossier du jeu,
    pas `--game` : refusé par le pilote ; sans `--extract-container`, ScarletNX retire l'extraction et relit le dump). Recompiler :
    `scarletnx --data D -r <dossier>`. Essayé dans CrossOver : la construction avec mod réussit, mais le jeu ne s'affiche pas sur
    Mac (MoltenVK n'a que Vulkan 1.2, ScarletNX veut 1.3). Sous Wine, Home prend le moteur x86-64.
  - Un jeu en construction est un **chantier** (`constructions.json`, tuile `construction:<n>`) : Reprendre, Abandonner, journal.
  - Mods : un dossier par mod dans `<id>_data/mods/`, avec `romfs/` et/ou `exefs/` ; désactivés dans `mods_off=` du `.ini`. Un mod de
    code (`exefs/`) fait recompiler le jeu (`scarletnx -r`).
  - En ligne : seul le réglage `network=` du jeu est proposé (« Internet »). Ne présente « Jouer en ligne » comme fonctionnel pour un
    jeu qu'après un essai réel de ce jeu avec ce mod. ScarletNX a `swkbd_text` pour répondre au clavier, mais à tous les claviers.
  - L'assistant suit l'ordre du Mac : le jeu, les clés, **« Comment veux-tu jouer ? »** (`MenusSwitch.Mode`), le mod en ligne, le
    serveur, la mise à jour, les DLC, « Prêt à construire ». La mise à jour est facultative en local ; en ligne, c'est celle que le mod
    demande, écrite en gros (`Menu.Alerte`) et confirmée par « Es-tu sûr ? » (Home ne sait pas lire la version d'un .nsp).
  - « En ligne » n'existe que pour les jeux de `MenusSwitch.ModsEnLigne`, **la même table que `Atelier.modsEnLigne` sur Mac** : une
    ligne des deux côtés pour ajouter un jeu. Le jeu est reconnu par ses numéros de titre (.nsp) ou le nom du fichier. Le mod donné
    est vérifié (`exefs/<module>`) et rangé dans `%LOCALAPPDATA%\Home\mods-en-ligne\`. Un jeu hors table : « Suggérer un mod en
    ligne » (demande GitHub pré-remplie). Ces mods ont été essayés sur Mac, aucun sur Windows : l'écran le dit.
  - Home cherche seul ce qu'il faut (`Trouvailles`, comme `fichiersCandidats` sur Mac : Téléchargements, Bureau, Documents, racine
    des autres disques) : la liste des jeux, `prod.keys` et `title.keys` (installés d'office, aussi depuis `%USERPROFILE%\.switch`),
    la mise à jour et les DLC du jeu choisi, le .zip ou le dossier du mod en ligne. Un dump est reconnu par son numéro de titre
    (ticket du .nsp, ou `[0100…]` dans le nom) : …000 = jeu, …800 = mise à jour, autre = DLC. `HOME_CHERCHER=<dossier>` limite la
    recherche à un dossier d'essai (scénarios `ajouter`, `essaimaj`).
  - À la fin de la construction, Home pose le mod, recompile avec lui, met `network=1` et garde l'adresse du serveur, si on l'a
    donnée, dans `recompiled/<id>/serveur.txt` (sur le PC seulement), qu'il passe à chaque lancement (`--swkbd-text=`).
    Un mod en ligne et l'adresse d'un serveur ne sont jamais dans le dépôt ni dans l'installeur sans l'accord écrit de l'auteur.
  - Jamais de jeu, de dump ni de clé téléchargés, et Home ne dit pas où en trouver.
- **Menu en jeu** (`EnJeu.cs`, recopie de `HUDView` / `toggleQuick` / `quickAct`) : une fenêtre à part, transparente, toujours devant
  le jeu (`FenetreRapide`), ouverte par le pavé tactile d'une manette PlayStation (lue directement en HID, `ManetteSony` : XInput ne
  la voit pas), le bouton PS ou Xbox, ou Select + Start. Fermer le jeu, Retour à Home, Volume du jeu (`SonJeu` : la
  session du jeu dans le mélangeur de Windows, gardé par jeu dans `Config.Volumes`), et Joueurs pour un jeu en ligne. Limites de
  Windows : la manette n'est pas retirée au jeu pendant que le menu est ouvert, et rien ne passe devant un plein écran exclusif.
  La liste des joueurs ne vient pas du SSH (la clé ne se partage pas) : le serveur la publie lui-même avec `serveur/totk-etat.py`,
  sur le port juste après celui du jeu (`JoueursEnLigne`). Scénarios `rapide`, `rapidevolume`, `rapidejoueurs`. Jamais essayé sur un PC.
- **Caméra à la souris** (`MenusSwitch.Souris`, options d'un jeu Switch) : `mouse_look`, `mouse_look_sensitivity`, `mouse_look_invert_y`,
  `mouse_look_left` / `_right` / `_middle` dans `[Controllers]` du .ini du jeu. ScarletNX officiel ne sait pas le faire : c'est un
  petit changement à nous (un commit, branche `home` d'un fork GPL de ScarletNX, calcul dans `mouse_look.c` avec son test), compilé
  pour Windows par le workflow `home-windows.yml` du fork, qui publie l'archive et son SHA-256. `SCARLETNX-REF` peut nommer ce dépôt
  (`depot=`) ; s'il ne répond pas, Home retombe sur l'officiel, sans la souris. Le clavier de ScarletNX suit déjà la position des
  touches (ZQSD sur AZERTY = WASD). Sur Mac, les mêmes réglages (sensibilité, axe inversé) sont dans Réglages du jeu
  (`TOTK_MOUSE_SENSITIVITY`, `TOTK_MOUSE_INVERT_Y`). Jamais essayé avec un vrai jeu.
- **Pas sur Windows** : SMO Online, GameBanana, capture, la barre de volume du haut, choix des images dans Home (un fichier à la place).
- **Premier lancement**, dans l'ordre du Mac, chaque étape à valider : `BienvenueVue` (recopie de `BienvenueView` : trois cartes
  Tout / Nintendo / PC, « Commencer », « Ignorer » discret) ; « Clés de la console » (`MenusSwitch.AccueilCles` : « Recherche… », puis
  « prod.keys : trouvé » + « Continuer », ou « Choisir prod.keys » + « Plus tard » ; « Quelles clés ? ») ; l'installation
  (`Bibliotheque.AppliquerMode` : « Installation pour : … », ou « tout est déjà installé ») ; « Tes bibliothèques »
  (`AccueilBibliotheques` : sur Windows rien à connecter, Home montre ce que Steam et Epic ont installé). Le choix (`Config.Mode`)
  se change dans Menu → Composants (`OuvrirMode`), qui montre aussi ScarletNX et le met à jour. Pas d'étape « Moteurs » (un seul).
  L'installation du moteur occupe tout l'écran (`InstallationVue`, `Bibliotheque.Installation`, recopie d'`InstallationView`) : deux
  grands titres (Téléchargement, Mise en place), Réessayer / Continuer sans après un échec. La bienvenue reste dessous jusqu'à l'écran
  suivant (`BienvenueFige`) : on ne voit jamais la bibliothèque entre deux écrans.
- **Comme sur Mac** : haut / bas changent de catégorie, B demande « Quitter Home ? », Options revient d'un niveau, la carte d'une
  tâche a son menu (`OuvrirTacheMenu`), les catégories à soi (`Config.Categories`, `CategoriesJeux`), les points d'étape de
  l'assistant (`Menu.Etape`, `Bibliotheque.Pas`), les listes « Quelle mise à jour ? » / « Quels DLC ? » (`MenusSwitch.Proposer`).
- **ScarletNX, d'après sa documentation** (`docs/user/usage.md`, `settings.md`) : les sauvegardes sont dans `save/` du dossier de
  données (hors du jeu), sauf `save_layout=game` (`<id>_data/save`) ; `-r recompiled/<id>/<id> --update X.nsp` ajoute une mise à jour
  ou un DLC à un jeu déjà construit, sans le dump ; `-q` construit sans afficher l'avancement. Pas encore utilisés par Home.
- **Repères des services** : `U.Repere` et `U.Console` recopient `Symbole` du Mac (console portable, quatre carreaux, bielle,
  écusson). Ce sont des dessins de Home : aucun logo de marque dans le dépôt.
- **Désinstaller** : un jeu Switch part à la Corbeille. Pour un jeu Steam ou Epic, Home ne supprime rien lui-même : il ouvre la
  désinstallation de la boutique (`steam://uninstall/<appid>`, le lanceur Epic). Une app ajoutée à la main : « Retirer de Home » seulement.
- **Graphisme** : l'app Mac fait foi. `windows/` la recopie vue par vue ; une vue reste en place et on change ses propriétés (c'est ce
  qui l'anime), et on n'anime jamais une taille (seulement `RenderTransform` et l'opacité). « Animations réduites » : `Mouvement.Reduit`.
  Pour comparer : `HOME_APERCU=<dossier> Home.app/Contents/MacOS/Salon` écrit les menus, l'ouverture et l'avancement du Mac en PNG.
- **Pas de flou ni d'ombre calculés en direct** (`BlurEffect`, `DropShadowEffect`) : Avalonia les refait à chaque image dès que quelque
  chose bouge, et tout saccade. Un flou est fait **une seule fois** par Skia sur l'image réduite, puis gardé (`U.Flou`, `U.Flouter`) ;
  derrière un menu, c'est une photo réduite de la bibliothèque, floutée de la même façon (`Ecran.Voiler`). Ne jamais « flouter » en
  étirant une image de quelques points : ça donne de gros pixels. Une lueur (`U.Lueur`) est dessinée par Skia avec du tramage : un
  dégradé d'Avalonia sur fond sombre fait des anneaux. Le zoom lent du fond du Mac n'est pas repris (il redessine tout l'écran).
  Seule exception : la rangée voisine, immobile au repos, a un vrai flou (jamais de `BlurEffect` de rayon 0 laissé en place).
- **Écriture** : Mona Sans (GitHub, licence OFL), embarquée depuis `windows/polices/` ; sa version large très grasse remplace SF Pro
  Expanded Black, qu'Apple ne laisse pas redistribuer. **Icônes** : Fluent System Icons (Microsoft, MIT, paquet `FluentIcons.Avalonia`),
  en version pleine ; `Icones` traduit les noms de symboles du Mac, `U.Icone` les dessine comme des tracés (la police impose du noir).

| Fichier | Contenu |
|---|---|
| `Modele.cs` | `Jeu`, `Config`, `Menu` / `ElementMenu`, `Dossiers`, `Icones` (SF Symbols → Material, teintes) |
| `Bibliotheque.cs` | L'équivalent de `Library` : état, navigation, lancement, fin de partie, tous les menus |
| `Sources.cs` | `Steam`, `Epic`, `SteamGridDB`, `Boutiques` (eShop et PlayStation Store par le nom du jeu, sans clé : jaquette carrée, fond), `Titres` (le résultat est-il le bon jeu ?), `Images` |
| `Switch.cs` | `Moteur` (ScarletNX : version figée, téléchargement vérifié), `Ini`, `Chantier`, `Construction` (recompiler, lancer, reprendre), `MenusSwitch` (assistant, chantier, mods, Internet, Libérer de la place) |
| `SCARLETNX-REF` | La version de ScarletNX que Home installe, et l'empreinte de ses archives |
| `Vues.cs` | `Mouvement` (courbes et durées), `Ecran`, `Tuile`, `RangeeJeux`, `FondVue`, `Ouverture` (écran de démarrage), `PastilleTache`, « en cours de jeu », saisie |
| `VuesMenus.cs` | `VueMenu` : les trois formes de `MenuView` (rangée de pastilles, roue, grille d'affiches). `Menu.Genre` choisit la forme, comme sur Mac |
| `ANIMATIONS.md` | La fiche des animations de l'app Mac (courbes, durées, distances) : la référence de `Vues.cs` et `VuesMenus.cs` |
| `EnJeu.cs` | Le menu en jeu : `SonJeu` (volume du jeu), `JoueursEnLigne`, la partie de `Bibliotheque` qui le conduit, `VueRapide`, `FenetreRapide` |
| `Discord.cs` | La présence Discord, comme `Discord` sur Mac : tube nommé `discord-ipc-0…9`, même identifiant d'application, « Dans le menu » ou le jeu en cours ; l'adresse d'une jaquette est gardée dans `couverture.url`. `HOME_DISCORD=1` l'active aussi en démonstration |
| `Manette.cs` | `Manette` (XInput), `Sons` (les .wav de `app/sons`), `Systeme` (processus d'un dossier, Corbeille) |
| `MiseAJour.cs` | Mise à jour de Home depuis les releases de amas-cd/Home |
| `Programme.cs` | `Fenetre` : plein écran, échelle depuis 1920 de large, clavier, scénarios de test |

Données sur le PC : `%LOCALAPPDATA%\Home` (`jeux.json`, `statistiques.json`, `constructions.json`, `media/`, `cache/`, `scarletnx/`,
`log/home.log`, `steamgriddb-api-key` = **secret**).

**Règle de parité** : un changement de l'interface ou d'un menu dans `app/main.swift` se reporte dans `windows/` dans le même
commit quand il a un sens sur Windows (et inversement). Si ce n'est pas reporté, dis-le à Anas.

**Vérifier sur le Mac** (personne n'a de PC sous la main ; un ami d'Anas teste les releases) :
```bash
dotnet build windows/Home.csproj
HOME_DONNEES="$TMPDIR/home-win" HOME_DEMO=1 HOME_FENETRE=1 HOME_SCENARIO=options HOME_CAPTURE="$TMPDIR/home-win.png" dotnet windows/bin/Debug/net10.0/Home.dll
```
`HOME_DEMO=1` remplit la bibliothèque avec des tuiles d'exemple (aucun jeu n'est là). `HOME_SCENARIO` enchaîne des écrans ou des touches
(`options`, `plus`, `ajout`, `bienvenue`, `mode`, `modeinconnu`, `enligne`, `maj`, `sur`, `recap`, `mods`, `place`, `saisie`, `tache`, `echec`, `installation`, `installationechec`, `ouverture`, `left`, `right`, `ok`…). `HOME_CAPTURE` enregistre l'image de
la fenêtre puis quitte : lis le PNG. Cette image ne montre ni les flous ni un mouvement en cours : pour les voir, lance sans
`HOME_CAPTURE` et photographie la fenêtre (`screencapture -l <numéro de fenêtre>`). Ce qui est propre à Windows (registre Steam, fichiers Epic, XInput, lancement, Corbeille,
ScarletNX : aucun jeu ne tourne sur macOS) ne se teste pas sur Mac. Dans un compte rendu, sépare toujours « compilé », « vu à l'écran »
et « essayé avec un vrai jeu ».

Le workflow compile `windows/` sur `windows-latest` (job `windows`), puis fabrique le setup avec Inno Setup
(`windows/installeur.iss` : installation pour l'utilisateur seul dans `%LOCALAPPDATA%\Programs\Home`) et le publie sous le nom
`Home-win64-setup.exe`. La release contient `Home-macSilicon.dmg` et `Home-win64-setup.exe`, chacun avec son `.sha256` ; elle ne
sort que si les deux compilent.

**Mises à jour sur Windows** (`MiseAJour.cs`) : Home lit la dernière release de **amas-cd/Home** au démarrage, sans jeton (le
dépôt est public), et propose « Mettre à jour Home » : il télécharge `Home-win64-setup.exe`, vérifie son SHA-256, le lance en
silencieux et se rouvre. Il n'y a plus de dépôt amas-cd/Home-releases ni de secret `RELEASES_TOKEN`.

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
| `home-mettre-a-jour.command` | « Mettre à jour Home » : recompile depuis `~/Library/Application Support/Home/moteur/salon` si la source a changé |
| `alleger-build.sh` | Allège un dossier de construction |
| `journaux.command` | « Journaux pour Claude » : copie les journaux dans `~/Library/Application Support/Home/log/diag` |
| `totk-server.sh`, `smoo-server.sh` | Serveurs en ligne locaux (TOTK Online n'est plus local, voir plus bas) |
| `totk-moniteur.command` | Moniteur TOTK Online |

## Mises à jour des moteurs : garder les changements d'Anas

Les changements d'Anas vivent en séries de patchs dans le dépôt : `moteur/patches` (nxnative) et `moteur/mng/patches`
(MacNativeGames ; `series` donne l'ordre, `.upstream-ref` la version de l'amont dessous). `moteur/tools/serie.py` les rejoue sur
une nouvelle version, dans un dossier à part : le clone en service ne bouge que si tout s'est appliqué.

- Un patch que `git am -3` refuse est repris fichier par fichier, avec trois réparations sûres : fichier devenu un lien (appliqué
  sur la cible), fichier déplacé (renommage vu par git, sinon contexte), ajout simple à côté d'un changement de l'amont.
- Sinon la mise à jour s'arrête : rien n'est modifié, `<Home>/log/mng-maj.json` (ou `nxnative-maj.json`) passe à « attente » et un
  rapport dit quel patch, quel fichier et les versions en présence. Home l'affiche en tête de Mises à jour (`majEnAttente`).
  Dans ce cas : adapter le commit à la main dans le clone, puis relancer la mise à jour.
- Après une réussite, la série est réécrite dans `<Home>/moteur/mng` et dans `~/Home/moteur/mng` s'il existe : pense à l'enregistrer.
- Tests : `cd moteur && python3 -m unittest tools.tests.test_serie`.

## Jeux en ligne

- **TOTK Online** (mod de Kirbymimi) : le serveur tourne sur une VM **Azure for Students**.
  - VM : `serveur-jeux`, Belgium Central, B2ats_v2, Ubuntu 24.04, utilisateur `azureuser`.
  - Serveur : service systemd `totk`, dans `/opt/totk/TOTK_Online_Server`, port 10014.
  - Home lit l'adresse dans `serveurs/totk-adresse.txt`. Il la donne au jeu avec `TOTK_SWKBD_FIRST`, qui répond seulement au premier clavier : le chat du mod marche normalement.
  - Home ne démarre plus de serveur local quand l'adresse n'est pas locale.
  - La liste des joueurs vient du journal du serveur, lu par SSH toutes les 5 s (`journalctl -u totk`) avec `serveurs/totk-cle.pem`.
- **Dans l'assistant « Ajouter un jeu »** (étape `mode`, après le moteur) : « Comment veux-tu jouer ? ». « En ligne » n'existe que pour
  les jeux de `Atelier.modsEnLigne` (une ligne par jeu, ajoutée après un essai réel). Home demande une fois le .zip du mod pris chez son
  auteur et le range dans `<Home>/moteur/exefs-mods/<title id>/` ; la mise à jour que le mod exige devient obligatoire (sinon « Jouer en
  local à la place »). En local, la mise à jour est facultative et `DM_EXEFS_MODS_AUTO=0` empêche nxnative d'appliquer le mod rangé.
  Home trouve seul ce qui est déjà sur le Mac : `Atelier.lire` classe un fichier par son numéro de titre (…000 jeu, …800 mise à jour,
  autre DLC), « Quel jeu ? » ne liste que les jeux, la mise à jour et les DLC du jeu choisi sont proposés d'office, les clés et le mod
  en ligne sont pris dès qu'ils sont trouvés. La mise à jour exigée passe par « Es-tu sûr ? ». L'adresse du serveur se tape dans Home
  (`Library.demander`, `SaisieView`), pas dans une fenêtre de macOS. Un script qui connaît la raison d'un échec écrit une ligne
  « Pourquoi : … » : Home l'affiche dans la pastille et sur la tuile du chantier.
  L'installation des composants (`preparer-moteurs.command`) occupe tout l'écran (`InstallationView`, `Library.installation`), comme
  la mise en route d'une console : pas de bibliothèque avant la fin ; après un échec, « Réessayer » ou « Continuer sans ».
  Un mod en ligne n'est jamais mis dans le dépôt ni dans l'app sans l'accord écrit de son auteur. Jeu sans mod connu : « Suggérer un
  mod en ligne » ouvre une demande GitHub pré-remplie.
- **Super Mario Odyssey Online** (CraftyBoss / Sanae6, pas Kirbymimi) : serveur local `smoo-server.sh`, port 1027, via Tailscale.

## Où tu tournes : deux cas

Anas t'utilise surtout depuis l'**onglet Code** de l'app Claude. Regarde d'abord où tu es (`uname -s`) :

- **Dans le cloud** (Linux, dépôt cloné depuis GitHub ; c'est le cas par défaut de l'onglet Code) :
  - pas de macOS, donc pas de `swiftc` ni de dossier de Home : tu ne peux ni compiler Home toi-même, ni l'installer
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
  clone, il installe la release : `Home-macSilicon.dmg` de la page Releases.
- **Essayer Home sans toucher à l'installation en service** : `HOME_REGLAGES=<dossier>` (Home lit et écrit ses réglages là au lieu
  d'`Application Support/Salon` ; un `dossiers.json` d'essai dedans déplace aussi le dossier de Home et celui des jeux) et
  `HOME_CHERCHER=<dossier>` (la recherche de fichiers ne regarde que là, ni Téléchargements ni `~/.switch`). On lance la copie compilée
  par `HOME_BUILD_ONLY`, après avoir fermé le Home installé. De faux fichiers de jeu suffisent : un en-tête PFS0 avec un nom de ticket.
- **Compatibilité** : la cible est macOS 14 ; GitHub compile avec Xcode 26 / Swift 6.3. Le Mac d'Anas a un SDK plus récent :
  une API de macOS 27 compile chez lui mais casse la release. Vérifie le résultat du workflow après chaque push.
- **Signature** : avec le certificat « Home Dev » (créé par Anas dans son trousseau ; l'ancien nom « Salon Dev » marche aussi), Home garde
  la même identité d'une compilation à l'autre et macOS ne redemande pas ses autorisations (Accessibilité, Enregistrement d'écran, son du
  système). Les releases signent avec le même certificat si le dépôt a les secrets `HOME_DEV_P12` (le .p12 en base64) et `HOME_DEV_MDP` :
  c'est Anas qui les crée et les range dans Settings → Secrets → Actions. Ne les lis jamais, ne les mets jamais dans un fichier.
  Sans certificat, la signature est ad hoc. Ce certificat n'enlève pas l'avertissement de macOS au premier téléchargement.

## Envoyer une mise à jour

**Après toute modification du dépôt, demande toujours à Anas s'il veut envoyer la mise à jour. Ne pousse et ne publie jamais
sans son accord explicite pour cette fois-ci.** Le hook Stop (`.claude/hooks/demander-envoi.py`) te le rappelle s'il reste des
modifications pas envoyées.

1. Sur le Mac, vérifie que ça compile (commande ci-dessus). Partout, relis `git status` / `git diff` (pas de secret, pas de
   fichier de jeu).
2. Commit en français, sous le nom d'Anas :
   `git -c user.name=Anas -c user.email=273038692+amas-cd@users.noreply.github.com commit`
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
- Le dépôt est la source. Si `~/Library/Application Support/Home/moteur` diffère du dépôt sans raison connue, montre la différence à Anas
  avant de recopier quoi que ce soit.

## Feuille de route

Décidé avec Anas pour Home autonome (pour lui et ses amis) :

1. **Fait** : dépôt (privé au départ, public depuis novembre 2026), compilation et releases automatiques (0.1.0).
2. **Fait en grande partie (à tester sur un Mac neuf) : Home autonome.**
   - Fait : scripts embarqués et installés au démarrage ; « Préparer ce Mac » ; dossiers configurables (`Application Support/Salon/dossiers.json`,
     `HOME_RACINE` / `HOME_JEUX` dans les scripts) ; jeux Epic sans Obelisk (moteur Linux de Voile pour les programmes 64 bits ; un jeu 32 bits ou .NET est essayé sur le moteur Rosetta) ;
     liste de compatibilité.
   - Fait aussi : un .exe déjà installé devient une tuile (`pc.py ajouter-exe`), installation depuis un setup (`pc.py setup`, moteur Rosetta
     de Voile, 32 bits et .NET), connexion Epic dans une fenêtre de Home sans code à copier (`ConnexionEpic`), accueil au premier lancement.
   - Fait aussi : mode d'utilisation choisi au premier lancement et dans Menu → Mode d'utilisation (`Config.mode` : tout / nintendo / pc ;
     `Config.moteurs` : tout / mng / nxnative ; les scripts reçoivent `HOME_MOTEURS` et `HOME_AUSSI_PC`). Icône dessinée par `app/icone.swift`. L'écran du mode d'utilisation est `AccueilView` (mélange PS5 / Xbox / Switch 2) ; `HOME_APERCU=<dossier> Home.app/Contents/MacOS/Salon` en écrit trois PNG sans rien lancer.
   - Steam sans Obelisk : `moteur/steam` (outil Rust `home-steam`) pilote `obelisk-bridge`, la porte d'entrée de l'app Obelisk : connexion
     par QR code, bibliothèque, téléchargement, préfixe, hôte Steam (`obelisk-steam-host`, la bibliothèque de Valve), lancement, Steam Cloud.
     `preparer-steam.command` installe rustup (cible Intel, dans `<Home>/moteur/.rustup`), clone Obelisk au commit de `moteur/steam/OBELISK-REF`
     et compile tout dans `<Home>/moteur/bin`. Jeux dans `<Home>/pc/steam`. Tuiles `pc:steam:<appid>`, lancées par `steam.command lancer`.
     Pas encore vérifié : un téléchargement et un lancement réels (il faut le compte d'Anas connecté).
   - Reste : GOG, serveurs en ligne. Désinstaller un jeu PC : fait (Plus → Désinstaller ; `pc.py oublier`), pas encore essayé sur un vrai jeu.
     Un jeu Epic 32 bits ou .NET passe par le moteur Rosetta (`lancer_rosetta`) : pas encore essayé avec un vrai jeu.
   - Steam sans Obelisk (étudié, pas fait) : Obelisk fait tourner la vraie bibliothèque `steamclient.dylib` de Valve dans un petit programme
     Rust (`obelisk-steam-host`, interfaces privées figées sur une version) et télécharge avec son propre code Rust (`steam-kit`). Le reprendre
     demande Rust ≥ 1.98, un outil en ligne de commande à écrire, et connecte le compte par un client non officiel : à décider avec Anas.
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
   L'app téléchargée doit être re-signée sur place avec « Home Dev » si ce certificat existe, pour garder les autorisations.
