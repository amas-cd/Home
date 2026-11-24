#!/bin/bash
# Les jeux PC de Home sans Obelisk (moteur/pc/pc.py : moteur Voile, compte Epic, bibliothèque, installation, lancement), avec le
# Python qui a Legendary : celui de moteur/.venv-pc (créé par « pc.command preparer »), sinon celui du Mac.
#   pc.command etat | preparer | connexion CODE | bibliotheque | installer APP | lancer APP [--essai]
HR="${HOME_RACINE:-/Applications/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
export HOME_RACINE="$HR"
PY="$HR/moteur/.venv-pc/bin/python3"; [ -x "$PY" ] || PY=/usr/bin/python3
exec "$PY" -W ignore "$HR/moteur/pc/pc.py" "$@"
