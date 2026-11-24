#!/bin/bash
# MacNativeGames à jour : la dernière version du dépôt (tes commits gardés par-dessus, rebase), puis chaque app
# MacNativeGames reconstruite avec — TOTK Online avec ses mods de code actuels — sans la ROM.
export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"   # Home lance sans le PATH du Terminal : les outils Homebrew (ffmpeg, ffprobe, llvm)
GAMES=/Applications/Jeux; MNG="/Applications/Home/MacNativeGames"; OUT="/Applications/Home/moteur/outils"
cd "$MNG" || { echo "ÉCHEC : MacNativeGames introuvable dans $MNG"; exit 1; }
while pgrep -f "[b]uild_ipa_from_nsp.py|[b]uild_app.py|[u]pdate_runtime.py" >/dev/null; do echo "une autre construction tourne, j'attends…"; sleep 60; done
echo "== MacNativeGames"
avant="$(git rev-parse --short HEAD)"
if ! git -c user.name=Anas -c user.email=assosbs9@gmail.com pull --rebase --autostash --quiet; then
  git rebase --abort >/dev/null 2>&1
  echo "ÉCHEC : tes changements entrent en conflit avec la nouvelle version de MacNativeGames ; version $avant gardée (dis-le à Claude)"; exit 1
fi
apres="$(git rev-parse --short HEAD)"; echo "MacNativeGames : $avant → $apres"
ETATV="/Applications/Home/constructions/.mng-version"
if [ -z "$HOME_FORCER" ] && [ "$(git rev-parse HEAD)" = "$(cat "$ETATV" 2>/dev/null)" ]; then echo "MacNativeGames est déjà à jour"; exit 0; fi
ok=0
for app in "$GAMES"/*.app; do
  case "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" in org.macnativegames.*) ;; *) continue;; esac
  echo "== $(basename "$app" .app)"
  if [ "$(basename "$app")" = "The Legend of Zelda - Tears of the Kingdom.app" ]; then
    M=(); F="/Applications/Home/constructions/Zelda-Tears-of-the-Kingdom/.home-mods-code"
    [ -f "$F" ] && while IFS= read -r l; do [ -n "$l" ] && M+=("$l"); done < "$F"
    HOME_TACHE=1 /bin/bash "$OUT/totk-mng-online.command" "${M[@]}" < /dev/null || ok=1
  else
    /bin/bash "$OUT/mng-reconstruire.command" "$app" < /dev/null || ok=1
  fi
done
[ $ok -eq 0 ] && git rev-parse HEAD > "$ETATV"
[ $ok -eq 0 ] && echo "done in : MacNativeGames à jour" || echo "ÉCHEC d'une reconstruction (journaux dans /Applications/Home/log)"
exit $ok
