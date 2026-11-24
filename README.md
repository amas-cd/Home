# Home

Launcher de jeux façon console, à la manette. Sur **Mac** (Apple Silicon) : les jeux Switch recompilés pour le Mac
(nxnative, MacNativeGames), les jeux PC Epic et Steam, et les apps Mac. Sur **Windows** : les jeux Steam et Epic installés,
et les recomps PC.

Home ne contient aucun jeu, aucune clé et aucun fichier système : chacun utilise les copies de sa propre console et les jeux
qu'il possède.

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

Chaque fichier est accompagné de son `.sha256` pour vérifier le téléchargement.

En option sur Mac : [Background Music](https://github.com/kyleneideck/BackgroundMusic), pour régler le volume de chaque jeu.

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
Ça compile Home, l'installe dans `/Applications/Home.app` et le relance. Avec un certificat « Salon Dev »
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

## Licences

Le code de Home est sous licence MIT (voir `LICENSE`). Les projets repris ou utilisés sont listés dans
`THIRD_PARTY_NOTICES.md`. Utilise Home seulement avec des jeux que tu possèdes.
