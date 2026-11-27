#!/bin/bash
# Construit (ou reconstruit) un jeu Switch en app Mac, lancé depuis Home (Options du jeu, ou case + → Ajouter un jeu).
#   construire-jeu.command --moteur nxnative|mng --base <jeu.nsp|.xci|.nup> [--update <maj.nsp>]... [--dlc <dlc.nsp>]...
#                          [--exefs-mod <dossier>]... [--mod <dossier>]... [--mod-module <nso>] [--sortie <app>]
#   construire-jeu.command --moteur nxnative|mng --depuis-build <dossier de construction> [--exefs-mod <dossier>]... --sortie <app>
#   (MacNativeGames : mng-reconstruire.command, le moteur remis dans l'app sans la ROM)
# nxnative (par défaut) : moteur /Applications/Home/moteur/engine ; MacNativeGames : /Applications/Home/MacNativeGames
# (TOTK, BotW et les autres jeux qu'il gère). L'app va dans /Applications/Jeux ; si elle remplace une app existante,
# l'ancienne n'est supprimée qu'une fois la nouvelle prête. Les fichiers du jeu ne sont ni modifiés ni copiés.
# nxnative garde le jeu extrait dans son dossier <jeu>_build (extract/v<version>/) et l'app est faite de clones APFS de ces
# fichiers (aucune place en plus) : --depuis-build reconstruit à partir de là, sans le NSP, qui peut donc être supprimé.
# Home retient ce qui a servi (sources/registre.json). Journal : /Applications/Home/log/construire-<jeu>.log
HR="${HOME_RACINE:-$HOME/Library/Application Support/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
GAMES=$JX; H="$HR"; MOT="$H/moteur"; MNG="$H/MacNativeGames"; SRC="$H"; LOGD="$H/log"; CONS="$H/constructions"; mkdir -p "$CONS"
mkdir -p "$SRC" "$LOGD"
# HOME_DISCRET=1 (Home → Avancé → Construction silencieuse) : la construction tourne sur les cœurs économes du Mac
# (priorité « arrière-plan » de macOS) avec 4 compilations de shaders à la fois au lieu d'une par cœur : plus lente, mais
# le Mac reste frais et silencieux
DISCRET=(); if [ -n "$HOME_DISCRET" ]; then DISCRET=(/usr/sbin/taskpolicy -b); export J=4; fi
fin() { echo; read -r -p "Entrée pour fermer." _; exit "${1:-0}"; }
MOTEUR=nxnative; BASE=""; SORTIE=""; MODMOD=""; WORK=""; ICONE=""; UPD=(); DLC=(); EXEFS=(); MODS=()
while [ $# -gt 0 ]; do case "$1" in
  --moteur) MOTEUR="$2"; shift 2;; --base) BASE="$2"; shift 2;; --update) UPD+=("$2"); shift 2;; --dlc) DLC+=("$2"); shift 2;;
  --exefs-mod) EXEFS+=("$2"); shift 2;; --mod) MODS+=("$2"); shift 2;; --mod-module) MODMOD="$2"; shift 2;; --sortie) SORTIE="$2"; shift 2;;
  --depuis-build) WORK="${2%/}"; shift 2;; --icone) ICONE="$2"; shift 2;;
  *) echo "argument inconnu : $1"; fin 1;; esac; done
if [ -n "$WORK" ]; then
  if [ "$MOTEUR" = mng ]; then   # MacNativeGames : le moteur remis dans l'app, ses fichiers du jeu gardés (update_runtime.py), sans la ROM
    [ -d "$SORTIE" ] || { echo "App introuvable : $SORTIE"; fin 1; }
    CODE=("${MODS[@]}" "${EXEFS[@]}")
    [ ${#CODE[@]} -eq 0 ] && exec /bin/bash "$MOT/outils/mng-reconstruire.command" "$SORTIE" "$WORK"   # le moteur seul : update_runtime.py
    # un mod de code : l'app refaite depuis le dossier de construction (build_app.py --from-work), toujours sans la ROM
    case "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SORTIE/Contents/Info.plist" 2>/dev/null)" in
      1.0.0) VER=v0;; 1.2.1) VER=v121;; 1.4.3) VER=v143;; *) echo "Version de $SORTIE inconnue de MacNativeGames"; fin 1;; esac
    PY=""; for p in /opt/homebrew/bin/python3.14 "$HOME/.homebrew/bin/python3.14" "$(command -v python3.14 2>/dev/null)"; do [ -n "$p" ] && [ -x "$p" ] && { PY="$p"; break; }; done
    [ -z "$PY" ] && { echo "Python 3.14 introuvable"; fin 1; }
    LOG="$LOGD/construire-$(basename "$SORTIE" .app | tr -c 'A-Za-z0-9._-' '_').log"; exec > >(tee "$LOG") 2>&1
    ARGS=(--from-work "$VER" --work "$WORK" -o "$SORTIE"); [ -n "$MODMOD" ] && ARGS+=(--mod-module "$MODMOD")
    C="$(/bin/bash "$MOT/outils/mng-combiner-mods.sh" "$WORK/.home-mods-combines" "${CODE[@]}" | tail -1)"
    [ -n "$C" ] && [ -d "$C" ] && ARGS+=(--mod "$C")
    while IFS= read -r mm; do [ -n "$mm" ] && ARGS+=(--mod-module "$mm"); done < "$WORK/.home-mods-combines/modules.txt"
    echo "== MacNativeGames : ${#CODE[@]} mod(s) de code"
    ( cd "$MNG" && "${DISCRET[@]}" "$PY" build_app.py "${ARGS[@]}" ) || true
    grep -qE "done in|^Built .*\.app; native gameplay validation" "$LOG" && { echo "Prêt : $SORTIE"; fin 0; }
    echo "ÉCHEC — dis-le à Claude (journal : $LOG)"; fin 1
  fi
  [ -d "$WORK/extract" ] || { echo "Dossier de construction introuvable ou vide : $WORK (il faut alors le jeu de base)"; fin 1; }
  [ ${#UPD[@]} -gt 0 ] && { echo "Une mise à jour se construit avec le jeu de base (--base), pas depuis le dossier de construction"; fin 1; }
  NOM="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$WORK/source.json" 2>/dev/null)"
  [ -z "$NOM" ] && [ -n "$SORTIE" ] && NOM="$(basename "$SORTIE" .app)"; [ -z "$NOM" ] && NOM="$(basename "$WORK")"
  SLUG="$(basename "$WORK")"; SLUG="${SLUG%_build}"
else
  [ -e "$BASE" ] || { echo "Jeu de base introuvable : $BASE"; fin 1; }
  NOM="$(basename "$BASE")"; NOM="${NOM%.*}"; SLUG="$(printf '%s' "$NOM" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)"
  # une mise à jour d'un jeu déjà construit : son dossier de construction, s'il est connu, reçoit la nouvelle version
  if [ -n "$SORTIE" ]; then W0="$(/usr/bin/python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get(sys.argv[2]) or {}).get("travail") or "")' "$SRC/registre.json" "$SORTIE" 2>/dev/null)"
    [ -n "$W0" ] && [ -d "$W0" ] && SLUG="$(basename "$W0")" && SLUG="${SLUG%_build}"; fi
fi
for f in "${UPD[@]}" "${DLC[@]}"; do [ -e "$f" ] || { echo "Fichier introuvable : $f"; fin 1; }; done
LOG="$LOGD/construire-$SLUG.log"; exec > >(tee "$LOG") 2>&1
caffeinate -d -i -s -w $$ &
echo "===== $(date '+%d/%m %H:%M') : construction de $NOM avec $MOTEUR"
KEYS=""; [ -z "$WORK" ] && for k in "$HOME_CLES" "$HOME/Downloads/ProdKeys/prod.keys" "$HOME/.switch/prod.keys" "$HOME/Downloads/prod.keys" "$H/prod.keys"; do [ -f "$k" ] && { KEYS="$k"; break; }; done
[ -z "$KEYS" ] && [ -z "$WORK" ] && case "$BASE" in *.nup) ;; *) echo "prod.keys introuvable (cherché dans Téléchargements/ProdKeys, ~/.switch, Téléchargements, $JX)"; fin 1;; esac
if [ -n "$WORK" ]; then echo "depuis le dossier de construction : $WORK (aucun NSP, aucune clé)"; else echo "clés : ${KEYS:-aucune (NUP)}"; fi
# un seul build à la fois : deux en même temps saturent la mémoire
while pgrep -f "[b]uild_ipa_from_nsp.py|[b]uild_app.py" >/dev/null; do echo "$(date '+%H:%M') : un autre jeu se construit, j'attends…"; sleep 60; done

# nxnative lit un dossier qui contient le jeu, ses mises à jour et ses DLC : un dossier temporaire de liens vers tes fichiers
# (aucune copie), supprimé à la fin. Tes fichiers restent où ils sont.
ENTREE="$CONS/.entree-$$"; trap 'rm -rf "$ENTREE"' EXIT
TMPAPP="$CONS/.construction-$$.app"; rm -rf "$TMPAPP"
if [ "$MOTEUR" = mng ]; then
  [ -f "$MNG/build_app.py" ] || { echo "MacNativeGames introuvable dans $MNG"; fin 1; }
  PY=""; for p in /opt/homebrew/bin/python3.14 "$HOME/.homebrew/bin/python3.14" "$(command -v python3.14 2>/dev/null)"; do [ -n "$p" ] && [ -x "$p" ] && { PY="$p"; break; }; done
  [ -z "$PY" ] && { echo "Python 3.14 introuvable (MacNativeGames le demande) : lance une fois totk-mng-online.command, qui l'installe"; fin 1; }
  if [ -z "$LLVM_BIN" ]; then   # le contrôle de la réécriture (structck.py) désassemble avec llvm de Homebrew
    for l in /opt/homebrew/opt/llvm@23/bin "$HOME/.homebrew/opt/llvm@23/bin" /opt/homebrew/opt/llvm/bin "$HOME/.homebrew/opt/llvm/bin"; do [ -x "$l/llvm-objcopy" ] && { export LLVM_BIN="$l"; break; }; done
    [ -z "$LLVM_BIN" ] && { echo "Il manque llvm (MacNativeGames s'en sert pour vérifier le code réécrit) : dans le Terminal, tape  brew install llvm@23  puis relance la construction depuis Home."; fin 1; }
  fi
  ARGS=("$BASE" ${KEYS:+-k "$KEYS"} -o "$TMPAPP" --work "$CONS/$SLUG")
  case "$BASE" in *.nup|*.NUP)   # les bibliothèques Homebrew qu'un jeu Switch 2 demande (vidéos AV1 et VP9, son Opus)
    export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"   # Home lance sans le PATH du Terminal : ffmpeg et ffprobe de Homebrew
    manque=""; for b in dav1d libvpx opus; do [ -d "/opt/homebrew/opt/$b/lib" ] || [ -d "$HOME/.homebrew/opt/$b/lib" ] || manque="$manque $b"; done
    { command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; } || manque="$manque ffmpeg"   # la vidéo d'ouverture (make_opening_overlay.py)
    [ -n "$manque" ] && { echo "Il manque des outils Homebrew :$manque. Dans le Terminal, tape  brew install$manque  puis relance la construction depuis Home."; fin 1; };;
  esac
  case "$BASE" in *.nup|*.NUP) if ! printf '%s\n' "$@" | grep -qx -- --shared-fonts; then   # Switch 2 : les six polices système vérifiées qu'une construction de TOTK a déjà extraites
    for f in "$CONS"/*/totk/extracted/firmware/shared-fonts; do [ -f "$f/manifest.json" ] && { ARGS+=(--shared-fonts "$f"); echo "polices système : $f"; break; }; done
  fi;; esac
  case "$BASE" in
    *.nup|*.NUP)   # un .nup Switch 2 contient déjà sa mise à jour : rien d'autre à passer (Ocarina refuse --update / --dlc / --mod)
      [ ${#UPD[@]} -gt 0 ] && echo "mise à jour : déjà dans le .nup, le fichier choisi en plus n'est pas utilisé"
      [ ${#DLC[@]} -gt 0 ] && echo "contenus additionnels : pas pour un .nup, ignorés"
      [ $(( ${#MODS[@]} + ${#EXEFS[@]} )) -gt 0 ] && echo "mods : pas pendant la construction d'un jeu Switch 2, ignorés";;
    *)
      for u in "${UPD[@]}"; do [ "$u" != "$BASE" ] && ARGS+=(--update "$u"); done
      for d in "${DLC[@]}"; do ARGS+=(--dlc "$d"); done
      for m in "${MODS[@]}" "${EXEFS[@]}"; do ARGS+=(--mod "$m"); done
      [ -n "$MODMOD" ] && ARGS+=(--mod-module "$MODMOD");;
  esac
  echo; echo "== MacNativeGames (20 à 40 min, ne pas interrompre)"
  ( cd "$MNG" && "${DISCRET[@]}" "$PY" build_app.py "${ARGS[@]}" ) || true
  # réussite : « done in » (TOTK, BotW…), ou « Built <app>; native gameplay validation… » et l'app présente (Ocarina, games/oot/build.py)
  { grep -q "done in" "$LOG" || { grep -q "^Built .*\.app; native gameplay validation" "$LOG" && [ -d "$TMPAPP" ]; }; } || { echo
    # la raison, en clair, quand on la connaît : Home l'affiche sur la tuile du chantier
    grep -q "do not include system shared fonts" "$LOG" && echo "Pourquoi : Il faut le dump de la cartouche du jeu. Ce fichier-ci n'a pas les polices système de la console, dont MacNativeGames a besoin."
    echo "ÉCHEC — dis-le à Claude (journal : $LOG)"; rm -rf "$TMPAPP"; fin 1; }
else
  PY="$MOT/.venv/bin/python3"; TOOLS=""
  [ -x "$PY" ] || { PY=""; for c in "/Applications/NX Library.app" "/Applications/NXLibrary.app"; do
    for p in "$c/Contents/Resources/Runtime/python/bin/python3" "$c/Contents/Resources/python/bin/python3"; do [ -z "$PY" ] && [ -x "$p" ] && PY="$p"; done
    for t in "$c/Contents/Resources/Runtime/tools/bin" "$c/Contents/Resources/tools/bin" "$c/Contents/Resources/Runtime/bin"; do [ -z "$TOOLS" ] && [ -d "$t" ] && TOOLS="$t"; done; done; }
  [ -z "$PY" ] && PY="$(command -v python3)"
  export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 PATH="${TOOLS:+$TOOLS:}$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.dotnet:$PATH"
  export TMPDIR="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp/)}" LANG="${LANG:-en_US.UTF-8}"
  [ -f "$MOT/engine/scripts/build_ipa_from_nsp.py" ] || { echo "Moteur nxnative introuvable : $MOT/engine"; fin 1; }
  ( cd "$MOT" && "$PY" tools/engine.py stale >/dev/null 2>&1 || "$PY" tools/engine.py sync >/dev/null 2>&1 )
  # nxnative lit un dossier : celui des sources (base + mises à jour + DLC), ou le dossier du jeu quand la base en est un ;
  # un .nup se donne tel quel (il contient déjà ses mises à jour)
  if [ -n "$WORK" ]; then
    ARGS=(--from-build "$WORK" --platform mac-app -o "$TMPAPP")
    if [ ! -f "$WORK/source.json" ]; then   # un dossier d'avant source.json : le title ID vient de l'app
      TID0="$(/usr/libexec/PlistBuddy -c 'Print :DMTitleID' "$SORTIE/Contents/Info.plist" 2>/dev/null)"
      [ -n "$TID0" ] && ARGS+=(--title-id "$TID0") || { echo "Title ID introuvable (ni source.json dans $WORK, ni DMTitleID dans $SORTIE)"; fin 1; }
    fi
  else
    mkdir -p "$ENTREE"; for f in "$BASE" "${UPD[@]}" "${DLC[@]}"; do ln -s "$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")" "$ENTREE/$(basename "$f")"; done
    NXIN="$ENTREE"; [ -d "$BASE" ] && NXIN="$BASE"
    case "$BASE" in *.nup) NXIN="$BASE"; [ ${#UPD[@]} -gt 0 ] && echo "note : un .nup contient déjà ses mises à jour ; les fichiers de mise à jour en plus sont ignorés";; esac
    ARGS=("$NXIN" ${KEYS:+-k "$KEYS"} --platform mac-app --work-dir "$CONS/$SLUG" -o "$TMPAPP")
    WORK="$CONS/$SLUG"; FROMNSP=1
  fi
  for x in "${EXEFS[@]}"; do ARGS+=(--exefs-mod "$x"); done
  # un jeu sans icône à lui (un dump n'a pas de données de contrôle) : celle que Home donne, d'après sa jaquette
  if [ -n "$ICONE" ] && [ -f "$ICONE" ] && [ -z "$FROMNSP" ] && [ -n "$WORK" ] && ! ls "$WORK"/extract/*/icon.jpg >/dev/null 2>&1; then ARGS+=(--icon "$ICONE"); echo "icône : jaquette de Home"; fi
  echo; echo "== nxnative (premier build d'un jeu : 30 à 60 min ; reconstruction : quelques minutes ; ne pas interrompre)"
  if [ -n "$HOME_TACHE" ]; then   # lancé par Home : l'avancement en JSON, pour sa barre de progression
    ( cd "$MOT/engine" && "${DISCRET[@]}" "$PY" scripts/build_ipa_from_nsp.py "${ARGS[@]}" --progress json 2>&1 )
  else
    ( cd "$MOT/engine" && "${DISCRET[@]}" "$PY" scripts/build_ipa_from_nsp.py "${ARGS[@]}" ) | grep --line-buffered -E "\[[0-9]+/[0-9]+\]|✓|done:|RED|Error|error:|Traceback|title|Title" | cut -c1-200
  fi
  grep -qE '\] done:|"msg": "done: ' "$LOG" || { echo; echo "ÉCHEC — dis-le à Claude (journal : $LOG)"; rm -rf "$TMPAPP"; fin 1; }
  # les versions qui ne servent plus (l'ancienne après une mise à jour) quittent le dossier de construction : seules restent
  # celles que l'app vient d'utiliser (source.json), dont ses fichiers sont des clones
  if [ -f "$WORK/source.json" ]; then
    for v in $(/usr/bin/python3 -c 'import json,sys,os; k=set(json.load(open(sys.argv[1])).get("versions") or []); d=sys.argv[2]
print(" ".join(n for n in os.listdir(d) if k and n not in k and n[:1]=="v" and n[1:].isdigit()))' "$WORK/source.json" "$WORK/extract" 2>/dev/null); do
      rm -rf "$WORK/extract/$v" && echo "ancienne version retirée du dossier de construction : $v"; done
  fi
  # le dossier de construction allégé (caches de shaders, fichiers intermédiaires) ; GARDER_CACHES=1 les garde
  [ -z "$GARDER_CACHES" ] && /bin/bash "$MOT/outils/alleger-build.sh" "$WORK"
fi
[ -d "$TMPAPP" ] || { echo "l'app construite est introuvable ($TMPAPP)"; fin 1; }

# Le nom final : celui demandé, sinon le nom du jeu (« : » devient « - », comme le Finder l'affiche)
if [ -z "$SORTIE" ]; then
  N="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$TMPAPP/Contents/Info.plist" 2>/dev/null)"; [ -z "$N" ] && N="$NOM"
  N="$(printf '%s' "$N" | sed -e 's#:# -#g' -e 's#/# - #g' -e 's/  */ /g')"; SORTIE="$GAMES/$N.app"
fi
# mode jeu de macOS désactivé (il bloque le GPU à sa fréquence la plus basse)
P="$TMPAPP/Contents/Info.plist"; if /usr/libexec/PlistBuddy -c "Print :LSSupportsGameMode" "$P" 2>/dev/null | grep -q true; then
  /usr/libexec/PlistBuddy -c "Set :LSSupportsGameMode false" "$P" && codesign --force --deep --preserve-metadata=entitlements -s - "$TMPAPP" 2>&1 | grep -v "replacing existing"; fi
[ -e "$SORTIE" ] && { rm -rf "$SORTIE" && echo "ancienne app supprimée : $SORTIE"; }
mv "$TMPAPP" "$SORTIE" || { echo "impossible de placer l'app dans $SORTIE"; fin 1; }

# Le registre : ce qui a servi, pour les mises à jour et reconstructions depuis le Salon
TIDF="$(/usr/libexec/PlistBuddy -c 'Print :DMTitleID' "$SORTIE/Contents/Info.plist" 2>/dev/null)"
[ -n "$TIDF" ] && [ -n "$WORK" ] && [ -d "$WORK" ] && printf '%s\n' "$TIDF" > "$WORK/.title-id"
[ "$MOTEUR" = mng ] && WORK="$CONS/$SLUG"
/usr/bin/python3 - "$SRC/registre.json" "$SORTIE" "$MOTEUR" "$BASE" "$MODMOD" "$WORK" "$TIDF" "${#UPD[@]}" "${UPD[@]}" "${DLC[@]}" <<'EOF'
import json, os, sys
reg, app, moteur, base, modmod, work, tid, nupd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], int(sys.argv[8])
rest = sys.argv[9:]; upd, dlc = rest[:nupd], rest[nupd:]
d = {}
try: d = json.load(open(reg))
except Exception: pass
old = d.get(app) or {}
if not base:   # une reconstruction sans NSP : les fichiers d'origine restent ceux de la dernière construction
    base, upd, dlc = old.get("base", ""), old.get("update", []), old.get("dlc", [])
d[app] = {"moteur": moteur, "base": base, "update": upd, "dlc": dlc, "modModule": modmod or None, "travail": work or None, "titre": tid or None,
          "local": (os.environ.get("DM_EXEFS_MODS_AUTO") == "0") or None}   # construit en local : le mod en ligne rangé sur ce Mac n'est pas appliqué
tmp = reg + ".tmp"; json.dump(d, open(tmp, "w"), indent=1, ensure_ascii=False); os.replace(tmp, reg)
EOF
osascript -e "display notification \"$(basename "$SORTIE") est prêt\" with title \"Construction terminée\"" 2>/dev/null
echo; echo "Terminé ($(date '+%H:%M')) : $SORTIE — il apparaît dans Home (Recharger si besoin)."
[ -n "$FROMNSP" ] && [ -f "$WORK/source.json" ] && echo "Le jeu est gardé dans $WORK : tes fichiers .nsp ne sont plus nécessaires pour le reconstruire."
fin 0
