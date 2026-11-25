# Projets tiers

Home ne contient aucun jeu, aucune clé et aucun fichier système Nintendo. Il compile ou lance des projets tiers,
récupérés sur le Mac ou le PC de chacun :

| Projet | Licence | Utilisation |
|---|---|---|
| [nxnative](https://github.com/seedds/nxnative) | MIT, © 2026 seedds | Moteur des jeux Switch ; les patchs de `moteur/patches/` s'appliquent dessus |
| [MacNativeGames](https://github.com/ly05010419/MacNativeGames) | MIT, © 2026 MacNativeGames contributors | Tears of the Kingdom / Breath of the Wild sur Mac |
| [Obelisk](https://github.com/Zagrios/Obelisk) | GPL-3.0, © Zagrios | `moteur/obelisk/launch.sh` en est repris ; `moteur/steam` (l'outil `home-steam`) se compile avec sa source, téléchargée sur le Mac au commit de `moteur/steam/OBELISK-REF`. Ces deux parties de Home sont donc sous GPL-3.0. Home ne lit ni n'ouvre l'app Obelisk |
| [Voile](https://github.com/Zagrios/Voile) | GPL-3.0, © Zagrios | Le moteur Windows des jeux PC sur Mac. Programme à part, téléchargé sur le Mac ; Home ne l'inclut pas |
| [Legendary](https://github.com/derrod/legendary) | GPL-3.0 | Compte, bibliothèque et téléchargement Epic Games. Installé à part sur le Mac, appelé par `moteur/pc/pc.py` |
| [Background Music](https://github.com/kyleneideck/BackgroundMusic) | GPL-2.0 | Volume par jeu sous macOS 14.0 et 14.1 seulement (ensuite Home a son propre mélangeur) ; Home parle à son périphérique audio, il ne l'inclut pas |
| [ScarletNX](https://github.com/scarletnx/ScarletNX) | GPL-3.0-or-later, © 2026 the ScarletNX contributors | Home pour Windows : recompile et lance les jeux Switch. Programme à part, téléchargé sur le PC depuis [scarletnx/nightly](https://github.com/scarletnx/nightly/releases) à la version de `windows/SCARLETNX-REF` ; Home n'inclut ni ne modifie son code |
| [Mona Sans](https://github.com/github/mona-sans) | OFL-1.1, © 2023 GitHub | L'écriture de Home pour Windows (`windows/polices`, avec sa licence) |
| [Fluent System Icons](https://github.com/microsoft/fluentui-system-icons), par le paquet [FluentIcons](https://github.com/davidxuang/FluentIcons) | MIT | Les icônes de Home pour Windows |
| Kenney « Interface Sounds » | CC0 | Banque de sons de rechange (`app/sons/banque`) |

Les six sons de l'interface (`app/sons/*.wav`) sont des sons originaux, créés pour Home : ils ne viennent d'aucun projet tiers.

## Licence de Home

Le code de Home est sous licence MIT (`LICENSE`), à deux exceptions, sous GPL-3.0 parce qu'elles reprennent ou utilisent du code d'Obelisk :
`moteur/obelisk/launch.sh` et `moteur/steam/`. Les patchs de `moteur/patches/` et de `moteur/mng/patches/` sont des modifications de
nxnative et de MacNativeGames, sous la licence de ces projets (MIT).

## Marques et contenus

Nintendo, Switch, Epic Games, Steam, Windows, PlayStation et les noms des jeux sont des marques de leurs propriétaires. Home n'est lié à
aucun d'eux et n'est ni approuvé ni soutenu par eux. Il n'embarque aucun de leurs logos : les repères des services sont de simples
initiales ou symboles dessinés pour Home. Les jaquettes, fonds et logos des jeux ne sont pas dans ce dépôt : chaque installation les
télécharge pour son propre usage depuis les boutiques, SteamGridDB (avec la clé de l'utilisateur) et Wikipédia.
