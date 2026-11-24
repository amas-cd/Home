#!/bin/bash
# Mise à jour de nuit : le moteur passe au dernier nxnative (avec tes patchs : Salon, volume, plein écran, online SMO) s'ils s'appliquent
# encore, puis chaque jeu nxnative est reconstruit depuis son dossier de construction (sans NSP), puis le Mac se met en veille.
# Si un patch entre en conflit avec le nouveau nxnative, le moteur reste tel quel (Claude fera la mise à jour à la main) et les jeux sont
# quand même reconstruits avec lui. Lancé par Home (Options → Mises à jour → Mettre à jour le moteur nxnative). TOTK passe par MacNativeGames.
# Journal : /Applications/Home/log/mettre-a-jour.log — bilan : rapport sur le Bureau
HR="${HOME_RACINE:-$HOME/Library/Application Support/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
GAMES=$JX; MOT="$HR/moteur"; LOGD="$HR/log"; CONS="$HR/constructions"; mkdir -p "$LOGD"
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
  # un patch ne s'applique plus tel quel : les réparations sûres de tools/serie.py (fichier déplacé ou devenu un lien, ajout simple à
  # côté d'un changement de l'amont). Si elles ne suffisent pas, rien n'est écrit : la version et les patchs restent, Home l'affiche.
  "$PY" tools/engine.py --tmp "$MOT/.bump-tmp" bump --to main --repair --report "$LOGD/nxnative-maj-rapport.txt" > "$LOGD/nxnative-maj.log" 2>&1; code=$?
  if [ $code -eq 0 ]; then
    STATUS+=("moteur : $avant → $(cut -c1-12 .upstream-ref) ($(grep -c '^repaired: ' "$LOGD/nxnative-maj.log") patch(s) réparé(s) seul(s))")
  else
    STATUS+=("moteur : mise à jour nxnative en attente, un de tes changements ne s'applique plus → version $avant gardée (rapport : $LOGD/nxnative-maj-rapport.txt)")
    [ -f "$LOGD/nxnative-maj-rapport.txt" ] || tail -20 "$LOGD/nxnative-maj.log" > "$LOGD/nxnative-maj-rapport.txt"
    printf '{"etat": "attente", "rapport": "%s", "version_gardee": "%s"}\n' "$LOGD/nxnative-maj-rapport.txt" "$avant" > "$LOGD/nxnative-maj.json"
  fi
fi
# la mise à jour est passée (ou il n'y avait rien de neuf) : plus rien en attente ; et la série part aussi dans le dépôt Home s'il est là
if [ "$(cat "$LOGD/nxnative-maj.json" 2>/dev/null | grep -c attente)" = 1 ] && "$PY" tools/engine.py --tmp "$MOT/.bump-tmp" bump --to main --dry >/dev/null 2>&1; then rm -f "$LOGD/nxnative-maj.json" "$LOGD/nxnative-maj-rapport.txt"; fi
if [ "$avant" != "$(cut -c1-12 .upstream-ref)" ] && [ -d "$HOME/Home/moteur/patches" ] && [ "$HOME/Home/moteur" != "$MOT" ]; then
  rsync -a --delete --exclude README.md "$MOT/patches/" "$HOME/Home/moteur/patches/" && cp "$MOT/.upstream-ref" "$HOME/Home/moteur/.upstream-ref" && echo "série nxnative recopiée dans $HOME/Home/moteur (à enregistrer dans le dépôt)"
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
