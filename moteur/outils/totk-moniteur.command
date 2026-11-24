#!/bin/bash
# Moniteur TOTK Online : en direct, ce qui compte pendant que tu joues — connexion au serveur, joueurs, sauvegardes envoyées,
# plantage du jeu (avec notification), arrêt du serveur. Laisse la fenêtre ouverte à côté ; Ctrl+C pour fermer.
HR="${HOME_RACINE:-$HOME/Library/Application Support/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
GAME_LOG="$HOME/Library/Logs/MacNativeGames/totk.log"; SRV_LOG="$HR/log/totk-server.log"; SALON_LOG="$HR/log/salon.log"
B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'
notif() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 & }
etat() {
  printf '\e]0;Moniteur TOTK Online\a'
  local jeu srv
  pgrep -x TOTK >/dev/null && jeu="${G}en cours${N}" || jeu="${D}fermé${N}"
  /usr/sbin/lsof -nP -iTCP:10014 -sTCP:LISTEN >/dev/null 2>&1 && srv="${G}en marche (port 10014)${N}" || srv="${D}arrêté${N}"
  echo "${B}TOTK Online${N} — jeu : $jeu — serveur : $srv — $(date '+%H:%M:%S')"
}
clear; echo "${B}Moniteur TOTK Online${N}  ${D}(Ctrl+C pour fermer)${N}"; etat; echo
touch "$GAME_LOG" "$SRV_LOG" 2>/dev/null
saves=0
# Les trois journaux en direct, filtrés et mis en forme ; tail -F suit aussi le journal du jeu quand il est recréé à chaque lancement
tail -n 0 -F "$SRV_LOG" "$GAME_LOG" "$SALON_LOG" 2>/dev/null | while IFS= read -r l; do
  t="${D}$(date '+%H:%M:%S')${N}"
  case "$l" in
    "==> "*) ;;
    *"TOTKServer: Initialized successfully"*) echo "$t ${G}● serveur prêt${N}";;
    *"TOTKServer: "*" connected"*) p="${l#*TOTKServer: }"; echo "$t ${G}● ${p% connected} connecté au serveur${N}"; notif "TOTK Online" "${p% connected} connecté";;
    *"TOTKServer: "*" left"*) p="${l#*TOTKServer: }"; echo "$t ${Y}● ${p% left} a quitté le serveur${N}";;
    *"threw exception"*|*"Exception"*) echo "$t ${R}▲ serveur : ${l:0:140}${N}";;
    *"SaveServer: Applying save request"*) saves=$((saves+1)); [ $((saves % 25)) -eq 1 ] && echo "$t ${C}↑ sauvegarde envoyée au serveur (${saves} changements) : ${l##*: }${N}";;
    *"SyncedActorServer: Adding client"*) echo "$t ${C}● monde partagé rejoint${N}";;
    *"[totk-boot]"*) echo "$t ${D}démarrage : ${l#*] }${N}";;
    *"[totk-online] connect:"*|*"[totk-online] recv:"*"reset"*|*"Broken pipe"*) echo "$t ${R}▲ réseau : ${l#*] }${N}";;
    *"[totk] signal="*) echo "$t ${R}${B}✖ LE JEU A PLANTÉ${N} ${R}(${l#*signal=}) — dis « crash » à Claude${N}"; notif "TOTK Online" "Le jeu a planté";;
    *"Fin de session Tears"*) echo "$t ${Y}■ partie terminée${N}"; sleep 1; etat;;
    *"TOTK Online : serveur lancé"*) echo "$t ${D}lancement du serveur…${N}";;
    *"TOTK Online : serveur arrêté"*) echo "$t ${D}serveur arrêté par le Salon${N}";;
    *"Tears of the Kingdom : lancé"*) echo; etat; echo "$t ${G}▶ TOTK lancé${N}";;
  esac
done
