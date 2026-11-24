#!/bin/bash
# Home recompilé depuis sa source (moteur/salon) et réinstallé dans /Applications/Home.app, puis rouvert — seulement si la
# source a changé depuis la version installée (son empreinte est dans l'app) ; sinon « Home est déjà à jour ».
# Lancé par Home lui-même : il se ferme pendant l'installation, la sortie vers lui est alors coupée (SIGPIPE ignoré).
HR="${HOME_RACINE:-/Applications/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
trap '' PIPE
S="$HR/moteur/salon"
neuf="$(cat "$S/main.swift" "$S/veille.swift" "$S/salon-construire.command" 2>/dev/null | shasum -a 256 | cut -c1-64)"
if [ -z "$HOME_FORCER" ] && [ "$neuf" = "$(cat /Applications/Home.app/Contents/Resources/source.sha 2>/dev/null)" ]; then
  echo "Home est déjà à jour"; exit 0
fi
exec /bin/bash "$S/salon-construire.command"
