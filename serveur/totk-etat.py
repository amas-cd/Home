#!/usr/bin/env python3
# Page d'état d'un serveur TOTK Online : la liste des joueurs connectés, en lecture seule.
#
# Pourquoi : sur Mac, Home lit le journal du serveur par SSH avec la clé de celui qui le tient. Cette clé ne se partage pas : les
# amis qui jouent depuis un PC n'ont donc pas la liste. Ce petit service la publie à leur place. Il ne donne que des pseudos, rien
# d'autre du journal, et n'accepte aucune commande.
#
# Home pour Windows la lit sur le port juste après celui du jeu : serveur sur 10014 → page d'état sur 10015.
#   GET /joueurs  →  {"joueurs": ["…", "…"]}
#
# Installation sur le serveur (une fois), à faire par celui qui le tient :
#   1. copier ce fichier dans /opt/totk/totk-etat.py
#   2. créer /etc/systemd/system/totk-etat.service :
#        [Unit]
#        Description=Page d'etat TOTK Online (joueurs connectes)
#        After=totk.service
#        [Service]
#        ExecStart=/usr/bin/python3 /opt/totk/totk-etat.py --port 10015 --service totk
#        User=<l'utilisateur du serveur>
#        Restart=always
#        [Install]
#        WantedBy=multi-user.target
#   3. sudo systemctl daemon-reload && sudo systemctl enable --now totk-etat
#   4. ouvrir le port TCP 10015 en entrée (pare-feu du serveur et de l'hébergeur)
# L'utilisateur doit pouvoir lire le journal (groupe « adm » ou « systemd-journal »).
#
# Essai sans serveur : python3 totk-etat.py --journal un-fichier.log --port 10015
import argparse, json, re, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONNECTE = re.compile(r"TOTKServer: (.+) connected$")
PARTI = re.compile(r"TOTKServer: (.+) left$")

def joueurs(lignes):
    """Les mêmes règles que Home sur Mac : « X connected », « X left », et tout repart de zéro quand le serveur redémarre."""
    la = []
    for l in lignes:
        l = l.strip()
        m = CONNECTE.search(l)
        if m:
            if m.group(1) not in la: la.append(m.group(1))
            continue
        m = PARTI.search(l)
        if m:
            if m.group(1) in la: la.remove(m.group(1))
        elif "TOTKServer: Initialized" in l:
            la = []
    return la

def lire(args):
    if args.journal:
        with open(args.journal, encoding="utf-8", errors="replace") as f: return f.read().splitlines()[-20000:]
    r = subprocess.run(["journalctl", "-u", args.service, "-o", "cat", "--no-pager", "-n", "20000"], capture_output=True, text=True, timeout=10)
    return r.stdout.splitlines()

def main():
    p = argparse.ArgumentParser(description="Page d'état TOTK Online : les joueurs connectés")
    p.add_argument("--port", type=int, default=10015)
    p.add_argument("--service", default="totk", help="le service systemd du serveur")
    p.add_argument("--journal", help="lire ce fichier au lieu de journalctl (essais)")
    args = p.parse_args()
    cache = {"quand": 0.0, "corps": b'{"joueurs": []}'}

    class Page(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.split("?")[0].rstrip("/") != "/joueurs": self.send_error(404); return
            if time.time() - cache["quand"] > 3:   # au plus une lecture du journal toutes les 3 s, quel que soit le nombre de demandes
                try: cache["corps"] = json.dumps({"joueurs": joueurs(lire(args))[:64]}, ensure_ascii=False).encode()
                except Exception: pass
                cache["quand"] = time.time()
            self.send_response(200); self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(cache["corps"]))); self.send_header("Cache-Control", "no-store"); self.end_headers()
            self.wfile.write(cache["corps"])
        def log_message(self, *a): pass   # pas de journal des visites

    ThreadingHTTPServer(("0.0.0.0", args.port), Page).serve_forever()

if __name__ == "__main__":
    main()
