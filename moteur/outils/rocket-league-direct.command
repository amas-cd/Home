#!/bin/bash
# Prépare le lancement DIRECT de Rocket League depuis le Salon (sans ouvrir Obelisk).
# Avant : installe toi-même Legendary (client Epic open source) dans le Terminal :   python3 -m pip install --user legendary-gl
# Ce script ensuite :
#  1. retrouve Legendary et te connecte à ton compte Epic (connexion séparée de celle d'Obelisk, qui garde la sienne) ;
#  2. déclare à Legendary l'installation existante d'Obelisk (aucun téléchargement) ;
#  3. écrit la recette de lancement (moteur Voile d'Obelisk, préfixe, exécutable, options) à partir de la capture analyser-rocket-league ;
#  4. vérifie que Legendary fournit bien un code de connexion Epic.
MOT="/Applications/Home/moteur"; OB="$MOT/obelisk"; CAP="/Applications/Home/log/rocket-league"; mkdir -p "$OB"
fin() { echo; read -r -p "Entrée pour fermer." _; exit "${1:-0}"; }
[ -f "$CAP/launch.sh" ] && [ -f "$CAP/arguments.txt" ] || { echo "Il manque la capture ($CAP/launch.sh et arguments.txt) : lance d'abord analyser-rocket-league.command."; fin 1; }
cp "$CAP/launch.sh" "$OB/launch.sh"; chmod +x "$OB/launch.sh"

echo "== 1/4 Legendary"
BIN="$(python3 -c 'import sysconfig; print(sysconfig.get_path("scripts", "posix_user"))')/legendary"
[ -x "$BIN" ] || BIN="$(command -v legendary)"
[ -x "$BIN" ] || { echo "Legendary introuvable. Dans le Terminal :  python3 -m pip install --user legendary-gl   puis relance ce script."; fin 1; }
echo "$BIN" > "$OB/legendary-path.txt"; echo "legendary : $BIN"
if "$BIN" status 2>&1 | grep -qi "not logged in"; then
  echo; echo "Connexion à ton compte Epic : une page web s'ouvre, connecte-toi, puis copie la valeur « authorizationCode » affichée et colle-la ici."
  "$BIN" auth || { echo "Connexion Epic non faite."; fin 1; }
else echo "Déjà connecté : $("$BIN" status 2>&1 | grep -i 'epic account' | head -1)"; fi

echo; echo "== 2/4 installation existante"
INFO="$(python3 - <<'PY'
import glob, json, os
root = os.path.expanduser('~/Library/Application Support/com.zagrios.obelisk')
for f in glob.glob(root + '/epic-installations-*.json'):
    if '.incomplete' in f: continue
    for i in json.load(open(f)):
        if i.get('appName') == 'Sugar':
            print(i['directory']); print(i.get('name', 'Rocket League').replace('®', '').replace('™', '').strip()); break
PY
)"
DIR="$(printf '%s\n' "$INFO" | sed -n 1p)"; NAME="$(printf '%s\n' "$INFO" | sed -n 2p)"
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "Rocket League (Sugar) introuvable dans les installations Epic d'Obelisk."; fin 1; }
echo "dossier : $DIR"
echo "métadonnées Epic (liste des jeux)…"; "$BIN" list --platform Windows 2>&1 | grep -i "rocket" | head -2
if "$BIN" list-installed 2>&1 | grep -q "Sugar"; then echo "déjà déclaré à Legendary"; else "$BIN" import --disable-check --platform Windows Sugar "$DIR" 2>&1 | grep -v "warnings.warn\|NotOpenSSL\|update available\|New version\|Release\|Download URL\|^\s*\[\*\]\|^-\s*$\|^$"; fi

echo; echo "== 3/4 recette"
NS="$(python3 - <<'PY'
import glob, json, os
root = os.path.expanduser('~/Library/Application Support/com.zagrios.obelisk')
for f in glob.glob(root + '/epic-installations-*.json'):
    if '.incomplete' in f: continue
    for i in json.load(open(f)):
        if i.get('appName') == 'Sugar': print(i.get('namespace', '')); break
PY
)"
python3 - "$CAP/arguments.txt" "$OB/recette-epic.json" "$OB/launch.sh" "$DIR" "$NAME" "$NS" <<'PY'
import sys, json, re, os
args_line, out, launcher, directory, name, ns = sys.argv[1:7]
line = open(args_line).read().strip()
assert line.startswith('obelisk-linux-engine '), line[:40]
head, tail = line[len('obelisk-linux-engine '):].split(' --graphics ', 1)
paths = [p for p in re.split(r' (?=/(?:Users|opt|Applications|Volumes|private|var|tmp)/)', head) if p]   # chemins avec espaces
assert len(paths) == 4, paths
runtime, home, install, cwd = paths
opts, rest = tail.split(' -- ', 1)
parts = opts.split(' --env ')
graphics = parts[0].strip(); envs = [e.strip() for e in parts[1:]]
toks = rest.split(' ')
exe = toks[0]
static = [a for a in toks[1:] if a and not (a.startswith('-AUTH_') or a.lower().startswith('-epic'))]   # les paramètres Epic viennent frais de Legendary
recipe = [{"appName": "Sugar", "namespace": ns, "nom": name, "dossier": os.path.basename(directory), "launcher": launcher, "runtime": runtime, "home": home,
           "install": install, "cwd": cwd, "graphics": graphics, "envs": envs, "exe": exe, "args": static}]
json.dump(recipe, open(out, 'w'), indent=2, ensure_ascii=False)
print("moteur :", runtime); print("exe :", exe); print("options :", static); print(len(envs), "variables ; namespace", ns)
PY
# Le code de connexion vient directement de la bibliothèque Legendary (pas besoin que le jeu soit « installé » pour Legendary)
cat > "$OB/code-epic.py" <<'PY'
# Imprime les paramètres de connexion Epic pour lancer un jeu : python3 code-epic.py <appName> <namespace>
import sys, warnings
warnings.filterwarnings("ignore")
from legendary.core import LegendaryCore
app, ns = sys.argv[1], sys.argv[2]
core = LegendaryCore()
if not core.login():
    print("ERREUR: connexion Epic impossible (relance rocket-league-direct.command)", file=sys.stderr); sys.exit(1)
code = core.egs.get_game_token()["code"]
u = core.lgd.userdata
print(f"-AUTH_LOGIN=unused -AUTH_PASSWORD={code} -AUTH_TYPE=exchangecode -epicapp={app} -epicenv=Prod -EpicPortal "
      f"-epicusername={u.get('displayName', '')} -epicuserid={u.get('account_id', '')} -epiclocale=fr -epicsandboxid={ns}")
PY

echo; echo "== 4/4 test du code Epic"
if python3 -W ignore "$OB/code-epic.py" Sugar "$NS" 2>&1 | grep -q -- "-AUTH_PASSWORD="; then echo "OK : code de connexion obtenu. Le Salon lancera Rocket League directement (Options → Lancement : Direct)."
else echo "Pas de code — sortie :"; python3 -W ignore "$OB/code-epic.py" Sugar "$NS" 2>&1 | tail -5; fi
fin 0
