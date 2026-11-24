#!/bin/bash
# Mods RomFS d'un jeu MacNativeGames (TOTK…), appelé par le Salon quand tu actives ou désactives un mod :
#   mng-mods-appliquer.command <app> [dossier de mod activé]...
# MacNativeGames ne lit que les fichiers listés dans mods/<version>/manifest.tsv (docs/mods.md) : le dossier est refait avec
# le romfs/ de chaque mod activé, dans l'ordre (le dernier gagne), puis le manifeste est recalculé avec l'outil du projet.
# Sans mod activé, le dossier est vidé (jeu d'origine). La première fois, ce qui s'y trouvait est gardé à côté.
APP="$1"; shift
MNG="/Applications/Home/MacNativeGames"; BASE="$HOME/Library/Application Support/MacNativeGames/TOTK/mods"
fin() { echo; read -r -t 8 -p "Fenêtre fermée dans 8 s (Entrée pour fermer maintenant)." _; exit "${1:-0}"; }
[ -d "$APP" ] || { echo "App introuvable : $APP"; fin 1; }
VER="$(ls "$APP/Contents/Resources/totk/extracted" 2>/dev/null | grep -E '^v[0-9]+$' | head -1)"
[ -n "$VER" ] || { echo "Version du jeu introuvable dans $APP (Contents/Resources/totk/extracted/v…)"; fin 1; }
pgrep -x TOTK >/dev/null && { echo "Quitte d'abord le jeu (⌘Q) : les mods se lisent au démarrage."; fin 1; }
D="$BASE/$VER"; mkdir -p "$BASE"
if [ -d "$D" ] && [ ! -f "$D/.salon" ] && [ -n "$(ls -A "$D" 2>/dev/null)" ]; then
  mv "$D" "$BASE/$VER.avant-salon-$(date '+%Y%m%d-%H%M')" && echo "contenu précédent gardé : $BASE/$VER.avant-salon-…"; fi
rm -rf "$D"; mkdir -p "$D"; touch "$D/.salon"
n=0
for m in "$@"; do
  R="$(find "$m" -maxdepth 4 -type d -iname romfs 2>/dev/null | head -1)"; [ -z "$R" ] && R="$m"
  rsync -a --exclude='.DS_Store' --exclude='manifest.tsv' --exclude='.salon*' "$R/" "$D/" && { n=$((n+1)); echo "mod : $(basename "$m")"; }
done
if [ $n -eq 0 ]; then echo "aucun mod activé : $VER revient au jeu d'origine"; fin 0; fi
PY=""; for p in /opt/homebrew/bin/python3.14 "$HOME/.homebrew/bin/python3.14" "$(command -v python3.14 2>/dev/null)" /usr/bin/python3; do [ -n "$p" ] && [ -x "$p" ] && { PY="$p"; break; }; done
echo; echo "manifeste ($n mod(s), calcul des empreintes : quelques secondes à une minute)…"
( cd "$MNG" && "$PY" games/totk/scripts/make_mod_manifest.py "$D" --app "$APP" --version "$VER" ) || { echo "ÉCHEC du manifeste — dis-le à Claude"; fin 1; }
echo "Mods prêts pour le prochain lancement."
fin 0
