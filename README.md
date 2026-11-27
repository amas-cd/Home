# Home

Launcher de jeux façon console, à la manette. Sur **Mac** (Apple Silicon) : les jeux Switch recompilés pour le Mac
(nxnative, MacNativeGames), les jeux PC Epic et Steam, et les apps Mac. Sur **Windows** : les jeux Steam et Epic installés,
et les jeux Switch que Home recompile lui-même avec ScarletNX, à partir du dump et des clés de ta propre console.

Home ne contient aucun jeu, aucune clé et aucun fichier système : chacun utilise les copies de sa propre console et les jeux
qu'il possède.

## Ce que Home fait, et ne fait pas

- Home **ne contient et ne télécharge aucun jeu**, aucune clé (`prod.keys`) et aucun fichier système, et ne dit pas où en trouver.
- Il s'utilise avec les jeux que tu possèdes : pour la Switch, les copies que tu as extraites toi-même de **ta** console et de **tes**
  cartouches ; pour le PC, les jeux de ton propre compte Epic Games ou Steam.
- Il ne contourne aucune protection, aucun DRM ni aucun anti-triche. Un jeu que son éditeur refuse hors de Windows n'est pas lancé.
- Home est gratuit, sans publicité et sans dons. Il n'est lié ni à Nintendo, ni à Epic Games, ni à Valve, ni à aucun éditeur.
- Les jeux PC passent par des outils qui ne sont pas ceux des boutiques (Legendary pour Epic, le code d'Obelisk pour Steam). Renseigne-toi
  sur les conditions d'utilisation de ton compte : c'est toi qui choisis de t'en servir.

Les demandes de jeux, de clés ou de liens sont fermées sans réponse (voir « Signaler un problème »).

## Installer

Ouvre la dernière [release](https://github.com/amas-cd/Home/releases/latest).

**Mac (Apple Silicon)**
1. Télécharge `Home-macSilicon.dmg`, ouvre-le et glisse **Home** dans **Applications**.
2. Fais un clic droit sur Home → **Ouvrir** → **Ouvrir**. L'app n'est pas signée par un compte Apple Developer, donc macOS
   le demande à la première ouverture seulement.
3. Au premier lancement, Home demande ce que tu veux en faire (jeux Switch, jeux PC) et installe les composants qu'il faut.

**Windows (64 bits)**
1. Télécharge `Home-win64-setup.exe` et lance-le. Il installe Home pour ton compte seulement, sans droits d'administrateur.
2. Home propose ensuite ses mises à jour tout seul, depuis les releases de ce dépôt.
3. Pour un jeu Switch : « Ajouter un jeu → Switch », Home cherche lui-même le fichier de ton jeu, sa mise à jour et ton `prod.keys` sur le PC (sinon tu les lui montres). Il télécharge ScarletNX,
   construit le jeu et crée sa tuile. Il faut une carte graphique avec Vulkan 1.3. Home ne fournit ni jeu ni clé.

Chaque fichier est accompagné de son `.sha256` pour vérifier le téléchargement.

Le volume de chaque jeu se règle dans Home sans rien installer d'autre (macOS 14.2 ou plus récent) : Home fait passer le son du jeu par lui.
macOS demande une fois l'autorisation d'enregistrer le son du système.

## Contenu du dépôt

| Dossier | Rôle |
|---|---|
| `app/` | Home pour Mac (`main.swift`), l'app « veille » qui ouvre Home quand une manette se connecte, les sons, et `salon-construire.command` qui compile et installe Home |
| `windows/` | Home pour Windows (C# / Avalonia) |
| `moteur/outils/` | Les scripts que Home lance : construire un jeu, reconstruire, mods, mises à jour, serveurs en ligne |
| `moteur/patches/`, `moteur/mng/` | Les patchs appliqués à nxnative et à MacNativeGames, et la version de chacun sur laquelle ils s'appliquent |
| `moteur/tools/` | Gestion des moteurs : version figée, patchs rejoués à chaque mise à jour, notes de version |
| `moteur/pc/`, `moteur/steam/`, `moteur/obelisk/`, `moteur/compat/` | Jeux PC : Epic (Legendary), Steam, lancement, liste de compatibilité |
| `scripts/installer-local.sh` | Recopie le dépôt dans `/Applications/Home/moteur`, puis compile et installe Home sur ton Mac |
| `CLAUDE.md`, `.claude/` | Le contexte pour Claude Code |

## Compiler

**Mac**
```bash
bash app/salon-construire.command
```
Ça compile Home, l'installe dans `/Applications/Home.app` et le relance. Avec un certificat « Home Dev »
(Trousseaux d'accès → Assistant de certification → Créer un certificat, type « Signature de code »),
macOS garde les autorisations de Home d'une version à l'autre.

**Windows**
```bash
dotnet build windows/Home.csproj
```

## Publier une version

Chaque push sur `main` est compilé par GitHub Actions (onglet **Actions**), pour Mac et pour Windows. Pour publier une release :
**Actions → Construire Home → Run workflow**, tape la version (ex. `0.3.0`), puis **Run workflow**. La release « Home 0.3.0 »
apparaît quelques minutes plus tard avec `Home-macSilicon.dmg` et `Home-win64-setup.exe`. Pousser un tag `v0.3.0` fait pareil.

## Signaler un problème

Ouvre un ticket avec le jeu concerné, sa version, et le journal (Menu → Avancé → Journaux). Ne joins jamais un jeu, un dump, une clé
ni un lien pour en télécharger : le ticket serait supprimé.

## Licences

Le code de Home est sous licence MIT (voir `LICENSE`), sauf `moteur/obelisk/launch.sh` et `moteur/steam/`, sous GPL-3.0. Les projets
repris ou utilisés, les marques et les contenus sont détaillés dans `THIRD_PARTY_NOTICES.md`. Utilise Home seulement avec des jeux que tu possèdes.
