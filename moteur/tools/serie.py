#!/usr/bin/env python3
"""Garder ses changements par-dessus un dépôt qui avance : rejouer une série de patchs sur une nouvelle version, avec des
réparations sûres quand un patch ne s'applique plus, et un arrêt propre (rien n'est touché) quand ce n'est pas sûr.

Sert à MacNativeGames (les commits d'Anas dans <Home>/MacNativeGames, gardés en série dans moteur/mng/patches) et au moteur
nxnative (moteur/patches, géré par tools/engine.py, qui appelle `rejouer` quand sa propre mise à jour bute sur un conflit).

Commandes (Python 3.9+, git) :
  mng-maj --clone DIR --racine DIR [--vers REF] [--sans-fetch] [--depot DIR]
        met le clone à jour : branche de sauvegarde datée, puis la série (les commits du clone qui ne sont pas dans l'amont)
        rejouée sur la nouvelle version dans un dossier à part ; le clone ne bouge qu'à la fin, si tout s'est appliqué.
        Sortie 0 : à jour. 3 : en attente (un changement ne s'applique plus ; rapport dans <racine>/log). 1 : autre échec.
  mng-exporter --clone DIR --dest DIR [--dest DIR…]
        écrit la série du clone (patches/*.patch, patches/series, .upstream-ref) dans chaque dossier « mng » donné.
  rejouer --arbre DIR --ancienne SHA --rapport FICHIER PATCH…
        applique les patchs, dans l'ordre, sur l'arbre git DIR (déjà placé sur la nouvelle version). Sortie 0 ou 3.

Un patch s'applique d'abord avec `git am -3`. S'il bute, il est repris morceau par morceau (un fichier à la fois) :
  a) le fichier est devenu un lien dans l'amont (vers shared/…) : le morceau est appliqué sur la cible du lien ;
  b) le fichier a été déplacé ou renommé : on le retrouve (renommages vus par git, sinon le contexte du morceau) ;
  c) git signale un conflit : deux lignes voisines changées chacune d'un côté passent toutes les deux ; si les mêmes lignes
     ont changé des deux côtés, on garde la version de l'amont et on y remet l'ajout, seulement quand le changement d'Anas
     est un ajout pur (des lignes, ou des mots dans une liste) dont la place ne fait aucun doute.
Tout le reste arrête la mise à jour : c'est à un humain de décider.
"""
import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

IDENT = ('-c', 'user.name=Anas', '-c', 'user.email=assosbs9@gmail.com', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false')
FUSION = ('-c', 'merge.conflictStyle=diff3', '-c', 'diff.renameLimit=30000', '-c', 'merge.renameLimit=30000')


def dire(*a):
    print(*a, flush=True)


def git(*a, cwd, entree=None, texte=True):
    r = subprocess.run(['git', *IDENT, *a], cwd=str(cwd), input=entree, capture_output=True, check=False)   # l'identité partout : même `am --abort` la demande
    if texte:
        r.stdout = r.stdout.decode('utf-8', 'replace'); r.stderr = r.stderr.decode('utf-8', 'replace')
    return r


def ok(*a, cwd):
    r = git(*a, cwd=cwd)
    if r.returncode:
        raise RuntimeError(f"git {' '.join(a[:3])}… : {(r.stderr.strip().splitlines() or ['échec'])[-1]}")
    return r.stdout.strip()


# ---------------------------------------------------------------------------------------------------------------- un patch

class Morceau:
    """La partie d'un patch qui touche un fichier"""
    def __init__(self, brut):
        self.brut = brut
        tete = brut.split(b'\n@@', 1)[0].split(b'\nGIT binary patch', 1)[0]
        m = re.match(rb'diff --git a/(.+?) b/(.+?)\n', brut)
        self.chemin = m.group(2).decode('utf-8', 'replace') if m else '?'
        self.cree = b'\nnew file mode ' in tete
        self.supprime = b'\ndeleted file mode ' in tete
        self.renomme = b'\nrename from ' in tete
        self.binaire = b'\nGIT binary patch' in brut or b'\nBinary files ' in brut

    def vers(self, cible):
        """Le même morceau, pour un autre chemin"""
        a, c = self.chemin.encode(), cible.encode()
        tete, sep, reste = self.brut.partition(b'\n@@')
        lignes = tete.split(b'\n')
        for i, l in enumerate(lignes):       # les trois lignes qui nomment le fichier (la dernière n'a pas de fin de ligne dans l'en-tête)
            if l == b'diff --git a/' + a + b' b/' + a: lignes[i] = b'diff --git a/' + c + b' b/' + c
            elif l == b'--- a/' + a: lignes[i] = b'--- a/' + c
            elif l == b'+++ b/' + a: lignes[i] = b'+++ b/' + c
        tete = b'\n'.join(lignes)
        m = Morceau(tete + sep + reste); m.chemin = cible
        return m

    def lignes_reperes(self):
        """Des lignes du fichier d'origine assez longues pour le reconnaître ailleurs (contexte et lignes retirées)"""
        out = []
        for l in self.brut.split(b'\n'):
            if l[:1] in (b' ', b'-') and not l.startswith(b'---'):
                t = l[1:].decode('utf-8', 'replace')
                if len(t.strip()) >= 30 and t.strip() not in out: out.append(t.strip())
        return sorted(out, key=len, reverse=True)[:4]


def lire_patch(fichier):
    """(en-tête du courriel, morceaux) d'un patch de `git format-patch`"""
    brut = Path(fichier).read_bytes()
    fin = brut.rfind(b'\n-- \n')            # la signature de git, après le dernier morceau
    if fin > 0 and b'\ndiff --git ' not in brut[fin:]: brut = brut[:fin + 1]
    parts = re.split(rb'(?m)^(?=diff --git a/)', brut)
    return parts[0], [Morceau(p) for p in parts[1:]]


def infos_patch(fichier, tmp):
    """Auteur, date, message du commit que le patch décrit (git mailinfo)"""
    msg, rien = Path(tmp) / 'msg', Path(tmp) / 'diff'
    r = git('mailinfo', '-k', str(msg), str(rien), cwd=tmp, entree=Path(fichier).read_bytes())
    champs = dict(l.split(': ', 1) for l in r.stdout.splitlines() if ': ' in l)
    sujet = re.sub(r'^\[PATCH[^\]]*\]\s*', '', champs.get('Subject', Path(fichier).stem))
    corps = msg.read_text('utf-8', 'replace') if msg.exists() else ''
    return {'auteur': f"{champs.get('Author', 'Anas')} <{champs.get('Email', 'assosbs9@gmail.com')}>", 'date': champs.get('Date', ''),
            'sujet': sujet, 'message': sujet + ('\n\n' + corps.strip() + '\n' if corps.strip() else '\n')}


# ------------------------------------------------------------------------------------------------------------ règle c)

def _ajouts(base, moi):
    """Si `moi` n'est que `base` avec des éléments en plus : [(position dans base, éléments ajoutés)], sinon None"""
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, base, moi, autojunk=False).get_opcodes():
        if op == 'equal': continue
        if op != 'insert': return None
        out.append((i1, moi[j1:j2]))
    return out


def _placer(amont, base, ajouts, fin_ok=True):
    """Remet dans `amont` ce qui a été ajouté à `base`, chaque ajout après l'élément qui le précédait. None si la place est douteuse."""
    res = list(amont)
    for pos, quoi in sorted(ajouts, key=lambda x: -x[0]):
        nouveaux = [q for q in quoi if q not in res]
        if not nouveaux: continue                      # l'amont l'a déjà
        if len(nouveaux) != len(quoi): return None     # à moitié là : pas un ajout simple
        if not base: i = 0          # deux ajouts au même endroit : le mien reste collé à la ligne qui le précédait, ceux de l'amont suivent
        elif pos > 0 and res.count(base[pos - 1]) == 1: i = res.index(base[pos - 1]) + 1
        elif pos < len(base) and res.count(base[pos]) == 1: i = res.index(base[pos])
        elif pos == len(base) and fin_ok: i = len(res)
        else: return None
        res[i:i] = nouveaux
    return res


def _mots(ligne):
    """Une ligne en mots, la fin de ligne et un « \\ » de continuation mis de côté"""
    fin = ligne[len(ligne.rstrip('\r\n')):]; corps = ligne.rstrip('\r\n')
    suite = ''
    m = re.search(r'\s*\\$', corps)
    if m: suite = corps[m.start():]; corps = corps[:m.start()]
    debut = corps[:len(corps) - len(corps.lstrip())]
    return debut, corps.split(), suite + fin


def fusion_ajout(amont, base, moi):
    """Les trois versions d'un passage en conflit (listes de lignes) → le passage fusionné, ou None s'il faut un humain."""
    if moi == base: return amont
    if amont == base: return moi
    if amont == moi: return amont
    a = _ajouts(base, moi)
    if a is not None:                                   # des lignes en plus
        r = _placer(amont, base, a)
        if r is not None: return r
    if len(amont) == len(base) == len(moi):             # mêmes lignes, des mots en plus (une liste de fichiers sur une ligne)
        res = []
        for la, lb, lm in zip(amont, base, moi):
            if lm == lb: res.append(la); continue
            if la == lb: res.append(lm); continue
            da, ma, fa = _mots(la); _, mb, _ = _mots(lb); _, mm, _ = _mots(lm)
            aj = _ajouts(mb, mm)
            if aj is None or len(mb) < 2: return None
            r = _placer(ma, mb, aj)
            if r is None: return None
            res.append(da + ' '.join(r) + fa)
        return res
    return None


def _retouches(base, autre):
    return [(i1, i2, autre[j1:j2]) for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, base, autre, autojunk=False).get_opcodes() if op != 'equal']


def fusion(amont, base, moi):
    """Fusion à trois d'un passage, plus fine que celle de git (qui met en conflit deux lignes voisines changées chacune d'un côté) :
    les retouches qui ne touchent pas les mêmes lignes passent toutes ; là où elles se touchent, seul un ajout simple passe."""
    if moi == base: return amont
    if amont == base or amont == moi: return moi if amont == base else amont
    ra, rm = _retouches(base, amont), _retouches(base, moi)
    def touche(e, f):   # mêmes lignes, ou un ajout posé au bord ou au milieu de ce que l'autre a changé
        return max(e[0], f[0]) < min(e[1], f[1]) or (e[0] == e[1] and f[0] <= e[0] <= f[1]) or (f[0] == f[1] and e[0] <= f[0] <= e[1])
    groupes = []                                       # [début, fin, retouches de l'amont, retouches à moi]
    for cote, liste in ((2, ra), (3, rm)):
        for e in liste:
            g = [e[0], e[1], [], []]; g[cote].append(e); groupes.append(g)
    groupes.sort(key=lambda g: (g[0], g[1]))
    fus = []
    for g in groupes:
        if fus and any(touche(e, f) for e in g[2] + g[3] for f in fus[-1][2] + fus[-1][3]):
            fus[-1][1] = max(fus[-1][1], g[1]); fus[-1][0] = min(fus[-1][0], g[0]); fus[-1][2] += g[2]; fus[-1][3] += g[3]
        else: fus.append(g)
    def version(d, f, retouches):                      # base[d:f] avec les retouches d'un côté
        out, i = [], d
        for i1, i2, neuf in sorted(retouches):
            out += base[i:i1] + neuf; i = i2
        return out + base[i:f]
    res, i = [], 0
    for d, f, ea, em in fus:
        res += base[i:d]
        if not em: res += version(d, f, ea)
        elif not ea: res += version(d, f, em)
        else:
            r = fusion_ajout(version(d, f, ea), base[d:f], version(d, f, em))
            if r is None: return None
            res += r
        i = f
    return res + base[i:]


def resoudre_conflits(fichier):
    """Résout les conflits marqués (style diff3) d'un fichier quand chacun est un ajout simple. (réussi, premier conflit resté)"""
    try: lignes = Path(fichier).read_text('utf-8').splitlines(keepends=True)
    except (UnicodeDecodeError, OSError): return False, None
    out, i, n = [], 0, len(lignes)
    while i < n:
        if not lignes[i].startswith('<<<<<<< '): out.append(lignes[i]); i += 1; continue
        try:
            b = next(k for k in range(i + 1, n) if lignes[k].startswith('||||||| '))
            s = next(k for k in range(b + 1, n) if lignes[k].startswith('======='))
            f = next(k for k in range(s + 1, n) if lignes[k].startswith('>>>>>>> '))
        except StopIteration: return False, ''.join(lignes[i:i + 40])
        amont, base, moi = lignes[i + 1:b], lignes[b + 1:s], lignes[s + 1:f]
        r = fusion(amont, base, moi)
        if r is None: return False, {'amont': ''.join(amont), 'base': ''.join(base), 'moi': ''.join(moi)}
        out += r; i = f + 1
    Path(fichier).write_text(''.join(out), 'utf-8')
    return True, None


# ------------------------------------------------------------------------------------------------------- un morceau

class Arbre:
    def __init__(self, dossier, ancienne):
        self.d = Path(dossier); self.ancienne = ancienne; self._renommes = None

    def mode(self, chemin):
        r = git('ls-tree', 'HEAD', '--', chemin, cwd=self.d).stdout.split()
        return r[0] if r else None

    def cible_lien(self, chemin):
        """Le fichier que désigne le lien `chemin` de l'amont, s'il est dans le dépôt"""
        but = git('cat-file', 'blob', f'HEAD:{chemin}', cwd=self.d).stdout.strip()
        c = os.path.normpath(os.path.join(os.path.dirname(chemin), but))
        return c if not c.startswith('..') and self.mode(c) in ('100644', '100755') else None

    def renomme_en(self, chemin):
        """Le nouveau nom de `chemin` d'après git (comparaison de l'ancienne et de la nouvelle version)"""
        if self._renommes is None:
            self._renommes = {}
            if self.ancienne:
                r = git(*FUSION, 'diff', '-M50%', '--name-status', '--diff-filter=R', self.ancienne, 'HEAD', cwd=self.d)
                for l in r.stdout.splitlines():
                    p = l.split('\t')
                    if len(p) == 3: self._renommes.setdefault(p[1], []).append(p[2])
        c = self._renommes.get(chemin, [])
        return c[0] if len(c) == 1 else None

    def retrouve(self, m):
        """Le seul fichier de l'amont qui contient les lignes repères du morceau"""
        trouves = None
        for l in m.lignes_reperes():
            r = git('grep', '-lF', '-e', l, 'HEAD', cwd=self.d).stdout.splitlines()
            f = {x.split(':', 1)[1] for x in r if ':' in x}
            f = {x for x in f if self.mode(x) in ('100644', '100755')}
            trouves = f if trouves is None else trouves & f
            if not trouves: return None
        return next(iter(trouves)) if trouves and len(trouves) == 1 else None

    def conflits(self):
        return git('diff', '--name-only', '--diff-filter=U', cwd=self.d).stdout.split('\n')

    def remettre(self):
        git('reset', '--hard', '--quiet', 'HEAD', cwd=self.d); git('clean', '-fdq', cwd=self.d)

    def poser(self, m):
        """Applique un morceau tel quel (fusion à trois). 'propre', 'conflit' (marqueurs posés dans le fichier) ou 'refus'."""
        r = git(*FUSION, 'apply', '--3way', '--index', '--whitespace=nowarn', '-', cwd=self.d, entree=m.brut)
        if r.returncode == 0: return 'propre', r.stderr
        if m.chemin in self.conflits(): return 'conflit', r.stderr
        return 'refus', r.stderr

    def appliquer(self, m):
        """Applique un morceau, avec les réparations sûres. (état, explication) ; état 'propre', 'repare' ou 'echec'."""
        note, mode = None, self.mode(m.chemin)
        ailleurs = mode == '120000' or (mode is None and not m.cree)    # vu avant d'essayer : `git apply --3way` sur un lien abîme l'index
        if not ailleurs:
            etat, err = self.poser(m)
            if etat == 'propre': return 'propre', None
            if etat == 'refus': return 'echec', {'raison': "git refuse ce morceau sans dire où est le conflit", 'git': err.strip()[-600:]}
        else:
            if m.cree or m.renomme or m.binaire:
                return 'echec', {'raison': f"ce morceau renomme ou remplace {m.chemin}, que la nouvelle version a déplacé"}
            if mode == '120000':
                cible = self.cible_lien(m.chemin)
                note = f"{m.chemin} est devenu un lien : appliqué sur {cible}"
                if not cible: return 'echec', {'raison': f"{m.chemin} est devenu un lien dont la cible n'est pas un fichier du dépôt"}
            else:
                cible = self.renomme_en(m.chemin) or self.retrouve(m)
                note = f"{m.chemin} a été déplacé : appliqué sur {cible}"
                if not cible: return 'echec', {'raison': f"{m.chemin} n'existe plus dans la nouvelle version, et aucun fichier ne lui correspond sans doute possible"}
            if m.supprime: return 'echec', {'raison': f"ce morceau supprime {m.chemin}, que la nouvelle version a déplacé vers {cible}"}
            m = m.vers(cible)
            etat, err = self.poser(m)
            if etat == 'propre': return 'repare', note
            if etat == 'refus':     # pas de fusion à trois possible là-bas : patch, avec un peu de tolérance sur le contexte
                essai = subprocess.run(['patch', '-p1', '--fuzz=2', '--dry-run', '-N', '-s'], cwd=str(self.d), input=m.brut, capture_output=True, check=False)
                if essai.returncode: return 'echec', {'raison': note + ", mais le texte autour a trop changé", 'git': essai.stdout.decode('utf-8', 'replace')[-600:]}
                subprocess.run(['patch', '-p1', '--fuzz=2', '-N', '-s', '--no-backup-if-mismatch'], cwd=str(self.d), input=m.brut, capture_output=True, check=False)
                git('add', '--', m.chemin, cwd=self.d)
                return 'repare', note + " (contexte approché)"
        # conflit : les mêmes lignes ont changé des deux côtés
        fait, reste = resoudre_conflits(self.d / m.chemin)
        if not fait:
            return 'echec', {'raison': f"{m.chemin} : les mêmes lignes ont changé des deux côtés, et ce n'est pas un ajout simple", 'versions': reste, 'note': note}
        git('add', '--', m.chemin, cwd=self.d)
        return 'repare', (note + " ; " if note else '') + f"{m.chemin} : version de l'amont gardée, ajout remis dessus"


# -------------------------------------------------------------------------------------------------------- une série

def rejouer(arbre_dir, ancienne, patchs, rapport=None):
    """Applique les patchs dans l'ordre sur l'arbre (un commit par patch). → {'ok', 'appliques', 'repares', 'deja', 'echec'}"""
    arbre = Arbre(arbre_dir, ancienne)
    bilan = {'ok': True, 'appliques': 0, 'repares': [], 'deja': [], 'echec': None}
    tmp = tempfile.mkdtemp(prefix='serie-')
    try:
        for p in patchs:
            p = Path(p)
            avant = git('rev-parse', 'HEAD', cwd=arbre.d).stdout.strip()
            r = git(*FUSION, 'am', '-3', '--quiet', '--keep-cr', str(p), cwd=arbre.d)
            if r.returncode == 0:
                if git('rev-parse', 'HEAD^{tree}', cwd=arbre.d).stdout == git('rev-parse', avant + '^{tree}', cwd=arbre.d).stdout:
                    git('reset', '--hard', '--quiet', avant, cwd=arbre.d); bilan['deja'].append(p.name)     # la fusion n'a rien changé : l'amont a déjà ce changement
                else: bilan['appliques'] += 1
                continue
            git('am', '--abort', cwd=arbre.d); git('am', '--quit', cwd=arbre.d); arbre.remettre()   # --quit : l'état de am part même si --abort a refusé
            info = infos_patch(p, tmp); _, morceaux = lire_patch(p); notes = []
            for m in morceaux:
                etat, quoi = arbre.appliquer(m)
                if etat == 'echec':
                    arbre.remettre()
                    bilan['ok'] = False
                    bilan['echec'] = {'patch': p.name, 'sujet': info['sujet'], 'fichier': m.chemin, 'morceau': m.brut.decode('utf-8', 'replace')[:6000], **quoi}
                    if rapport: ecrire_rapport(rapport, bilan, arbre)
                    return bilan
                if etat == 'repare': notes.append(quoi)
            reste = [x for x in arbre.conflits() if x]
            if reste:       # ne devrait pas arriver : un morceau dit appliqué a laissé un conflit
                arbre.remettre(); bilan['ok'] = False
                bilan['echec'] = {'patch': p.name, 'sujet': info['sujet'], 'fichier': reste[0], 'raison': f"{reste[0]} : conflit que l'outil ne sait pas lire"}
                if rapport: ecrire_rapport(rapport, bilan, arbre)
                return bilan
            if git('diff', '--cached', '--quiet', cwd=arbre.d).returncode == 0:
                bilan['deja'].append(p.name); continue          # l'amont a déjà ce changement
            env = dict(os.environ, GIT_COMMITTER_NAME='Anas', GIT_COMMITTER_EMAIL='assosbs9@gmail.com')
            c = subprocess.run(['git', *IDENT, 'commit', '--quiet', '--author', info['auteur'], *(['--date', info['date']] if info['date'] else []), '-F', '-'],
                               cwd=str(arbre.d), input=info['message'].encode(), capture_output=True, env=env, check=False)
            if c.returncode:
                arbre.remettre(); bilan['ok'] = False
                bilan['echec'] = {'patch': p.name, 'sujet': info['sujet'], 'fichier': '', 'raison': 'le commit a échoué : ' + c.stderr.decode('utf-8', 'replace')[-300:]}
                if rapport: ecrire_rapport(rapport, bilan, arbre)
                return bilan
            bilan['appliques'] += 1; bilan['repares'].append({'patch': p.name, 'sujet': info['sujet'], 'notes': notes})
        return bilan
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def ecrire_rapport(fichier, bilan, arbre):
    e = bilan['echec']; v = e.get('versions')
    t = [f"Mise à jour en attente — {time.strftime('%d/%m/%Y %H:%M')}", '',
         "Un de tes changements ne s'applique plus sur la nouvelle version. Rien n'a été modifié : l'ancienne version et tes apps restent en place.", '',
         f"Changement : {e['sujet']}", f"Patch      : {e['patch']}", f"Fichier    : {e['fichier']}", f"Pourquoi   : {e['raison']}"]
    if e.get('note'): t.append(f"À savoir   : {e['note']}")
    t += ['', f"Déjà passés avant lui : {bilan['appliques']} changement(s), dont {len(bilan['repares'])} réparé(s) seul(s)."]
    if isinstance(v, dict):
        t += ['', '=' * 30 + " LA NOUVELLE VERSION (l'amont)", v['amont'].rstrip('\n'), '', '=' * 30 + ' AVANT (la version que tu avais modifiée)', v['base'].rstrip('\n'),
              '', '=' * 30 + ' TA VERSION', v['moi'].rstrip('\n')]
    else:
        if isinstance(v, str): t += ['', '=' * 30 + ' LE CONFLIT DANS LE FICHIER', v.rstrip('\n')]
        if e.get('fichier') and arbre.mode(e['fichier']) in ('100644', '100755') and arbre.ancienne:
            d = git('diff', '--stat', arbre.ancienne, 'HEAD', '--', e['fichier'], cwd=arbre.d).stdout.strip()
            if d: t += ['', '=' * 30 + " CE QUE L'AMONT A CHANGÉ DANS CE FICHIER", d]
        elif e.get('fichier') and arbre.mode(e['fichier']) == '120000':
            t += ['', f"Dans la nouvelle version, {e['fichier']} est un lien vers " + git('cat-file', 'blob', f"HEAD:{e['fichier']}", cwd=arbre.d).stdout.strip()]
    if e.get('git'): t += ['', '=' * 30 + ' CE QUE DIT GIT', e['git']]
    if e.get('morceau'): t += ['', '=' * 30 + ' TON CHANGEMENT (le morceau du patch)', e['morceau'].rstrip('\n')]
    t += ['', "Que faire : montre ce rapport à Claude. Il adaptera ce changement à la nouvelle version, puis la mise à jour repartira."]
    Path(fichier).parent.mkdir(parents=True, exist_ok=True)
    Path(fichier).write_text('\n'.join(t) + '\n', 'utf-8')


# ------------------------------------------------------------------------------------------------- MacNativeGames

def exporter(clone, base, dests):
    """La série du clone (base..HEAD) dans chaque dossier « mng » : patches/*.patch, patches/series, .upstream-ref"""
    tmp = Path(tempfile.mkdtemp(prefix='serie-export-'))
    try:
        ok('format-patch', '--quiet', '--full-index', '--binary', '--zero-commit', '--no-signature', '-o', str(tmp), f'{base}..HEAD', cwd=clone)
        noms = sorted(f.name for f in tmp.glob('*.patch'))
        for d in dests:
            d = Path(d); pd = d / 'patches'; pd.mkdir(parents=True, exist_ok=True)
            for vieux in pd.glob('*.patch'): vieux.unlink()
            for nfic in noms: shutil.copy2(tmp / nfic, pd / nfic)
            (pd / 'series').write_text(''.join(x + '\n' for x in noms), 'utf-8')
            (d / '.upstream-ref').write_text(base + '\n', 'utf-8')
        return noms
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def noter(racine, **etat):
    f = Path(racine) / 'log' / 'mng-maj.json'; f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps(dict(etat, quand=time.strftime('%Y-%m-%d %H:%M:%S')), ensure_ascii=False, indent=1) + '\n', 'utf-8')


def cmd_mng_maj(a):
    clone, racine = Path(a.clone), Path(a.racine)
    rapport = racine / 'log' / 'mng-maj-rapport.txt'
    if git('rev-parse', '--git-dir', cwd=clone).returncode: dire(f'ÉCHEC : {clone} n\'est pas un dépôt git'); return 1
    if (Path(ok('rev-parse', '--git-dir', cwd=clone)) / 'rebase-merge').exists() or git('rev-parse', '--verify', '--quiet', 'REBASE_HEAD', cwd=clone).returncode == 0:
        dire('ÉCHEC : un rebase est resté en cours dans MacNativeGames (dis-le à Claude)'); return 1
    avant = ok('rev-parse', 'HEAD', cwd=clone)
    if not a.sans_fetch:
        r = git('fetch', '--quiet', 'origin', cwd=clone)
        if r.returncode: dire('ÉCHEC : impossible de joindre le dépôt MacNativeGames (connexion ?)'); return 1
    vers = ok('rev-parse', '--verify', f'{a.vers}^{{commit}}', cwd=clone)
    base = ok('merge-base', 'HEAD', vers, cwd=clone)
    miens = ok('rev-list', '--count', f'{base}..HEAD', cwd=clone)
    # le dernier commit qui a construit des apps qui marchent (noté par mng-mettre-a-jour.command après une reconstruction réussie)
    bon = ''
    try: bon = (racine / 'constructions' / '.mng-version').read_text().strip()
    except OSError: pass
    if bon and git('cat-file', '-e', f'{bon}^{{commit}}', cwd=clone).returncode == 0: git('branch', '--force', 'dernier-bon', bon, cwd=clone)
    else: bon = ''
    if base == vers:
        dire(f'MacNativeGames : rien de nouveau ({vers[:8]}, {miens} changements à toi)')
        etat = {}
        try: etat = json.loads((racine / 'log' / 'mng-maj.json').read_text())
        except (OSError, ValueError): pass
        if etat.get('etat') == 'attente': noter(racine, etat='ok', version=vers, dernier_bon=bon)
        return 0
    sauvegarde = 'sauvegarde-' + time.strftime('%Y%m%d-%H%M%S')
    ok('branch', sauvegarde, 'HEAD', cwd=clone)
    dire(f'MacNativeGames : {base[:8]} → {vers[:8]}, {miens} changements à toi à rejouer (sauvegarde : branche {sauvegarde})')
    travail = racine / f'.mng-maj-{os.getpid()}'
    series = Path(tempfile.mkdtemp(prefix='serie-mng-'))
    try:
        ok('format-patch', '--quiet', '--full-index', '--binary', '-o', str(series), f'{base}..HEAD', cwd=clone)
        patchs = sorted(series.glob('*.patch'))
        git('worktree', 'prune', cwd=clone)
        ok('worktree', 'add', '--quiet', '--detach', str(travail), vers, cwd=clone)
        bilan = rejouer(travail, base, patchs, rapport)
        if not bilan['ok']:
            e = bilan['echec']
            noter(racine, etat='attente', patch=e['patch'], sujet=e['sujet'], fichier=e['fichier'], raison=e['raison'], rapport=str(rapport),
                  version_gardee=avant, version_voulue=vers, sauvegarde=sauvegarde, dernier_bon=bon)
            git('branch', '-D', sauvegarde, cwd=clone)      # rien n'a bougé : la sauvegarde ne sert à rien
            dire(f"EN ATTENTE : « {e['sujet']} » ne s'applique plus ({e['fichier']}) — {e['raison']}")
            dire(f'Version {avant[:8]} gardée, rien n\'a été modifié. Rapport : {rapport}')
            return 3
        bout = ok('rev-parse', 'HEAD', cwd=travail)
        for r in bilan['repares']: dire(f"  réparé seul : {r['sujet']} — " + ' ; '.join(r['notes']))
        for d in bilan['deja']: dire(f'  déjà dans la nouvelle version, retiré de la série : {d}')
        # tout s'est appliqué : seulement maintenant, le clone passe à la nouvelle version
        sale = bool(git('status', '--porcelain', '--untracked-files=no', cwd=clone).stdout.strip())
        if sale: ok('stash', 'push', '--quiet', '-m', f'avant {sauvegarde}', cwd=clone)
        branche = git('symbolic-ref', '--quiet', '--short', 'HEAD', cwd=clone).stdout.strip() or 'main'
        r = git('checkout', '--quiet', '-B', branche, bout, cwd=clone)
        if r.returncode:
            if sale: git('stash', 'pop', '--quiet', cwd=clone)
            dire('ÉCHEC : le clone n\'a pas pu passer à la nouvelle version (' + (r.stderr.strip().splitlines() or ['?'])[-1] + f') ; version {avant[:8]} gardée'); return 1
        if sale and git('stash', 'pop', '--quiet', cwd=clone).returncode:
            dire('  tes modifications non enregistrées sont restées de côté (git stash list) : elles ne s\'appliquaient plus telles quelles')
        dests = [racine / 'moteur' / 'mng'] + [Path(d) / 'moteur' / 'mng' for d in a.depot if (Path(d) / 'moteur' / 'mng').is_dir()]
        noms = exporter(clone, vers, dests)
        noter(racine, etat='ok', version=bout, amont=vers, patchs=len(noms), repares=len(bilan['repares']), sauvegarde=sauvegarde, dernier_bon=bon)
        try: rapport.unlink()
        except OSError: pass
        dire(f'MacNativeGames : {len(noms)} changements rejoués sur {vers[:8]}' + (f", dont {len(bilan['repares'])} réparés seuls" if bilan['repares'] else '') +
             ' ; série mise à jour dans ' + ', '.join(str(d) for d in dests))
        return 0
    except RuntimeError as x:
        dire(f'ÉCHEC : {x} ; version {avant[:8]} gardée'); return 1
    finally:
        git('worktree', 'remove', '--force', str(travail), cwd=clone); shutil.rmtree(travail, ignore_errors=True); git('worktree', 'prune', cwd=clone)
        shutil.rmtree(series, ignore_errors=True)


def cmd_mng_exporter(a):
    clone = Path(a.clone)
    base = ok('merge-base', 'HEAD', a.vers, cwd=clone)
    noms = exporter(clone, base, a.dest)
    dire(f'{len(noms)} patchs sur {base[:8]} écrits dans ' + ', '.join(a.dest))
    return 0


def cmd_rejouer(a):
    bilan = rejouer(a.arbre, a.ancienne, a.patchs, a.rapport)
    for r in bilan['repares']: dire(f"réparé seul : {r['patch']} — " + ' ; '.join(r['notes']))
    for d in bilan['deja']: dire(f'déjà dans la nouvelle version : {d}')
    if not bilan['ok']:
        e = bilan['echec']; dire(f"EN ATTENTE : {e['patch']} ({e['fichier']}) — {e['raison']}"); return 3
    dire(f"{bilan['appliques']} patchs appliqués")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('mng-maj'); p.add_argument('--clone', required=True); p.add_argument('--racine', required=True)
    p.add_argument('--vers', default='origin/main'); p.add_argument('--sans-fetch', action='store_true'); p.add_argument('--depot', action='append', default=[])
    p.set_defaults(f=cmd_mng_maj)
    p = sp.add_parser('mng-exporter'); p.add_argument('--clone', required=True); p.add_argument('--dest', action='append', required=True)
    p.add_argument('--vers', default='origin/main'); p.set_defaults(f=cmd_mng_exporter)
    p = sp.add_parser('rejouer'); p.add_argument('--arbre', required=True); p.add_argument('--ancienne', default=''); p.add_argument('--rapport')
    p.add_argument('patchs', nargs='+'); p.set_defaults(f=cmd_rejouer)
    a = ap.parse_args(argv)
    try: return a.f(a)
    except RuntimeError as x:
        dire(f'ÉCHEC : {x}'); return 1


if __name__ == '__main__':
    sys.exit(main())
