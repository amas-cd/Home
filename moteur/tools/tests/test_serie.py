"""tools/serie.py : les réparations sûres, sur de petits dépôts fabriqués ici (python3 -m unittest tools.tests.test_serie)."""
import importlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
S = importlib.import_module('serie')


def g(*a, cwd):
    return subprocess.run(['git', *S.IDENT, *a], cwd=str(cwd), capture_output=True, text=True, check=True).stdout.strip()


class Depot:
    """Un amont (base → nouvelle version) et un changement à moi fait sur la base"""
    def __init__(self, tmp, base, amont, moi):
        self.d = Path(tmp) / 'depot'; self.d.mkdir()
        g('init', '-q', '-b', 'main', cwd=self.d)
        self.ecrire(base); self.base = self.commit('base')
        self.ecrire(moi); self.commit('mon changement')
        self.patchs = Path(tmp) / 'patchs'
        g('format-patch', '-q', '--full-index', '--binary', '-o', str(self.patchs), f'{self.base}..HEAD', cwd=self.d)
        g('checkout', '-q', '-B', 'amont', self.base, cwd=self.d)
        self.ecrire(amont); self.nouvelle = self.commit('amont')
        self.rapport = Path(tmp) / 'rapport.txt'

    def ecrire(self, fichiers):
        for nom, contenu in fichiers.items():
            f = self.d / nom
            if f.is_symlink() or f.exists(): f.unlink()
            if contenu is None: continue
            f.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(contenu, tuple): os.symlink(contenu[0], f)      # ('cible',) : un lien
            else: f.write_text(contenu)

    def commit(self, message):
        g('add', '-A', cwd=self.d); g('commit', '-q', '-m', message, cwd=self.d)
        return g('rev-parse', 'HEAD', cwd=self.d)

    def rejouer(self):
        return S.rejouer(self.d, self.base, sorted(self.patchs.glob('*.patch')), self.rapport)

    def lire(self, nom):
        return (self.d / nom).read_text()


CODE = ''.join(f'ligne {i}\n' for i in range(1, 21))


class Reparations(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='test-serie-')
        self.addCleanup(lambda: __import__('shutil').rmtree(self.tmp, ignore_errors=True))

    def test_propre(self):
        d = Depot(self.tmp, {'a.c': CODE}, {'a.c': CODE.replace('ligne 18\n', 'ligne 18 amont\n')}, {'a.c': CODE.replace('ligne 3\n', 'ligne 3 moi\n')})
        b = d.rejouer()
        self.assertTrue(b['ok']); self.assertEqual(b['repares'], [])
        self.assertIn('ligne 3 moi', d.lire('a.c')); self.assertIn('ligne 18 amont', d.lire('a.c'))

    def test_a_fichier_devenu_un_lien(self):
        d = Depot(self.tmp, {'jeu/runtime/a.c': CODE},
                  {'jeu/runtime/a.c': ('../../shared/runtime/a.c',), 'shared/runtime/a.c': CODE.replace('ligne 18\n', 'ligne 18 amont\n')},
                  {'jeu/runtime/a.c': CODE.replace('ligne 3\n', 'ligne 3 moi\n')})
        b = d.rejouer()
        self.assertTrue(b['ok'], b['echec']); self.assertEqual(len(b['repares']), 1)
        self.assertTrue((d.d / 'jeu/runtime/a.c').is_symlink())                  # le lien de l'amont reste un lien
        self.assertIn('ligne 3 moi', d.lire('shared/runtime/a.c')); self.assertIn('ligne 18 amont', d.lire('shared/runtime/a.c'))

    def test_b_fichier_deplace(self):
        d = Depot(self.tmp, {'ancien/a.c': CODE}, {'ancien/a.c': None, 'nouveau/b.c': CODE.replace('ligne 18\n', 'ligne 18 amont\n')},
                  {'ancien/a.c': CODE.replace('ligne 3\n', 'ligne 3 moi\n')})
        b = d.rejouer()
        self.assertTrue(b['ok'], b['echec'])
        self.assertFalse((d.d / 'ancien/a.c').exists()); self.assertIn('ligne 3 moi', d.lire('nouveau/b.c'))

    def test_c_liste_sur_une_ligne(self):
        base = 'SRCS = a.c b.c c.c\nall: $(SRCS)\n'
        d = Depot(self.tmp, {'Makefile': base}, {'Makefile': base.replace('b.c c.c', 'b.c c.c amont.c')}, {'Makefile': base.replace('a.c b.c', 'a.c moi.c b.c')})
        b = d.rejouer()
        self.assertTrue(b['ok'], b['echec'])
        self.assertEqual(d.lire('Makefile').splitlines()[0], 'SRCS = a.c moi.c b.c c.c amont.c')

    def test_c_lignes_voisines(self):
        base = 'un(a)\ndeux(b)\n'
        d = Depot(self.tmp, {'x.py': base}, {'x.py': 'un(a)\ndeux(b,\n     amont)\n'}, {'x.py': 'un(a, moi)\ndeux(b)\n'})
        b = d.rejouer()
        self.assertTrue(b['ok'], b['echec']); self.assertEqual(d.lire('x.py'), 'un(a, moi)\ndeux(b,\n     amont)\n')

    def test_c_deux_ajouts_au_meme_endroit(self):
        base = 'debut()\nfin()\n'
        d = Depot(self.tmp, {'x.c': base}, {'x.c': 'debut()\namont()\nfin()\n'}, {'x.c': 'debut()\nmoi()\nfin()\n'})
        b = d.rejouer()
        self.assertTrue(b['ok'], b['echec']); self.assertEqual(d.lire('x.c'), 'debut()\nmoi()\namont()\nfin()\n')   # le mien reste collé à sa ligne d'avant

    def test_pas_sur_on_s_arrete_sans_rien_toucher(self):
        base = 'valeur = calcule(a)\n'
        d = Depot(self.tmp, {'x.py': base}, {'x.py': 'valeur = calcule(a) if a else 0\n'}, {'x.py': 'valeur = autre(a, b)\n'})
        b = d.rejouer()
        self.assertFalse(b['ok']); self.assertEqual(b['echec']['fichier'], 'x.py')
        self.assertEqual(g('rev-parse', 'HEAD', cwd=d.d), d.nouvelle)            # aucun commit en plus
        self.assertEqual(g('status', '--porcelain', cwd=d.d), '')               # l'arbre est propre
        self.assertIn('TA VERSION', d.rapport.read_text()); self.assertIn("LA NOUVELLE VERSION", d.rapport.read_text())

    def test_deja_dans_l_amont(self):
        moi = CODE.replace('ligne 3\n', 'ligne 3 moi\n')
        d = Depot(self.tmp, {'a.c': CODE}, {'a.c': moi}, {'a.c': moi})
        b = d.rejouer()
        self.assertTrue(b['ok']); self.assertEqual(b['appliques'], 0)


if __name__ == '__main__':
    unittest.main()
