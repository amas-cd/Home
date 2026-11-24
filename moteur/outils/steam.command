#!/bin/bash
# Steam dans Home (moteur/bin/home-steam, compilé par preparer-steam.command) :
#   steam.command etat | connexion | deconnexion | bibliotheque | installer APP | jeux | lancer APP | plan APP DOSSIER
HR="${HOME_RACINE:-$HOME/Library/Application Support/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
B="$HR/moteur/bin/home-steam"
export HOME_RACINE="$HR"
[ -x "$B" ] || { echo '{"absent": true}'; exit 4; }
exec "$B" "$@"
