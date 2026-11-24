#!/bin/bash
# mng-combiner-mods.sh <dossier combiné> <mod>... : les mods de code activés dans Home réunis en un seul dossier de mod pour
# MacNativeGames (build_app.py --mod n'en prend qu'un) — exefs/<mod>/ : leurs correctifs de main (IPS, IPS32, pchtxt ;
# mod_exefs.py les lit tous et refuse deux mods qui changent les mêmes octets), romfs/ : leurs fichiers, le dernier gagne.
# Leurs modules de code (exefs/subsdkN, des NSO) sont listés dans <dossier combiné>/modules.txt, un par ligne, pour
# build_app.py --mod-module. Affiche le dossier combiné s'il contient des correctifs ou des fichiers, rien sinon.
HR="${HOME_RACINE:-/Applications/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
D="${1%/}"; shift
rm -rf "$D"; mkdir -p "$D/exefs"; : > "$D/modules.txt"
for m in "$@"; do
  [ -d "$m/exefs" ] || continue
  n="$(printf "%s" "$(basename "$m")" | tr -c "A-Za-z0-9._-" "_")"
  for f in "$m"/exefs/*; do
    [ -f "$f" ] || continue
    if [ "$(head -c 4 "$f" 2>/dev/null)" = "NSO0" ]; then
      case "$(basename "$f")" in main|sdk|rtld) echo "note : $n/exefs/$(basename "$f") remplace un module du jeu : ignoré";; *) printf '%s\n' "$f" >> "$D/modules.txt";; esac
    else mkdir -p "$D/exefs/$n"; cp "$f" "$D/exefs/$n/"; fi
  done
  [ -d "$m/romfs" ] && { mkdir -p "$D/romfs"; rsync -a --exclude='.DS_Store' "$m/romfs/" "$D/romfs/"; }
done
if [ -n "$(find "$D/exefs" -type f 2>/dev/null | head -1)" ] || [ -d "$D/romfs" ]; then echo "$D"; else rmdir "$D/exefs" 2>/dev/null; fi
exit 0
