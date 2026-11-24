#!/bin/bash
# Construit « Home » (ex-Salon), le launcher façon console, avec les outils développeur d'Apple (swiftc), et l'installe dans /Applications/Home.app.
# Son identifiant (fr.anas.salon), son certificat « Salon Dev » et ses réglages (Application Support/Salon) ne changent pas : autorisations et réglages gardés.
# Aucune dépendance : une source Swift (main.swift à côté de ce script) → une app signée localement. À relancer après toute modification de main.swift.
D="$(cd "$(dirname "$0")" && pwd)"; OUT="/Applications/Home.app"; OLD="/Applications/Jeux/Salon.app"; B="$D/.build"; rm -rf "$B"; mkdir -p "$B/Salon.app/Contents/MacOS" "$B/Salon.app/Contents/Resources"
xcode-select -p >/dev/null 2>&1 || { echo "Outils développeur Apple manquants : xcode-select --install"; read -r -p "Entrée pour fermer." _; exit 1; }
echo "== compilation ($(date '+%H:%M'))"
if ! xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 -framework SwiftUI -framework AppKit -framework AVKit -framework GameController -framework ApplicationServices -framework Carbon -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework CoreAudio -framework AudioToolbox "$D/main.swift" -o "$B/Salon.app/Contents/MacOS/Salon" 2>&1 | tee "$D/compilation.log"; then :; fi
# l'ouverture de Home à la connexion d'une manette (une petite app « Home » invisible) (lancé à l'ouverture de session)
V="$B/Salon.app/Contents/Library/LoginItems/Home.app/Contents"; mkdir -p "$V/MacOS"
xcrun swiftc -O -target arm64-apple-macos14.0 -framework AppKit -framework IOKit "$D/veille.swift" -o "$V/MacOS/Home" 2>&1 | tee -a "$D/compilation.log"
cat > "$V/Info.plist" <<'PLV'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Home</string><key>CFBundleDisplayName</key><string>Home</string><key>CFBundleIdentifier</key><string>fr.anas.home.veille</string><key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>Home</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string><key>LSBackgroundOnly</key><true/><key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLV
[ -x "$B/Salon.app/Contents/MacOS/Salon" ] || { echo; echo "ÉCHEC de compilation : dis « c'est fait » à Claude, il lira $D/compilation.log"; read -r -p "Entrée pour fermer." _; exit 1; }
cat > "$B/Salon.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Home</string><key>CFBundleDisplayName</key><string>Home</string>
<key>CFBundleIdentifier</key><string>fr.anas.salon</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleExecutable</key><string>Salon</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/><key>NSAudioCaptureUsageDescription</key><string>Home règle le volume de tes jeux sans toucher à celui du Mac : pour ça il fait passer leur son par lui.</string>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string><key>LSSupportsGameMode</key><false/>
<key>NSSupportsAutomaticTermination</key><false/><key>NSSupportsSuddenTermination</key><false/>
</dict></plist>
PLIST
# Version affichée par Home et comparée aux releases GitHub (GitHub Actions la donne : le tag sans le « v », ex. 0.1.0)
[ -n "$HOME_VERSION" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $HOME_VERSION" "$B/Salon.app/Contents/Info.plist"
# icône : trois cartes en éventail et une manette, dessinées en code par icone.swift (pas d'image externe)
swift "$D/icone.swift" "$B/AppIcon.png" 2>/dev/null || true
if [ -f "$B/AppIcon.png" ]; then mkdir -p "$B/AppIcon.iconset"; for sz in 16 32 128 256 512; do sips -z $sz $sz "$B/AppIcon.png" --out "$B/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null; sips -z $((sz*2)) $((sz*2)) "$B/AppIcon.png" --out "$B/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null; done
  iconutil -c icns "$B/AppIcon.iconset" -o "$B/Salon.app/Contents/Resources/AppIcon.icns" 2>/dev/null; fi
[ -f "$B/Salon.app/Contents/Resources/AppIcon.icns" ] && [ -d "$V" ] && { mkdir -p "$V/Resources"; cp "$B/Salon.app/Contents/Resources/AppIcon.icns" "$V/Resources/"; }
# Sons : les six sons originaux de Home à la racine, et la banque CC0 de Kenney (« Interface Sounds ») comme rechange
# l'empreinte de la source : « Mettre à jour Home » ne recompile que si elle a changé
cat "$D/main.swift" "$D/veille.swift" "$0" "$D/icone.swift" 2>/dev/null | shasum -a 256 | cut -c1-64 > "$B/Salon.app/Contents/Resources/source.sha"
if [ -d "$D/sons" ]; then mkdir -p "$B/Salon.app/Contents/Resources/sons"; cp -R "$D/sons/." "$B/Salon.app/Contents/Resources/sons/"; fi
# Logos des services (Epic Games, Steam) montrés dans l'écran Comptes
if [ -d "$D/logos" ]; then mkdir -p "$B/Salon.app/Contents/Resources/logos"; cp "$D"/logos/*.png "$B/Salon.app/Contents/Resources/logos/"; fi
# Le moteur embarqué : les scripts, les outils, la version figée des moteurs et la source de Home. L'app les installe dans
# <Home>/moteur à son premier lancement et après une mise à jour (moteur/outils/installer-embarque.sh) : c'est ce qui la rend autonome.
# Depuis le dépôt, le moteur est à côté (../moteur) ; depuis l'installation (<Home>/moteur/salon), c'est le dossier parent.
MO="$D/../moteur"; [ -d "$MO/outils" ] || MO="$D/.."
if [ -d "$MO/outils" ]; then E="$B/Salon.app/Contents/Resources/moteur"; mkdir -p "$E/salon"
  for d in outils tools patches obelisk pc compat mng steam; do [ -d "$MO/$d" ] && rsync -a --exclude .DS_Store --exclude __pycache__ --exclude tests --exclude target --exclude notes --exclude 'recette-*.json' --exclude legendary-path.txt "$MO/$d" "$E/"; done
  cp "$MO/.upstream-ref" "$MO/README.md" "$E/" 2>/dev/null
  rsync -a --exclude .DS_Store --exclude .build --exclude '*.log' --exclude 'main.swift.avant-*' --exclude 'cle-*' "$D/" "$E/salon/"
  ( cd "$E" && find . -type f ! -name .empreinte -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-64 ) > "$E/.empreinte"
fi
# Signature : si tu as créé un certificat « Salon Dev » (Trousseaux d'accès → Assistant de certification → Créer un certificat, type « Signature de code »),
# l'app est signée avec et macOS garde ses autorisations (Accessibilité, Enregistrement d'écran, données d'autres apps) d'une version à l'autre.
# Sinon, signature ad hoc : l'identité change à chaque compilation et macOS redemande les autorisations.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Salon Dev"'; then
  codesign --force --deep -s "Salon Dev" "$B/Salon.app" 2>&1 | grep -v "replacing existing"; echo "signé avec « Salon Dev » : autorisations conservées"
else
  codesign --force --deep -s - "$B/Salon.app" >/dev/null 2>&1; echo "signature ad hoc (crée un certificat « Salon Dev » dans Trousseaux d'accès pour ne plus voir les demandes d'autorisation à chaque build)"
fi
# Construction seule (GitHub Actions, ou HOME_BUILD_ONLY=<dossier>) : l'app signée est posée dans ce dossier, rien n'est installé ni quitté
if [ -n "$HOME_BUILD_ONLY" ]; then
  mkdir -p "$HOME_BUILD_ONLY" && rm -rf "$HOME_BUILD_ONLY/Home.app" && cp -R "$B/Salon.app" "$HOME_BUILD_ONLY/Home.app" && rm -rf "$B" || exit 1
  echo "Home.app construit : $HOME_BUILD_ONLY/Home.app"; exit 0
fi
# quitter l'ancienne version par son identifiant (« Home » seul désignerait aussi l'app Maison d'Apple)
osascript -e 'tell application id "fr.anas.salon" to quit' >/dev/null 2>&1; sleep 1
LA="$HOME/Library/LaunchAgents/fr.anas.home.veille.plist"; launchctl bootout "gui/$(id -u)" "$LA" >/dev/null 2>&1
rm -rf "$OUT" && cp -R "$B/Salon.app" "$OUT" && rm -rf "$B"
VEILLE="$OUT/Contents/Library/LoginItems/Home.app/Contents/MacOS/Home"
if [ -x "$VEILLE" ]; then   # Home s'ouvre à la connexion d'une manette (Menu → Avancé pour le désactiver)
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$LA" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>fr.anas.home.veille</string>
<key>ProgramArguments</key><array><string>$VEILLE</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string>
</dict></plist>
PL
  launchctl bootstrap "gui/$(id -u)" "$LA" 2>/dev/null && echo "Home s'ouvrira à la connexion d'une manette"
fi
for o in "$OLD" /Applications/Jeux/Home.app; do [ -d "$o" ] && rm -rf "$o" && echo "ancienne app retirée : $o"; done
# dossiers du launcher + liste de jeux de départ (Roblox, Obelisk s'ils sont installés)
S="$HOME/Library/Application Support/Salon"; mkdir -p "$S/media" "$S/jeux" "$S/sons"
if [ ! -f "$S/jeux.json" ]; then
  L=""; for a in "/Applications/Roblox.app:Roblox"; do p="${a%%:*}"; n="${a#*:}"; [ -d "$p" ] && L="$L${L:+,}
  {\"chemin\": \"$p\", \"nom\": \"$n\"}"; done
  printf '{\n  "jeux": [%s\n  ]\n}\n' "$L" > "$S/jeux.json"
fi
cat > "$S/LISEZMOI.txt" <<'TXT'
Home — launcher façon console (ex-Salon)
• Jeux affichés : toutes les apps de /Applications/Jeux + celles de jeux.json + les apps ou alias déposés dans le dossier « jeux ».
• jeux.json : {"jeux": [{"chemin": "/Applications/Roblox.app", "nom": "Roblox"}]} — ajoute une ligne par jeu.
• Médias : media/<nom du jeu tel qu'affiché>/cover.jpg (jaquette), fond.jpg (fond), fond.mp4 (fond animé, en boucle, muet).
• Catégories : onglet « Tous » + Switch / Switch 2 / Mac / PC (automatiques) + les tiennes : touche + (ou bouton ⊕ en haut, ou Options → Nouvelle catégorie…).
• Illustrations : reprises de NX Library (cache et choix manuels), sinon en ligne (nlib.cc par title id, SteamGridDB par nom avec ta clé), sinon icône de l'app.
• Sons : six sons originaux créés pour Home ; banque de rechange Kenney « Interface Sounds » (CC0). Pour en changer : copie un son de Home.app/Contents/Resources/sons/banque dans le dossier « sons » sous le nom deplacer/onglet/ouvrir/retour/valider/lancer .wav. X → Sons pour couper.\n• Journal : /Applications/Home/log/salon.log (jaquettes, SteamGridDB, lancements).
• Rocket League (Obelisk) : au premier lancement, autorise Salon dans Réglages Système → Confidentialité et sécurité → Accessibilité (à refaire après chaque recompilation, l'app étant signée localement).
• Commandes : flèches ou stick/croix = choisir, L1/R1 ou Tab = catégorie, Entrée ou A = jouer, Y ou O = options, Échap ou ⌘Q = quitter, ⌘R = recharger, ⌘F = plein écran.
TXT
echo; echo "Home installé : $OUT — médias et réglages dans $S"; open "$OUT"
sleep 3; osascript -e 'tell application "Terminal" to close (every window whose name contains "salon-construire")' >/dev/null 2>&1 &
exit 0
