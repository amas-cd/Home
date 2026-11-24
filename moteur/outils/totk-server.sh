#!/bin/sh
# Serveur TOTK Online (Kirbymimi), lancé par Home avant le jeu, puis indépendant : quitter ou relancer TOTK ne l'arrête plus,
# donc les joueurs connectés par Tailscale restent connectés (le mod ne se reconnecte pas tout seul).
# Il s'arrête quand Tailscale est fermé ou déconnecté (plus d'adresse 100.64.0.0/10 sur le Mac pendant 30 s), une fois TOTK
# quitté : en solo sans Tailscale, il tourne le temps de la partie. Ne fait rien si un serveur écoute déjà sur le port 10014.
SRV="/Applications/Home/mods/0100F2C0115B6000/TOTK_Online_Server"
PORT=10014
if /usr/sbin/lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "un serveur écoute déjà sur $PORT"; exit 0; fi
JAVA=""
JH="$(/usr/libexec/java_home -v 25+ 2>/dev/null || true)"
[ -n "$JH" ] && JAVA="$JH/bin/java"
for j in /opt/homebrew/opt/openjdk/bin/java "$HOME/.homebrew/opt/openjdk/bin/java" /usr/local/opt/openjdk/bin/java; do
  [ -z "$JAVA" ] && [ -x "$j" ] && JAVA="$j"
done
[ -z "$JAVA" ] && JAVA="$(command -v java || true)"
[ -z "$JAVA" ] && { echo "Java introuvable : installe Java 25 (https://adoptium.net, Temurin 25, macOS aarch64 .pkg)"; exit 1; }
V="$("$JAVA" -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')"
[ "${V:-0}" -lt 25 ] 2>/dev/null && echo "attention : Java $V trouvé, le serveur demande Java 25 ou plus"
cd "$SRV" || { echo "pas de $SRV"; exit 1; }
mkdir -p "/Applications/Home/log"
# The server reads commands from its console: with no terminal its input is at end of file at once, and it logged
# "Unknown command name" in a loop (4 GB in minutes, a core busy). A pipe that never closes gives it an input that just waits.
# Sa propre session (setsid) : Home arrête les enfants de ce script à la fin de la partie, le serveur n'en est plus un.
export JAVA
/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' -- /bin/sh -c 'tail -f /dev/null | "$JAVA" -jar server.jar 2>&1 | grep --line-buffered -v "Unknown command name"' > "/Applications/Home/log/totk-server.log" 2>&1 < /dev/null &
GROUPE=$!   # chef de la session du serveur : tail, java et grep sont dans son groupe
# Le gardien : toutes les 10 s, Tailscale est-il connecté ? Trois fois non (30 s) et TOTK fermé : le serveur s'arrête
# (TERM au groupe : java sauvegarde en quittant).
export GROUPE PORT
/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' -- /bin/sh -c '
  ts() { /sbin/ifconfig 2>/dev/null | grep -Eq "inet 100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\."; }
  sleep 20; off=0
  while kill -0 "$GROUPE" 2>/dev/null; do
    if ts; then off=0; else off=$((off+1)); fi
    if [ $off -ge 3 ] && ! /usr/bin/pgrep -x TOTK >/dev/null; then
      echo "[Home] Tailscale fermé : arrêt du serveur ($(date "+%H:%M"))" >> /Applications/Home/log/totk-server.log
      kill -TERM -- "-$GROUPE" 2>/dev/null; sleep 10; kill -KILL -- "-$GROUPE" 2>/dev/null; exit 0
    fi
    sleep 10
  done' > /dev/null 2>&1 < /dev/null &
for _ in $(seq 1 120); do /usr/sbin/lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && { echo "serveur à l'écoute sur $PORT"; exit 0; }; sleep 0.5; done
echo "le serveur n'a pas démarré : voir /Applications/Home/log/totk-server.log"; exit 1
