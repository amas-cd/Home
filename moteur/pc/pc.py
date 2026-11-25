#!/usr/bin/env python3
"""pc.py — les jeux PC de Home, sans Obelisk : le moteur Windows (Voile), le compte Epic Games (Legendary), la bibliothèque,
l'installation et le lancement d'un jeu.

Home reprend ce que fait Obelisk (https://github.com/Zagrios/Obelisk, GPL-3.0), d'après sa source :
  - Voile, son moteur Windows, est téléchargé depuis le flux public de Zagrios/Voile (taille et SHA-256 vérifiés) dans
    <Home>/voile/<version>. Home n'utilise jamais les fichiers d'Obelisk ; « importer » reprend une fois ce qu'il avait installé.
  - Les jeux tournent sur le « moteur Linux » de Voile (voile-wine pour Linux, exécuté par fexdarwin-run) : c'est lui qui laisse
    Easy Anti-Cheat charger son module Linux (Rocket League, Fall Guys…). Il ne lance que des programmes Windows 64 bits qui
    ne sont pas en .NET. Un jeu Epic qui démarre autrement est essayé sur le moteur Rosetta.
  - Le « moteur Rosetta » de Voile (Wine pour Mac Intel) sert aux installateurs (setups) et aux .exe 32 bits ou .NET ajoutés à la
    main, avec les variables d'Obelisk (rosetta.rs).
  - La commande est celle d'Obelisk (crates/game-runtime/src/wine/linux_engine.rs) : launch.sh RUNTIME HOME INSTALL CWD
    --graphics … --env … -- EXE ARGS, avec le préfixe créé par wineboot au premier lancement.
  - Les réglages par jeu (exécutable, rendu, arguments) viennent des profils d'Obelisk (profiles.json), lus en ligne et gardés
    dans <Home>/pc/profils.json.
Epic : le téléchargement et la connexion passent par Legendary (https://github.com/derrod/legendary). Home ne voit jamais
le mot de passe : la connexion se fait sur le site d'Epic, qui donne un code à coller.

Aucun anti-triche n'est modifié ni contourné : un jeu que son éditeur refuse sur Linux et Mac est bloqué par la liste de
compatibilité (moteur/compat/pc.json), avec sa raison et sa source.

  pc.py etat                    ce qui est prêt, en JSON
  pc.py preparer                Legendary (dans moteur/.venv-pc) et Voile, s'ils manquent
  pc.py connexion CODE          le compte Epic, avec le code donné par la page de connexion
  pc.py connexion CODE --nouveau   un compte Epic de plus, qui devient le compte actif
  pc.py compte-choisir ID       change de compte actif (les identifiants sont dans « etat »)
  pc.py deconnexion             oublie le compte Epic actif
  pc.py bibliotheque            les jeux du compte, en JSON, avec leur compatibilité
  pc.py installer APP           télécharge un jeu dans <Home>/pc/jeux
  pc.py lancer APP [--essai]    lance un jeu (--essai : affiche la commande sans rien lancer, code Epic masqué)
  pc.py ajouter-exe EXE [--nom NOM] [--prefixe DOSSIER]   un jeu déjà installé : son .exe devient une tuile (app « exe:<id> »)
  pc.py setup SETUP --nom NOM   lance un installateur (.exe 32 ou 64 bits, .msi) sur le moteur Rosetta, puis liste ce qu'il a installé
"""
import hashlib, json, os, re, shutil, subprocess, sys, time, unicodedata, urllib.request
from pathlib import Path

RACINE = Path(os.environ.get('HOME_RACINE') or Path.home() / 'Library/Application Support/Home')
MOT = RACINE / 'moteur'
PC = RACINE / 'pc'                      # jeux/, prefixes/, jeux.json, profils.json
VOILE = RACINE / 'voile'
OBELISK = Path.home() / 'Library/Application Support/com.zagrios.obelisk'   # lu une seule fois, par « importer » : ce qu'Obelisk avait installé
FLUX = 'https://raw.githubusercontent.com/Zagrios/Voile/main/voile-feed.json'
PROFILS = 'https://raw.githubusercontent.com/Zagrios/Obelisk/main/crates/game-runtime/profiles.json'
CONTRAT = 1                             # le « contrat » de Voile que cette commande de lancement connaît (docs/CONTRACT.md d'Obelisk)
ICI = Path(__file__).resolve().parent
TACHE = bool(os.environ.get('HOME_TACHE'))   # lancé par Home : l'avancement en JSON pour sa barre


def dire(*a): print(*a, flush=True)
def etape(nom, k=1, n=1):
    dire(f'== {nom}')
    if TACHE: dire(json.dumps({'ev': 'stage', 'k': k, 'n': n, 'name': nom}, ensure_ascii=False))
def avance(f):
    if TACHE: dire(json.dumps({'ev': 'progress', 'frac': round(max(0.0, min(1.0, f)), 4)}))
def echec(msg, code=1): dire('ÉCHEC : ' + msg); sys.exit(code)
def lire_json(p, defaut):
    try: return json.loads(Path(p).read_text(encoding='utf-8'))
    except Exception: return defaut
def ecrire_json(p, d):
    p = Path(p); p.parent.mkdir(parents=True, exist_ok=True); t = p.with_suffix(p.suffix + '.tmp')
    t.write_text(json.dumps(d, indent=1, ensure_ascii=False), encoding='utf-8'); os.replace(t, p)
def telecharger(url, delai=20):
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'Home'}), timeout=delai) as r: return r.read()


# ---------- Voile ----------
def cle_version(v):
    """v26.3.0-27 > v26.3.0-27.beta1 > v26.3.0-26 (l'ordre d'Obelisk : [A, B, C, R, 1, 0] et [A, B, C, R, 0, N] pour une bêta)"""
    m = re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)-(\d+)(?:\.beta(\d+))?', v)
    if not m: return None
    a, b, c, r, beta = m.groups()
    return [int(a), int(b), int(c), int(r)] + ([0, int(beta)] if beta else [1, 0])

def voile_installe():
    """(dossier du moteur Linux, version, d'où) : le Voile de Home (<Home>/voile) ; None s'il n'y en a pas"""
    return voile_dans(VOILE, 'home')

def voile_dans(base, ou):
    """Le Voile le plus récent d'un dossier de Voile"""
    for base, ou in ((base, ou),):
        trouves = []
        try: noms = [d for d in base.iterdir() if d.is_dir()]
        except OSError: noms = []
        for d in noms:
            k = cle_version(d.name)
            if k and (d / 'linux/engine/fexdarwin-run').is_file() and (d / 'linux/wine/bin/wine').is_file(): trouves.append((k, d))
        if trouves:
            d = max(trouves)[1]; return d / 'linux', d.name, ou
    return None

def installer_voile():
    etape('Moteur Windows (Voile)', 1, 2)
    flux = json.loads(telecharger(FLUX))
    if flux.get('format') != 1: echec('le flux de Voile a changé de format (dis-le à Claude)')
    choix = [(cle_version(r.get('version', '')), r) for r in flux.get('releases', []) if r.get('contract', 1) == CONTRAT and not r.get('withdrawn')]
    choix = [c for c in choix if c[0] and str(c[1].get('url', '')).startswith('https://github.com/Zagrios/Voile/releases/download/')]
    if not choix: echec('aucune version de Voile utilisable dans le flux')
    r = max(choix, key=lambda c: c[0])[1]; version, taille, sha = r['version'], int(r['size']), r['sha256']
    libre = os.statvfs(RACINE).f_bavail * os.statvfs(RACINE).f_frsize
    if libre < taille * 8: echec(f'pas assez de place pour Voile ({taille * 8 / 1e9:.0f} Go libres nécessaires)')
    VOILE.mkdir(parents=True, exist_ok=True); arch = VOILE / f'.{version}.tar.xz'; tmp = VOILE / f'.{version}.tmp'
    dire(f'Voile {version} : téléchargement ({taille / 1e6:.0f} Mo)')
    h = hashlib.sha256(); lu = 0
    with urllib.request.urlopen(urllib.request.Request(r['url'], headers={'User-Agent': 'Home'}), timeout=60) as src, open(arch, 'wb') as f:
        while True:
            b = src.read(1 << 20)
            if not b: break
            f.write(b); h.update(b); lu += len(b); avance(lu / taille * 0.9)
    if lu != taille or h.hexdigest() != sha: arch.unlink(missing_ok=True); echec('le téléchargement de Voile est incomplet ou modifié (taille ou SHA-256 différents) : relance')
    dire('Voile : décompression…')
    subprocess.run(['/bin/rm', '-rf', str(tmp)]); tmp.mkdir()
    if subprocess.run(['/usr/bin/tar', '-xJf', str(arch), '-C', str(tmp)]).returncode != 0: echec('décompression de Voile impossible')
    d = tmp / f'voile-{version}'
    if not (d / 'bin/wine').is_file() or lire_json(d / 'runtime.json', {}).get('version') != version: echec("l'archive de Voile n'a pas la forme attendue (dis-le à Claude)")
    os.replace(d, VOILE / version); subprocess.run(['/bin/rm', '-rf', str(tmp), str(arch)]); avance(1)
    dire(f'Voile {version} installé dans {VOILE / version}')


# ---------- Legendary (Epic Games) ----------
# Plusieurs comptes Epic : Legendary garde un compte par dossier de réglages (LEGENDARY_CONFIG_PATH). Le compte « defaut » est celui
# de Legendary lui-même (~/.config/legendary) ; les comptes ajoutés ont chacun leur dossier dans <Home>/pc/epic/<id>. Un seul est
# actif à la fois (bibliothèque, installation) ; un jeu installé retient son compte et se lance avec lui.
def comptes_epic():
    d = lire_json(PC / 'epic/comptes.json', {}); l = d.get('comptes') or ['defaut']
    return {'actif': d.get('actif') if d.get('actif') in l else l[0], 'comptes': l}
def noter_comptes(actif, liste): ecrire_json(PC / 'epic/comptes.json', {'actif': actif, 'comptes': liste})

def coeur(compte=None):
    import warnings; warnings.filterwarnings('ignore')
    import logging; logging.disable(logging.WARNING)
    c = compte or comptes_epic()['actif']
    if c == 'defaut': os.environ.pop('LEGENDARY_CONFIG_PATH', None)
    else: (PC / 'epic' / c).mkdir(parents=True, exist_ok=True); os.environ['LEGENDARY_CONFIG_PATH'] = str(PC / 'epic' / c)
    from legendary.core import LegendaryCore
    return LegendaryCore()

def nom_compte(i):
    try: return (coeur(i).lgd.userdata or {}).get('displayName')
    except Exception: return None

def legendary_present():
    try:
        import warnings; warnings.filterwarnings('ignore')
        import legendary.core  # noqa: F401
        return True
    except Exception: return False

def installer_legendary():
    etape('Compte Epic (Legendary)', 2, 2)
    venv = MOT / '.venv-pc'; py = venv / 'bin/python3'
    if not py.exists() and subprocess.run([sys.executable, '-m', 'venv', str(venv)]).returncode != 0: echec("impossible de créer l'environnement Python des jeux PC")
    r = subprocess.run([str(py), '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', 'legendary-gl'], capture_output=True, text=True)
    if r.returncode != 0: dire(r.stdout[-800:], r.stderr[-800:]); echec("Legendary ne s'est pas installé (connexion ?)")
    dire('Legendary : prêt')

def connecte(c):
    try: return bool(c.lgd.userdata)   # un compte est enregistré (sa validité se vérifie à l'usage : login())
    except Exception: return False


# ---------- compatibilité ----------
def norme(s):
    s = unicodedata.normalize('NFKD', s or '').encode('ascii', 'ignore').decode().lower()
    return re.sub(r'[^a-z0-9]+', ' ', s.replace('®', '').replace('™', '')).strip()

def compat_table():
    for p in (MOT / 'compat/pc.json', ICI.parent / 'compat/pc.json'):
        d = lire_json(p, None)
        if d: return d.get('jeux', [])
    return []

def compat(app, nom, table=None, namespace=None):
    """L'entrée de la liste de compatibilité pour ce jeu (par identifiant Epic, par espace de noms Epic, sinon par nom
    exact), ou None : un jeu inconnu n'est jamais bloqué"""
    table = compat_table() if table is None else table
    a, n, ns = (app or '').lower(), norme(nom), (namespace or '').lower()
    for j in table:
        if a and str(j.get('epic') or '').lower() == a: return j
    for j in table:
        if ns and str(j.get('epic_namespace') or '').lower() == ns: return j
    for j in table:
        if n and norme(j.get('nom')) == n: return j
    return None


# ---------- les jeux installés par Home ----------
def jeux_home(): return lire_json(PC / 'jeux.json', [])
def noter_jeu(app, nom, dossier, namespace):
    l = [j for j in jeux_home() if j.get('app') != app]; l.append({'app': app, 'nom': nom, 'dossier': str(dossier), 'namespace': namespace, 'compte': comptes_epic()['actif']})
    ecrire_json(PC / 'jeux.json', sorted(l, key=lambda j: j['nom'].lower()))


# ---------- lecture d'un .exe ----------
def pe(chemin):
    """(64 bits x86-64 ?, .NET ?) d'un programme Windows, d'après son en-tête ; (None, None) s'il n'est pas lisible"""
    try:
        with open(chemin, 'rb') as f:
            t = f.read(4096)
            o = int.from_bytes(t[0x3c:0x40], 'little')
            if t[:2] != b'MZ' or o + 0x108 > len(t) or t[o:o + 4] != b'PE\0\0': return None, None
            machine = int.from_bytes(t[o + 4:o + 6], 'little'); opt = o + 24; magie = int.from_bytes(t[opt:opt + 2], 'little')
            dirs = opt + (112 if magie == 0x20b else 96); clr = dirs + 14 * 8
            return machine == 0x8664, int.from_bytes(t[clr:clr + 4], 'little') != 0
    except OSError: return None, None

def contient(chemin, *motifs, limite=600 << 20):
    """Quels motifs (en minuscules) apparaissent dans le fichier : sert à voir si un jeu importe d3d12.dll sans d3d11.dll"""
    vus = set(); reste = b''; lu = 0
    try:
        with open(chemin, 'rb') as f:
            while lu < limite:
                b = f.read(4 << 20)
                if not b: break
                lu += len(b); bloc = (reste + b).lower()
                for m in motifs:
                    if m in bloc: vus.add(m)
                reste = b[-32:]
    except OSError: pass
    return vus

def amorce_eac(install):
    """Le lanceur Easy Anti-Cheat d'un jeu (comme Obelisk : un dossier EasyAntiCheat avec Settings.json, à 2 niveaux au plus,
    et à côté un .exe dont la description commence par « Easy Anti-Cheat Bootstrapper »), ou None"""
    file = [(Path(install), 0)]; vus = 0
    while file and vus < 256:
        d, p = file.pop(0); vus += 1
        try: enfants = sorted(d.iterdir())
        except OSError: continue
        if (d / 'EasyAntiCheat/Settings.json').is_file():
            marque = 'Easy Anti-Cheat Bootstrapper'.encode('utf-16-le').lower()
            for e in enfants:
                if e.suffix.lower() == '.exe' and e.is_file() and e.stat().st_size < (64 << 20) and marque in contient(e, marque): return e
        if p < 2: file += [(e, p + 1) for e in enfants if e.is_dir() and not e.is_symlink()]
    return None

def langue_mac():
    """La langue et la région du Mac (fr_BE) : Wine en tire sa langue Windows, par LC_ALL"""
    try: l = subprocess.run(['/usr/bin/defaults', 'read', '-g', 'AppleLocale'], capture_output=True, text=True, timeout=5).stdout.strip().split('@')[0]
    except Exception: l = ''
    return l if re.fullmatch(r'[a-z]{2,3}_[A-Z]{2}', l) else 'en_US'

def profil(app, namespace):
    """Le profil d'Obelisk pour ce jeu Epic (moteur, rendu, exécutable, arguments), lu en ligne (3 s) et gardé pour hors ligne"""
    cache = PC / 'profils.json'
    try:
        d = json.loads(telecharger(PROFILS, delai=3))
        if d.get('format') == 1: ecrire_json(cache, d)
    except Exception: d = lire_json(cache, {})
    for g in d.get('games', []):
        e = g.get('epic') or {}
        if e.get('app_name') == app and (not namespace or e.get('namespace') in (None, namespace)): return g
    return {}


# ---------- commandes ----------
def cmd_etat():
    v = voile_installe(); leg = legendary_present(); c = None
    if leg:
        try: c = coeur()
        except Exception: leg = False
    nom = None
    if c and connecte(c):
        try: nom = c.lgd.userdata.get('displayName') or '?'
        except Exception: nom = '?'
    ce = comptes_epic(); liste = [{'id': i, 'nom': nom_compte(i), 'actif': i == ce['actif']} for i in ce['comptes']] if leg else []
    dire(json.dumps({'voile': v[1] if v else None, 'voile_source': v[2] if v else None, 'legendary': leg, 'compte': nom, 'comptes': [x for x in liste if x['nom']], 'jeux': len(jeux_home())}, ensure_ascii=False))

def cmd_preparer():
    if voile_installe(): dire(f'Voile : déjà là ({voile_installe()[1]})')
    else: installer_voile()
    if legendary_present(): dire('Legendary : déjà là')
    else: installer_legendary()
    dire('done in : jeux PC prêts')

def cmd_connexion(code, nouveau=False):
    code = code.strip().strip('"')
    m = re.search(r'"authorizationCode"\s*:\s*"([0-9a-fA-F]+)"', code)   # toute la réponse de la page collée : le code en est tiré
    if m: code = m.group(1)
    if not re.fullmatch(r'[0-9a-fA-F]{20,64}', code): echec("ce n'est pas un code de connexion Epic (la valeur de « authorizationCode »)")
    ce = comptes_epic(); cible = ce['actif']
    if nouveau:   # un compte de plus : son propre dossier, gardé seulement si Epic accepte le code
        n = 2
        while f'c{n}' in ce['comptes'] or (PC / 'epic' / f'c{n}').exists(): n += 1
        cible = f'c{n}'
    c = coeur(cible)
    if not c.auth_code(code):
        if nouveau: subprocess.run(['/bin/rm', '-rf', str(PC / 'epic' / cible)])
        echec('Epic a refusé le code (il ne sert qu\'une fois et expire vite) : recommence la connexion')
    if nouveau: noter_comptes(cible, ce['comptes'] + [cible])
    dire('Connecté à Epic : ' + str(c.lgd.userdata.get('displayName', '')))

def cmd_compte_choisir(i):
    ce = comptes_epic()
    if i not in ce['comptes']: echec('compte Epic inconnu')
    noter_comptes(i, ce['comptes']); dire('Compte Epic : ' + str(nom_compte(i)))

def cmd_deconnexion():
    ce = comptes_epic(); a = ce['actif']
    coeur(a).lgd.invalidate_userdata()
    reste = [i for i in ce['comptes'] if i != a or a == 'defaut']   # le compte de base garde sa place (vide), les autres disparaissent
    suivant = next((i for i in reste if i != a and nom_compte(i)), reste[0] if reste else 'defaut')
    noter_comptes(suivant, reste or ['defaut']); dire('Déconnecté d\'Epic')

def cmd_images(app):
    """Les images qu'Epic donne pour un jeu (jaquette, fond, logo), d'après ce que Legendary a déjà en mémoire : rien à demander en
    ligne, pas de clé. Home s'en sert quand il n'a pas d'autre image."""
    g = coeur().get_game(app, update_meta=False)
    imgs = {i.get('type'): i.get('url') for i in ((g.metadata if g else None) or {}).get('keyImages', []) if i.get('url')}
    def premier(*types): return next((imgs[t] for t in types if t in imgs), None)
    dire(json.dumps({'jaquette': premier('DieselGameBoxTall', 'OfferImageTall', 'Thumbnail', 'DieselGameBox'),
                     'fond': premier('DieselGameBox', 'OfferImageWide', 'DieselStoreFrontWide', 'Featured'),
                     'logo': premier('DieselGameBoxLogo', 'ProductLogo')}, ensure_ascii=False))

def cmd_importer():
    """Reprend dans Home ce qu'Obelisk avait installé sur ce Mac, sans rien retélécharger : le moteur Voile (copie sans place en
    plus sur un disque APFS), les jeux Epic (déplacés dans <Home>/pc/jeux, déclarés à Legendary) et les jeux Steam des comptes
    connectés dans Home (déplacés dans <Home>/pc/steam/jeux, avec leur reçu). Après ça, Home n'a plus besoin d'Obelisk."""
    faits, restes = [], []
    # le moteur
    if not voile_installe():
        v = voile_dans(OBELISK / 'Voile', 'obelisk')
        if v:
            VOILE.mkdir(parents=True, exist_ok=True); src = v[0].parent
            r = subprocess.run(['/bin/cp', '-cR', str(src), str(VOILE / src.name)], capture_output=True, text=True)
            if r.returncode == 0 and voile_installe(): faits.append(f'moteur Voile {v[1]}')
            else: shutil.rmtree(VOILE / src.name, ignore_errors=True); restes.append('moteur Voile : la copie a échoué, il sera téléchargé (Composants)')
    def recus(magasin):
        out = {}
        for f in sorted(OBELISK.glob(f'{magasin}-installations-*.json')):
            if '.incomplete' in f.name: continue
            for j in lire_json(f, []):
                if isinstance(j, dict) and Path(str(j.get('directory', ''))).is_dir(): out.setdefault(str(j.get('appName') or j.get('appId')), (f, j))
        return out
    def deplacer(src, dest):
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.exists(): return False
        try: os.rename(src, dest); return True          # même disque : immédiat, rien n'est copié
        except OSError: return False
    def recaler(app, dossier):
        """Legendary connaissait peut-être déjà ce jeu à son ancien endroit (import fait avant) : il prend le nouveau dossier"""
        k = coeur(); i = k.get_installed_game(app)
        if i and Path(i.install_path) != Path(dossier): i.install_path = str(dossier); k.lgd.set_installed_game(app, i)
    for j in jeux_home():       # un import d'avant, resté à l'ancien dossier chez Legendary
        if j.get('namespace') and Path(j.get('dossier', '')).is_dir() and legendary_present():
            try: recaler(j['app'], j['dossier'])
            except Exception: pass
    def nom_dossier(nom): return re.sub(r'[^A-Za-z0-9]+', '-', re.sub('[®™©]', '', nom)).strip('-') or 'jeu'
    # Epic : le dossier vient dans <Home>/pc/jeux, Legendary l'adopte (import, sans revérifier 40 Go), Home le note
    epic = recus('epic')
    if epic:
        c = coeur() if legendary_present() else None
        if not c or not c.login(): restes += [f"{j['name']} (Epic) : connecte d'abord ton compte Epic dans Home" for _, j in epic.values()]
        else:
            for app, (_, j) in epic.items():
                nom = re.sub('[®™©]', '', j.get('name') or app).strip(); src = Path(j['directory']); dest = PC / 'jeux' / nom_dossier(nom)
                if any(x.get('app') == app for x in jeux_home()): continue
                if not c.get_game(app, update_meta=True, platform='Windows'): restes.append(f"{nom} (Epic) : pas dans la bibliothèque du compte connecté dans Home"); continue
                if not deplacer(src, dest): restes.append(f'{nom} (Epic) : son dossier n\'a pas pu être déplacé'); continue
                r = subprocess.run([sys.executable, '-W', 'ignore', '-m', 'legendary.cli', '-y', 'import', app, str(dest), '--disable-check', '--platform', 'Windows'],
                                   capture_output=True, text=True, stdin=subprocess.DEVNULL, env=dict(os.environ))
                recaler(app, dest)
                if not coeur().get_installed_game(app):
                    os.rename(dest, src); restes.append(f'{nom} (Epic) : Legendary ne l\'a pas reconnu, remis où il était (' + ((r.stderr or r.stdout).strip().splitlines() or ['?'])[-1][:120] + ')'); continue
                noter_jeu(app, nom, dest, j.get('namespace')); faits.append(f'{nom} (Epic)')
    # Steam : seulement les jeux d'un compte connecté dans Home ; le reçu suit le jeu, avec son nouveau dossier
    comptes = {str(x.get('steam_id')) for x in (lire_json(PC / 'steam/comptes.json', {}).get('comptes') or []) if isinstance(x, dict)}
    for app, (f, j) in recus('steam').items():
        ident = f.name[len('steam-installations-'):-len('.json')]; nom = j.get('name') or app
        mien = PC / 'steam' / f.name; liste = lire_json(mien, [])
        if any(str(x.get('appId')) == app for x in liste): continue
        if ident not in comptes: restes.append(f"{nom} (Steam) : connecte d'abord ce compte Steam dans Home (Comptes)"); continue
        src = Path(j['directory']); dest = PC / 'steam/jeux' / src.name
        if not deplacer(src, dest): restes.append(f'{nom} (Steam) : son dossier n\'a pas pu être déplacé'); continue
        ecrire_json(mien, liste + [dict(j, directory=str(dest))]); faits.append(f'{nom} (Steam)')
    dire(json.dumps({'importes': faits, 'restes': restes}, ensure_ascii=False))

def cmd_bibliotheque():
    c = coeur()
    if not c.login(): echec('pas connecté à Epic', 2)
    table = compat_table(); chez_home = {j['app']: j for j in jeux_home()}; sortie = []
    for g in c.get_game_list(update_assets=True, platform='Windows'):
        e = compat(g.app_name, g.app_title, table, g.namespace) or {}
        tiers = (g.metadata or {}).get('customAttributes', {}).get('ThirdPartyManagedApp', {}).get('value')
        imgs = {i.get('type'): i.get('url') for i in (g.metadata or {}).get('keyImages', []) if i.get('url')}   # la jaquette : l'affiche en hauteur d'abord
        image = next((imgs[t] for t in ('DieselGameBoxTall', 'OfferImageTall', 'DieselGameBox', 'OfferImageWide', 'Thumbnail') if t in imgs), None)
        sortie.append({'app': g.app_name, 'nom': g.app_title, 'namespace': g.namespace, 'image': image, 'installe': g.app_name in chez_home and Path(chez_home[g.app_name]['dossier']).is_dir(),
                       'etat': e.get('etat') or 'inconnu', 'raison': e.get('raison'), 'preuve': e.get('preuve'), 'lanceur': tiers})
    dire(json.dumps(sorted(sortie, key=lambda j: j['nom'].lower()), ensure_ascii=False))

def cmd_installer(app):
    c = coeur()
    if not c.login(): echec('pas connecté à Epic', 2)
    g = c.get_game(app, update_meta=True, platform='Windows')
    if not g: echec(f'{app} n\'est pas dans ta bibliothèque Epic')
    e = compat(app, g.app_title, None, g.namespace)
    if e and e.get('etat') == 'bloque': echec(f'{g.app_title} ne peut pas tourner sur Mac — {e.get("raison")}', 3)
    etape(f'Téléchargement de {g.app_title}')
    (PC / 'jeux').mkdir(parents=True, exist_ok=True)
    p = subprocess.Popen([sys.executable, '-W', 'ignore', '-m', 'legendary.cli', '-y', 'install', app, '--platform', 'Windows', '--base-path', str(PC / 'jeux'), '--skip-sdl'],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace', stdin=subprocess.DEVNULL)
    for l in p.stdout:
        m = re.search(r'Progress: ([0-9.]+)%', l)
        if m: avance(float(m.group(1)) / 100)
        elif not TACHE or re.search(r'ERROR|CRITICAL|Install size|Download size|Finished', l): dire(l.rstrip()[:200])
    if p.wait() != 0: echec(f'le téléchargement de {g.app_title} a échoué (place sur le disque ? connexion ?)')
    c = coeur(); i = c.get_installed_game(app)
    if not i or not Path(i.install_path).is_dir(): echec('Legendary ne retrouve pas le jeu installé')
    noter_jeu(app, g.app_title, i.install_path, g.namespace)
    dire(f'done in : {g.app_title} installé dans {i.install_path}')

def cmd_lancer(app, essai=False):
    if app.startswith('exe:'): return cmd_lancer_local(app, essai)
    v = voile_installe()
    if not v: echec('le moteur Windows (Voile) n\'est pas installé : Home → Ajouter un jeu → Jeu PC', 4)
    runtime = v[0]
    c = coeur((jeu_local(app) or {}).get('compte'))   # le compte avec lequel le jeu a été installé
    if not c.login(): echec('pas connecté à Epic (le compte de ce jeu a été déconnecté)', 2)
    i = c.get_installed_game(app); g = c.get_game(app, platform='Windows')
    if not i or not g: echec(f'{app} n\'est pas installé')
    e = compat(app, g.app_title, None, g.namespace)
    if e and e.get('etat') == 'bloque': echec(f'{g.app_title} ne peut pas tourner sur Mac — {e.get("raison")}', 3)
    install = Path(i.install_path).resolve()
    pr = profil(app, g.namespace)
    if pr.get('minimum_voile') and (cle_version(v[1]) or []) < (cle_version(pr['minimum_voile']) or []): echec(f'{g.app_title} demande Voile {pr["minimum_voile"]} ou plus récent (ici {v[1]})', 4)
    params = c.get_launch_parameters(app, disable_wine=True)

    # l'exécutable : celui du profil d'Obelisk, sinon celui d'Epic ; s'il n'est pas un programme 64 bits natif, le lanceur
    # Easy Anti-Cheat du jeu quand il en a un (c'est ce que le programme de l'éditeur aurait démarré)
    exe = install / (pr.get('executable') or (i.executable or '').replace('\\', '/'))
    x64, dotnet = pe(exe)
    if not pr.get('executable') and (x64 is not True or dotnet):
        b = amorce_eac(install)
        if b: exe = b; x64, dotnet = pe(exe)
    if not exe.is_file(): echec(f'programme du jeu introuvable : {exe}')
    if x64 is not True or dotnet:   # le moteur Linux ne sait pas le lancer : on essaie le moteur Rosetta (Wine pour Mac), qui lance le 32 bits et le .NET
        dire(f'{g.app_title} démarre par un programme {"en .NET" if dotnet else "32 bits"} ({exe.name}) : le moteur Linux ne le lance pas, essai avec le moteur Rosetta')
        return lancer_rosetta(g.app_title, exe, list(params.game_parameters) + list(params.egl_parameters) + list(params.user_parameters), PC / 'prefixes' / (install.name + '-rosetta'), v, essai)
    lancer_linux(g.app_title, install, exe, list(params.game_parameters), list(params.egl_parameters), list(params.user_parameters), pr, v, essai, app)


def lancer_linux(titre, install, exe, args_jeu, epic, args_joueur, pr, v, essai, app=''):
    """Lance un programme Windows 64 bits sur le moteur Linux de Voile, avec la commande d'Obelisk (linux_engine.rs)"""
    runtime = v[0]
    rel = exe.relative_to(install).as_posix(); cwd = '/opt/game' + ('/' + str(Path(rel).parent) if str(Path(rel).parent) != '.' else '')

    # le rendu : celui du profil ; sinon DXMT, ou D3DMetal pour un jeu qui importe Direct3D 12 sans Direct3D 11
    rendu = {'Dxmt': 'dxmt', 'D3DMetal': 'd3dmetal'}.get(pr.get('graphics') or '')
    if not rendu:
        vus = contient(exe, b'd3d12.dll', b'd3d11.dll'); rendu = 'd3dmetal' if b'd3d12.dll' in vus and b'd3d11.dll' not in vus else 'dxmt'

    # le préfixe : <Home>/pc/prefixes/<dossier du jeu>-linux/prefix, créé par wineboot dans le moteur au premier lancement
    home = PC / 'prefixes' / ((app.replace(':', '-') if app.startswith('exe:') else install.name) + '-linux'); prefixe = home / 'prefix'   # un .exe ajouté à la main : son identifiant (deux jeux peuvent avoir un dossier de même nom)
    langue = langue_mac()
    surcharges = 'mscoree,mshtml=;winemenubuilder.exe=d;d3d11,dxgi,d3d12=n' + ''.join(f';{k}={m}' for k, m in (pr.get('dll_overrides') or {}).items())
    invite = [('HOME', '/home/user'), ('USER', 'user'), ('LOGNAME', 'user'), ('PATH', '/opt/wine/bin:/usr/bin:/bin'), ('LANG', 'en_US.UTF-8'),
              ('WINEPREFIX', '/home/user/prefix'), ('WINEARCH', 'win64'), ('WINEDEBUG', 'err+all,fixme-all'), ('WINEDLLOVERRIDES', surcharges),
              ('VTEST_SOCKET_NAME', '/run/obelisk/vtest.sock'), ('NPT_DEBUG', 'force_vtest'), ('LC_ALL', langue + '.UTF-8')] + list((pr.get('variables') or {}).items())
    d3d = [runtime / 'windows' / n for n in ('d3d11.dll', 'dxgi.dll', 'd3d12.dll')]; neptune = runtime / 'wine/lib/wine/x86_64-windows/nptunix.dll'
    if not all(f.is_file() for f in d3d + [neptune]): echec('le moteur Voile est incomplet (un antivirus a pu retirer des fichiers) : réinstalle-le', 4)

    # les arguments, dans l'ordre d'Obelisk : ceux du jeu, la connexion Epic, ceux du profil, le jeton de possession en dernier
    jeton = next((a for a in epic if a.startswith('-epicovt=')), None)
    epic = [a for a in epic if not a.startswith('-epicovt=')]
    args = list(args_jeu) + epic + list(pr.get('arguments') or []) + list(args_joueur)
    if app == 'Sugar': args.append('-language=' + {'fr': 'FRA', 'it': 'ITA', 'de': 'DEU'}.get(langue[:2], 'INT'))   # Rocket League : sa langue vient de la ligne de commande
    if jeton: args.append('-epicovt=C:\\.home\\ownership.bin')   # le moteur n'a pas de lecteur Z: : le jeton est posé dans le préfixe

    lanceur = next((p for p in (ICI / 'launch.sh', MOT / 'obelisk/launch.sh', ICI.parent / 'obelisk/launch.sh') if p.is_file()), None)
    if not lanceur: echec('launch.sh introuvable dans le moteur de Home')
    cmd = ['/bin/bash', str(lanceur), str(runtime), str(home), str(install), cwd, '--graphics', rendu]
    for k, val in invite: cmd += ['--env', f'{k}={val}']
    cmd += ['--', '/opt/game/' + rel] + args
    env = {k: os.environ[k] for k in ('HOME', 'TMPDIR', 'USER', 'LOGNAME', 'LANG') if k in os.environ}
    env.update({'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'OBELISK_APP_NAME': re.sub('[®™©]', '', titre).strip()})

    if essai:
        masque = [re.sub(r'(-AUTH_PASSWORD=).*', r'\1<masqué>', a) for a in cmd]
        dire(json.dumps({'voile': v[1], 'profil': pr.get('name'), 'prefixe': str(prefixe), 'prefixe_existe': (prefixe / 'system.reg').is_file(), 'commande': masque}, ensure_ascii=False, indent=1)); return

    home.mkdir(parents=True, exist_ok=True); os.chmod(home, 0o700)
    if not (prefixe / 'system.reg').is_file():
        dire('Premier lancement : préparation de Windows (environ une minute)…')
        boot = [str(runtime / 'engine/run-with-timeout.sh'), '600', str(runtime / 'engine/fexdarwin-run'), '--cwd', '/home/user']
        for k, val in invite: boot += ['--env', f'{k}={val}']
        boot += ['/bin/sh', '-c', '/opt/wine/bin/wine wineboot --init; /opt/wine/bin/wineserver -w']
        r = subprocess.run(boot, env={'FEXDARWIN_LKD': '1', 'FEXDARWIN_ROOT': str(runtime / 'root'), 'FEXDARWIN_ROOT_RO': '1', 'FEXDARWIN_BIND': f'/opt/wine={runtime / "wine"}:ro;/home/user={home}'},
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode != 0 or not (prefixe / 'system.reg').is_file(): echec('la préparation de Windows a échoué (dis-le à Claude)', 4)
    sys32 = prefixe / 'drive_c/windows/system32'
    import shutil
    for f in d3d: shutil.copyfile(f, sys32 / f.name)
    if not (sys32 / neptune.name).exists(): shutil.copyfile(neptune, sys32 / neptune.name)
    if jeton:
        d = prefixe / 'drive_c/.home'; d.mkdir(exist_ok=True); shutil.copyfile(jeton.split('=', 1)[1], d / 'ownership.bin')
    dire(f'{titre} : lancement ({rendu}, Voile {v[1]})'); sys.stdout.flush()
    os.chdir(install); os.execve(cmd[0], cmd, env)


# ---------- moteur Rosetta de Voile (Wine pour Mac Intel, traduit par Rosetta) : les programmes 32 bits et .NET, les setups ----------
def rosetta_present():
    try: return subprocess.run(['/usr/bin/arch', '-x86_64', '/usr/bin/true'], capture_output=True, timeout=20).returncode == 0
    except Exception: return False

def env_hote():
    """L'environnement de départ d'un jeu, comme Obelisk (native.rs) : le dossier personnel, le compte, la langue, rien d'autre"""
    e = {'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'TMPDIR': os.environ.get('TMPDIR') or '/tmp', 'LANG': langue_mac() + '.UTF-8'}
    u = os.environ.get('USER') or os.environ.get('LOGNAME')
    if u: e['USER'] = e['LOGNAME'] = u
    return e

def env_rosetta(racine, prefixe, rendu='d3dmetal', tous_les_rendus=False):
    """Les variables de Wine sur le moteur Rosetta, comme Obelisk (rosetta.rs, environment) ; racine = <Voile>/<version>"""
    mono = any(n.name.startswith('wine-mono-') for n in (racine / 'share/wine/mono').iterdir()) if (racine / 'share/wine/mono').is_dir() else False
    e = {'WINEPREFIX': str(prefixe), 'WINEDLLOVERRIDES': ('' if mono else 'mscoree,') + 'mshtml=;winemenubuilder.exe=d', 'WINEDEBUG': 'err+all,fixme-all',
         'WINEMSYNC': '1', 'WINE_LARGE_ADDRESS_AWARE': '1', 'ROSETTA_ADVERTISE_AVX': '1', 'DOTNET_EnableWriteXorExecute': '0'}
    if (racine / 'lib/gstreamer-1.0').is_dir(): e['GST_PLUGIN_SYSTEM_PATH'] = str(racine / 'lib/gstreamer-1.0'); e['GST_REGISTRY'] = str(prefixe / 'obelisk-gstreamer-registry.bin')
    if (racine / 'lib/external/libd3dshared.dylib').is_file(): e['CX_APPLEGPTK_LIBD3DSHARED_PATH'] = str(racine / 'lib/external/libd3dshared.dylib')
    cadre = racine / 'lib/external/D3DMetal.framework/D3DMetal'
    if cadre.is_file(): e['D3DMETAL_FRAMEWORK_PATH'] = str(cadre)
    dossiers = [racine / 'lib/d3dmetal', racine / 'lib/dxmt'] if (rendu == 'd3dmetal' or tous_les_rendus) else [racine / 'lib/dxmt']
    dossiers = [str(d) for d in dossiers if d.is_dir()]
    if dossiers: e['WINEDLLPATH_PREPEND'] = ':'.join(dossiers)
    if (racine / ('lib/external/libd3dshared.dylib' if rendu == 'd3dmetal' else 'lib/dxmt')).exists(): e['CX_ACTIVE_GRAPHICS_BACKEND'] = rendu
    if rendu == 'd3dmetal': e['D3DM_SUPPORT_DXR'] = '0'
    return e

def preparer_prefixe_rosetta(racine, prefixe):
    """Crée le préfixe Windows au premier usage (wineboot --init, tous les rendus devant pour que leurs DLL y aient leur place)"""
    if not (racine / 'bin/wine').is_file(): echec('le moteur Voile est incomplet (bin/wine manque)', 4)
    if not rosetta_present(): echec('Rosetta manque : dans le Terminal, tape  softwareupdate --install-rosetta --agree-to-license  puis recommence', 4)
    prefixe.mkdir(parents=True, exist_ok=True); os.chmod(prefixe, 0o700)
    if (prefixe / 'system.reg').is_file(): return
    dire('Préparation de Windows (environ une minute)…')
    env = dict(env_hote(), **env_rosetta(racine, prefixe, tous_les_rendus=True))
    r = subprocess.run([str(racine / 'bin/wine'), 'wineboot', '--init'], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([str(racine / 'bin/wineserver'), '-w'], env={'WINEPREFIX': str(prefixe)})
    if r.returncode != 0 or not (prefixe / 'system.reg').is_file(): echec('la préparation de Windows a échoué (dis-le à Claude)', 4)
    for prof in (prefixe / 'drive_c/users').glob('*'):   # les dossiers Documents, Bureau… du préfixe ne pointent pas vers ceux du Mac
        for d in (prof, prof / 'Desktop'):
            try: liens = [x for x in d.iterdir() if x.is_symlink()]
            except OSError: continue
            for x in liens:
                x.unlink()
                if d == prof: x.mkdir()

def exes_du_prefixe(prefixe):
    """Les .exe d'un préfixe, hors Windows lui-même : sert à voir ce qu'un setup a installé"""
    c = prefixe / 'drive_c'; vus = {}
    for base, dossiers, fichiers in os.walk(c):
        if Path(base) == c: dossiers[:] = [d for d in dossiers if d.lower() != 'windows']
        for f in fichiers:
            if f.lower().endswith('.exe'):
                p = Path(base) / f
                try: vus[str(p)] = p.stat().st_size
                except OSError: pass
    return vus

def racine_jeu(exe):
    """Le dossier du jeu vu par le moteur Linux : celui du .exe, ou pour un jeu Unreal (<Projet>/Binaries/Win64) celui du projet"""
    d = Path(exe).parent
    if d.name.lower() in ('win64', 'win32') and d.parent.name.lower() == 'binaries' and len(d.parents) > 3:
        projet = d.parent.parent   # <Projet>/Binaries/Win64 ; avec un dossier Engine à côté du projet, le jeu commence un cran plus haut
        return projet.parent if (projet.parent / 'Engine').is_dir() else projet
    return d

def jeu_local(app):
    for j in jeux_home():
        if j.get('app') == app: return j
    return None

def cmd_ajouter_exe(exe, nom=None, prefixe=None):
    exe = Path(exe).expanduser().resolve()
    if not exe.is_file() or exe.suffix.lower() != '.exe': echec(f'ce n\'est pas un programme Windows (.exe) : {exe}')
    x64, dotnet = pe(exe)
    if x64 is None: echec(f'{exe.name} n\'est pas un programme Windows lisible')
    nom = (nom or exe.stem).strip()
    e = compat(None, nom)
    if e and e.get('etat') == 'bloque': echec(f'{nom} ne peut pas tourner sur Mac — {e.get("raison")}', 3)
    # 64 bits natif : le moteur Linux (celui qui laisse passer Easy Anti-Cheat) ; 32 bits, .NET ou installé par un setup : le moteur Rosetta
    moteur = 'linux' if (x64 and not dotnet and not prefixe) else 'rosetta'
    app = 'exe:' + hashlib.sha1(str(exe).encode()).hexdigest()[:12]
    l = [j for j in jeux_home() if j.get('app') != app]
    l.append({'app': app, 'nom': nom, 'dossier': str(racine_jeu(exe)), 'exe': str(exe), 'moteur': moteur, 'prefixe': str(prefixe) if prefixe else None})
    ecrire_json(PC / 'jeux.json', sorted(l, key=lambda j: j['nom'].lower()))
    dire(json.dumps({'app': app, 'nom': nom, 'moteur': moteur}, ensure_ascii=False))

def cmd_setup(setup, nom):
    """Lance un installateur Windows (setup.exe, .msi) dans un préfixe neuf sur le moteur Rosetta, attend sa fin, puis dit
    quels programmes il a installés (JSON) : Home fait choisir celui du jeu"""
    v = voile_installe()
    if not v: echec('le moteur Windows (Voile) n\'est pas installé : Home → Ajouter un jeu → Jeu PC', 4)
    racine = v[0].parent; setup = Path(setup).expanduser().resolve()
    if not setup.is_file() or setup.suffix.lower() not in ('.exe', '.msi'): echec(f'ce n\'est pas un installateur Windows (.exe ou .msi) : {setup}')
    e = compat(None, nom)
    if e and e.get('etat') == 'bloque': echec(f'{nom} ne peut pas tourner sur Mac — {e.get("raison")}', 3)
    prefixe = PC / 'prefixes' / ('setup-' + (re.sub(r'[^A-Za-z0-9._-]+', '-', nom).strip('-')[:50] or 'jeu'))
    preparer_prefixe_rosetta(racine, prefixe)
    avant = exes_du_prefixe(prefixe)
    env = dict(env_hote(), **env_rosetta(racine, prefixe))
    dire(f'Installateur : {setup.name} — suis ses étapes dans sa fenêtre, en gardant le dossier proposé (C:\\\\…)'); sys.stdout.flush()
    cmd = [str(racine / 'bin/wine')] + (['msiexec', '/i', str(setup)] if setup.suffix.lower() == '.msi' else [str(setup)])
    subprocess.run(cmd, env=env, cwd=str(setup.parent), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([str(racine / 'bin/wineserver'), '-w'], env={'WINEPREFIX': str(prefixe)})
    apres = exes_du_prefixe(prefixe)
    bruit = re.compile(r'unins|uninstall|setup|install|redist|vcredist|vc_redist|dxsetup|dotnet|crash|report|launcherpatcher|ue4prereq|helper|update', re.I)
    neufs = [(t, p) for p, t in apres.items() if p not in avant and not bruit.search(Path(p).name)]
    cands = [{'exe': p, 'nom': Path(p).stem, 'taille': t} for t, p in sorted(neufs, reverse=True)[:12]]
    dire(json.dumps({'prefixe': str(prefixe), 'candidats': cands}, ensure_ascii=False))

def cmd_lancer_local(app, essai=False):
    j = jeu_local(app)
    if not j: echec(f'{app} n\'est pas dans les jeux de Home')
    v = voile_installe()
    if not v: echec('le moteur Windows (Voile) n\'est pas installé : Home → Ajouter un jeu → Jeu PC', 4)
    exe = Path(j['exe'])
    if not exe.is_file(): echec(f'programme du jeu introuvable : {exe} (disque débranché ? jeu déplacé ?)')
    e = compat(None, j['nom'])
    if e and e.get('etat') == 'bloque': echec(f'{j["nom"]} ne peut pas tourner sur Mac — {e.get("raison")}', 3)
    if j.get('moteur') == 'linux':
        lancer_linux(j['nom'], Path(j['dossier']).resolve(), exe.resolve(), [], [], [], {}, v, essai, app)
        return
    lancer_rosetta(j['nom'], exe, [], Path(j['prefixe']) if j.get('prefixe') else PC / 'prefixes' / app.replace(':', '-'), v, essai)

def lancer_rosetta(titre, exe, args, prefixe, v, essai):
    """Lance un programme Windows sur le moteur Rosetta de Voile : les .exe ajoutés à la main, et les jeux que le moteur Linux ne sait pas lancer"""
    racine = v[0].parent; rendu = 'd3dmetal'
    cmd = [str(racine / 'bin/wine'), str(exe), *args]; env = dict(env_hote(), **env_rosetta(racine, prefixe, rendu))
    if essai:
        dire(json.dumps({'voile': v[1], 'moteur': 'rosetta', 'prefixe': str(prefixe), 'prefixe_existe': (prefixe / 'system.reg').is_file(), 'commande': cmd, 'env': env}, ensure_ascii=False, indent=1)); return
    preparer_prefixe_rosetta(racine, prefixe)
    dire(f'{titre} : lancement (moteur Rosetta, {rendu}, Voile {v[1]})'); sys.stdout.flush()
    os.chdir(exe.parent); os.execve(cmd[0], cmd, env)


def main():
    a = sys.argv[1:]
    if not a or a[0] in ('-h', '--help'): dire(__doc__); return
    c = a[0]
    if c == 'etat': cmd_etat()
    elif c == 'preparer': cmd_preparer()
    elif c == 'connexion' and len(a) >= 2: cmd_connexion(a[1], nouveau='--nouveau' in a[2:])
    elif c == 'compte-choisir' and len(a) == 2: cmd_compte_choisir(a[1])
    elif c == 'deconnexion': cmd_deconnexion()
    elif c == 'bibliotheque': cmd_bibliotheque()
    elif c == 'importer': cmd_importer()
    elif c == 'images' and len(a) == 2: cmd_images(a[1])
    elif c == 'installer' and len(a) == 2: cmd_installer(a[1])
    elif c == 'lancer' and len(a) >= 2: cmd_lancer(a[1], essai='--essai' in a[2:])
    elif c == 'ajouter-exe' and len(a) >= 2:
        o = a[2:]; cmd_ajouter_exe(a[1], o[o.index('--nom') + 1] if '--nom' in o else None, o[o.index('--prefixe') + 1] if '--prefixe' in o else None)
    elif c == 'setup' and len(a) == 4 and a[2] == '--nom': cmd_setup(a[1], a[3])
    else: echec('commande inconnue (pc.py --help)')


if __name__ == '__main__':
    main()
