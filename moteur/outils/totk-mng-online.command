#!/bin/bash
# TOTK MacNativeGames + mod ONLINE (TOTK Online de Kirbymimi) : le module du mod est réécrit et chargé à côté des modules du jeu (étape 1 du portage).
# Première construction seulement : ~/Downloads/TOTK/base.xci (1.0.0) + update.nsp (1.2.1) + ~/Downloads/ProdKeys/prod.keys ;
# ensuite, sans la ROM (mng-reconstruire.command).
# App : /Applications/Jeux/The Legend of Zelda - Tears of the Kingdom.app (à côté de la version solo) — cache partagé : TOTK_mng_build — journal : log/build-totk-mng-online.log
export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"   # Home lance sans le PATH du Terminal : les outils Homebrew (ffmpeg, ffprobe, llvm)
MNG="/Applications/Home/MacNativeGames"; GAMES=/Applications/Jeux; LOGD="/Applications/Home/log"; mkdir -p "$LOGD"; LOG="$LOGD/build-totk-mng-online.log"
# Arguments : les dossiers des mods de code activés dans Home (avec exefs/) ; aucun = pas de mod de code.
# L'app existe déjà : tout se fait SANS la ROM. Mêmes mods de code que la dernière fois (TOTK_mng_build/.home-mods-code) :
# seul le moteur est remis dans l'app (mng-reconstruire.command, quelques minutes). Mods de code changés : l'app est refaite
# depuis le dossier de construction (build_app.py --from-work v121). La ROM ne sert qu'à la toute première construction
# (ou TOTK_FULL=1).
APP="$GAMES/The Legend of Zelda - Tears of the Kingdom.app"; WORKD="/Applications/Home/constructions/Zelda-Tears-of-the-Kingdom"; ETAT="$WORKD/.home-mods-code"; MODS_CODE=("$@")
DEPUIS_TRAVAIL=""
if [ -d "$APP" ] && [ -z "$TOTK_FULL" ]; then
  if [ "$(printf '%s\n' "${MODS_CODE[@]}")" = "$(cat "$ETAT" 2>/dev/null)" ]; then exec /bin/bash "/Applications/Home/moteur/outils/mng-reconstruire.command" "$APP" "$WORKD"; fi
  DEPUIS_TRAVAIL=1
fi
exec > >(tee "$LOG") 2>&1
caffeinate -d -i -s -w $$ &
echo "===== $(date '+%d/%m %H:%M') : TOTK MacNativeGames ONLINE"
[ -f "$MNG/build_app.py" ] || { echo "MacNativeGames n'est pas encore dans $MNG (colle d'abord la commande git clone)"; read -r -p "Entrée pour fermer." _; exit 1; }
# outils : développeur Apple, Homebrew (opus, libvpx, Python 3.14)
xcode-select -p >/dev/null 2>&1 || { echo "Les outils développeur d'Apple manquent : une fenêtre d'installation s'ouvre, relance ce script après."; xcode-select --install; read -r -p "Entrée pour fermer." _; exit 1; }
BREW=""; for b in /opt/homebrew/bin/brew "$HOME/.homebrew/bin/brew"; do [ -x "$b" ] && { BREW="$b"; break; }; done
if [ -n "$BREW" ]; then echo "Homebrew : $BREW"; "$BREW" install opus libvpx python@3.14 2>&1 | tail -3
else echo "Homebrew introuvable dans /opt/homebrew (MacNativeGames le demande là) — dis-le à Claude"; fi
PY=""; for p in /opt/homebrew/bin/python3.14 "$HOME/.homebrew/bin/python3.14" "$(command -v python3.14 2>/dev/null)"; do [ -n "$p" ] && [ -x "$p" ] && { PY="$p"; break; }; done
[ -z "$PY" ] && { echo "Python 3.14 introuvable — dis-le à Claude"; read -r -p "Entrée pour fermer." _; exit 1; }
echo "Python : $PY"
cd "$MNG" || exit 1
MODMOD="/Applications/Home/moteur/exefs-mods/0100F2C0115B6000/TOTK_Online/exefs/subsdk4"
if [ -n "$DEPUIS_TRAVAIL" ]; then   # sans la ROM : depuis les fichiers déjà extraits et vérifiés du dossier de construction
  echo "mods de code : ${MODS_CODE[*]:-aucun} — l'app est refaite depuis $WORKD, sans la ROM"
  ARGS=(--from-work v121 --work "$WORKD" -o "$APP" --mod-module "$MODMOD" --no-native-4k)
else
  for f in "$HOME/Downloads/TOTK/base.xci" "$HOME/Downloads/TOTK/update.nsp" "$HOME/Downloads/ProdKeys/prod.keys"; do [ -f "$f" ] || { echo "Première construction : il faut $f"; read -r -p "Entrée pour fermer." _; exit 1; }; done
  ARGS=("$HOME/Downloads/TOTK/base.xci" -k "$HOME/Downloads/ProdKeys/prod.keys" --update "$HOME/Downloads/TOTK/update.nsp" -o "$APP" --mod-module "$MODMOD" --work "$WORKD" --no-native-4k)   # pas de 4K native : écran 1080p, et 1,4 Go de RAM en moins sur 16 Go
fi
if [ ${#MODS_CODE[@]} -gt 0 ]; then   # tous les mods de code : leurs correctifs réunis en un dossier, leurs modules chacun le sien
  C="$(/bin/bash "/Applications/Home/moteur/outils/mng-combiner-mods.sh" "$WORKD/.home-mods-combines" "${MODS_CODE[@]}" | tail -1)"
  [ -n "$C" ] && [ -d "$C" ] && ARGS+=(--mod "$C")
  while IFS= read -r mm; do [ -n "$mm" ] && ARGS+=(--mod-module "$mm"); done < "$WORKD/.home-mods-combines/modules.txt"
  echo "mods de code : ${#MODS_CODE[@]}"
fi
echo; echo "== construction (20 à 40 min, ne pas interrompre)"
DISCRET=(); [ -n "$HOME_DISCRET" ] && DISCRET=(/usr/sbin/taskpolicy -b)
"${DISCRET[@]}" "$PY" build_app.py "${ARGS[@]}"
if grep -q "done in" "$LOG"; then printf '%s\n' "${MODS_CODE[@]}" > "$ETAT"; echo; echo "TOTK Online MNG prêt : $GAMES/The Legend of Zelda - Tears of the Kingdom.app (premier lancement : 1-2 min de préparation)"
  osascript -e 'display notification "TOTK Online MNG est prêt" with title "Construction terminée"' 2>/dev/null
  ok=0
else echo; echo "ÉCHEC — dis-le à Claude (journal : $LOG)"; ok=1; fi
[ -z "$HOME_TACHE" ] && read -r -p "Entrée pour fermer." _
exit $ok
