#!/bin/bash
# Installe le dépôt sur ce Mac : recopie app/ et moteur/ dans /Applications/Home/moteur (là où le Home installé lit ses scripts
# tant qu'il n'est pas autonome), puis recompile et réinstalle /Applications/Home.app.
#   bash scripts/installer-local.sh                 tout recopier, puis compiler et installer Home
#   bash scripts/installer-local.sh --sans-compiler  seulement recopier (un changement de script, pas de main.swift)
# Rien n'est supprimé dans /Applications/Home : les fichiers propres à ce Mac (recettes Obelisk, journaux, clés, sauvegardes
# main.swift.avant-*) restent. Le dépôt est la source : ne modifie pas /Applications/Home/moteur à la main.
set -e
R="$(cd "$(dirname "$0")/.." && pwd)"; M="${HOME_RACINE:-$HOME/Library/Application Support/Home}/moteur"; [ -d "$M" ] || [ ! -d /Applications/Home/moteur ] || M=/Applications/Home/moteur   # une installation d'avant, pas encore déplacée
[ -d "$M" ] || { echo "Pas d'installation de Home dans $M : rien à recopier."; exit 1; }
EX=(--exclude .DS_Store --exclude __pycache__ --exclude .build --exclude compilation.log)
mkdir -p "$M/salon" "$M/outils" "$M/tools" "$M/patches" "$M/obelisk"
rsync -a "${EX[@]}" "$R/app/" "$M/salon/"
rsync -a "${EX[@]}" "$R/moteur/outils/" "$M/outils/"
rsync -a "${EX[@]}" "$R/moteur/tools/" "$M/tools/"
# les patchs nxnative vont avec leur version figée : si ce Mac a avancé (« Mettre à jour nxnative »), ses patchs ont été refaits pour
# sa version et ceux du dépôt ne s'y appliquent plus forcément — on garde les siens et on le dit
if [ ! -f "$M/.upstream-ref" ] || [ "$(cat "$M/.upstream-ref")" = "$(cat "$R/moteur/.upstream-ref")" ]; then rsync -a "${EX[@]}" "$R/moteur/patches/" "$M/patches/"
else echo "nxnative : ce Mac est sur $(cut -c1-12 "$M/.upstream-ref"), le dépôt sur $(cut -c1-12 "$R/moteur/.upstream-ref") : patchs de ce Mac gardés (montre la différence à Claude)"; fi
rsync -a "${EX[@]}" "$R/moteur/obelisk/" "$M/obelisk/"
EX+=(--exclude target)
for d in pc compat mng steam; do SUP=(); [ "$d" = mng ] && SUP=(--delete)   # la série MacNativeGames change de noms de fichiers : les anciens partent
  [ -d "$R/moteur/$d" ] && { mkdir -p "$M/$d"; rsync -a "${SUP[@]}" "${EX[@]}" "$R/moteur/$d/" "$M/$d/"; }; done
[ -f "$M/.upstream-ref" ] || cp "$R/moteur/.upstream-ref" "$M/.upstream-ref"   # la version figée de nxnative : celle de ce Mac est gardée (elle avance avec « Mettre à jour nxnative »)
cp "$R/moteur/README.md" "$M/README.md"
chmod +x "$M"/outils/*.command "$M"/outils/*.sh "$M"/salon/*.command 2>/dev/null || true
echo "Dépôt recopié dans $M ($(git -C "$R" rev-parse --short HEAD 2>/dev/null || echo '?'))"
[ "$1" = "--sans-compiler" ] && exit 0
bash "$M/salon/salon-construire.command"
