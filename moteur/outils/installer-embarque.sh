#!/bin/bash
# installer-embarque.sh <dossier moteur embarqué dans Home.app> : installe ou met à jour, dans <Home>/moteur, ce que l'app
# embarque (Contents/Resources/moteur) — les scripts, les outils, la liste de compatibilité, la source de Home, et la
# version figée des moteurs (nxnative : .upstream-ref + patches ; MacNativeGames : mng/). Home le lance tout seul au
# démarrage quand l'empreinte de ce qu'il embarque n'est pas celle déjà installée : c'est ce qui le rend autonome (une
# release téléchargée apporte ses scripts avec elle).
# Rien de propre à ce Mac n'est touché : recettes, journaux, clés, constructions, engine/, MacNativeGames/ restent.
# La version figée de nxnative n'est remplacée que si ce Mac a encore celle que Home avait installée : un moteur mis à jour
# ici (Mises à jour → Moteurs) ou modifié à la main est gardé.
HR="${HOME_RACINE:-/Applications/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
SRC="${1%/}"; M="$HR/moteur"
[ -d "$SRC/outils" ] || { echo "ÉCHEC : pas de moteur embarqué dans $SRC"; exit 1; }
mkdir -p "$M" "$HR/log" "$HR/constructions" "$JX" 2>/dev/null || { echo "ÉCHEC : impossible de créer $M (dossier protégé ? Choisis-en un autre dans Application Support/Salon/dossiers.json)"; exit 1; }
EX=(--exclude .DS_Store --exclude __pycache__)
for d in outils tools obelisk pc compat mng steam salon; do
  [ -d "$SRC/$d" ] && { mkdir -p "$M/$d" && rsync -a "${EX[@]}" "$SRC/$d/" "$M/$d/" || { echo "ÉCHEC : copie de $d"; exit 1; }; }
done
[ -f "$SRC/README.md" ] && cp "$SRC/README.md" "$M/README.md"
chmod +x "$M"/outils/*.command "$M"/outils/*.sh "$M"/salon/*.command 2>/dev/null

# nxnative : le commit figé et la série de patchs
empreinte() { cat "$1/.upstream-ref" "$1/patches/series" "$1"/patches/*.patch 2>/dev/null | shasum -a 256 | cut -c1-64; }
if [ -f "$SRC/.upstream-ref" ] && [ -d "$SRC/patches" ]; then
  neuf="$(empreinte "$SRC")"; ici="$(empreinte "$M")"
  if [ ! -f "$M/.upstream-ref" ] || [ "$ici" = "$(cat "$M/.moteur-embarque" 2>/dev/null)" ]; then
    # jamais installé, ou resté tel que Home l'avait posé : la version de l'app (les patchs retirés de la série partent aussi)
    mkdir -p "$M/patches" && rsync -a --delete "${EX[@]}" "$SRC/patches/" "$M/patches/" && cp "$SRC/.upstream-ref" "$M/.upstream-ref" && printf '%s\n' "$neuf" > "$M/.moteur-embarque"
    [ "$ici" != "$neuf" ] && echo "nxnative : version figée $(cut -c1-12 "$M/.upstream-ref") installée (moteur refait à la prochaine construction)"
  elif [ "$ici" = "$neuf" ]; then printf '%s\n' "$neuf" > "$M/.moteur-embarque"   # identique à celle de l'app : suivra les prochaines
  else echo "nxnative : la version de ce Mac ($(cut -c1-12 "$M/.upstream-ref")) est gardée, elle a été mise à jour ou modifiée ici"; fi
fi
[ -f "$SRC/.empreinte" ] && cp "$SRC/.empreinte" "$M/.embarque"
echo "Moteur de Home installé dans $M"
