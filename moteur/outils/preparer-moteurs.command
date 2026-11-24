#!/bin/bash
# Prépare ce Mac à construire les jeux Switch : vérifie les outils développeur d'Apple, installe avec Homebrew ce qui manque,
# puis récupère les deux moteurs — nxnative (le commit figé de moteur/.upstream-ref + les patchs de moteur/patches) et
# MacNativeGames (le commit figé de moteur/mng/.upstream-ref + les patchs de moteur/mng/patches).
# Lancé par Home au premier lancement et depuis Menu → Mises à jour → Moteurs → Préparer ce Mac. Sans risque à relancer :
# chaque étape ne fait que ce qui manque. Rien n'est demandé au clavier ; ce que le script ne peut pas faire seul (Xcode,
# Homebrew : ils demandent ton mot de passe) est expliqué à la fin, et il suffit de relancer après.
#   preparer-moteurs.command            tout préparer
# Le mode d'utilisation choisi dans Home décide de ce qui est préparé :
#   HOME_MOTEURS=tout (défaut) | mng (MacNativeGames seul) | nxnative (nxnative seul) | aucun (pas de jeux Nintendo)
#   HOME_AUSSI_PC=1 : à la fin, aussi le moteur Windows des jeux PC (pc.command preparer : Voile et Legendary)
#   preparer-moteurs.command --etat     seulement dire ce qui est prêt (une ligne « cle=ok|manque|… » par outil), sans rien installer
# Journal : <Home>/log/preparer-moteurs.log
HR="${HOME_RACINE:-$HOME/Library/Application Support/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/local/share/dotnet:$HOME/.dotnet:$PATH"   # Home lance sans le PATH du Terminal
MOT="$HR/moteur"; MNG="$HR/MacNativeGames"; LOGD="$HR/log"; mkdir -p "$LOGD" "$HR/constructions" "$JX"
ETAT=""; [ "$1" = "--etat" ] && ETAT=1
NX=1; MG=1; case "${HOME_MOTEURS:-tout}" in mng) NX="";; nxnative) MG="";; aucun) NX=""; MG="";; esac   # ce que le mode d'utilisation demande
[ -z "$ETAT" ] && exec > >(tee "$LOGD/preparer-moteurs.log") 2>&1
A_FAIRE=()   # ce qui reste à faire à la main
etape() { [ -z "$ETAT" ] && { echo; echo "== $1"; [ -n "$HOME_TACHE" ] && printf '{"ev": "stage", "k": %s, "n": 6, "name": "%s"}\n' "$2" "$1"; }; }
dit() { if [ -n "$ETAT" ]; then echo "$1=$2"; else echo "$3"; fi; }

# --- 1. Outils développeur d'Apple. nxnative compile les shaders avec Xcode entier (pas seulement les outils en ligne de commande).
etape "Outils Apple" 1
XCODE=manque
if xcode-select -p >/dev/null 2>&1; then
  XCODE=outils; /usr/bin/xcodebuild -version >/dev/null 2>&1 && XCODE=ok
fi
case $XCODE in
  ok) dit xcode ok "Xcode : $(/usr/bin/xcodebuild -version 2>/dev/null | head -1)";;
  outils) dit xcode "$([ -n "$NX" ] && echo outils || echo ok)" "Outils en ligne de commande présents, mais pas Xcode : les jeux MacNativeGames se construisent, pas ceux de nxnative."
     [ -n "$NX" ] && A_FAIRE+=("Installe Xcode (App Store, gratuit), ouvre-le une fois, puis relance « Préparer ce Mac » : nxnative en a besoin pour les shaders.");;
  manque) dit xcode manque "Les outils développeur d'Apple manquent."
     [ -z "$ETAT" ] && { xcode-select --install >/dev/null 2>&1; echo "Une fenêtre d'installation d'Apple vient de s'ouvrir : accepte, attends la fin, puis relance « Préparer ce Mac »."; }
     A_FAIRE+=("Termine l'installation des outils développeur d'Apple (la fenêtre ouverte), puis relance.");;
esac
if [ -z "$NX" ]; then [ -n "$ETAT" ] && echo "metal=ignore"
elif [ $XCODE = ok ]; then   # le compilateur Metal : un composant de Xcode à télécharger à part
  if xcrun -f metal >/dev/null 2>&1; then dit metal ok "Compilateur Metal : présent"
  elif [ -n "$ETAT" ]; then echo "metal=manque"
  else echo "Compilateur Metal : téléchargement (composant de Xcode)…"; /usr/bin/xcodebuild -downloadComponent MetalToolchain 2>&1 | tail -2
    xcrun -f metal >/dev/null 2>&1 || A_FAIRE+=("Le compilateur Metal n'a pas pu être téléchargé : dans le Terminal, tape  xcodebuild -downloadComponent MetalToolchain"); fi
else [ -n "$ETAT" ] && echo "metal=manque"; fi

# --- 2. Homebrew et ses outils. Homebrew s'installe avec ton mot de passe : le script ne le fait pas à ta place.
etape "Outils Homebrew" 2
BREW=""; for b in /opt/homebrew/bin/brew "$HOME/.homebrew/bin/brew"; do [ -x "$b" ] && { BREW="$b"; break; }; done
NX_OUTILS="xcodegen zstd glslang"; MNG_OUTILS="opus libvpx python@3.14 llvm@23"
if [ -z "$BREW" ]; then
  dit brew manque "Homebrew manque."
  A_FAIRE+=("Installe Homebrew : ouvre https://brew.sh, copie la commande d'installation dans le Terminal, puis relance « Préparer ce Mac ».")
else
  dit brew ok "Homebrew : $BREW"
  [ -z "$NX" ] && NX_OUTILS=""; [ -z "$MG" ] && MNG_OUTILS=""
  manque=""; for f in $NX_OUTILS $MNG_OUTILS; do [ -d "$("$BREW" --prefix 2>/dev/null)/opt/$f" ] || manque="$manque $f"; done
  if [ -z "$manque" ]; then dit formules ok "Outils Homebrew : tous présents"
  elif [ -n "$ETAT" ]; then echo "formules=manque:$manque"
  else echo "Installation de :$manque (quelques minutes)"; HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" install $manque 2>&1 | grep -E "^==> (Pouring|Installing)|Error|Warning: No available" | cut -c1-160
    for f in $manque; do [ -d "$("$BREW" --prefix)/opt/$f" ] || A_FAIRE+=("Homebrew n'a pas installé $f : dans le Terminal, tape  brew install $f"); done; fi
fi
# .NET 10 : nxnative lit les fichiers du jeu avec (l'installeur officiel demande un mot de passe)
if [ -z "$NX" ]; then [ -n "$ETAT" ] && echo "dotnet=ignore"
elif command -v dotnet >/dev/null 2>&1; then dit dotnet ok ".NET : $(dotnet --version 2>/dev/null | head -1)"
else dit dotnet manque ".NET manque."
  A_FAIRE+=("Installe le SDK .NET 10 (nxnative lit les jeux avec) : dans le Terminal, tape  brew install --cask dotnet-sdk  puis relance."); fi

# --- 3. Python de nxnative : un environnement à lui (moteur/.venv) avec les modules que sa documentation demande
etape "Python" 3
PYB=""; for p in /opt/homebrew/bin/python3.14 "$HOME/.homebrew/bin/python3.14" /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12; do [ -x "$p" ] && { PYB="$p"; break; }; done
VPY="$MOT/.venv/bin/python3"; MODULES='import lz4, capstone, fontTools, nsz, zbic'
if [ -z "$NX" ]; then [ -n "$ETAT" ] && echo "python=ignore"
elif [ -x "$VPY" ] && "$VPY" -c "$MODULES" >/dev/null 2>&1; then dit python ok "Python de nxnative : prêt"
elif [ ! -x "$VPY" ] && command -v python3 >/dev/null 2>&1 && python3 -c "$MODULES" >/dev/null 2>&1; then dit python ok "Python : celui de ce Mac a déjà les modules de nxnative ($(command -v python3))"
elif [ -n "$ETAT" ]; then echo "python=manque"
elif [ -z "$PYB" ]; then echo "Python 3.12 ou plus récent manque (il vient avec Homebrew)."; A_FAIRE+=("Python : il s'installe avec les outils Homebrew ci-dessus, relance ensuite.")
else echo "Environnement Python de nxnative ($("$PYB" -V 2>&1))…"
  { [ -x "$VPY" ] || "$PYB" -m venv "$MOT/.venv"; } && "$VPY" -m pip install --quiet --disable-pip-version-check lz4 "capstone>=5,<6" fonttools nsz zbic 2>&1 | tail -3
  "$VPY" -c "$MODULES" >/dev/null 2>&1 && echo "Python de nxnative : prêt" || A_FAIRE+=("Les modules Python de nxnative ne se sont pas installés (voir $LOGD/preparer-moteurs.log) — dis-le à Claude.")
fi

# --- 4. nxnative : le commit figé + les patchs (tools/engine.py sync ; ne fait rien si le moteur est déjà à ce commit)
etape "nxnative" 4
if [ -z "$NX" ]; then [ -n "$ETAT" ] && echo "nxnative=ignore" || echo "nxnative : pas demandé par le mode d'utilisation"
elif [ -n "$ETAT" ]; then
  if [ -f "$MOT/engine/scripts/build_ipa_from_nsp.py" ]; then echo "nxnative=ok"; else echo "nxnative=manque"; fi
elif [ ! -f "$MOT/.upstream-ref" ]; then echo "La version figée de nxnative manque dans $MOT (relance Home : il la réinstalle)"; A_FAIRE+=("Relance Home, puis « Préparer ce Mac ».")
elif ! command -v git >/dev/null 2>&1 || [ $XCODE = manque ]; then echo "git manque (il vient avec les outils d'Apple)"
else
  PYE="$VPY"; [ -x "$PYE" ] || PYE="${PYB:-/usr/bin/python3}"
  if ( cd "$MOT" && "$PYE" tools/engine.py stale >/dev/null 2>&1 ); then echo "nxnative : déjà prêt ($(cut -c1-12 "$MOT/.upstream-ref"))"
  else echo "nxnative : téléchargement du commit $(cut -c1-12 "$MOT/.upstream-ref") et application des patchs…"
    ( cd "$MOT" && "$PYE" tools/engine.py sync 2>&1 | tail -5 )
    ( cd "$MOT" && "$PYE" tools/engine.py stale >/dev/null 2>&1 ) && echo "nxnative : prêt" || A_FAIRE+=("nxnative n'a pas pu être préparé (voir $LOGD/preparer-moteurs.log) — dis-le à Claude.")
  fi
fi

# --- 5. MacNativeGames (Tears of the Kingdom, Breath of the Wild, Ocarina of Time) : le dépôt officiel au commit figé, puis
# les patchs de Home par-dessus. Un dépôt déjà là n'est pas touché : « Mettre à jour MacNativeGames » s'en occupe.
etape "MacNativeGames" 5
if [ -z "$MG" ]; then [ -n "$ETAT" ] && echo "mng=ignore" || echo "MacNativeGames : pas demandé par le mode d'utilisation"
elif [ -f "$MNG/build_app.py" ]; then dit mng ok "MacNativeGames : déjà là ($(git -C "$MNG" log -1 --format=%h 2>/dev/null))"
elif [ -n "$ETAT" ]; then echo "mng=manque"
elif ! command -v git >/dev/null 2>&1 || [ $XCODE = manque ]; then echo "git manque (il vient avec les outils d'Apple)"
else
  PIN="$(cat "$MOT/mng/.upstream-ref" 2>/dev/null)"; TMP="$HR/.MacNativeGames-$$"
  echo "MacNativeGames : téléchargement…"
  if git clone --quiet https://github.com/ly05010419/MacNativeGames.git "$TMP" 2>&1 | tail -2 && [ -f "$TMP/build_app.py" ]; then
    if [ -n "$PIN" ] && ls "$MOT"/mng/patches/*.patch >/dev/null 2>&1; then
      if git -C "$TMP" checkout --quiet -B main "$PIN" 2>/dev/null && git -C "$TMP" -c user.name=Home -c user.email=home@localhost -c commit.gpgsign=false am --quiet -3 "$MOT"/mng/patches/*.patch 2>&1 | tail -3; then
        echo "MacNativeGames : $(ls "$MOT"/mng/patches/*.patch | wc -l | tr -d ' ') patchs de Home appliqués"
      else git -C "$TMP" am --abort >/dev/null 2>&1; git -C "$TMP" checkout --quiet -B main origin/HEAD 2>/dev/null
        echo "MacNativeGames : les patchs de Home ne s'appliquent pas, version officielle gardée (dis-le à Claude)"; fi
    fi
    mv "$TMP" "$MNG" && echo "MacNativeGames : prêt"
  else rm -rf "$TMP"; A_FAIRE+=("MacNativeGames n'a pas pu être téléchargé (connexion ?) : relance « Préparer ce Mac »."); fi
fi

etape "Bilan" 6
[ -n "$ETAT" ] && exit 0
if [ -n "$HOME_AUSSI_PC" ]; then   # le mode d'utilisation comprend les jeux PC : le moteur Windows dans la foulée
  echo; echo "== Jeux PC"; /bin/bash "$MOT/outils/pc.command" preparer 2>&1 | grep -v '"ev"' | sed 's/^done in : .*$/Jeux PC : prêts/' ; [ "${PIPESTATUS[0]}" -eq 0 ] || A_FAIRE+=("Le moteur Windows des jeux PC ne s'est pas installé : case + → Jeu PC pour réessayer.")
fi
if [ ${#A_FAIRE[@]} -eq 0 ]; then echo "Tout est prêt : ajoute un jeu Switch depuis Home (case +)."; echo "done in : ce Mac est prêt"; exit 0; fi
echo "Il reste ${#A_FAIRE[@]} chose(s) à faire à la main :"; i=1; for a in "${A_FAIRE[@]}"; do echo "  $i. $a"; i=$((i+1)); done
echo "ÉCHEC : ${A_FAIRE[0]}"; exit 1
