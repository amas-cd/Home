#!/bin/bash
# Prépare Steam dans Home, sans Obelisk : compile home-steam (moteur/steam), un petit outil au-dessus du code Steam d'Obelisk
# (https://github.com/Zagrios/Obelisk, GPL-3.0), récupéré au commit figé de moteur/steam/OBELISK-REF dans moteur/obelisk-src.
# Il faut Rust (installé ici avec Homebrew s'il manque) et les outils d'Apple. Le programme va dans <Home>/moteur/bin/home-steam.
# Sans risque à relancer : rien n'est refait si l'outil est déjà à jour. Journal : <Home>/log/preparer-steam.log
HR="${HOME_RACINE:-/Applications/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"   # Home lance sans le PATH du Terminal
MOT="$HR/moteur"; S="$MOT/steam"; SRC="$MOT/obelisk-src"; LOGD="$HR/log"; mkdir -p "$LOGD" "$MOT/bin"
exec > >(tee "$LOGD/preparer-steam.log") 2>&1
etape() { echo; echo "== $1"; [ -n "$HOME_TACHE" ] && printf '{"ev": "stage", "k": %s, "n": 3, "name": "%s"}\n' "$2" "$1"; }
[ -f "$S/Cargo.toml" ] || { echo "ÉCHEC : la source de home-steam manque dans $S (relance Home : il la réinstalle)"; exit 1; }
REF="$(cat "$S/OBELISK-REF")"; EMP="$(cat "$S/Cargo.toml" "$S/OBELISK-REF" "$S"/src/*.rs | shasum -a 256 | cut -c1-64)"
if [ -x "$MOT/bin/home-steam" ] && [ "$EMP" = "$(cat "$MOT/bin/.home-steam.sha" 2>/dev/null)" ]; then echo "Steam : l'outil est déjà prêt"; echo "done in : Steam prêt"; exit 0; fi

etape "Rust" 1
xcode-select -p >/dev/null 2>&1 || { echo "ÉCHEC : les outils développeur d'Apple manquent (Menu → Mises à jour → Moteurs → Préparer ce Mac)"; exit 1; }
if ! command -v cargo >/dev/null 2>&1; then
  BREW=""; for b in /opt/homebrew/bin/brew "$HOME/.homebrew/bin/brew"; do [ -x "$b" ] && { BREW="$b"; break; }; done
  [ -n "$BREW" ] || { echo "ÉCHEC : Homebrew manque (https://brew.sh), il sert à installer Rust"; exit 1; }
  echo "Installation de Rust (quelques minutes)…"; HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" install rust 2>&1 | tail -2
  command -v cargo >/dev/null 2>&1 || { echo "ÉCHEC : Rust ne s'est pas installé — dans le Terminal : brew install rust"; exit 1; }
fi
echo "Rust : $(cargo --version)"

etape "Code Steam d'Obelisk" 2
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$REF" ]; then
  [ -L "$SRC" ] && { echo "ÉCHEC : $SRC est un lien vers une autre version d'Obelisk"; exit 1; }
  if [ ! -d "$SRC/.git" ]; then git init --quiet "$SRC" && git -C "$SRC" remote add origin https://github.com/Zagrios/Obelisk.git || { echo "ÉCHEC : impossible de créer $SRC"; exit 1; }; fi
  echo "Téléchargement d'Obelisk au commit $(printf %s "$REF" | cut -c1-12)…"
  git -C "$SRC" fetch --quiet --depth 1 origin "$REF" && git -C "$SRC" checkout --quiet FETCH_HEAD || { echo "ÉCHEC : téléchargement de la source d'Obelisk (connexion ?)"; exit 1; }
fi
echo "Obelisk : $(git -C "$SRC" rev-parse --short HEAD)"

etape "Compilation de home-steam" 3
[ -f "$S/Cargo.lock" ] || cp "$SRC/Cargo.lock" "$S/Cargo.lock"   # les mêmes versions de bibliothèques qu'Obelisk
( cd "$S" && cargo build --release 2>&1 | grep -E "^error|^warning: unused|Finished|Compiling home-steam" | cut -c1-200 )
[ -x "$S/target/release/home-steam" ] || { echo "ÉCHEC : home-steam n'a pas compilé (journal : $LOGD/preparer-steam.log) — dis-le à Claude"; exit 1; }
cp "$S/target/release/home-steam" "$MOT/bin/home-steam" && printf '%s\n' "$EMP" > "$MOT/bin/.home-steam.sha"
echo "done in : Steam prêt"
