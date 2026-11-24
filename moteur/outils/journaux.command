#!/bin/bash
# Copie les journaux et réglages des jeux dans /Applications/Home/log/diag, pour que Claude puisse les lire.
HR="${HOME_RACINE:-/Applications/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
D="$HR/log/diag"; mkdir -p "$D"; SUP="$HOME/Library/Application Support/nxnative"
cp "$HOME"/Library/Logs/nxnative/*.log "$D/" 2>/dev/null
for t in 0100F2C0115B6000 0100000000010000; do cp "$SUP/$t/env.txt" "$D/env-$t.txt" 2>/dev/null; done
# MacNativeGames (TOTK) : journal du dernier lancement et rapports de plantage récents
M="$HOME/Library/Application Support/MacNativeGames/TOTK"; mkdir -p "$D/mng"; cp "$M"/*.log "$D/mng/" 2>/dev/null; ls "$M" > "$D/mng/dossier.txt" 2>/dev/null; ls "$M/profile" > "$D/mng/profile.txt" 2>/dev/null
cp "$HOME"/Library/Logs/MacNativeGames/*.log "$D/mng/" 2>/dev/null   # journal MNG (TOTK_DEBUG_LOG=1, activé par le Salon)
ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i "totk\|MacNativeGames\|Tears\|Salon" | head -4 | while read f; do cp "$HOME/Library/Logs/DiagnosticReports/$f" "$D/mng/"; done
date '+%d/%m %H:%M' > "$D/copie.txt"; echo "Journaux copiés. Fenêtre fermée dans 3 s."; sleep 3
osascript -e 'tell application "Terminal" to close (every window whose name contains "journaux")' >/dev/null 2>&1 &
exit 0
