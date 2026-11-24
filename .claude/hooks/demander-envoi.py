#!/usr/bin/env python3
"""Hook Stop de Claude Code pour le dépôt Home.

Quand Claude a fini de répondre et que le dépôt contient des modifications pas encore envoyées sur GitHub (fichiers modifiés,
ou commits pas encore poussés), il est renvoyé au travail avec une consigne : demander à Anas s'il veut envoyer la mise à jour.
La question n'est posée qu'une fois par état du dépôt : l'empreinte de l'état est gardée dans .git/home-envoi-demande, et tant
que rien ne change (par exemple Anas a répondu « garder en local »), le hook laisse Claude s'arrêter.
Le hook ne bloque jamais sur une erreur : sans git, sans dépôt ou sans branche suivie, il laisse passer."""
import hashlib
import json
import os
import subprocess
import sys


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True, timeout=20)
    return r.stdout if r.returncode == 0 else None


def prochaine_version():
    """La dernière release (tag vX.Y.Z le plus haut connu localement), avec le dernier nombre augmenté de 1."""
    tags = [t.strip() for t in (git("tag", "--list", "v*") or "").splitlines() if t.strip()]
    def cle(t):
        try:
            return tuple(int(x) for x in t[1:].split("."))
        except ValueError:
            return (-1,)
    tags = [t for t in tags if cle(t) != (-1,)]
    if not tags:   # clone superficiel (onglet Code dans le cloud) : les tags ne sont pas là, on demande la dernière release à GitHub
        try:
            r = subprocess.run(["gh", "api", "repos/amas-cd/home/releases", "--jq", ".[0].tag_name"], capture_output=True, text=True, timeout=15)
            t = r.stdout.strip() if r.returncode == 0 else ""
            if t.startswith("v") and cle(t) != (-1,):
                tags = [t]
        except Exception:
            pass
    if not tags:
        return "0.1.0"
    a = list(max(tags, key=cle)[1:].split("."))
    a[-1] = str(int(a[-1]) + 1)
    return ".".join(a)


def main():
    try:
        entree = json.load(sys.stdin)
    except Exception:
        entree = {}
    if entree.get("stop_hook_active"):
        return 0   # Claude continue déjà à cause de ce hook : ne pas boucler
    racine = os.environ.get("CLAUDE_PROJECT_DIR") or entree.get("cwd") or os.getcwd()
    try:
        os.chdir(racine)
        if git("rev-parse", "--is-inside-work-tree") is None:
            return 0
        statut = git("status", "--porcelain") or ""
        diff = git("diff", "HEAD") or ""
        # commits pas encore sur GitHub : par rapport à la branche suivie, sinon (branche de session jamais poussée) ceux
        # qu'aucune branche distante connue ne contient
        distantes = (git("for-each-ref", "--count=1", "refs/remotes") or "").strip()   # aucune branche distante connue : on ne peut pas savoir
        en_avance = (git("rev-list", "--count", "@{u}..HEAD") or (distantes and git("rev-list", "--count", "HEAD", "--not", "--remotes")) or "0").strip()
        if not statut.strip() and en_avance in ("", "0"):
            return 0   # rien à envoyer
        tete = (git("rev-parse", "HEAD") or "").strip()
        empreinte = hashlib.sha256("\n".join([tete, statut, diff, en_avance]).encode()).hexdigest()
        git_dir = (git("rev-parse", "--git-dir") or ".git").strip()
        memo = os.path.join(git_dir, "home-envoi-demande")
        try:
            if open(memo).read().strip() == empreinte:
                return 0   # déjà demandé pour cet état exact
        except OSError:
            pass
        with open(memo, "w") as f:
            f.write(empreinte)
    except Exception:
        return 0
    fichiers = len([l for l in statut.splitlines() if l.strip()])
    resume = []
    if fichiers:
        resume.append(f"{fichiers} fichier(s) modifié(s) pas encore commité(s)")
    if en_avance not in ("", "0"):
        resume.append(f"{en_avance} commit(s) pas encore poussé(s) sur GitHub")
    raison = (
        "Le dépôt Home a des modifications pas encore envoyées (" + ", ".join(resume) + "). "
        "Si ton travail est fini, demande maintenant à Anas, avec AskUserQuestion, s'il veut envoyer la mise à jour, "
        f"en proposant : « Publier la release {prochaine_version()} » (recommandé si l'app change), « Pousser sans release », "
        "« Garder en local ». Rappelle en une phrase ce qui a changé. Puis suis la section « Envoyer une mise à jour » de CLAUDE.md. "
        "Si ton travail n'est pas fini (tu attends une réponse d'Anas sur autre chose), ne pose pas cette question maintenant : "
        "termine simplement ta réponse, elle sera posée à la fin."
    )
    print(json.dumps({"decision": "block", "reason": raison}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
