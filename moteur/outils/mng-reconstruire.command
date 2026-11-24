#!/bin/bash
# Reconstruit une app MacNativeGames (TOTK, BotW) SANS la ROM ni les clés : update_runtime.py de MacNativeGames remet dans
# l'app le moteur de ce dépôt (avec nos correctifs) et garde les fichiers du jeu qu'elle contient déjà (modules réécrits,
# RomFS, polices, données du jeu). Si la chaîne des shaders a changé, les shaders de démarrage sont refaits depuis le
# dossier de construction (--seed), toujours sans la ROM.
#   mng-reconstruire.command <app> [dossier de construction]
# Journal : /Applications/Home/log/mng-reconstruire.log
export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"   # Home lance sans le PATH du Terminal : les outils Homebrew (ffmpeg, ffprobe, llvm)
APP="${1%/}"; GAMES=/Applications/Jeux; MNG="/Applications/Home/MacNativeGames"; LOGD="/Applications/Home/log"; mkdir -p "$LOGD"; LOG="$LOGD/mng-reconstruire.log"
WORK="${2%/}"
if [ -z "$APP" ]; then   # lancé d'un double-clic, sans argument : l'app MacNativeGames de /Applications/Jeux (TOTK Online d'abord)
  for a in "/Applications/Jeux/The Legend of Zelda - Tears of the Kingdom.app" /Applications/Jeux/*.app; do
    [ -d "$a" ] || continue
    case "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$a/Contents/Info.plist" 2>/dev/null)" in org.macnativegames.*) APP="$a"; break;; esac
  done
fi
fin() { echo; read -r -p "Entrée pour fermer." _; exit "${1:-0}"; }
exec > >(tee "$LOG") 2>&1
echo "===== $(date '+%d/%m %H:%M') : $(basename "$APP") — moteur MacNativeGames, sans la ROM"
[ -d "$APP" ] || { echo "App introuvable : $APP (une première construction demande la ROM)"; fin 1; }
[ -f "$MNG/update_runtime.py" ] || { echo "MacNativeGames introuvable dans $MNG"; fin 1; }
if [ -z "$WORK" ]; then   # le dossier de construction : celui que le registre de Home garde pour l'app, sinon d'après son nom
  WORK="$(/usr/bin/python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get(sys.argv[2]) or {}).get("travail") or "")' /Applications/Home/registre.json "$APP" 2>/dev/null)"
  [ -z "$WORK" ] && case "$(basename "$APP")" in *TOTK*|*Tears*) WORK="/Applications/Home/constructions/Zelda-Tears-of-the-Kingdom";; *BotW*|*Breath*) WORK="/Applications/Home/constructions/Zelda-Breath-of-the-Wild";; *Ocarina*) WORK="/Applications/Home/constructions/OOT";; esac
fi
[ -n "$WORK" ] && [ ! -d "$WORK" ] && WORK=""
pgrep -x TOTK >/dev/null && { echo "Quitte d'abord le jeu (⌘Q)."; fin 1; }
while pgrep -f "[b]uild_ipa_from_nsp.py|[b]uild_app.py|[u]pdate_runtime.py" >/dev/null; do echo "$(date '+%H:%M') : une autre construction tourne, j'attends…"; sleep 60; done
caffeinate -d -i -s -w $$ &
DISCRET=(); [ -n "$HOME_DISCRET" ] && DISCRET=(/usr/sbin/taskpolicy -b)
PY=""; for p in /opt/homebrew/bin/python3.14 "$HOME/.homebrew/bin/python3.14" "$(command -v python3.14 2>/dev/null)"; do [ -n "$p" ] && [ -x "$p" ] && { PY="$p"; break; }; done
[ -z "$PY" ] && { echo "Python 3.14 introuvable (Homebrew : brew install python@3.14) — dis-le à Claude"; fin 1; }
ARGS=("$APP" --no-native-5k); [ -n "$WORK" ] && ARGS+=(--work "$WORK")
echo "dossier de construction : ${WORK:-celui par défaut de MacNativeGames}"
echo; echo "== moteur (quelques minutes, ne pas interrompre)"
( cd "$MNG" && "${DISCRET[@]}" "$PY" update_runtime.py "${ARGS[@]}" ); ok=$?
if [ $ok -ne 0 ] && ! grep -q "done in" "$LOG" && grep -q -- "--seed" "$LOG"; then
  echo; echo "== la chaîne des shaders a changé : shaders de démarrage refaits depuis le dossier de construction (toujours sans la ROM)"
  ( cd "$MNG" && "${DISCRET[@]}" "$PY" update_runtime.py "${ARGS[@]}" --seed ); ok=$?
fi
if [ $ok -eq 0 ] && grep -qE "done in|^Built .*\.app|updated" "$LOG"; then
  echo; echo "Prêt : $APP a le moteur à jour. La ROM n'a pas servi."
  osascript -e "display notification \"$(basename "$APP" .app) est à jour\" with title \"Reconstruction terminée\"" 2>/dev/null; fin 0
fi
echo; echo "ÉCHEC — dis-le à Claude (journal : $LOG)."
echo "(Si MacNativeGames dit que l'app « needs build_app.py », seule une construction complète, avec la ROM, peut la refaire.)"
fin 1
