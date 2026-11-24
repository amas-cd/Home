#!/bin/bash
# alleger-build.sh <dossier _build> : retire d'un dossier de construction nxnative ce qui ne sert qu'à accélérer la construction
# suivante — le cache de compilation des shaders (cas.db), la bibliothèque de shaders complète d'où l'app a tiré la sienne,
# le paquet de shaders extrait, les lots intermédiaires des pipelines, les gros journaux. L'app garde tout ce qu'il lui faut :
# ses fichiers sont à elle (le RomFS et les pipelines sont des clones APFS du dossier, qui restent). La construction suivante
# refait ces fichiers (plus longue : la traduction et la compilation des shaders sont refaites).
# Sans argument : tous les dossiers de construction nxnative de /Applications/Home/constructions.
HR="${HOME_RACINE:-/Applications/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
if [ $# -eq 0 ]; then for d in "$HR/constructions"/*; do [ -d "$d/extract" ] && /bin/bash "$0" "$d"; done
  case "$0" in */.salon/*|*alleger*) read -r -t 15 -p "Fenêtre fermée dans 15 s." _;; esac; exit 0; fi
W="${1%/}"; [ -d "$W/extract" ] || { echo "pas un dossier de construction nxnative : $W"; exit 1; }
avant=$(du -sk "$W" | cut -f1)
rm -rf "$W/shader/cache" "$W/shader/pkg" "$W/shader/pkg.key" "$W/shader/pkg.outputs.key" "$W/pso/mac-work" "$W/tmp" "$W"/shader/mac-b-*.key "$W"/shader/ios
find "$W/logs" -type f -size +20M -delete 2>/dev/null
find "$W" -name .DS_Store -delete 2>/dev/null
apres=$(du -sk "$W" | cut -f1)
echo "dossier de construction allégé ($(basename "$W")) : $(( (avant - apres) / 1048576 )) Go retirés"
