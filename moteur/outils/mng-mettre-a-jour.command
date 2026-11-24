#!/bin/bash
# MacNativeGames à jour : la dernière version du dépôt (tes commits rejoués par-dessus, tools/serie.py), puis chaque app
# MacNativeGames reconstruite avec — TOTK Online avec ses mods de code actuels — sans la ROM.
HR="${HOME_RACINE:-$HOME/Library/Application Support/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"   # Home lance sans le PATH du Terminal : les outils Homebrew (ffmpeg, ffprobe, llvm)
GAMES=$JX; MNG="$HR/MacNativeGames"; OUT="$HR/moteur/outils"
cd "$MNG" || { echo "ÉCHEC : MacNativeGames introuvable dans $MNG"; exit 1; }
while pgrep -f "[b]uild_ipa_from_nsp.py|[b]uild_app.py|[u]pdate_runtime.py" >/dev/null; do echo "une autre construction tourne, j'attends…"; sleep 60; done
echo "== MacNativeGames"
avant="$(git rev-parse --short HEAD)"
# Tes changements (les commits du clone qui ne sont pas dans l'amont) sont rejoués sur la nouvelle version par tools/serie.py, dans un
# dossier à part : le clone ne bouge que si tout s'est appliqué. Un patch qui bute est réparé seul quand c'est sûr (fichier devenu un
# lien, fichier déplacé, ajout simple) ; sinon rien ne change et un rapport est écrit dans $HR/log (Home l'affiche : « en attente »).
PY="$(command -v python3)"; [ -x "$HR/moteur/.venv/bin/python3" ] && PY="$HR/moteur/.venv/bin/python3"
DEPOT=(); [ -d "$HOME/Home/moteur/mng" ] && DEPOT=(--depot "$HOME/Home")   # le dépôt Home, s'il est sur ce Mac : la série y est mise à jour aussi
"$PY" "$HR/moteur/tools/serie.py" mng-maj --clone "$MNG" --racine "$HR" "${DEPOT[@]}"; code=$?
if [ $code -eq 3 ]; then echo "ÉCHEC : Mise à jour MacNativeGames en attente : un de tes changements ne s'applique plus (version $avant gardée, rapport dans $HR/log/mng-maj-rapport.txt)"; exit 1; fi
[ $code -eq 0 ] || { echo "ÉCHEC : la mise à jour de MacNativeGames n'a pas pu se faire ; version $avant gardée"; exit 1; }
apres="$(git rev-parse --short HEAD)"; echo "MacNativeGames : $avant → $apres"
ETATV="$HR/constructions/.mng-version"
if [ -z "$HOME_FORCER" ] && [ "$(git rev-parse HEAD)" = "$(cat "$ETATV" 2>/dev/null)" ]; then echo "MacNativeGames est déjà à jour"; exit 0; fi
ok=0
for app in "$GAMES"/*.app; do
  case "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" in org.macnativegames.*) ;; *) continue;; esac
  echo "== $(basename "$app" .app)"
  if [ "$(basename "$app")" = "The Legend of Zelda - Tears of the Kingdom.app" ]; then
    M=(); F="$HR/constructions/Zelda-Tears-of-the-Kingdom/.home-mods-code"
    [ -f "$F" ] && while IFS= read -r l; do [ -n "$l" ] && M+=("$l"); done < "$F"
    HOME_TACHE=1 /bin/bash "$OUT/totk-mng-online.command" "${M[@]}" < /dev/null || ok=1
  else
    /bin/bash "$OUT/mng-reconstruire.command" "$app" < /dev/null || ok=1
  fi
done
[ $ok -eq 0 ] && git rev-parse HEAD > "$ETATV"
[ $ok -eq 0 ] && echo "done in : MacNativeGames à jour" || echo "ÉCHEC d'une reconstruction (journaux dans $HR/log)"
exit $ok
