// Home pour Windows — la manette (XInput : manettes Xbox et tout ce que Steam ou Windows présente comme telle), les sons, et
// les quelques appels Windows dont Home a besoin (processus d'un dossier, Corbeille).
using System.Runtime.InteropServices;
using System.Text;
using Avalonia.Threading;

namespace Home;

public sealed class Manette
{
    [StructLayout(LayoutKind.Sequential)] struct Pad { public ushort Boutons; public byte GachetteG, GachetteD; public short LX, LY, RX, RY; }
    [StructLayout(LayoutKind.Sequential)] struct Etat { public uint Paquet; public Pad Pad; }
    [StructLayout(LayoutKind.Sequential)] struct Pile { public byte Type, Niveau; }
    [DllImport("xinput1_4.dll")] static extern uint XInputGetState(uint i, out Etat e);
    [DllImport("xinput1_4.dll", EntryPoint = "#100")] static extern uint XInputGetStateEx(uint i, out Etat e);   // la même, avec le bouton Xbox (0x0400)
    [DllImport("xinput1_4.dll")] static extern uint XInputGetBatteryInformation(uint i, byte quoi, out Pile p);

    const ushort Haut = 1, Bas = 2, Gauche = 4, Droite = 8, Start = 0x10, Back = 0x20, LB = 0x100, RB = 0x200, Xbox = 0x400, A = 0x1000, B = 0x2000, Y = 0x8000;
    bool avecXbox = true, menuTenu;
    readonly Bibliotheque lib; readonly Func<bool> active;
    readonly Dictionary<string, bool> touches = new(); int dernierX, dernierY; DateTime prochainX, prochainY;
    readonly DispatcherTimer minuteur = new() { Interval = TimeSpan.FromMilliseconds(16) };
    int tours; bool disponible = OperatingSystem.IsWindows();

    /// `active` : Home est au premier plan. XInput lit la manette même quand un jeu est devant : sans ce test, jouer ferait défiler Home derrière.
    public Manette(Bibliotheque lib, Func<bool> active) { this.lib = lib; this.active = active; minuteur.Tick += (_, _) => Lire(); if (disponible) { minuteur.Start(); ManetteSony.Demarrer(); } }

    void Lire()
    {
        Etat e = default; uint n = 0; bool branchee = false;
        try { for (n = 0; n < 4 && !branchee; n++) branchee = XInputGetState(n, out e) == 0; }
        catch (Exception x) { disponible = false; minuteur.Stop(); Journal.Ecrire("XInput indisponible : " + x.Message); return; }
        // pas de manette pour XInput : une manette PlayStation branchée telle quelle, lue directement
        var sony = false; var pave = false;
        if (!branchee && ManetteSony.Etat is { } ps) { branchee = sony = true; pave = ps.pave; e.Pad = new Pad { Boutons = ps.boutons, LX = ps.lx, LY = ps.ly }; }
        var aides = sony ? Aides.PlayStation : branchee ? Aides.Xbox : Aides.Clavier;
        if (lib.Aides != aides) { lib.Aides = aides; lib.Signaler(); }
        if (!branchee) { if (lib.Batterie != null) { lib.Batterie = null; lib.Signaler(); } return; }
        if (sony) { if (lib.Batterie != null) { lib.Batterie = null; lib.Signaler(); } } else if (++tours % 600 == 1) LireBatterie(n - 1);   // toutes les 10 s
        // En jeu, un bouton dont les jeux ne se servent presque pas ouvre et ferme le menu en jeu : le pavé tactile d'une manette
        // PlayStation (comme sur Mac) ou son bouton PS, le bouton Xbox, ou Select + Start ensemble sur n'importe quelle manette.
        // Tant que le menu est fermé, rien d'autre ne compte : le reste appartient au jeu.
        if (lib.EnCours != null)
        {
            var b = e.Pad.Boutons;
            if (!sony && avecXbox) try { if (XInputGetStateEx(n - 1, out var ex) == 0) b = ex.Pad.Boutons; } catch { avecXbox = false; }
            var menu = pave || (b & Xbox) != 0 || (b & (Start | Back)) == (Start | Back);
            if (menu && !menuTenu) { Journal.Ecrire("manette en jeu : menu en jeu"); lib.BasculerRapide(); }
            menuTenu = menu;
            if (!lib.Rapide || menu) { touches.Clear(); dernierX = dernierY = 0; return; }
        }
        else if (!active()) { touches.Clear(); dernierX = dernierY = 0; return; }
        var p = e.Pad; var now = DateTime.Now;
        // Les directions, comme pollPad sur Mac. Le stick : il faut le pousser franchement (0,8) pour un cran, il reste engagé jusqu'à
        // 0,45 (pas de cran parasite en relâchant) et seul l'axe dominant compte (une diagonale ne bouge pas dans deux sens). En
        // maintenant : la croix répète après 0,6 s puis toutes les 0,3 s, le stick après 0,8 s puis toutes les 0,45 s.
        double sx = p.LX / 32767.0, sy = p.LY / 32767.0;
        int stickX = Math.Abs(sx) >= Math.Abs(sy) && Math.Abs(sx) > (dernierX != 0 ? 0.45 : 0.8) ? Math.Sign(sx) : 0;
        int stickY = Math.Abs(sy) > Math.Abs(sx) && Math.Abs(sy) > (dernierY != 0 ? 0.45 : 0.8) ? -Math.Sign(sy) : 0;   // XInput : le haut est positif
        int croixX = (p.Boutons & Gauche) != 0 ? -1 : (p.Boutons & Droite) != 0 ? 1 : 0, croixY = (p.Boutons & Haut) != 0 ? -1 : (p.Boutons & Bas) != 0 ? 1 : 0;
        Axe(croixX != 0 ? croixX : stickX, croixX != 0, ref dernierX, ref prochainX, "left", "right", now);
        Axe(croixY != 0 ? croixY : stickY, croixY != 0, ref dernierY, ref prochainY, "up", "down", now);
        (string, bool)[] etats =
        [
            ("ok", (p.Boutons & A) != 0), ("back", (p.Boutons & B) != 0), ("options", (p.Boutons & Start) != 0), ("plus", (p.Boutons & Back) != 0),
            ("catL", (p.Boutons & LB) != 0), ("catR", (p.Boutons & RB) != 0), ("tri", (p.Boutons & Y) != 0),
        ];
        foreach (var (nom, appuye) in etats)
        {   // un bouton ne compte qu'à l'appui : le tenir ne répète rien
            touches.TryGetValue(nom, out var avant);
            if (appuye && !avant) Nav(nom);
            touches[nom] = appuye;
        }
    }
    void Nav(string k) { if (lib.Rapide) lib.NavRapide(k); else lib.Nav(k); }
    void Axe(int sens, bool croix, ref int dernier, ref DateTime prochain, string moins, string plus, DateTime now)
    {
        if (sens == 0) { dernier = 0; return; }
        if (sens != dernier) { dernier = sens; prochain = now.AddMilliseconds(croix ? 600 : 800); Nav(sens < 0 ? moins : plus); }
        else if (now >= prochain) { prochain = now.AddMilliseconds(croix ? 300 : 450); Nav(sens < 0 ? moins : plus); }
    }
    void LireBatterie(uint i)
    {
        try
        {
            int? pct = XInputGetBatteryInformation(i, 0, out var b) == 0 && b.Type is 2 or 3 ? b.Niveau switch { 0 => 5, 1 => 30, 2 => 65, _ => 100 } : null;   // filaire : pas de pile à montrer
            if (lib.Batterie != pct) { lib.Batterie = pct; lib.Signaler(); }
        }
        catch { }
    }
}

/// Les manettes PlayStation (DualShock 4, DualSense) branchées telles quelles, en USB ou en Bluetooth : Windows ne les présente pas à
/// XInput, Home les lit donc directement (HID). C'est aussi ce qui donne le pavé tactile, que XInput n'a pas : comme sur Mac, c'est
/// lui qui ouvre le menu en jeu, un bouton dont les jeux ne se servent presque pas.
/// L'état est rendu dans la forme de XInput (mêmes bits de boutons, mêmes axes) : le reste de `Manette` ne fait pas la différence.
static class ManetteSony
{
    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [StructLayout(LayoutKind.Sequential)] struct Interface { public int Taille; public Guid Classe; public int Drapeaux; public IntPtr Reserve; }
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr enumerateur, IntPtr fenetre, uint drapeaux);
    [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr liste, IntPtr info, ref Guid g, uint index, ref Interface i);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr liste, ref Interface i, IntPtr detail, int taille, out int voulu, IntPtr info);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr liste);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(string nom, uint acces, uint partage, IntPtr securite, uint creation, uint drapeaux, IntPtr modele);

    static readonly object verrou = new(); static (ushort boutons, short lx, short ly, bool pave, DateTime quand) etat; static bool lance;
    /// L'état de la manette PlayStation, s'il y en a une qui parle (lu il y a moins d'une seconde et demie)
    public static (ushort boutons, short lx, short ly, bool pave)? Etat { get { lock (verrou) return (DateTime.Now - etat.quand).TotalSeconds < 1.5 ? (etat.boutons, etat.lx, etat.ly, etat.pave) : null; } }

    public static void Demarrer()
    {
        if (lance || !OperatingSystem.IsWindows()) return;
        lance = true;
        new Thread(() =>
        {
            while (true)
            {
                try { if (Trouver() is { } m) Ecouter(m.chemin, m.dualsense); }
                catch (Exception e) { Journal.Ecrire("manette PlayStation : " + e.Message); }
                Thread.Sleep(3000);   // aucune manette, ou elle vient d'être débranchée : on regarde à nouveau
            }
        }) { IsBackground = true, Name = "manette PlayStation" }.Start();
    }
    /// Le premier périphérique HID de Sony qui est une DualShock 4 ou une DualSense
    static (string chemin, bool dualsense)? Trouver()
    {
        HidD_GetHidGuid(out var hid);
        var liste = SetupDiGetClassDevs(ref hid, IntPtr.Zero, IntPtr.Zero, 0x12);   // DIGCF_PRESENT | DIGCF_DEVICEINTERFACE
        if (liste == IntPtr.Zero || liste == new IntPtr(-1)) return null;
        try
        {
            for (uint n = 0; n < 256; n++)
            {
                var i = new Interface { Taille = Marshal.SizeOf<Interface>() };
                if (!SetupDiEnumDeviceInterfaces(liste, IntPtr.Zero, ref hid, n, ref i)) break;
                SetupDiGetDeviceInterfaceDetail(liste, ref i, IntPtr.Zero, 0, out var taille, IntPtr.Zero);
                if (taille <= 0) continue;
                var detail = Marshal.AllocHGlobal(taille);
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);   // cbSize de la structure, pas de la mémoire
                    if (!SetupDiGetDeviceInterfaceDetail(liste, ref i, detail, taille, out _, IntPtr.Zero)) continue;
                    var chemin = Marshal.PtrToStringUni(detail + 4)?.ToLowerInvariant() ?? "";
                    if (!chemin.Contains("054c")) continue;   // Sony
                    if (chemin.Contains("0ce6") || chemin.Contains("0df2")) return (chemin, true);                              // DualSense, DualSense Edge
                    if (chemin.Contains("05c4") || chemin.Contains("09cc") || chemin.Contains("0ba0")) return (chemin, false);   // DualShock 4, et son adaptateur
                }
                finally { Marshal.FreeHGlobal(detail); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(liste); }
        return null;
    }
    static void Ecouter(string chemin, bool dualsense)
    {
        using var poignee = CreateFile(chemin, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);   // lecture seule, partagée : le jeu la lit aussi
        if (poignee.IsInvalid) return;
        using var flux = new FileStream(poignee, FileAccess.Read, 1, false);
        Journal.Ecrire("manette PlayStation reliée (" + (dualsense ? "DualSense" : "DualShock 4") + ")");
        var b = new byte[1024];
        while (true)
        {
            var n = flux.Read(b, 0, b.Length); if (n <= 0) return;
            // où sont les sticks et les trois octets de boutons, selon la manette et la liaison
            int s, f;
            if (dualsense) { if (b[0] == 0x31) { s = 2; f = 9; } else if (b[0] == 0x01 && n >= 64) { s = 1; f = 8; } else if (b[0] == 0x01) { s = 1; f = 5; } else continue; }
            else { if (b[0] == 0x11) { s = 3; f = 7; } else if (b[0] == 0x01) { s = 1; f = 5; } else continue; }
            if (n < f + 3) continue;
            byte face = b[f], epaule = b[f + 1], systeme = b[f + 2]; int croix = face & 0x0F; ushort x = 0;
            if (croix is 7 or 0 or 1) x |= 1; if (croix is 3 or 4 or 5) x |= 2; if (croix is 5 or 6 or 7) x |= 4; if (croix is 1 or 2 or 3) x |= 8;   // haut, bas, gauche, droite
            if ((face & 0x20) != 0) x |= 0x1000; if ((face & 0x40) != 0) x |= 0x2000; if ((face & 0x80) != 0) x |= 0x8000;                       // croix = A, rond = B, triangle = Y
            if ((epaule & 0x01) != 0) x |= 0x100; if ((epaule & 0x02) != 0) x |= 0x200; if ((epaule & 0x10) != 0) x |= 0x20; if ((epaule & 0x20) != 0) x |= 0x10;   // L1, R1, Share, Options
            if ((systeme & 0x01) != 0) x |= 0x400;   // le bouton PS, comme le bouton Xbox
            short Axe(byte v, bool inverse) => (short)Math.Clamp((inverse ? 128 - v : v - 128) * 256, short.MinValue, short.MaxValue);
            lock (verrou) etat = (x, Axe(b[s], false), Axe(b[s + 1], true), (systeme & 0x02) != 0, DateTime.Now);   // XInput : le haut est positif
        }
    }
}

/// Les sons de l'interface : les mêmes fichiers .wav que sur Mac (les six sons créés pour Home, et son jingle), copiés à côté de l'exécutable
public static class Sons
{
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern bool PlaySound(string? fichier, IntPtr module, uint drapeaux);
    public static bool Actifs = true;
    public static void Jouer(string nom)
    {
        if (!Actifs || !OperatingSystem.IsWindows()) return;
        var f = Path.Combine(AppContext.BaseDirectory, "sons", nom + ".wav");
        try { if (File.Exists(f)) PlaySound(f, IntPtr.Zero, 0x00020000 | 0x0001 | 0x0002); } catch { }   // SND_FILENAME | SND_ASYNC | SND_NODEFAULT
    }
}

public static class Systeme
{
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint acces, bool herite, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, uint drapeaux, StringBuilder nom, ref uint taille);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    /// Un programme de ce dossier tourne-t-il ? Steam et Epic rendent la main dès le clic : c'est ainsi que Home sait quand la partie finit.
    /// QueryFullProcessImageName ne lève pas d'exception sur les processus protégés, contrairement à Process.MainModule.
    public static bool TourneDans(string dossier) => PidsDans(dossier, un: true).Count > 0;
    /// Les programmes de ce dossier qui tournent (`un` : s'arrêter au premier)
    public static HashSet<int> PidsDans(string dossier, bool un = false)
    {
        var pids = new HashSet<int>();
        if (!OperatingSystem.IsWindows() || dossier == "") return pids;
        var racine = Path.GetFullPath(dossier).TrimEnd('\\') + "\\";
        foreach (var p in System.Diagnostics.Process.GetProcesses())
        {
            using (p)
            {
                var h = OpenProcess(0x1000, false, p.Id);   // PROCESS_QUERY_LIMITED_INFORMATION
                if (h == IntPtr.Zero) continue;
                try { var sb = new StringBuilder(1024); uint n = 1024; if (QueryFullProcessImageName(h, 0, sb, ref n) && sb.ToString().StartsWith(racine, StringComparison.OrdinalIgnoreCase)) { pids.Add(p.Id); if (un) return pids; } }
                finally { CloseHandle(h); }
            }
        }
        return pids;
    }
    /// Ferme un jeu : on demande d'abord à sa fenêtre de se fermer (il enregistre), puis on arrête ce qui reste au bout de 3 s
    public static void Fermer(string dossier, System.Diagnostics.Process? lance)
    {
        if (!OperatingSystem.IsWindows()) return;
        var pids = PidsDans(dossier); try { if (lance is { HasExited: false }) pids.Add(lance.Id); } catch { }
        var ouverts = new List<System.Diagnostics.Process>();
        foreach (var pid in pids) try { var p = System.Diagnostics.Process.GetProcessById(pid); ouverts.Add(p); p.CloseMainWindow(); } catch { }
        Thread.Sleep(3000);
        foreach (var p in ouverts) try { if (!p.HasExited) p.Kill(true); } catch { } finally { p.Dispose(); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Operation { public IntPtr Fenetre; public uint Quoi; public string De; public string? Vers; public ushort Drapeaux; public bool Annule; public IntPtr Noms; public string? Titre; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref Operation op);
    /// À la Corbeille, jamais de suppression définitive : l'utilisateur peut toujours revenir en arrière
    public static bool Corbeille(string chemin)
    {
        if (!OperatingSystem.IsWindows() || !(Directory.Exists(chemin) || File.Exists(chemin))) return false;
        var op = new Operation { Quoi = 3, De = chemin + "\0\0", Drapeaux = 0x40 | 0x10 | 0x4 | 0x400 };   // FO_DELETE ; ALLOWUNDO | NOCONFIRMATION | SILENT | NOERRORUI
        return SHFileOperation(ref op) == 0 && !op.Annule;
    }
    /// Montre un fichier dans l'Explorateur, sélectionné
    public static void Montrer(string fichier)
    {
        try { if (OperatingSystem.IsWindows()) System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{fichier}\""); }
        catch (Exception e) { Journal.Ecrire($"ouverture de {fichier} : {e.Message}"); }
    }
    public static void Ouvrir(string cible)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(cible) { UseShellExecute = true }); }
        catch (Exception e) { Journal.Ecrire($"ouverture de {cible} : {e.Message}"); }
    }
}
