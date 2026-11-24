#!/bin/bash
# Copie les rapports de plantage de Salon dans /Applications/Home/log/salon-crash pour que Claude les lise.
HR="${HOME_RACINE:-$HOME/Library/Application Support/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
OUT="$HR/log/salon-crash"; mkdir -p "$OUT"
n=0
for f in "$HOME/Library/Logs/DiagnosticReports"/Salon*.ips "$HOME/Library/Logs/DiagnosticReports"/Salon*.crash; do [ -f "$f" ] && { cp "$f" "$OUT/"; n=$((n+1)); }; done
echo "$n rapport(s) copié(s) dans $OUT"
L=$(ls -t "$OUT"/Salon* 2>/dev/null | head -1)
if [ -n "$L" ]; then echo "== dernier : $L"; python3 - "$L" <<'PY'
import sys, json
raw = open(sys.argv[1], encoding='utf-8', errors='replace').read()
# format .ips : une ligne JSON d'en-tête puis le corps JSON
parts = raw.split('\n', 1)
try:
    body = json.loads(parts[1])
    print('exception :', body.get('exception'))
    print('termination :', body.get('termination'))
    if 'asi' in body: print('asi :', body['asi'])
    if 'lastExceptionBacktrace' in body: print('lastExceptionBacktrace :', str(body['lastExceptionBacktrace'])[:1500])
    tid = body.get('faultingThread', 0)
    th = body['threads'][tid]
    imgs = body.get('usedImages', [])
    for fr in th.get('frames', [])[:25]:
        img = imgs[fr.get('imageIndex', 0)] if fr.get('imageIndex', 0) < len(imgs) else {}
        print('  ', img.get('name', '?'), fr.get('symbol', ''), '+', fr.get('symbolLocation', ''), fr.get('sourceLine', ''))
except Exception as e:
    print('lecture brute :', e); print(raw[:3000])
PY
fi
read -r -p "Entrée pour fermer." _
