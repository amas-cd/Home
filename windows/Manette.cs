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
    [DllImport("xinput1_4.dll")] static extern uint XInputGetBatteryInformation(uint i, byte quoi, out Pile p);

    const ushort Haut = 1, Bas = 2, Gauche = 4, Droite = 8, Start = 0x10, Back = 0x20, LB = 0x100, RB = 0x200, A = 0x1000, B = 0x2000;
    readonly Bibliotheque lib; readonly Func<bool> active;
    readonly Dictionary<string, (bool appuye, DateTime prochain)> touches = new();
    readonly DispatcherTimer minuteur = new() { Interval = TimeSpan.FromMilliseconds(16) };
    int tours; bool disponible = OperatingSystem.IsWindows();

    /// `active` : Home est au premier plan. XInput lit la manette même quand un jeu est devant : sans ce test, jouer ferait défiler Home derrière.
    public Manette(Bibliotheque lib, Func<bool> active) { this.lib = lib; this.active = active; minuteur.Tick += (_, _) => Lire(); if (disponible) minuteur.Start(); }

    void Lire()
    {
        Etat e = default; uint n = 0; bool branchee = false;
        try { for (n = 0; n < 4 && !branchee; n++) branchee = XInputGetState(n, out e) == 0; }
        catch (Exception x) { disponible = false; minuteur.Stop(); Journal.Ecrire("XInput indisponible : " + x.Message); return; }
        var aides = branchee ? Aides.Xbox : Aides.Clavier;
        if (lib.Aides != aides) { lib.Aides = aides; lib.Signaler(); }
        if (!branchee) { if (lib.Batterie != null) { lib.Batterie = null; lib.Signaler(); } return; }
        if (++tours % 600 == 1) LireBatterie(n - 1);   // toutes les 10 s
        if (!active() || lib.EnCours != null) { touches.Clear(); return; }
        var p = e.Pad; const int seuil = 16000;
        (string, bool)[] etats =
        [
            ("left", (p.Boutons & Gauche) != 0 || p.LX < -seuil), ("right", (p.Boutons & Droite) != 0 || p.LX > seuil),
            ("up", (p.Boutons & Haut) != 0 || p.LY > seuil), ("down", (p.Boutons & Bas) != 0 || p.LY < -seuil),
            ("ok", (p.Boutons & A) != 0), ("back", (p.Boutons & B) != 0), ("options", (p.Boutons & Start) != 0), ("plus", (p.Boutons & Back) != 0),
            ("catL", (p.Boutons & LB) != 0), ("catR", (p.Boutons & RB) != 0),
        ];
        var now = DateTime.Now;
        foreach (var (nom, appuye) in etats)
        {
            touches.TryGetValue(nom, out var t);
            var direction = nom is "left" or "right" or "up" or "down";
            if (appuye && !t.appuye) { touches[nom] = (true, now.AddMilliseconds(380)); lib.Nav(nom); }
            else if (appuye && direction && now >= t.prochain) { touches[nom] = (true, now.AddMilliseconds(110)); lib.Nav(nom); }   // maintenu : ça défile
            else if (!appuye && t.appuye) touches[nom] = (false, now);
        }
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
    public static bool TourneDans(string dossier)
    {
        if (!OperatingSystem.IsWindows() || dossier == "") return false;
        var racine = Path.GetFullPath(dossier).TrimEnd('\\') + "\\";
        foreach (var p in System.Diagnostics.Process.GetProcesses())
        {
            using (p)
            {
                var h = OpenProcess(0x1000, false, p.Id);   // PROCESS_QUERY_LIMITED_INFORMATION
                if (h == IntPtr.Zero) continue;
                try { var sb = new StringBuilder(1024); uint n = 1024; if (QueryFullProcessImageName(h, 0, sb, ref n) && sb.ToString().StartsWith(racine, StringComparison.OrdinalIgnoreCase)) return true; }
                finally { CloseHandle(h); }
            }
        }
        return false;
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
    public static void Ouvrir(string cible)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(cible) { UseShellExecute = true }); }
        catch (Exception e) { Journal.Ecrire($"ouverture de {cible} : {e.Message}"); }
    }
}
