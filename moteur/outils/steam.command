#!/bin/bash
# Steam dans Home (moteur/bin/home-steam, compilé par preparer-steam.command) :
#   steam.command etat | connexion | deconnexion | bibliotheque | installer APP DOSSIER | plan APP DOSSIER
HR="${HOME_RACINE:-/Applications/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
B="$HR/moteur/bin/home-steam"
[ -x "$B" ] || { echo '{"absent": true}'; exit 4; }
exec "$B" "$@"
