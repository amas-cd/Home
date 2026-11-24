#!/bin/bash
# Mise à jour de nuit : le moteur passe au dernier nxnative (avec tes patchs : Salon, volume, plein écran, online SMO) s'ils s'appliquent
# encore, puis chaque jeu nxnative est reconstruit depuis son dossier de construction (sans NSP), puis le Mac se met en veille.
# Si un patch entre en conflit avec le nouveau nxnative, le moteur reste tel quel (Claude fera la mise à jour à la main) et les jeux sont
# quand même reconstruits avec lui. Lancé par Home (Options → Mises à jour → Mettre à jour le moteur nxnative). TOTK passe par MacNativeGames.
# Journal : /Applications/Home/log/mettre-a-jour.log — bilan : rapport sur le Bureau
GAMES=/Applications/Jeux; MOT="/Applications/Home/moteur"; LOGD="/Applications/Home/log"; CONS="/Applications/Home/constructions"; mkdir -p "$LOGD"
exec > >(tee -a "$LOGD/mettre-a-jour.log") 2>&1
echo; echo "===== $(date '+%d/%m %H:%M') : moteur + rebuild ====="
caffeinate -d -i -s -w $$ &
PY="$MOT/.venv/bin/python3"; [ -x "$PY" ] || PY="/Applications/NX Library.app/Contents/Resources/Runtime/python/bin/python3"; [ -x "$PY" ] || PY="$(command -v python3)"
STATUS=()

echo; echo "== moteur : mise à jour vers le dernier nxnative"
cd "$MOT"; mkdir -p .bump-tmp
avant="$(cut -c1-12 .upstream-ref)"
if "$PY" tools/engine.py --tmp "$MOT/.bump-tmp" bump --to main --dry >/dev/null 2>&1; then
  "$PY" tools/engine.py --tmp "$MOT/.bump-tmp" bump --to main >/dev/null 2>&1 && STATUS+=("moteur : $avant → $(cut -c1-12 .upstream-ref)") || STATUS+=("moteur : mise à jour ÉCHOUÉE, version $avant gardée")
else
  STATUS+=("moteur : tes patchs entrent en conflit avec le nouveau nxnative → version $avant gardée (dis-le à Claude)")
fi
"$PY" tools/engine.py --tmp "$MOT/.bump-tmp" sync >/dev/null 2>&1 || STATUS+=("moteur : sync ÉCHOUÉ")
rm -rf "$MOT"/.bump-tmp
# rien de nouveau (même nxnative, mêmes correctifs que la dernière reconstruction) : les jeux ne sont pas refaits
EMP="$(cat "$MOT/.upstream-ref" "$MOT"/patches/series "$MOT"/patches/*.patch 2>/dev/null | shasum -a 256 | cut -c1-64)"
if [ -z "$HOME_FORCER" ] && [ "$EMP" = "$(cat "$CONS/.nxnative-version" 2>/dev/null)" ]; then
  echo "nxnative est déjà à jour"; exit 0
fi

# chaque app nxnative de /Applications/Jeux (DMTitleID) dont le dossier de construction <title id>_…build existe encore
for app in "$GAMES"/*.app; do
  TID="$(/usr/libexec/PlistBuddy -c 'Print :DMTitleID' "$app/Contents/Info.plist" 2>/dev/null)"; [ -n "$TID" ] || continue
  W=""; for d in "$CONS"/*; do [ -d "$d/extract" ] || continue
    if grep -qix "$TID" "$d/.title-id" 2>/dev/null || grep -qi "\"app\": \"$TID\"" "$d/source.json" 2>/dev/null; then W="$d"; break; fi; done
  NOMJ="$(basename "$app" .app)"; [ -n "$W" ] || { STATUS+=("$NOMJ : pas de dossier de construction, pas reconstruit"); continue; }
  echo; echo "== $NOMJ ($TID) depuis $W"
  /bin/bash "$MOT/outils/construire-jeu.command" --moteur nxnative --depuis-build "$W" --sortie "$app" < /dev/null
  L="$LOGD/construire-$(basename "$W").log"
  grep -qE '\] done:|"msg": "done: ' "$L" 2>/dev/null && STATUS+=("$NOMJ : OK") || STATUS+=("$NOMJ : ÉCHEC ($L)")
done

printf '%s\n' "${STATUS[@]}" | grep -q "ÉCHEC" || printf '%s\n' "$EMP" > "$CONS/.nxnative-version"
R="$HOME/Desktop/Rapport build nuit.txt"
{ echo "RAPPORT DU BUILD DE NUIT — $(date '+%d/%m/%Y %H:%M')"; echo; printf '  %s\n' "${STATUS[@]}"; echo; echo "Moteur : $(git -C "$MOT/engine" log --oneline -1 2>/dev/null | cut -c1-80)"; } > "$R"
cat "$R"; cp "$R" "$LOGD/rapport-nuit.txt" 2>/dev/null
osascript -e 'display notification "Rapport sur le Bureau : Rapport build nuit.txt" with title "Build de nuit terminé"' 2>/dev/null
# lancé depuis le Salon (SALON_SANS_VEILLE=1) : pas de mise en veille, la fenêtre attend
if [ -n "$SALON_SANS_VEILLE" ]; then read -r -p "Terminé. Entrée pour fermer." _; exit 0; fi
echo "$(date '+%H:%M') : mise en veille dans 30 s (Ctrl+C pour annuler)"; sleep 30
pmset sleepnow 2>/dev/null || osascript -e 'tell application "System Events" to sleep'
