# Imprime les paramètres de connexion Epic pour lancer un jeu : python3 code-epic.py <appName> <namespace>
import sys, warnings
warnings.filterwarnings("ignore")
from legendary.core import LegendaryCore
app, ns = sys.argv[1], sys.argv[2]
core = LegendaryCore()
if not core.login():
    print("ERREUR: connexion Epic impossible (relance rocket-league-direct.command)", file=sys.stderr); sys.exit(1)
code = core.egs.get_game_token()["code"]
u = core.lgd.userdata
print(f"-AUTH_LOGIN=unused -AUTH_PASSWORD={code} -AUTH_TYPE=exchangecode -epicapp={app} -epicenv=Prod -EpicPortal "
      f"-epicusername={u.get('displayName', '')} -epicuserid={u.get('account_id', '')} -epiclocale=fr -epicsandboxid={ns}")
