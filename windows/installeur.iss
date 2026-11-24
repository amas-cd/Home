; Le setup de Home pour Windows (Inno Setup 6), fabriqué par le workflow : dist\Home-Setup.exe.
; Installe pour l'utilisateur seul, sans droits administrateur : Home peut ainsi se mettre à jour tout seul en relançant ce setup
; en silencieux (/SILENT). Les données (jeux.json, recomps…) sont ailleurs, dans %LOCALAPPDATA%\Home : une mise à jour ou une
; désinstallation n'y touche pas.
#define Version GetEnv("HOME_VERSION")

[Setup]
AppId={{8E0B6A51-6C7B-4F0E-9D52-3C1A7F2B9E10}
AppName=Home
AppVersion={#Version}
DefaultDirName={localappdata}\Programs\Home
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=Home-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\Home.exe
CloseApplications=yes

[Languages]
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"

[Files]
Source: "..\dist\Home\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Home"; Filename: "{app}\Home.exe"
Name: "{autodesktop}\Home"; Filename: "{app}\Home.exe"

[Run]
; Pas de « skipifsilent » : après une mise à jour silencieuse, Home se rouvre tout seul
Filename: "{app}\Home.exe"; Description: "Lancer Home"; Flags: nowait postinstall
