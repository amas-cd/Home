#!/bin/sh
# Super Mario Odyssey: Online server. Started by the game (DM_COMPANION), but it lives on its own: quitting or relaunching
# Mario no longer restarts it, so the players connected through Tailscale stay connected (a restart dropped them, and their
# game does not reconnect by itself). It keeps running until the Mac restarts. Does nothing if a server already listens on 1027.
HR="${HOME_RACINE:-$HOME/Library/Application Support/Home}"; JX="${HOME_JEUX:-/Applications/Jeux}"   # les dossiers de Home (Home les donne ; sinon ceux par défaut)
SRV="$HR/serveurs/SmoOnlineServer"
LOG="$HR/log/smoo-server.log"   # Home y lit les joueurs connectés (menu rapide, carte Joueurs)
if /usr/sbin/lsof -nP -iTCP:1027 -sTCP:LISTEN >/dev/null 2>&1; then echo "a server already listens on 1027: nothing to start"; exit 0; fi
DOTNET=""
for d in "$HOME/.dotnet/dotnet" /opt/homebrew/bin/dotnet "$HOME/.homebrew/bin/dotnet" /usr/local/share/dotnet/dotnet /usr/local/bin/dotnet; do [ -x "$d" ] && { DOTNET="$d"; break; }; done
[ -z "$DOTNET" ] && { echo "dotnet not found"; exit 1; }
export DOTNET_ROLL_FORWARD=Major DOTNET_CLI_TELEMETRY_OPTOUT=1
cd "$SRV" || { echo "no $SRV"; exit 1; }
mkdir -p "$HR/log"
DLL="$(ls Server/bin/Release/*/Server.dll 2>/dev/null | head -1)"
if [ -n "$DLL" ]; then set -- "$DOTNET" "$DLL"; else set -- "$DOTNET" run --project Server/Server.csproj -c Release; fi
# Its own session (setsid), out of the game's process group that the launcher stops; its console input is a pipe that never
# closes (with none, Console.ReadLine returns at once and its command loop spins a core).
/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' -- /bin/sh -c 'tail -f /dev/null | "$@"' sh "$@" > "$LOG" 2>&1 < /dev/null &
for _ in $(seq 1 60); do /usr/sbin/lsof -nP -iTCP:1027 -sTCP:LISTEN >/dev/null 2>&1 && { echo "server listening on 1027"; exit 0; }; sleep 0.5; done
echo "the server did not start: see $LOG"; exit 1
