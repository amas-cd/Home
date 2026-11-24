# Home

Launcher de jeux façon console pour Mac (Apple Silicon) : jeux Switch recompilés pour le Mac
(nxnative, MacNativeGames), jeux PC Epic et Steam via Obelisk, et apps Mac, dans une seule interface
à la manette.

Dépôt privé : Anas et les amis invités.

## Installer

1. Ouvre la dernière release (onglet **Releases** à droite) et télécharge `Home.zip`.
2. Décompresse-le et glisse **Home.app** dans **Applications**.
3. Fais un clic droit sur Home → **Ouvrir** → **Ouvrir**. L'app n'est pas signée par un compte Apple Developer,
   donc macOS le demande à la première ouverture seulement.

Il faut aussi :
- les outils développeur d'Apple (`xcode-select --install`), pour compiler les jeux ;
- tes propres jeux, clés et fichiers système, copiés depuis **ta** console. Rien de tout ça n'est dans ce dépôt ;
- l'app Obelisk, si tu veux tes jeux Epic et Steam ;
- [Background Music](https://github.com/kyleneideck/BackgroundMusic), pour régler le volume de chaque jeu.

## Contenu du dépôt

| Dossier | Rôle |
|---|---|
| `app/` | Le code de Home (`main.swift`), l'app « veille » qui ouvre Home quand une manette se connecte, les sons, et `salon-construire.command` qui compile et installe Home |
| `moteur/outils/` | Les scripts que Home lance : construire un jeu, reconstruire, mods, mises à jour, serveurs en ligne |
| `moteur/patches/` | Les patchs appliqués à nxnative (online, 60 fps TotK, plein écran, volume…) |
| `moteur/tools/` | Gestion du moteur nxnative (version figée, patchs, notes de version) |
| `moteur/obelisk/` | Lancement direct des jeux Epic via Legendary |

## Compiler sur son Mac

```bash
bash app/salon-construire.command
```

Ça compile Home, l'installe dans `/Applications/Home.app` et le relance. Avec un certificat « Salon Dev »
(Trousseaux d'accès → Assistant de certification → Créer un certificat, type « Signature de code »),
macOS garde les autorisations de Home d'une version à l'autre.

## Publier une version

Chaque push sur `main` est compilé par GitHub Actions (onglet **Actions**). Pour publier une release :

```bash
git tag v0.2.0 && git push origin v0.2.0
```

La release « Home 0.2.0 » apparaît avec `Home.zip`.

## Inviter un ami

**Settings → Collaborators → Add people**, avec son nom GitHub. Il voit alors le dépôt et ses releases.

## Licences

Le code de Home est sous licence MIT (voir `LICENSE`). Les projets repris ou utilisés sont listés dans
`THIRD_PARTY_NOTICES.md`. Utilise Home seulement avec des jeux que tu possèdes.
