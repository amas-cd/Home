#!/bin/bash
# Prépare Steam dans Home, sans Obelisk, à partir de la source d'Obelisk (https://github.com/Zagrios/Obelisk, GPL-3.0) récupérée
# au commit figé de moteur/steam/OBELISK-REF dans moteur/obelisk-src :
#   - home-steam (moteur/steam) : l'outil de Home, qui pilote le circuit Steam d'Obelisk (connexion, bibliothèque, téléchargement, lancement) ;
#   - l'hôte Steam d'Obelisk (crates/steam-native) : obelisk-steam-host, qui fait tourner la bibliothèque Steam de Valve à côté du jeu,
#     son adaptateur (arm64 + Intel) et son assistant Intel. Ils vont dans <Home>/moteur/bin/SteamNative, signés sur place.
# Il faut les outils d'Apple, Homebrew et Rust avec la cible Intel : rustup est installé par Homebrew s'il manque, et sa chaîne
# d'outils va dans <Home>/moteur/.rustup (rien dans ton dossier personnel). Les composants de Valve et le moteur Voile, eux, sont
# téléchargés par l'outil au premier jeu installé.
# Sans risque à relancer : rien n'est refait si tout est déjà à jour. Journal : <Home>/log/preparer-steam.log
HR="${HOME_RACINE:-$HOME/Library/Application Support/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
export PATH="$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"   # Home lance sans le PATH du Terminal
MOT="$HR/moteur"; S="$MOT/steam"; SRC="$MOT/obelisk-src"; LOGD="$HR/log"; mkdir -p "$LOGD" "$MOT/bin"
exec > >(tee "$LOGD/preparer-steam.log") 2>&1
etape() { echo; echo "== $1"; [ -n "$HOME_TACHE" ] && printf '{"ev": "stage", "k": %s, "n": 3, "name": "%s"}\n' "$2" "$1"; }
[ -f "$S/Cargo.toml" ] || { echo "ÉCHEC : la source de home-steam manque dans $S (relance Home : il la réinstalle)"; exit 1; }
REF="$(cat "$S/OBELISK-REF")"; EMP="$(cat "$S/Cargo.toml" "$S/OBELISK-REF" "$S"/src/*.rs | shasum -a 256 | cut -c1-64)"
if [ -x "$MOT/bin/home-steam" ] && [ -x "$MOT/bin/SteamNative/obelisk-steam-host" ] && [ "$EMP" = "$(cat "$MOT/bin/.home-steam.sha" 2>/dev/null)" ]; then echo "Steam : l'outil est déjà prêt"; echo "done in : Steam prêt"; exit 0; fi

etape "Rust" 1
xcode-select -p >/dev/null 2>&1 || { echo "ÉCHEC : les outils développeur d'Apple manquent (Menu → Mises à jour → Moteurs → Préparer ce Mac)"; exit 1; }
BREW=""; for b in /opt/homebrew/bin/brew "$HOME/.homebrew/bin/brew"; do [ -x "$b" ] && { BREW="$b"; break; }; done
[ -n "$BREW" ] || { echo "ÉCHEC : Homebrew manque (https://brew.sh), il sert à installer Rust"; exit 1; }
RU="$("$BREW" --prefix)/opt/rustup/bin"
if [ ! -x "$RU/rustup" ]; then echo "Installation de rustup…"; HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" install rustup 2>&1 | tail -1; fi
[ -x "$RU/rustup" ] || { echo "ÉCHEC : rustup ne s'est pas installé — dans le Terminal : brew install rustup"; exit 1; }
export RUSTUP_HOME="$MOT/.rustup" PATH="$RU:$PATH"
if ! rustup run stable rustc --print target-libdir --target x86_64-apple-darwin 2>/dev/null | xargs -I{} test -d {}; then
  echo "Installation de Rust (avec la cible Intel, quelques minutes)…"
  rustup toolchain install stable --profile minimal --target x86_64-apple-darwin --no-self-update 2>&1 | tail -1
fi
cargo --version >/dev/null 2>&1 || { echo "ÉCHEC : Rust ne s'est pas installé (voir $LOGD/preparer-steam.log)"; exit 1; }
echo "Rust : $(cargo --version)"

etape "Code Steam d'Obelisk" 2
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$REF" ]; then
  [ -L "$SRC" ] && { echo "ÉCHEC : $SRC est un lien vers une autre version d'Obelisk"; exit 1; }
  if [ ! -d "$SRC/.git" ]; then git init --quiet "$SRC" && git -C "$SRC" remote add origin https://github.com/Zagrios/Obelisk.git || { echo "ÉCHEC : impossible de créer $SRC"; exit 1; }; fi
  echo "Téléchargement d'Obelisk au commit $(printf %s "$REF" | cut -c1-12)…"
  git -C "$SRC" fetch --quiet --depth 1 origin "$REF" && git -C "$SRC" checkout --quiet FETCH_HEAD || { echo "ÉCHEC : téléchargement de la source d'Obelisk (connexion ?)"; exit 1; }
fi
echo "Obelisk : $(git -C "$SRC" rev-parse --short HEAD)"

etape "Compilation (5 à 10 minutes la première fois)" 3
[ -f "$S/Cargo.lock" ] || cp "$SRC/Cargo.lock" "$S/Cargo.lock"   # les mêmes versions de bibliothèques qu'Obelisk
filtre() { grep -E "^error|Finished|Compiling (home-steam|obelisk-steam)" | cut -c1-200; }
( cd "$S" && cargo build --release 2>&1 | filtre )
[ -x "$S/target/release/home-steam" ] || { echo "ÉCHEC : home-steam n'a pas compilé (journal : $LOGD/preparer-steam.log) — dis-le à Claude"; exit 1; }
# l'hôte Steam d'Obelisk : l'hôte en arm64 (il ne doit pas tourner sous Rosetta), l'adaptateur dans les deux architectures
# (il est inséré dans le jeu, qui tourne en Intel sur le moteur Rosetta), l'assistant D3DMetal en Intel
export CARGO_TARGET_DIR="$S/target/steam-native"; N="$SRC/crates/steam-native/Cargo.toml"
cargo build --locked --manifest-path "$N" --workspace --bin obelisk-steam-host --lib --release --target aarch64-apple-darwin 2>&1 | filtre
cargo build --locked --manifest-path "$N" -p obelisk-steam-native --bin obelisk-steam-sdk --release --target x86_64-apple-darwin 2>&1 | filtre
cargo build --locked --manifest-path "$N" -p obelisk-steam-discovery-adapter --lib --release --target x86_64-apple-darwin 2>&1 | filtre
A="$CARGO_TARGET_DIR/aarch64-apple-darwin/release"; I="$CARGO_TARGET_DIR/x86_64-apple-darwin/release"; AD=libobelisk_steam_discovery_adapter.dylib
[ -x "$A/obelisk-steam-host" ] && [ -f "$A/$AD" ] && [ -f "$I/$AD" ] && [ -x "$I/obelisk-steam-sdk" ] || { echo "ÉCHEC : l'hôte Steam n'a pas compilé (journal : $LOGD/preparer-steam.log) — dis-le à Claude"; exit 1; }
D="$MOT/bin/SteamNative"; T="$MOT/bin/.SteamNative-$$"; rm -rf "$T"; mkdir -p "$T"
cp "$A/obelisk-steam-host" "$T/obelisk-steam-host" && cp "$I/obelisk-steam-sdk" "$T/obelisk-steam-sdk-x86_64" && /usr/bin/lipo -create "$A/$AD" "$I/$AD" -output "$T/$AD" || { echo "ÉCHEC : assemblage de l'hôte Steam"; exit 1; }
# signature sur place (ad hoc), avec les droits qu'Obelisk donne à son hôte : charger la bibliothèque de Valve, garder DYLD_*
E="$SRC/packaging/steam-host.entitlements"
/usr/bin/codesign --force --sign - --options runtime --identifier fr.anas.home.steam-host --entitlements "$E" "$T/obelisk-steam-host" 2>/dev/null
/usr/bin/codesign --force --sign - --identifier fr.anas.home.steam-discovery "$T/$AD" 2>/dev/null
/usr/bin/codesign --force --sign - --options runtime --identifier fr.anas.home.steam-sdk-x86_64 --entitlements "$E" "$T/obelisk-steam-sdk-x86_64" 2>/dev/null
rm -rf "$D" && mv "$T" "$D" || { echo "ÉCHEC : installation de l'hôte Steam dans $D"; exit 1; }
cp "$S/target/release/home-steam" "$MOT/bin/home-steam" && printf '%s\n' "$EMP" > "$MOT/bin/.home-steam.sha"
echo "done in : Steam prêt"
