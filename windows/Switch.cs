// Home pour Windows — les jeux Switch, construits par Home lui-même avec ScarletNX (https://github.com/scarletnx/ScarletNX,
// GPL-3.0-or-later) : l'équivalent Windows de nxnative et MacNativeGames sur Mac. On donne une fois le dump et les clés tirés de sa
// propre console ; Home recompile le jeu en programme Windows, dans son dossier, et crée la tuile.
//
// ScarletNX est un programme à part : Home le télécharge (releases de scarletnx/nightly, version figée dans SCARLETNX-REF) et le lance.
// Aucune ligne de son code n'est reprise ici. Home ne télécharge ni jeu, ni clé, ni fichier système, et ne dit pas où en trouver.
//
// Le jeu construit se suffit à lui-même : `--extract-container` copie le jeu, ses mises à jour et ses DLC dans son dossier
// (recompiled/<id>/), les mods y sont copiés aussi, et les shaders y sont préparés au premier lancement. Le dump d'origine ne sert plus.
using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Avalonia.Platform;
using Avalonia.Threading;

namespace Home;

/// ScarletNX sur ce PC : où il est, quelle version, et comment l'installer
public static class Moteur
{
    public const string Depot = "scarletnx/nightly";
    /// Le dossier de données de ScarletNX (son `--data`) : le moteur, les clés copiées, et les jeux construits dans recompiled/
    public static string Donnees => Dossiers.Dossier("scarletnx");
    static string Programmes => Path.Combine(Donnees, "moteur");
    static string FichierVersion => Path.Combine(Programmes, "version.txt");
    public static string? Version { get { try { return File.Exists(FichierVersion) ? File.ReadAllText(FichierVersion).Trim() : null; } catch { return null; } } }
    public static string? Exe { get { try { return Directory.Exists(Programmes) ? Directory.EnumerateFiles(Programmes, "scarletnx.exe", SearchOption.AllDirectories).FirstOrDefault() : null; } catch { return null; } } }
    /// Sous Wine ou CrossOver sur un Mac Apple Silicon, Windows se dit ARM alors que seuls les programmes x86-64 y tournent (par
    /// Rosetta) : on y prend le moteur x86-64. Sur un vrai PC ARM, le moteur ARM.
    [DllImport("ntdll.dll", EntryPoint = "wine_get_version")] static extern IntPtr VersionDeWine();
    public static readonly bool SousWine = Wine();
    static bool Wine() { try { return OperatingSystem.IsWindows() && VersionDeWine() != IntPtr.Zero; } catch { return false; } }
    static bool Arm => RuntimeInformation.OSArchitecture == Architecture.Arm64 && !SousWine;
    static string Archive => Arm ? "ScarletNX-windows-aarch64.zip" : "ScarletNX-windows-x86_64.zip";
    /// Le moteur installé est-il fait pour ce PC ? (un moteur ARM posé sous CrossOver par une version précédente ne démarre pas)
    static bool BonneArchitecture(string exe)
    {
        try
        {
            using var f = File.OpenRead(exe); using var r = new BinaryReader(f);
            f.Position = 0x3C; f.Position = r.ReadInt32() + 4; var machine = r.ReadUInt16();   // en-tête PE : 0xAA64 = ARM64, 0x8664 = x86-64
            return (machine == 0xAA64) == Arm;
        }
        catch { return true; }
    }

    /// La version figée, notée dans le dépôt (windows/SCARLETNX-REF, comme moteur/.upstream-ref côté Mac) : « cle=valeur » par ligne
    static Dictionary<string, string> Reference()
    {
        var r = new Dictionary<string, string>();
        try
        {
            using var s = new StreamReader(AssetLoader.Open(new Uri("avares://Home/SCARLETNX-REF")));
            foreach (var l in s.ReadToEnd().Split('\n').Select(x => x.Trim()).Where(x => x != "" && !x.StartsWith('#') && x.Contains('=')))
                r[l[..l.IndexOf('=')].Trim()] = l[(l.IndexOf('=') + 1)..].Trim();
        }
        catch (Exception e) { Journal.Ecrire("SCARLETNX-REF illisible : " + e.Message); }
        return r;
    }

    /// Installe ScarletNX s'il n'est pas là, et rend le chemin de scarletnx.exe. D'abord la version figée ; ScarletNX ne garde que ses
    /// 30 dernières nightlies, donc si elle a disparu, la dernière publiée, avec son empreinte lue chez GitHub. Sans empreinte qui
    /// correspond, rien n'est installé : c'est un programme qu'on exécute.
    public static async Task<string> Preparer(Tache t, Action signaler, bool derniere = false)
    {
        if (!derniere && Exe is { } la) { if (BonneArchitecture(la)) return la; Journal.Ecrire("le moteur installé n'est pas fait pour ce PC : il est remplacé"); }
        var reference = Reference(); var tag = reference.GetValueOrDefault("tag", ""); var empreinte = reference.GetValueOrDefault(Arm ? "aarch64" : "x86_64");
        var zip = Dossiers.Fichier("telechargements", Archive);
        var dit = DateTime.MinValue;
        void Avance(long lu, long total)
        {   // quatre fois par seconde suffisent : chaque morceau reçu redessinait tout l'écran
            if (lu < total && (DateTime.Now - dit).TotalSeconds < 0.25) return;
            dit = DateTime.Now; t.Fraction = total > 0 ? 0.9 * lu / total : null; t.Etape = $"Téléchargement du moteur… {lu / 1048576} Mo" + (total > 0 ? $" sur {total / 1048576}" : ""); Dispatcher.UIThread.Post(signaler);
        }
        string? recue = null;
        // D'où il vient : le dépôt noté dans SCARLETNX-REF (`depot=`, le ScarletNX de Home, avec la caméra à la souris), sinon l'officiel.
        // Si la version figée n'y est plus, la dernière de ce dépôt ; s'il ne répond pas du tout, la dernière officielle (sans la souris).
        var depot = reference.GetValueOrDefault("depot", Depot);
        if (!derniere && tag != "")
        {
            try { recue = await Reseau.Telecharger($"https://github.com/{depot}/releases/download/{tag}/{Archive}", zip, Avance); }
            catch (Exception e) { Journal.Ecrire($"ScarletNX {tag} n'est plus publié ({e.Message}) : on prend la dernière version"); }
        }
        if (recue == null)
        {
            var d = await Reseau.Json($"https://api.github.com/repos/{depot}/releases/latest");
            if (d == null && depot != Depot) { Journal.Ecrire($"{depot} ne répond pas : ScarletNX officiel, sans la caméra à la souris"); depot = Depot; d = await Reseau.Json($"https://api.github.com/repos/{depot}/releases/latest"); }
            if (d == null) throw new InvalidOperationException("la liste des versions de ScarletNX n'a pas pu être lue");
            JsonElement Fichier(JsonDocument doc) => doc.RootElement.GetProperty("assets").EnumerateArray().FirstOrDefault(a => a.GetProperty("name").GetString() == Archive);
            if (depot != Depot && Fichier(d).ValueKind != JsonValueKind.Object)
            {   // le ScarletNX de Home n'est compilé que pour les PC x86-64 : un PC ARM prend l'officiel
                Journal.Ecrire($"{depot} n'a pas de build pour ce PC : ScarletNX officiel, sans la caméra à la souris"); depot = Depot; d.Dispose();
                d = await Reseau.Json($"https://api.github.com/repos/{depot}/releases/latest") ?? throw new InvalidOperationException("la liste des versions de ScarletNX n'a pas pu être lue");
            }
            using var _ = d;
            tag = d.RootElement.GetProperty("tag_name").GetString() ?? "";
            var fichier = d.RootElement.GetProperty("assets").EnumerateArray().FirstOrDefault(a => a.GetProperty("name").GetString() == Archive);
            if (fichier.ValueKind != JsonValueKind.Object) throw new InvalidOperationException("la dernière version de ScarletNX n'a pas de build pour ce PC");
            var url = fichier.GetProperty("browser_download_url").GetString() ?? "";
            if (!url.StartsWith($"https://github.com/{depot}/releases/download/", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("adresse de téléchargement inattendue");
            empreinte = fichier.TryGetProperty("digest", out var dg) && dg.GetString() is { } x && x.StartsWith("sha256:") ? x[7..] : null;
            recue = await Reseau.Telecharger(url, zip, Avance);
        }
        if (empreinte == null) Journal.Ecrire($"ScarletNX {tag} : pas d'empreinte publiée, le fichier n'a pas pu être vérifié");
        else if (!recue.Equals(empreinte, StringComparison.OrdinalIgnoreCase)) { try { File.Delete(zip); } catch { } throw new InvalidDataException("le moteur reçu n'est pas celui qui a été publié (empreinte différente) : rien n'a été installé"); }
        t.Etape = "Installation du moteur…"; t.Fraction = 0.95; Dispatcher.UIThread.Post(signaler);
        // décompressé à côté puis mis en place : une coupure ne laisse jamais un moteur à moitié installé
        var neuf = Programmes + ".neuf";
        await Task.Run(() =>
        {
            if (Directory.Exists(neuf)) Directory.Delete(neuf, true);
            Extraire(zip, neuf); File.WriteAllText(Path.Combine(neuf, "version.txt"), tag);
            if (Directory.Exists(Programmes)) Directory.Delete(Programmes, true);
            Directory.Move(neuf, Programmes);
            try { File.Delete(zip); } catch { }
        });
        Journal.Ecrire($"moteur ScarletNX installé : {tag}, sha256 {recue}{(empreinte == null ? " (non vérifié)" : "")}");
        return Exe ?? throw new FileNotFoundException("scarletnx.exe n'est pas dans l'archive du moteur");
    }

    /// Décompresse sans jamais écrire hors du dossier (noms d'entrée comme « ..\..\x »)
    public static void Extraire(string zip, string dest)
    {
        using var a = ZipFile.OpenRead(zip);
        var racine = Path.GetFullPath(dest).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        foreach (var e in a.Entries)
        {
            var rel = e.FullName.Replace('\\', '/');
            if (rel == "" || rel.EndsWith('/')) continue;
            var cible = Path.GetFullPath(Path.Combine(dest, rel));
            if (!cible.StartsWith(racine, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("archive invalide : un fichier sortirait de son dossier");
            Directory.CreateDirectory(Path.GetDirectoryName(cible)!); e.ExtractToFile(cible, true);
        }
    }
}

/// Un réglage du fichier .ini d'un jeu ScarletNX (« [Section] » puis « cle=valeur ») : lu et réécrit sans toucher au reste
public static class Ini
{
    public static string Lire(string fichier, string section, string cle)
    {
        try
        {
            var dedans = false;
            foreach (var l in File.Exists(fichier) ? File.ReadAllLines(fichier) : [])
            {
                var t = l.Trim();
                if (t.StartsWith('[')) dedans = t.Equals($"[{section}]", StringComparison.OrdinalIgnoreCase);
                else if (dedans && t.StartsWith(cle + "=", StringComparison.OrdinalIgnoreCase)) return t[(cle.Length + 1)..].Trim();
                else if (dedans && t.StartsWith(cle + " =", StringComparison.OrdinalIgnoreCase)) return t[(t.IndexOf('=') + 1)..].Trim();
            }
        }
        catch (Exception e) { Journal.Ecrire($"lecture de {Path.GetFileName(fichier)} : {e.Message}"); }
        return "";
    }
    public static void Ecrire(string fichier, string section, string cle, string valeur)
    {
        var lignes = File.Exists(fichier) ? File.ReadAllLines(fichier).ToList() : new List<string>();
        int debut = lignes.FindIndex(l => l.Trim().Equals($"[{section}]", StringComparison.OrdinalIgnoreCase));
        if (debut < 0) { if (lignes.Count > 0 && lignes[^1].Trim() != "") lignes.Add(""); lignes.Add($"[{section}]"); debut = lignes.Count - 1; }
        var fin = lignes.FindIndex(debut + 1, l => l.TrimStart().StartsWith('[')); if (fin < 0) fin = lignes.Count;
        var i = lignes.FindIndex(debut + 1, fin - debut - 1, l => l.Trim().Split('=')[0].Trim().Equals(cle, StringComparison.OrdinalIgnoreCase) && l.Contains('='));
        if (i >= 0) lignes[i] = $"{cle}={valeur}"; else lignes.Insert(fin, $"{cle}={valeur}");
        var tmp = fichier + ".tmp"; File.WriteAllLines(tmp, lignes); File.Move(tmp, fichier, true);
    }
}

/// Un jeu en construction (`Chantier` sur Mac) : ce qui a été demandé, pour que sa tuile puisse reprendre si c'est coupé
public sealed class Chantier
{
    public string Id { get; set; } = ""; public string Titre { get; set; } = ""; public string Dump { get; set; } = "";
    public List<string> Ajouts { get; set; } = new();   // mises à jour et DLC
    public string? Mod { get; set; }       // un mod à installer dès que le jeu est construit (dossier ou .zip)
    public string? Serveur { get; set; }   // l'adresse du serveur de ce mod, s'il joue en ligne
    public bool ModSeul { get; set; }      // le jeu est construit, il ne reste que le mod à poser (son étape a échoué)
    public string? Raison { get; set; }    // pourquoi la construction s'est arrêtée, pour le dire sur sa tuile
    public string Journal { get; set; } = ""; public DateTime Debut { get; set; } = DateTime.Now;
}

public static class Construction
{
    static string Fichier => Dossiers.Fichier("constructions.json");
    public static List<Chantier> Chantiers() => Json.Lire<List<Chantier>>(Fichier);
    static void Noter(List<Chantier> c) => Json.Ecrire(Fichier, c);
    /// Le chantier qui tourne en ce moment (un seul à la fois : une recompilation prend presque tout le processeur)
    public static string? EnCours { get; private set; }
    static Process? processus; static bool abandon, arret;
    /// Arrête la construction en cours sans rien jeter : le chantier reste, « Reprendre » repart de là
    public static void Arreter() { if (processus is { } p) { arret = true; try { p.Kill(true); } catch { } } }
    static void Garder(Chantier c) { var tous = Chantiers(); var i = tous.FindIndex(x => x.Id == c.Id); if (i >= 0) { tous[i] = c; Noter(tous); } }
    public static string Recompiles => Path.Combine(Moteur.Donnees, "recompiled");
    public static string ClesProd => Path.Combine(Moteur.Donnees, "prod.keys");
    public static string ClesTitres => Path.Combine(Moteur.Donnees, "title.keys");

    // Un jeu construit : recompiled/<id>/ avec son programme <id>.exe, son code, son tampon <id>.abi, ses réglages <id>.ini et ses données <id>_data/
    public static string Programme(string dossier) => Path.Combine(dossier, Path.GetFileName(dossier) + ".exe");
    public static string Reglages(string dossier) => Path.Combine(dossier, Path.GetFileName(dossier) + ".ini");
    public static string Data(string dossier) => Path.Combine(dossier, Path.GetFileName(dossier) + "_data");
    public static string Mods(string dossier) => Path.Combine(Data(dossier), "mods");
    /// L'adresse du serveur d'un mod en ligne, gardée à côté du jeu (sur ce PC seulement). Home la donne au jeu à chaque lancement.
    public static string FichierServeur(string dossier) => Path.Combine(dossier, "serveur.txt");
    public static string Serveur(string dossier) { try { var f = FichierServeur(dossier); return File.Exists(f) ? File.ReadLines(f).FirstOrDefault()?.Trim() ?? "" : ""; } catch { return ""; } }
    /// ScarletNX n'écrit le tampon .abi qu'à la fin d'une recompilation réussie : c'est ce qui dit qu'un jeu est prêt
    static bool Pret(string dossier) => File.Exists(Programme(dossier)) && File.Exists(Path.Combine(dossier, Path.GetFileName(dossier) + ".abi"));

    public static List<Jeu> Jeux()
    {
        var jeux = new List<Jeu>();
        try
        {
            if (Directory.Exists(Recompiles))
                foreach (var d in Directory.GetDirectories(Recompiles).Where(Pret))
                    jeux.Add(new Jeu { Id = "switch:" + Path.GetFileName(d), Nom = Nom(d), Origine = Origine.Switch, Cible = Programme(d), Dossier = d });
        }
        catch (Exception e) { Journal.Ecrire("jeux Switch : " + e.Message); }
        return jeux;
    }
    /// Le nom du jeu, lu dans son control.nacp : 16 langues de 0x300 octets, le nom dans les 0x200 premiers. Le français (3) d'abord.
    static string Nom(string dossier)
    {
        try
        {
            var f = Path.Combine(Data(dossier), "control.nacp");
            if (File.Exists(f))
            {
                var o = File.ReadAllBytes(f);
                foreach (var langue in new[] { 3, 0, 1 }.Concat(Enumerable.Range(0, 16)))
                {
                    var debut = langue * 0x300; if (debut + 0x200 > o.Length) continue;
                    var n = Encoding.UTF8.GetString(o, debut, 0x200); var z = n.IndexOf('\0'); if (z >= 0) n = n[..z];
                    if (n.Trim() != "") return n.Trim();
                }
            }
        }
        catch { }
        return Path.GetFileName(dossier);
    }

    /// Les arguments de la recompilation : `-r` sans jouer, `--extract-container` pour que le jeu soit copié dans son dossier et ne
    /// dépende plus du dump, les clés, puis le dump et chaque mise à jour ou DLC
    static List<string> Arguments(Chantier c)
    {
        var a = new List<string> { "--data", Moteur.Donnees, "-r", "--extract-container", "--keys", ClesProd };
        if (File.Exists(ClesTitres)) { a.Add("--title-keys"); a.Add(ClesTitres); }
        a.Add(c.Dump);
        foreach (var u in c.Ajouts) { a.Add("--update"); a.Add(u); }
        return a;
    }

    public static void Commencer(Bibliotheque lib, string dump, List<string> ajouts, string? mod = null, string? serveur = null)
    {
        var id = "construction:" + Guid.NewGuid().ToString("N")[..8];
        var c = new Chantier { Id = id, Titre = Path.GetFileNameWithoutExtension(dump), Dump = dump, Ajouts = ajouts, Mod = mod, Serveur = serveur, Journal = Dossiers.Fichier("log", id.Replace(':', '-') + ".log") };
        var tous = Chantiers(); tous.Add(c); Noter(tous);
        lib.Recharger(selectionner: id);
        _ = Lancer(lib, c);
    }

    /// Lance (ou relance) la construction d'un chantier. Relancer la même commande reprend : ScarletNX refait ce qui manque.
    public static async Task Lancer(Bibliotheque lib, Chantier c)
    {
        if (lib.Tache is { Fini: false }) { lib.Dire("Une autre tâche est en cours : attends qu'elle finisse"); return; }
        var t = new Tache { Titre = "Construction de " + c.Titre, Etape = "Préparation du moteur…", Journal = c.Journal, Arreter = Arreter };
        lib.Tache = t; EnCours = c.Id; abandon = false; arret = false; lib.FermerMenus();
        if (c.Raison != null) { c.Raison = null; Garder(c); }
        string? dossier = null;
        try
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("un jeu Switch ne se construit que sur Windows");
            if (!File.Exists(c.Dump)) throw new FileNotFoundException("le fichier du jeu n'est plus là : " + c.Dump);
            if (!File.Exists(ClesProd)) throw new FileNotFoundException("les clés (prod.keys) ne sont plus installées dans Home");
            var exe = await Moteur.Preparer(t, lib.Signaler);
            t.Etape = "Lecture du jeu…"; t.Fraction = null; lib.Signaler();
            var avant = Directory.Exists(Recompiles) ? Directory.GetDirectories(Recompiles).ToHashSet() : new HashSet<string>();
            // Une reprise après un échec survenu une fois le jeu construit (la pose du mod, par exemple) : le jeu est déjà là, fait
            // pendant ce chantier. On ne relance pas ScarletNX dessus (il refuse d'extraire sur un jeu fini : « Extraction failed ») ;
            // on reprend à l'étape du mod.
            try
            {
                if (Trouvailles.Lire(c.Dump).titre is { Length: > 0 } titre && Directory.GetDirectories(Recompiles).FirstOrDefault(d => Path.GetFileName(d).Equals(titre, StringComparison.OrdinalIgnoreCase)) is { } fait
                    && Pret(fait) && (c.ModSeul || Directory.GetLastWriteTime(fait) >= c.Debut.AddMinutes(-1))) { dossier = fait; Journal.Ecrire($"construction de {c.Titre} : le jeu est déjà construit, reprise à l'étape du mod"); }
            }
            catch { }
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Moteur.Donnees };
            foreach (var a in Arguments(c)) psi.ArgumentList.Add(a);
            string derniere = ""; var verrou = new object(); DateTime vu = DateTime.MinValue;
            if (dossier == null) await using (var journal = new StreamWriter(c.Journal, false, Encoding.UTF8) { AutoFlush = true })
            {
                journal.WriteLine($"{DateTime.Now:dd/MM/yyyy HH:mm:ss}  ScarletNX {Moteur.Version}  " + string.Join(' ', psi.ArgumentList.Select(a => a.Contains(' ') ? $"\"{a}\"" : a)));
                void Ligne(string? l)
                {
                    if (string.IsNullOrWhiteSpace(l)) return;
                    lock (verrou)
                    {
                        journal.WriteLine(l); derniere = l.Trim();
                        if (l.StartsWith("Built ", StringComparison.Ordinal)) dossier = Path.GetDirectoryName(l[6..].Trim());
                        if (Etape(l) is { } e) t.Etape = e;
                        if ((DateTime.Now - vu).TotalMilliseconds < 400) return;   // une recompilation écrit des milliers de lignes : l'écran n'en suit que quelques-unes
                        vu = DateTime.Now;
                    }
                    Dispatcher.UIThread.Post(lib.Signaler);
                }
                using var p = Process.Start(psi) ?? throw new InvalidOperationException("ScarletNX n'a pas démarré");
                processus = p;
                p.OutputDataReceived += (_, e) => Ligne(e.Data); p.ErrorDataReceived += (_, e) => Ligne(e.Data);
                p.BeginOutputReadLine(); p.BeginErrorReadLine();
                await p.WaitForExitAsync(); p.WaitForExit();
                processus = null;
                if (abandon) throw new OperationCanceledException();
                if (p.ExitCode != 0) { journal.Flush(); throw new InvalidOperationException(Raison(c.Journal, derniere != "" ? derniere : $"ScarletNX s'est arrêté (code {p.ExitCode})")); }
            }
            dossier ??= Directory.GetDirectories(Recompiles).Where(d => !avant.Contains(d)).OrderByDescending(Directory.GetLastWriteTime).FirstOrDefault()
                ?? Directory.GetDirectories(Recompiles).OrderByDescending(Directory.GetLastWriteTime).FirstOrDefault();
            if (dossier == null || !Pret(dossier)) throw new InvalidOperationException("ScarletNX a fini sans produire le jeu : voir le journal");
            if (c.Mod != null)
            {   // un mod demandé avec le jeu : posé dans son dossier, puis le code est recompilé avec lui (un mod en ligne est un mod de code)
                t.Etape = "Installation du mod…"; lib.Signaler();
                var nom = await Task.Run(() => InstallerMod(dossier, c.Mod, Path.GetFileNameWithoutExtension(c.Mod.TrimEnd(Path.DirectorySeparatorChar, '/')), remplacer: true));
                Journal.Ecrire($"mod installé avec le jeu : {nom}");
                Ini.Ecrire(Reglages(dossier), "Network", "network", "1");   // un mod en ligne a besoin de la connexion du PC, avec ou sans adresse réglée
                if (!string.IsNullOrWhiteSpace(c.Serveur)) File.WriteAllText(FichierServeur(dossier), c.Serveur.Trim());
                if (Directory.Exists(Path.Combine(Mods(dossier), nom, "exefs")))
                {
                    t.Etape = "Recompilation du code avec le mod…"; lib.Signaler();
                    var (code, erreur) = await Executer(exe, ArgumentsRecompiler(dossier), c.Journal);
                    if (code != 0) throw new InvalidOperationException(Raison(c.Journal, erreur));
                }
            }
            Noter(Chantiers().Where(x => x.Id != c.Id).ToList());
            t.Etape = "Terminé"; t.Fraction = 1; t.Fini = true;
            Journal.Ecrire($"jeu Switch construit : {Path.GetFileName(dossier)} ({Nom(dossier)}), moteur {Moteur.Version}");
            EnCours = null; lib.Recharger(selectionner: "switch:" + Path.GetFileName(dossier));
        }
        catch (OperationCanceledException)
        {
            Noter(Chantiers().Where(x => x.Id != c.Id).ToList());
            t.Etape = "Construction abandonnée"; t.Fini = true;   // voulu : pas une erreur, la carte s'en va seule EnCours = null; lib.Recharger();
        }
        catch (Exception e)
        {
            // le chantier reste : sa tuile propose « Reprendre », et dit pourquoi il s'est arrêté
            // Le jeu lui-même est construit et seule l'étape du mod a échoué : il est jouable en local, et on le dit.
            var modSeul = !arret && c.Mod != null && dossier != null && Pret(dossier);
            var raison = arret ? "Construction arrêtée" : SansChemin(e.Message); if (raison.Length > 160) raison = raison[..160];
            if (modSeul) raison = "Le jeu est construit et jouable en local. Le mod en ligne n'a pas pu être ajouté : " + raison;
            t.Erreur = raison; t.Etape = arret || modSeul ? raison : "Échec : " + raison; t.Fini = true; Journal.Ecrire($"construction de {c.Titre} : {e.Message}");
            c.Raison = arret ? null : raison; c.ModSeul = modSeul; Garder(c);
            if (modSeul) lib.Recharger();   // la tuile du jeu apparaît : il se lance sans le mod
        }
        EnCours = null; processus = null; lib.Signaler();
        lib.FinTache(t);
    }
    /// Lance ScarletNX et attend la fin, ce qu'il écrit ajouté au journal : son code de sortie et sa dernière ligne
    /// Pourquoi ScarletNX s'est arrêté. Sa dernière ligne est souvent générale (« Extraction failed (exit status 1). You can run the
    /// same command again. ») : la vraie raison est écrite juste avant, par l'étape qui a échoué. On rend la dernière ligne du journal
    /// qui parle d'une erreur sans être cette phrase générale ; à défaut, la dernière ligne telle quelle.
    static string Raison(string journal, string derniere)
    {
        try
        {
            string[] mots = ["error", "failed", "fail:", "cannot", "can't", "could not", "couldn't", "missing", "not found", "no such", "invalid", "denied", "not enough", "no space", "corrupt", "wrong", "unsupported", "needs "];
            using var f = new FileStream(journal, FileMode.Open, FileAccess.Read, FileShare.ReadWrite); using var r = new StreamReader(f);
            var lignes = r.ReadToEnd().Split('\n').Select(l => l.Trim()).Where(l => l != "").TakeLast(400).ToList();
            bool Generale(string l) => l.Contains("You can run the same command", StringComparison.OrdinalIgnoreCase) || l.Contains("exit status", StringComparison.OrdinalIgnoreCase);
            var precise = lignes.LastOrDefault(l => !Generale(l) && mots.Any(m => l.Contains(m, StringComparison.OrdinalIgnoreCase)));
            if (precise == null) return SansChemin(derniere);
            precise = System.Text.RegularExpressions.Regex.Replace(precise, @"^scarletnx(\.exe)?:\s*", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            return SansChemin(Generale(derniere) ? precise : derniere);
        }
        catch { return SansChemin(derniere); }
    }
    /// Recompiler un jeu déjà construit, là où il est (après un changement de ses mods de code). ScarletNX le reconnaît par son
    /// dossier (recompiled\<id>) ou par son programme (recompiled\<id>\<id>.exe) : driver.c, prepared_game. Le chemin
    /// « <id>\<id> » sans .exe, donné jusqu'ici, n'est ni l'un ni l'autre sur Windows : ScarletNX le prenait pour un dossier de
    /// jeu extrait et répondait « holds no exefs/main ». On donne le dossier.
    static string[] ArgumentsRecompiler(string dossierJeu) => ["--data", Moteur.Donnees, "-r", dossierJeu.TrimEnd('\\', '/')];
    /// Une raison sans chemin : le joueur n'a rien à faire de « C:\Users\…\AppData\… », et un chemin dit son nom de session. On
    /// garde le nom du fichier ou du dossier, entre guillemets.
    public static string SansChemin(string raison)
    {
        raison = System.Text.RegularExpressions.Regex.Replace(raison, @"^scarletnx(\.exe)?:\s*", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        // un chemin Windows (C:\dossier\…, les dossiers pouvant contenir des espaces) ou Unix (/a/b/c) : on n'en garde que le dernier morceau
        raison = System.Text.RegularExpressions.Regex.Replace(raison, @"[A-Za-z]:\\(?:[^\\/:*?""<>|\r\n]+\\)*([^\\/:*?""<>|\s]+)", m => "« " + m.Groups[1].Value + " »");
        raison = System.Text.RegularExpressions.Regex.Replace(raison, @"(?<![\w.»])/(?:[^/\s:]+/)+([^/\s:]+)", m => "« " + m.Groups[1].Value + " »");
        return raison.Trim();
    }
    static async Task<(int code, string derniere)> Executer(string exe, string[] arguments, string journal)
    {
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Moteur.Donnees };
        foreach (var a in arguments) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("ScarletNX n'a pas démarré");
        processus = p;
        var sortie = p.StandardOutput.ReadToEndAsync(); var erreurs = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync(); processus = null;
        var texte = await sortie + await erreurs; File.AppendAllText(journal, "\n" + string.Join(' ', arguments) + "\n" + texte);
        if (abandon) throw new OperationCanceledException();
        return (p.ExitCode, texte.Split('\n').LastOrDefault(l => l.Trim() != "")?.Trim() ?? $"code {p.ExitCode}");
    }

    /// Pose un mod (un dossier, ou un .zip) dans le dossier des mods d'un jeu, et rend son nom. Refuse ce qui n'est pas un mod.
    /// `remplacer` : un mod du même nom déjà là part à la Corbeille (une construction reprise réinstalle son mod en ligne ; sans ça
    /// elle butait sur celui qu'elle avait posé au premier essai). Ajouté à la main, un nom déjà pris reste refusé.
    public static string InstallerMod(string dossierJeu, string source, string nom, bool remplacer = false)
    {
        string? tmp = null;
        try
        {
            if (File.Exists(source))
            {
                if (!source.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("une archive de mod doit être un .zip");
                tmp = Path.Combine(Dossiers.Dossier("telechargements"), "mod-" + Guid.NewGuid().ToString("N")[..8]); Moteur.Extraire(source, tmp); source = tmp;
            }
            if (!Directory.Exists(source)) throw new DirectoryNotFoundException("le mod n'est plus là : " + source);
            if (Racine(source) is not { } racine) throw new InvalidDataException("ce n'est pas un mod : il n'y a ni dossier romfs ni dossier exefs dedans");
            nom = Dossiers.NomSur(nom.Trim().TrimStart('.')); if (nom == "") nom = "mod";
            var mods = Mods(dossierJeu); var cible = Path.Combine(mods, nom);
            if (Directory.Exists(cible) && !remplacer) throw new InvalidDataException($"un mod s'appelle déjà « {nom} » : supprime-le d'abord");
            if (Path.GetFullPath(racine).StartsWith(Path.GetFullPath(mods), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("ce dossier est déjà dans les mods du jeu");
            // copié sous un nom caché puis renommé : une copie coupée ne se montre jamais comme un mod (ScarletNX fait pareil)
            var enCours = Path.Combine(mods, "." + nom + ".adding"); if (Directory.Exists(enCours)) Directory.Delete(enCours, true);
            Copier(racine, enCours);
            if (Directory.Exists(cible) && !Systeme.Corbeille(cible)) throw new IOException($"l'ancien mod « {nom} » n'a pas pu être mis à la Corbeille");
            Directory.Move(enCours, cible);
            return nom;
        }
        finally { try { if (tmp != null && Directory.Exists(tmp)) Directory.Delete(tmp, true); } catch { } }   // la copie de travail de Home, pas un fichier de l'utilisateur
    }
    /// Le dossier qui porte vraiment le mod : celui qu'on a donné, ou un seul sous-dossier quand l'archive a un dossier de plus autour
    public static string? Racine(string d)
    {
        for (var i = 0; i < 3 && d != null; i++)
        {
            if (Directory.Exists(Path.Combine(d, "romfs")) || Directory.Exists(Path.Combine(d, "exefs"))) return d;
            var sous = Directory.GetDirectories(d); if (sous.Length != 1) return null; d = sous[0];
        }
        return null;
    }
    public static void Copier(string de, string vers)
    {
        Directory.CreateDirectory(vers);
        foreach (var f in Directory.GetFiles(de)) { if ((File.GetAttributes(f) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("le mod contient un lien : refusé"); File.Copy(f, Path.Combine(vers, Path.GetFileName(f))); }
        foreach (var d in Directory.GetDirectories(de)) { if ((File.GetAttributes(d) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("le mod contient un lien : refusé"); Copier(d, Path.Combine(vers, Path.GetFileName(d))); }
    }

    /// Ce que ScarletNX est en train de faire, en clair. Il n'annonce pas de pourcentage : la pastille montre l'étape, pas un chiffre.
    static string? Etape(string l) =>
        l.StartsWith("Recompiling ", StringComparison.Ordinal) ? "Recompilation du code…" : l.StartsWith("LLVM", StringComparison.Ordinal) ? "Compilation…" :
        l.StartsWith("Built ", StringComparison.Ordinal) ? "Assemblage du jeu…" : l.Contains("xtract", StringComparison.Ordinal) ? "Copie du jeu dans Home…" : null;

    /// Avant de désinstaller : ScarletNX range d'ordinaire les sauvegardes hors du jeu (save/ de son dossier de données), mais un jeu
    /// réglé sur save_layout=game les garde dans <id>_data/save. Celles-là sont mises de côté dans sauvegardes/<id> au lieu de partir.
    public static void GarderSauvegardes(Jeu j)
    {
        try
        {
            var dans = Path.Combine(Path.GetDirectoryName(Mods(j.Dossier)) ?? "", "save");
            if (!Directory.Exists(dans) || !Directory.EnumerateFileSystemEntries(dans).Any()) return;
            var cible = Dossiers.Fichier("sauvegardes", Path.GetFileName(j.Dossier) + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"));
            Directory.CreateDirectory(Path.GetDirectoryName(cible)!); Directory.Move(dans, cible);
            Home.Journal.Ecrire($"sauvegardes de {j.Nom} gardées : {cible}");
        }
        catch (Exception e) { Home.Journal.Ecrire($"sauvegardes de {j.Nom} : {e.Message}"); }
    }
    public static void Abandonner(Bibliotheque lib, Chantier c)
    {
        if (EnCours == c.Id && processus is { } p) { abandon = true; try { p.Kill(true); } catch { } return; }   // la suite se fait quand le programme s'arrête
        Noter(Chantiers().Where(x => x.Id != c.Id).ToList()); lib.FermerMenus(); lib.Recharger(); lib.Dire(c.ModSeul ? "Le jeu reste jouable en local, sans le mod" : "Construction abandonnée");
    }

    /// Télécharge ScarletNX d'avance, avec la pastille d'avancement ; `ensuite` se fait quand c'est installé (comme `apresTache` sur Mac)
    public static async Task PreparerMoteur(Bibliotheque lib, string titre = "Composants Nintendo", Action? ensuite = null, bool derniere = false)
    {
        if (lib.Tache is { Fini: false }) { lib.Dire("Une autre tâche est en cours : attends qu'elle finisse"); return; }
        var t = new Tache { Titre = titre, Etape = "Téléchargement du moteur…" }; lib.Tache = t; lib.Signaler();
        var reussi = false;
        try { await Moteur.Preparer(t, lib.Signaler, derniere); t.Etape = "Prêt"; t.Fraction = 1; t.Fini = true; reussi = true; }
        catch (Exception e) { t.Erreur = e.Message; t.Etape = "Échec : " + e.Message; t.Fini = true; Journal.Ecrire("moteur : " + e.Message); }
        lib.Signaler(); if (reussi) ensuite?.Invoke();
        lib.FinTache(t);
    }

    /// Recompile le code d'un jeu déjà construit, sans son dump : nécessaire après un changement de mod de code (exefs)
    public static async Task Recompiler(Bibliotheque lib, Jeu j)
    {
        var c = new Chantier { Id = "recompilation:" + j.Id, Titre = j.Nom, Journal = Dossiers.Fichier("log", "recompilation-" + Path.GetFileName(j.Dossier) + ".log") };
        if (lib.Tache is { Fini: false }) { lib.Dire("Une autre tâche est en cours : attends qu'elle finisse"); return; }
        var t = new Tache { Titre = "Mods de " + j.Nom, Etape = "Recompilation du code…" }; lib.Tache = t; lib.FermerMenus();
        try
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("la recompilation ne se fait que sur Windows");
            var exe = await Moteur.Preparer(t, lib.Signaler); t.Fraction = null; t.Etape = "Recompilation du code…"; lib.Signaler();
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Moteur.Donnees };
            foreach (var a in ArgumentsRecompiler(j.Dossier)) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("ScarletNX n'a pas démarré");
            var sortie = p.StandardOutput.ReadToEndAsync(); var erreurs = p.StandardError.ReadToEndAsync();
            await p.WaitForExitAsync(); File.WriteAllText(c.Journal, await sortie + await erreurs);
            if (p.ExitCode != 0) throw new InvalidOperationException(SansChemin((await erreurs).Trim().Split('\n').LastOrDefault(x => x.Trim() != "")?.Trim() ?? $"ScarletNX s'est arrêté (code {p.ExitCode})"));
            t.Etape = "Mods appliqués"; t.Fraction = 1; t.Fini = true;
        }
        catch (Exception e) { t.Erreur = e.Message; t.Etape = "Échec : " + e.Message; t.Fini = true; Journal.Ecrire($"recompilation de {j.Nom} : {e.Message}"); }
        lib.Signaler();
        lib.FinTache(t);
    }
}

/// Ce que Home trouve seul sur le PC pour construire un jeu : les dumps, les clés, le mod en ligne. Il regarde Téléchargements, Bureau,
/// Documents (trois niveaux) et la racine des autres disques (deux niveaux), comme `fichiersCandidats` sur Mac. Il ne lit que les noms
/// des fichiers, l'en-tête des .nsp et la liste des fichiers d'un .zip : rien n'est envoyé nulle part.
public static class Trouvailles
{
    public enum Sorte { Base, Maj, Dlc, Inconnu }
    static List<string> fichiers = new(), exefs = new(); static DateTime quand = DateTime.MinValue; static readonly object verrou = new();
    static readonly Dictionary<string, (Sorte, string?)> lus = new();
    static readonly string[] Extensions = [".nsp", ".xci", ".zip", ".keys"];

    /// Tous les fichiers utiles trouvés (gardés deux minutes : l'assistant y revient à chaque étape)
    public static List<string> Tout(bool frais = false)
    {
        lock (verrou)
        {
            if (!frais && (DateTime.Now - quand).TotalMinutes < 2) return fichiers;
            var f = new List<string>(); var e = new List<string>(); var vus = 0;
            void Parcourir(string dossier, int niveau)
            {
                if (niveau < 0 || vus > 30000) return;   // un dossier énorme ne bloque pas la recherche
                try
                {
                    foreach (var x in Directory.EnumerateFiles(dossier)) { vus++; if (Extensions.Contains(Path.GetExtension(x).ToLowerInvariant())) f.Add(x); }
                    foreach (var x in Directory.EnumerateDirectories(dossier))
                    {
                        var n = Path.GetFileName(x); vus++;
                        if (n.StartsWith('.') || n.StartsWith('$') || (File.GetAttributes(x) & (FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint)) != 0) continue;
                        if (n.Equals("exefs", StringComparison.OrdinalIgnoreCase)) e.Add(x);
                        Parcourir(x, niveau - 1);
                    }
                }
                catch { }   // un dossier qu'on n'a pas le droit de lire
            }
            var maison = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            // HOME_CHERCHER=<dossier> : pour les essais, ne regarder que là
            if (Environment.GetEnvironmentVariable("HOME_CHERCHER") is { Length: > 0 } essai) Parcourir(essai, 3);
            else foreach (var d in new[] { Path.Combine(maison, "Downloads"), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments) }.Where(d => d != "" && Directory.Exists(d)).Distinct())
                Parcourir(d, 3);
            if (OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("HOME_CHERCHER") is not { Length: > 0 })
                foreach (var disque in DriveInfo.GetDrives().Where(x => x.IsReady && x.DriveType is DriveType.Fixed or DriveType.Removable && !maison.StartsWith(x.Name, StringComparison.OrdinalIgnoreCase)))
                    Parcourir(disque.Name, 2);
            fichiers = f.Distinct().OrderByDescending(x => { try { return File.GetLastWriteTime(x); } catch { return DateTime.MinValue; } }).ToList(); exefs = e; quand = DateTime.Now;
            return fichiers;
        }
    }
    public static bool EstDump(string f) => Path.GetExtension(f).ToLowerInvariant() is ".nsp" or ".xci";
    /// « Téléchargements · 14,2 Go » : où est le fichier, et sa taille
    public static string Lieu(string f, bool taille = true)
    {
        var d = Path.GetFileName(Path.GetDirectoryName(f) ?? "") is { Length: > 0 } n ? n : Path.GetPathRoot(f) ?? "";
        d = d switch { "Downloads" => "Téléchargements", "Desktop" => "Bureau", "Documents" => "Documents", _ => d };
        if (!taille) return d;
        try { var o = new FileInfo(f).Length; return d + " · " + (o >= 1L << 30 ? $"{o / (double)(1L << 30):0.0} Go" : $"{o / (1L << 20)} Mo"); } catch { return d; }
    }

    /// Ce qu'est un dump, et de quel jeu. Le numéro de titre dit tout : il finit par 000 pour un jeu, 800 pour sa mise à jour, autre
    /// chose pour un DLC. On le lit dans le nom du ticket d'un .nsp, sinon entre crochets dans le nom du fichier ([0100…]) ; à défaut,
    /// les mots du nom (« update », « dlc », « [v65536] »). Un .xci sans indice est pris pour un jeu.
    public static (Sorte sorte, string? titre) Lire(string f)
    {
        lock (lus) if (lus.TryGetValue(f, out var deja)) return deja;
        string? id = null; var nom = Path.GetFileName(f);
        try
        {
            if (f.EndsWith(".nsp", StringComparison.OrdinalIgnoreCase))
            {
                using var s = File.OpenRead(f); var h = new byte[16];
                if (s.Read(h, 0, 16) == 16 && Encoding.ASCII.GetString(h, 0, 4) == "PFS0")
                {
                    int n = BitConverter.ToInt32(h, 4), t = BitConverter.ToInt32(h, 8);
                    if (n > 0 && n < 4096 && t > 0 && t < 1 << 20)
                    {
                        var reste = new byte[n * 24 + t];
                        if (s.Read(reste, 0, reste.Length) == reste.Length && System.Text.RegularExpressions.Regex.Match(Encoding.UTF8.GetString(reste, n * 24, t), @"(0[0-9A-Fa-f]{15})[0-9A-Fa-f]{16}\.tik", System.Text.RegularExpressions.RegexOptions.IgnoreCase) is { Success: true } tik) id = tik.Groups[1].Value.ToUpperInvariant();
                    }
                }
            }
        }
        catch { }
        if (id == null && System.Text.RegularExpressions.Regex.Match(nom, @"\[(0[0-9A-Fa-f]{15})\]") is { Success: true } crochet) id = crochet.Groups[1].Value.ToUpperInvariant();
        Sorte sorte;
        if (id != null) sorte = id.EndsWith("000") ? Sorte.Base : id.EndsWith("800") ? Sorte.Maj : Sorte.Dlc;
        else
        {
            // « maj » et « upd » seulement en mots entiers, comme sur Mac : « Majora's Mask » n'est pas une mise à jour
            var n = nom.ToLowerInvariant(); var version = System.Text.RegularExpressions.Regex.Match(n, @"\[v(\d+)\]");
            sorte = n.Contains("dlc") ? Sorte.Dlc : n.Contains("update") || n.Contains("patch") || n.Contains("mise a jour") || System.Text.RegularExpressions.Regex.IsMatch(n, "(?<![a-z])(maj|upd)(?![a-z])") || (version.Success && version.Groups[1].Value.TrimStart('0') != "") ? Sorte.Maj
                : n.EndsWith(".xci") || (version.Success) ? Sorte.Base : Sorte.Inconnu;
        }
        lock (lus) lus[f] = (sorte, id);
        return (sorte, id);
    }
    /// Le numéro du jeu de base auquel un dump se rattache (lui-même, sa mise à jour ou un de ses DLC)
    static string? BaseDe(string f)
    {
        var (sorte, id) = Lire(f);
        if (id == null) return sorte == Sorte.Base ? MenusSwitch.ModPour(f)?.Tid : null;
        if (sorte != Sorte.Dlc) return id[..13] + "000";
        return ulong.TryParse(id, System.Globalization.NumberStyles.HexNumber, null, out var v) ? (((v & ~0xFFFUL) - 0x1000)).ToString("X16") : null;
    }
    static bool MemeJeu(string f, string dump)
    {
        if (BaseDe(dump) is { } a && BaseDe(f) is { } b) return a == b;
        // pas de numéro des deux côtés : les mots du nom du jeu doivent se retrouver dans le nom de l'autre fichier
        string Nu(string x) => System.Text.RegularExpressions.Regex.Replace(Path.GetFileNameWithoutExtension(x), @"\[[^\]]*\]|\([^)]*\)", " ");
        return Titres.Correspond(Nu(f), Nu(dump)) && Nu(dump).Trim().Length >= 4;
    }
    public static List<string> MajsDe(string dump) => Tout().Where(f => f != dump && EstDump(f) && Lire(f).sorte == Sorte.Maj && MemeJeu(f, dump)).Take(30).ToList();
    public static string? MajDe(string dump) => Tout().FirstOrDefault(f => f != dump && EstDump(f) && Lire(f).sorte == Sorte.Maj && MemeJeu(f, dump));
    public static List<string> DlcDe(string dump) => Tout().Where(f => f != dump && EstDump(f) && Lire(f).sorte == Sorte.Dlc && MemeJeu(f, dump)).Take(60).ToList();

    /// Les clés : leur place habituelle (%USERPROFILE%\.switch, celle de ScarletNX et des émulateurs), sinon le fichier trouvé dans les dossiers regardés
    public static string? Cles(string nom)
    {
        var habituel = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".switch", nom);
        return Environment.GetEnvironmentVariable("HOME_CHERCHER") is not { Length: > 0 } && File.Exists(habituel) ? habituel : Tout().FirstOrDefault(f => Path.GetFileName(f).Equals(nom, StringComparison.OrdinalIgnoreCase));
    }
    public static List<string> ToutesLesCles(string nom)
    {
        var habituel = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".switch", nom);
        var liste = Tout().Where(f => Path.GetFileName(f).Equals(nom, StringComparison.OrdinalIgnoreCase)).ToList();
        if (Environment.GetEnvironmentVariable("HOME_CHERCHER") is not { Length: > 0 } && File.Exists(habituel)) liste.Insert(0, habituel);
        return liste;
    }
    /// Le mod en ligne d'un jeu, déjà sur le PC : un dossier exefs qui contient son module, ou un .zip qui le contient (on ne lit que sa liste de fichiers)
    public static string? Mod(MenusSwitch.ModEnLigne m)
    {
        Tout();
        if (exefs.FirstOrDefault(d => File.Exists(Path.Combine(d, m.Fichier))) is { } dossier) return Path.GetDirectoryName(dossier);
        foreach (var zip in fichiers.Where(f => f.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)).Take(300))
        {
            try
            {
                if (new FileInfo(zip).Length > 400L << 20) continue;
                using var a = ZipFile.OpenRead(zip);
                if (a.Entries.Any(e => e.FullName.Replace('\\', '/').EndsWith("exefs/" + m.Fichier, StringComparison.OrdinalIgnoreCase))) return zip;
            }
            catch { }   // une archive abîmée ou protégée
        }
        return null;
    }
}

/// Les écrans des jeux Switch : l'assistant de construction, le chantier, les mods, « Libérer de la place » (les mêmes mots que sur Mac)
public static class MenusSwitch
{
    const string Regle = "Home n'utilise que ce que tu as extrait de ta propre console : ton jeu et tes clés. Il n'en télécharge aucun.";

    // MARK: L'assistant de construction, dans l'ordre du Mac : le jeu, les clés, « Comment veux-tu jouer ? », le mod en ligne, la mise à
    // jour, les DLC, puis « Prêt à construire ». La mise à jour dépend du mode : facultative en local, obligatoire à la version que
    // le mod demande en ligne, absente si le mod veut le jeu de base.
    /// Ce qui a été choisi dans l'assistant
    public sealed class Demande { public string Dump = ""; public string? Maj; public List<string> Dlc = new(); public ModEnLigne? EnLigne; public string? Serveur; public bool MajCherchee, MajConfirmee, DlcCherches; }
    static string NomDe(Demande d) => Path.GetFileNameWithoutExtension(d.Dump);

    /// Home cherche lui-même les jeux déjà sur le PC (comme `proposer` sur Mac) : on choisit dans la liste, ou un autre fichier
    public static async void Ajouter(Bibliotheque lib)
    {
        Pas(lib, null, "jeu");
        lib.Ouvrir(new Menu { Titre = "Quel jeu ?", Symbole = "magnifyingglass", Texte = "Recherche des jeux sur ce PC…" });
        var jeux = await Task.Run(() => Trouvailles.Tout(frais: true).Where(f => Trouvailles.EstDump(f) && Trouvailles.Lire(f).sorte is Trouvailles.Sorte.Base or Trouvailles.Sorte.Inconnu).Take(40).ToList());
        if (lib.Menu?.Titre != "Quel jeu ?") return;   // il a fermé le menu pendant la recherche
        async void Autre() { if (lib.ChoisirFichier != null && await lib.ChoisirFichier("Le fichier du jeu, extrait de ta console", ["*.xci", "*.nsp"]) is { } f) Choisi(lib, f); }
        if (jeux.Count == 0) { lib.FermerMenus(); Autre(); return; }
        var m = new Menu { Titre = "Quel jeu ?", SousTitre = jeux.Count == 1 ? "1 jeu trouvé sur ce PC" : $"{jeux.Count} jeux trouvés sur ce PC", Symbole = "gamecontroller", Roue = true };
        foreach (var f in jeux) m.Elements.Add(new(Path.GetFileNameWithoutExtension(f), "gamecontroller", () => Choisi(lib, f), Trouvailles.Lieu(f)));
        m.Elements.Add(new("Chercher ailleurs…", "folder", Autre, "Avec l'Explorateur") { Section = " ", Teinte = Icones.Gris });
        lib.Ouvrir(m);
    }
    /// Le jeu est choisi : les clés. Home les installe seul s'il les trouve (à leur place habituelle, ou dans les dossiers qu'il regarde).
    static async void Choisi(Bibliotheque lib, string dump)
    {
        if (!File.Exists(Construction.ClesProd))
        {
            if (Trouvailles.Cles("prod.keys") is { } trouvees && Installer(lib, trouvees, Construction.ClesProd)) lib.Dire("Clés trouvées dans " + Trouvailles.Lieu(trouvees, taille: false) + " : installées dans Home");
            else if (lib.ChoisirFichier == null || await lib.ChoisirFichier("Les clés de ta console (prod.keys)", ["prod.keys", "*.keys"]) is not { } cles || !Installer(lib, cles, Construction.ClesProd)) return;
        }
        if (!File.Exists(Construction.ClesTitres) && Trouvailles.Cles("title.keys") is { } titres) Installer(lib, titres, Construction.ClesTitres);
        var d = new Demande { Dump = dump };
        if (dump.EndsWith(".nsp", StringComparison.OrdinalIgnoreCase) && !File.Exists(Construction.ClesTitres)) ClesTitres(lib, d); else Mode(lib, d);
    }
    /// Les clés sont copiées dans le dossier de Home, sur ce PC seulement : le jeu en a besoin à chaque lancement
    public static bool Installer(Bibliotheque lib, string source, string cible)
    {
        try { if (new FileInfo(source).Length > 4 << 20) throw new InvalidDataException("ce fichier est trop gros pour être un fichier de clés"); File.Copy(source, cible, true); return true; }
        catch (Exception e) { Journal.Ecrire("clés : " + e.Message); lib.Dire("Les clés n'ont pas pu être installées : " + e.Message); return false; }
    }
    /// Premier lancement, jeux Switch : le fichier prod.keys de la console, comme `accueilCles` sur Mac. Home regarde d'abord seul
    /// (« Recherche… ») ; l'étape se valide toujours : « Continuer » si les clés sont trouvées, « Plus tard » sinon (elles seront
    /// redemandées à la première construction).
    static string? clesVenuesDe;
    public static async void AccueilCles(Bibliotheque lib, Action puis, bool cherche = false)
    {
        if (!cherche && !File.Exists(Construction.ClesProd))
        {
            lib.Ouvrir(new Menu { Titre = "Clés de la console", Symbole = "key", Texte = "Recherche…" });
            var trouvees = await Task.Run(() => Trouvailles.Cles("prod.keys"));
            if (lib.Menu?.Titre != "Clés de la console") return;
            if (trouvees != null && Installer(lib, trouvees, Construction.ClesProd)) { clesVenuesDe = trouvees; if (Trouvailles.Cles("title.keys") is { } titres) Installer(lib, titres, Construction.ClesTitres); }
        }
        var la = File.Exists(Construction.ClesProd); void Ici() => AccueilCles(lib, puis, cherche: true); void Suite() { lib.FermerMenus(); puis(); }
        lib.Ouvrir(new Menu
        {
            Titre = "Clés de la console", Symbole = "key", Texte = "Home s'en sert pour construire tes jeux Switch. Elles restent sur ce PC.", Retour = Suite,
            Elements =
            {
                new(la ? "prod.keys : trouvé" : "Choisir prod.keys", "key", () => QuellesCles(lib, Ici), la ? (clesVenuesDe != null ? "Dans " + Trouvailles.Lieu(clesVenuesDe, taille: false) + " · " : "") + "choisir un autre fichier" : "Le fichier de clés extrait de ta propre console") { Teinte = Icones.Jaune },
                new(la ? "Continuer" : "Plus tard", "arrow.right", Suite) { Teinte = la ? Icones.Vert : Icones.Gris },
            },
        });
    }
    /// « Quelles clés ? » : les fichiers prod.keys que Home a trouvés, ou un autre à montrer
    static void QuellesCles(Bibliotheque lib, Action retour)
    {
        void Prendre(string f) { if (Installer(lib, f, Construction.ClesProd)) clesVenuesDe = f; retour(); }
        var m = new Menu { Titre = "Quelles clés ?", Symbole = "key", Roue = true, Retour = retour };
        foreach (var f in Trouvailles.ToutesLesCles("prod.keys").Take(12)) m.Elements.Add(new(Trouvailles.Lieu(f, taille: false), "key", () => Prendre(f), f));
        m.Elements.Add(new("Choisir un autre fichier…", "folder", async () => { if (lib.ChoisirFichier != null && await lib.ChoisirFichier("Le fichier prod.keys de ta console", ["prod.keys", "*.keys"]) is { } f) Prendre(f); else retour(); }, "prod.keys rangé ailleurs") { Section = " " });
        lib.Ouvrir(m);
    }
    static void ClesTitres(Bibliotheque lib, Demande d) => lib.Ouvrir(new Menu
    {
        Titre = "Clés du jeu", SousTitre = "Un second fichier de clés", Symbole = "key",
        Texte = "Ce fichier de jeu peut demander un second fichier de clés, title.keys, tiré lui aussi de ta console. Sans lui, certains jeux ne se lisent pas.",
        Elements =
        {
            new("Choisir title.keys", "key", async () => { if (lib.ChoisirFichier != null && await lib.ChoisirFichier("Les clés des jeux (title.keys)", ["title.keys", "*.keys"]) is { } f && Installer(lib, f, Construction.ClesTitres)) Mode(lib, d); }),
            new("Continuer sans", "arrow.right", () => Mode(lib, d)),
        },
    });

    // MARK: Jeux en ligne : la même table que sur Mac (Atelier.modsEnLigne dans app/main.swift). Ajouter un jeu = une ligne des deux côtés.
    /// Un mod en ligne appartient à son auteur : Home ne le fournit pas, ni dans le dépôt ni dans l'installeur. Le joueur donne une fois
    /// le fichier pris chez l'auteur ; Home le range dans mods-en-ligne/<title id>/<dossier> et le pose dans le jeu à la construction.
    /// `Maj` : la version du jeu que le mod exige (null = le jeu de base, sans mise à jour).
    /// Ces mods ont été essayés sur Mac. Sur Windows, avec ScarletNX, aucun ne l'a encore été : l'écran le dit.
    public sealed record ModEnLigne(string Tid, string Nom, string Auteur, string Source, string Dossier, string Fichier, string? Maj, string[] Indices);
    public static readonly ModEnLigne[] ModsEnLigne =
    [
        new("0100F2C0115B6000", "TOTK Online", "Kirbymimi", "son serveur Discord, lien sur gamebanana.com/wips/94930", "TOTK_Online", "subsdk4", "1.2.1", ["totk", "tears of the kingdom", "0100f2c0115b6000"]),
        new("0100000000010000", "Super Mario Odyssey Online", "CraftyBoss", "github.com/CraftyBoss/SuperMarioOdysseyOnline, le fichier « for Switch »", "SMO_Online_v1", "subsdk1", null, ["super mario odyssey", "0100000000010000"]),
    ];
    /// Les numéros de titre qu'un .nsp nomme dans sa table de fichiers (PFS0 : nombre d'entrées, taille de la table des noms, 24 octets par entrée)
    static List<string> TitresNSP(string fichier)
    {
        var ids = new List<string>();
        try
        {
            using var f = File.OpenRead(fichier); var h = new byte[16];
            if (f.Read(h, 0, 16) != 16 || Encoding.ASCII.GetString(h, 0, 4) != "PFS0") return ids;
            int n = BitConverter.ToInt32(h, 4), taille = BitConverter.ToInt32(h, 8);
            if (n <= 0 || n >= 4096 || taille <= 0 || taille >= 1 << 20) return ids;
            var reste = new byte[n * 24 + taille]; if (f.Read(reste, 0, reste.Length) != reste.Length) return ids;
            var noms = Encoding.UTF8.GetString(reste, n * 24, taille).ToUpperInvariant();
            foreach (var mot in new string(noms.Select(c => char.IsLetterOrDigit(c) ? c : ' ').ToArray()).Split(' ', StringSplitOptions.RemoveEmptyEntries))
                if (mot.Length >= 16 && (mot.StartsWith("01") || mot.StartsWith("04"))) ids.Add(mot[..16]);
        }
        catch { }
        return ids;
    }
    /// Le mod en ligne du jeu de ce fichier, s'il y en a un : par son numéro de titre (.nsp), sinon par le nom du fichier
    public static ModEnLigne? ModPour(string dump)
    {
        var ids = TitresNSP(dump).Select(t => t[..13] + "000").ToList(); var nom = Path.GetFileName(dump).ToLowerInvariant();
        return ModsEnLigne.FirstOrDefault(m => ids.Contains(m.Tid) || m.Indices.Any(nom.Contains));
    }
    static string DossierMod(ModEnLigne m) => Path.Combine(Dossiers.Racine, "mods-en-ligne", m.Tid, m.Dossier);
    static bool ModPret(ModEnLigne m) => File.Exists(Path.Combine(DossierMod(m), "exefs", m.Fichier));
    /// Range le mod donné (.zip ou dossier) : on y cherche exefs/<module du mod> ; le dossier qui contient cet exefs devient le mod.
    /// Un mod déjà rangé va à la Corbeille avant d'être remplacé.
    static bool RangerMod(ModEnLigne m, string source)
    {
        string? tmp = null;
        try
        {
            if (File.Exists(source)) { tmp = Path.Combine(Dossiers.Dossier("telechargements"), "mod-" + Guid.NewGuid().ToString("N")[..8]); Moteur.Extraire(source, tmp); source = tmp; }
            if (!Directory.Exists(source)) return false;
            var module = Directory.EnumerateFiles(source, m.Fichier, SearchOption.AllDirectories).FirstOrDefault(f => Path.GetFileName(Path.GetDirectoryName(f))!.Equals("exefs", StringComparison.OrdinalIgnoreCase));
            if (module == null) return false;
            var racine = Path.GetDirectoryName(Path.GetDirectoryName(module))!; var cible = DossierMod(m);
            if (Path.GetFullPath(racine).Equals(Path.GetFullPath(cible), StringComparison.OrdinalIgnoreCase)) return true;
            if (Directory.Exists(cible) && !Systeme.Corbeille(cible)) return false;
            Construction.Copier(racine, cible);
            Journal.Ecrire($"mod en ligne {m.Nom} rangé dans {cible}");
            return ModPret(m);
        }
        catch (Exception e) { Journal.Ecrire($"mod en ligne {m.Nom} : {e.Message}"); return false; }
        finally { try { if (tmp != null && Directory.Exists(tmp)) Directory.Delete(tmp, true); } catch { } }   // la copie de travail de Home
    }
    /// Un jeu sans mod en ligne connu : la personne le propose dans une demande GitHub pré-remplie, qu'elle complète et envoie elle-même
    static void SuggererMod(string jeu) => Systeme.Ouvrir("https://github.com/amas-cd/Home/issues/new?title=" + Uri.EscapeDataString("Mod en ligne : " + jeu) + "&body="
        + Uri.EscapeDataString($"Jeu : {jeu}\nNom du mod :\nAuteur :\nPage de l'auteur où le trouver :\nVersion du jeu demandée par le mod :\nDéjà essayé sur (Mac, Windows, Switch, émulateur) :\n"));

    // MARK: « Comment veux-tu jouer ? », juste après le jeu
    /// Les étapes de l'assistant pour ce jeu, dans l'ordre : le jeu, le mode, (en ligne : le mod, le serveur), la mise à jour, les DLC, le récapitulatif
    static void Pas(Bibliotheque lib, Demande? d, string quoi)
    {
        var e = new List<string> { "jeu", "mode" };
        if (d?.EnLigne != null) { e.Add("mod"); e.Add("serveur"); }
        if (d?.EnLigne is not { Maj: null }) e.Add("maj");
        e.Add("dlc"); e.Add("recap");
        lib.Pas = (Math.Max(1, e.IndexOf(quoi) + 1), e.Count);
    }
    /// Choisir des fichiers sans passer par l'Explorateur (`proposer` sur Mac) : la liste de ce que Home a trouvé, plusieurs d'un coup
    /// si on veut ; « Chercher ailleurs… » ouvre le sélecteur. Rien de trouvé : le sélecteur s'ouvre tout de suite.
    static async void Proposer(Bibliotheque lib, string titre, string? sousTitre, string icone, bool plusieurs, List<string> trouves, List<string> choisis, string question, Action retour, Action<List<string>> puis)
    {
        async Task Ailleurs() { if (lib.ChoisirFichier != null && await lib.ChoisirFichier(question, ["*.nsp", "*.xci"]) is { } f) puis(plusieurs ? choisis.Append(f).Distinct().ToList() : [f]); else retour(); }
        if (trouves.Count == 0) { await Ailleurs(); return; }
        void Montrer()
        {
            var m = new Menu { Titre = titre, SousTitre = sousTitre, Symbole = icone, Roue = true, Retour = retour };
            if (plusieurs && choisis.Count > 0) m.Elements.Add(new("Continuer", "arrow.right", () => puis(choisis), choisis.Count + (choisis.Count > 1 ? " choisis" : " choisi")) { Teinte = Icones.Vert });
            foreach (var f in trouves)
            {
                var pris = choisis.Contains(f);
                m.Elements.Add(new(Path.GetFileNameWithoutExtension(f), pris ? "checkmark" : icone, () =>
                {
                    if (!plusieurs) { puis([f]); return; }
                    if (pris) choisis.Remove(f); else choisis.Add(f);
                    Montrer();
                }, Trouvailles.Lieu(f)) { Teinte = pris ? Icones.Vert : null });
            }
            m.Elements.Add(new("Chercher ailleurs…", "folder", async () => await Ailleurs(), "Avec l'Explorateur") { Teinte = Icones.Gris });
            lib.Ouvrir(m);
        }
        Montrer();
    }
    public static void Mode(Bibliotheque lib, Demande d)
    {
        Pas(lib, d, "mode");
        void Local() { d.EnLigne = null; d.Serveur = null; Maj(lib, d); }
        var ici = () => Mode(lib, d);
        if (ModPour(d.Dump) is not { } m)
        {
            lib.Ouvrir(new Menu
            {
                Titre = "Comment veux-tu jouer ?", SousTitre = NomDe(d), Symbole = "person",
                Elements =
                {
                    new("En local", "gamecontroller", Local) { Teinte = Icones.Vert },
                    new("En ligne", "globe", () => lib.Ouvrir(new Menu
                    {
                        Titre = "Jouer en ligne", SousTitre = NomDe(d), Symbole = "globe", Retour = ici,
                        Texte = "Home ne connaît pas encore de mod en ligne pour ce jeu.\nSi tu en connais un, propose-le : il est essayé avant d'être ajouté.",
                        Elements = { new("Suggérer un mod en ligne", "safari", () => SuggererMod(NomDe(d)), "Ouvre une demande sur GitHub, à compléter"), new("Jouer en local", "gamecontroller", Local) { Teinte = Icones.Vert } },
                    }), "Aucun mod en ligne connu pour ce jeu") { Teinte = Icones.Gris },
                },
            });
            return;
        }
        lib.Ouvrir(new Menu
        {
            Titre = "Comment veux-tu jouer ?", SousTitre = NomDe(d), Symbole = "person",
            Elements = { new("En local", "gamecontroller", Local) { Teinte = Icones.Vert }, new("En ligne", "globe", () => EnLigne(lib, d, m), $"{m.Nom}, de {m.Auteur}") },
        });
    }
    public static void EnLigne(Bibliotheque lib, Demande d, ModEnLigne m)
    {
        Pas(lib, d, "mod");
        void Suite() { d.EnLigne = m; if (m.Maj == null) d.Maj = null; Serveur(lib, d); }
        void Donner(string? source) { if (source == null) return; if (RangerMod(m, source)) Suite(); else lib.Dire($"Ce fichier n'est pas {m.Nom} : il manque exefs/{m.Fichier}"); }
        if (!ModPret(m) && Trouvailles.Mod(m) is { } trouve && RangerMod(m, trouve)) lib.Dire($"{m.Nom} trouvé dans {Trouvailles.Lieu(trouve, taille: false)} : rangé dans Home");
        var pret = ModPret(m);
        var menu = new Menu
        {
            Titre = "Jouer en ligne", SousTitre = NomDe(d), Symbole = "globe", Retour = () => Mode(lib, d),
            Texte = $"{m.Nom} est un mod de {m.Auteur}. Home ne le fournit pas : prends-le chez son auteur ({m.Source}), puis donne-le ici une seule fois.\n"
                + (m.Maj != null ? $"Il demande la mise à jour {m.Maj} du jeu." : "Il demande le jeu de base, sans mise à jour.") + "\n\nPas encore essayé sur Windows : dis-nous si ça marche.",
        };
        if (pret) menu.Elements.Add(new("Continuer", "arrow.right", Suite, "Le mod est déjà sur ce PC") { Teinte = Icones.Vert });
        menu.Elements.Add(new(pret ? "Choisir un autre fichier…" : "Choisir le fichier du mod…", "shippingbox", async () => Donner(lib.ChoisirFichier != null ? await lib.ChoisirFichier($"{m.Nom} : le .zip du mod", ["*.zip"]) : null), $"Le .zip de {m.Auteur}"));
        menu.Elements.Add(new("Choisir le dossier du mod…", "folder", async () => Donner(lib.ChoisirDossier != null ? await lib.ChoisirDossier($"{m.Nom} : le dossier du mod") : null), $"Si tu l'as déjà décompressé : il contient exefs/{m.Fichier}"));
        menu.Elements.Add(new("Jouer en local", "gamecontroller", () => { d.EnLigne = null; d.Serveur = null; Maj(lib, d); }) { Teinte = Icones.Gris });
        lib.Ouvrir(menu);
    }
    /// L'adresse du serveur : Home la répondra quand le jeu ouvrira son clavier. Sans adresse, on la tape dans le jeu (et le chat du mod marche).
    static void Serveur(Bibliotheque lib, Demande d)
    {
        Pas(lib, d, "serveur");
        void Suite() { if (d.EnLigne?.Maj != null) Maj(lib, d); else Dlc(lib, d); }
        lib.Ouvrir(new Menu
        {
            Titre = "Le serveur", SousTitre = d.EnLigne?.Nom ?? NomDe(d), Symbole = "globe", Retour = () => EnLigne(lib, d, d.EnLigne!),
            Texte = "L'adresse que t'a donnée la personne qui tient le serveur. Home la répond à la place du clavier du jeu : c'est pratique, mais le chat du mod ne marche plus. Sans adresse, tu la taperas dans le jeu.",
            Elements =
            {
                new(string.IsNullOrWhiteSpace(d.Serveur) ? "Donner l'adresse" : "Changer l'adresse", "globe", () => lib.Demander("Adresse du serveur", "adresse:port", v => { d.Serveur = v; Serveur(lib, d); }), string.IsNullOrWhiteSpace(d.Serveur) ? "adresse:port" : "Adresse enregistrée"),
                new(string.IsNullOrWhiteSpace(d.Serveur) ? "Sans adresse" : "Continuer", "arrow.right", Suite, string.IsNullOrWhiteSpace(d.Serveur) ? "Je la taperai dans le jeu" : null) { Teinte = string.IsNullOrWhiteSpace(d.Serveur) ? Icones.Gris : Icones.Vert },
            },
        });
    }

    // MARK: La mise à jour : facultative en local ; en ligne, celle que le mod demande, et rien d'autre
    public static void Maj(Bibliotheque lib, Demande d)
    {
        Pas(lib, d, "maj");
        var exigee = d.EnLigne?.Maj;
        // la mise à jour de ce jeu, si elle est déjà sur le PC : proposée d'office (en ligne, elle passe quand même par « Es-tu sûr ? »)
        if (!d.MajCherchee) { d.MajCherchee = true; if (d.Maj == null && Trouvailles.MajDe(d.Dump) is { } t) { d.Maj = t; d.MajConfirmee = false; } }
        var m = new Menu
        {
            Titre = exigee != null ? "La mise à jour " + exigee : "La mise à jour", SousTitre = NomDe(d), Symbole = "arrow.down.circle",
            Retour = () => { if (d.EnLigne != null) Serveur(lib, d); else Mode(lib, d); },
            Alerte = exigee != null ? $"Il faut la version {exigee} du jeu" : null,
            Texte = exigee != null ? $"{d.EnLigne!.Nom} ne marche qu'avec la mise à jour {exigee} : donne ce fichier-là, pas une autre version." : "Si tu as la mise à jour du jeu, donne-la : elle est construite avec lui. Ce n'est pas obligatoire.",
        };
        void Suite()
        {
            if (exigee == null || d.MajConfirmee) { Dlc(lib, d); return; }
            // en ligne : une autre version que celle du mod donne un jeu qui ne se connecte pas, après une heure de construction. On redemande.
            lib.Ouvrir(new Menu
            {
                Titre = "Es-tu sûr ?", SousTitre = Path.GetFileName(d.Maj), Symbole = "exclamationmark", Retour = () => Maj(lib, d),
                Alerte = $"Ce fichier doit être la mise à jour {exigee}",
                Texte = $"Home ne peut pas le vérifier. Avec une autre version, {d.EnLigne!.Nom} ne marchera pas, et il faudra tout reconstruire.",
                Elements = { new($"Oui, c'est la {exigee}", "checkmark", () => { d.MajConfirmee = true; Dlc(lib, d); }) { Teinte = Icones.Vert }, new("Choisir un autre fichier", "arrow.left", () => Maj(lib, d)) { Teinte = Icones.Gris } },
            });
        }
        if (d.Maj != null) m.Elements.Add(new("Continuer", "arrow.right", Suite, Path.GetFileName(d.Maj) + " · " + Trouvailles.Lieu(d.Maj)) { Teinte = Icones.Vert });
        // la liste des mises à jour de ce jeu trouvées sur le PC ; « Chercher ailleurs… » ouvre le sélecteur
        m.Elements.Add(new(d.Maj == null ? "Choisir la mise à jour…" : "Choisir un autre fichier…", "arrow.down.circle", () =>
            Proposer(lib, "Quelle mise à jour ?", NomDe(d), "arrow.down.circle", false, Trouvailles.MajsDe(d.Dump), new(), exigee != null ? $"Le fichier de la mise à jour {exigee} du jeu" : "Le fichier de la mise à jour du jeu",
                () => Maj(lib, d), f => { if (f[0] != d.Dump) { d.Maj = f[0]; d.MajConfirmee = false; } Maj(lib, d); }), "Le fichier de la mise à jour"));
        if (exigee == null) m.Elements.Add(new("Pas de mise à jour", "arrow.right", () => { d.Maj = null; Dlc(lib, d); }) { Teinte = Icones.Gris });
        // sans cette mise à jour, pas de jeu en ligne : on repasse en local, où elle est facultative
        if (exigee != null) m.Elements.Add(new("Jouer en local à la place", "gamecontroller", () => { var mod = d.EnLigne!.Nom; d.EnLigne = null; d.Serveur = null; Maj(lib, d); lib.Dire("En local, sans " + mod); }, $"Sans {d.EnLigne!.Nom} : la mise à jour devient facultative") { Teinte = Icones.Gris });
        lib.Ouvrir(m);
    }
    static void Dlc(Bibliotheque lib, Demande d)
    {
        Pas(lib, d, "dlc");
        // les DLC de ce jeu déjà sur le PC sont ajoutés d'office ; « Tout retirer » les enlève
        if (!d.DlcCherches) { d.DlcCherches = true; foreach (var f in Trouvailles.DlcDe(d.Dump)) if (!d.Dlc.Contains(f)) d.Dlc.Add(f); }
        var m = new Menu { Titre = "Les contenus additionnels", SousTitre = NomDe(d), Symbole = "puzzlepiece", Retour = () => { if (d.EnLigne is { Maj: null }) Serveur(lib, d); else Maj(lib, d); } };
        // des DLC déjà trouvés : « Continuer » est le premier choix
        if (d.Dlc.Count > 0) m.Elements.Add(new("Continuer", "arrow.right", () => Recap(lib, d), d.Dlc.Count == 1 ? "1 DLC" : d.Dlc.Count + " DLC") { Teinte = Icones.Vert });
        // la liste des DLC de ce jeu trouvés sur le PC, plusieurs d'un coup ; « Chercher ailleurs… » ouvre le sélecteur
        m.Elements.Add(new(d.Dlc.Count == 0 ? "Choisir les DLC…" : "Changer les DLC…", "puzzlepiece", () =>
            Proposer(lib, "Quels DLC ?", NomDe(d), "puzzlepiece", true, Trouvailles.DlcDe(d.Dump).Union(d.Dlc).ToList(), d.Dlc.ToList(), "Le fichier d'un DLC du jeu",
                () => Dlc(lib, d), f => { d.Dlc = f.Where(x => x != d.Dump && x != d.Maj).Distinct().ToList(); Dlc(lib, d); }),
            d.Dlc.Count == 0 ? "Ceux que Home a trouvés, ou un autre fichier" : string.Join(", ", d.Dlc.Select(Path.GetFileNameWithoutExtension))));
        if (d.Dlc.Count == 0) m.Elements.Add(new("Pas de DLC", "arrow.right", () => Recap(lib, d)) { Teinte = Icones.Gris });
        if (d.Dlc.Count > 0) m.Elements.Add(new("Tout retirer", "xmark", () => { d.Dlc.Clear(); Dlc(lib, d); }) { Teinte = Icones.Gris });
        lib.Ouvrir(m);
    }
    public static void Recap(Bibliotheque lib, Demande d)
    {
        Pas(lib, d, "recap");
        var m = new Menu { Titre = "Prêt à construire", SousTitre = NomDe(d), Symbole = "hammer", Retour = () => Dlc(lib, d),
            Texte = "Home recompile le jeu en programme Windows et le copie dans son dossier : ensuite il se suffit à lui-même. Compte de quelques minutes à plus d'une heure, et la taille du jeu en place libre. " + Regle };
        m.Elements.Add(new() { Libelle = Path.GetFileName(d.Dump), Detail = "Le jeu", Icone = "gamecontroller", Info = true });
        m.Elements.Add(new() { Libelle = d.Maj != null ? Path.GetFileName(d.Maj) : "Aucune", Detail = "Mise à jour", Icone = "arrow.down.circle", Info = true });
        m.Elements.Add(new() { Libelle = d.Dlc.Count == 0 ? "Aucun" : string.Join(", ", d.Dlc.Select(Path.GetFileName)), Detail = "DLC", Icone = "puzzlepiece", Info = true });
        m.Elements.Add(new() { Libelle = d.EnLigne != null ? "En ligne · " + d.EnLigne.Nom : "En local", Detail = "Mode", Icone = d.EnLigne != null ? "globe" : "gamecontroller", Info = true });
        m.Elements.Add(new("Construire", "hammer", () =>
        {
            var ajouts = new List<string>(); if (d.Maj != null) ajouts.Add(d.Maj); ajouts.AddRange(d.Dlc);
            Construction.Commencer(lib, d.Dump, ajouts, d.EnLigne != null ? DossierMod(d.EnLigne) : null, d.Serveur);
        }, d.EnLigne != null ? "Le jeu, puis le mod : compte plus longtemps qu'un jeu seul" : null) { Teinte = Icones.Vert, Section = " " });
        lib.Ouvrir(m);
    }

    // MARK: Le chantier : la tuile d'un jeu en construction
    public static void Chantier(Bibliotheque lib, Jeu j)
    {
        if (Construction.Chantiers().FirstOrDefault(c => c.Id == j.Id) is not { } c) { lib.Recharger(); return; }
        if (Construction.EnCours == c.Id)
        {   // en cours : un seul choix, qui mène au menu de la tâche (Continuer, journal, Arrêter)
            lib.Ouvrir(new Menu { Titre = c.Titre, SousTitre = "En construction", Symbole = "hammer", Elements = { new("Voir l'avancement", "chart.bar", lib.OuvrirTacheMenu) { Teinte = Icones.Bleu } } });
            return;
        }
        // arrêtée : la raison en orange sous le titre, puis reprendre, lire le journal ou abandonner
        if (c.ModSeul)
        {   // le jeu est fait : il ne reste que le mod en ligne. On réessaie le mod seul, ou on joue en local sans lui.
            var seul = new Menu { Titre = c.Titre, SousTitre = "Le mod en ligne n'est pas posé", Symbole = "hammer", Alerte = c.Raison };
            seul.Elements.Add(new("Réessayer le mod", "arrow.clockwise", () => _ = Construction.Lancer(lib, c), "Le jeu n'est pas reconstruit : quelques minutes") { Teinte = Icones.Vert });
            seul.Elements.Add(new("Jouer en local", "gamecontroller", () => Construction.Abandonner(lib, c), "Garde le jeu sans le mod ; Mods → Ajouter un mod pour le remettre plus tard"));
            if (File.Exists(c.Journal)) seul.Elements.Add(new("Voir le journal", "doc", () => Systeme.Ouvrir(c.Journal), "Ce que la construction a écrit") { Teinte = Icones.Gris });
            lib.Ouvrir(seul); return;
        }
        var m = new Menu { Titre = c.Titre, SousTitre = "Construction arrêtée", Symbole = "hammer", Alerte = c.Raison };
        m.Elements.Add(new("Reprendre", "play.fill", () => _ = Construction.Lancer(lib, c), "La construction repart de là où elle peut") { Teinte = Icones.Vert });
        if (File.Exists(c.Journal)) m.Elements.Add(new("Voir le journal", "doc", () => Systeme.Ouvrir(c.Journal), "Ce que la construction a écrit") { Teinte = Icones.Gris });
        m.Elements.Add(new("Abandonner", "trash", () => Construction.Abandonner(lib, c), "Retire la tuile ; « Libérer de la place » enlève ce qui a été fait") { Destructif = true });
        lib.Ouvrir(m);
    }

    // MARK: Mods — un dossier par mod dans <jeu>_data/mods/, avec romfs/ et/ou exefs/ ; les mods désactivés sont dans mods_off= du .ini
    static List<string> ModsDe(Jeu j) { try { var d = Construction.Mods(j.Dossier); return Directory.Exists(d) ? Directory.GetDirectories(d).Select(Path.GetFileName).Where(n => n != null && !n.StartsWith('.')).Select(n => n!).OrderBy(n => n, StringComparer.Ordinal).ToList() : new(); } catch { return new(); } }
    static List<string> Eteints(Jeu j) => Ini.Lire(Construction.Reglages(j.Dossier), "Game", "mods_off").Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
    static bool DeCode(Jeu j, string mod) => Directory.Exists(Path.Combine(Construction.Mods(j.Dossier), mod, "exefs"));
    /// Un mod de code change le programme du jeu, que ScarletNX compile d'avance : après un changement, il faut recompiler
    static readonly HashSet<string> aRecompiler = new();

    public static void Mods(Bibliotheque lib, Jeu j)
    {
        var mods = ModsDe(j); var eteints = Eteints(j);
        var m = new Menu { Titre = "Mods", SousTitre = j.Nom, Symbole = "puzzlepiece", Retour = lib.OuvrirOptions };
        if (aRecompiler.Contains(j.Id))
            m.Elements.Add(new("Appliquer les mods", "hammer", () => { aRecompiler.Remove(j.Id); _ = Construction.Recompiler(lib, j); }, "Un mod de code a changé : le jeu doit être recompilé, quelques minutes"));
        m.Elements.Add(new("Ajouter un mod", "plus", () => AjouterMod(lib, j), "Depuis un dossier ou une archive .zip"));
        foreach (var mod in mods)
        {   // A active ou désactive directement, comme sur Mac
            var actif = !eteints.Contains(mod);
            m.Elements.Add(new(mod, actif ? "checkmark" : "puzzlepiece", () => Basculer(lib, j, mod), (actif ? "✓ Activé" : "Installé — A pour activer") + " · " + (DeCode(j, mod) ? "Mod de code" : "Mod de fichiers")) { Section = mod == mods[0] ? "Installés" : null, Teinte = actif ? Icones.Vert : null });
        }
        m.Elements.Add(new("Dossier des mods", "folder", () => { var d = Construction.Mods(j.Dossier); try { Directory.CreateDirectory(d); } catch { } Systeme.Ouvrir(d); }, "Un dossier par mod, avec romfs/ et/ou exefs/"));
        if (mods.Count > 0) m.Elements.Add(new("Supprimer un mod", "trash", () => SupprimerMod(lib, j)) { Destructif = true });
        var serveur = Construction.Serveur(j.Dossier);
        m.Elements.Add(new("Serveur en ligne" + (serveur != "" ? " : réglé" : ""), "globe", () => lib.Demander("Adresse du serveur", serveur != "" ? serveur + "  (« aucun » pour l'enlever)" : "adresse:port", v =>
        {
            if (v.Trim().Equals("aucun", StringComparison.OrdinalIgnoreCase)) v = "";
            try { File.WriteAllText(Construction.FichierServeur(j.Dossier), v.Trim()); if (v.Trim() != "") Ini.Ecrire(Construction.Reglages(j.Dossier), "Network", "network", "1"); } catch (Exception e) { Journal.Ecrire("serveur : " + e.Message); }
            Mods(lib, j);
        }), "Pour un mod en ligne : Home répond cette adresse quand le jeu ouvre son clavier. Tous ses claviers : le chat du mod ne marchera pas") { Section = "En ligne" });
        if (mods.Count == 0) m.Texte = "Aucun mod installé. Un mod est un dossier avec romfs/ (fichiers du jeu remplacés) et/ou exefs/ (code du jeu).";
        lib.Ouvrir(m);
    }
    static void Basculer(Bibliotheque lib, Jeu j, string mod)
    {
        var e = Eteints(j); var actif = !e.Contains(mod); if (actif) e.Add(mod); else e.Remove(mod);
        try { Ini.Ecrire(Construction.Reglages(j.Dossier), "Game", "mods_off", string.Join('/', e.Distinct())); if (DeCode(j, mod)) aRecompiler.Add(j.Id); }
        catch (Exception x) { Journal.Ecrire("mods_off : " + x.Message); lib.Dire("Le réglage n'a pas pu être écrit"); }
        Mods(lib, j);
    }
    static void SupprimerMod(Bibliotheque lib, Jeu j)
    {
        var m = new Menu { Titre = "Supprimer un mod", SousTitre = j.Nom, Symbole = "trash", Roue = true, Retour = () => Mods(lib, j) };
        foreach (var mod in ModsDe(j))
            m.Elements.Add(new(mod, "trash", () =>
            {
                var d = Path.Combine(Construction.Mods(j.Dossier), mod); var code = DeCode(j, mod);
                if (!Systeme.Corbeille(d)) { lib.Dire("Le mod n'a pas pu être mis à la Corbeille"); return; }
                if (code) aRecompiler.Add(j.Id);
                Journal.Ecrire($"mod supprimé : {mod} ({j.Nom})"); Mods(lib, j); lib.Dire(mod + " est à la Corbeille");
            }, "Le dossier du mod part à la Corbeille") { Destructif = true });
        lib.Ouvrir(m);
    }
    static void AjouterMod(Bibliotheque lib, Jeu j) => lib.Ouvrir(new Menu
    {
        Titre = "Ajouter un mod", SousTitre = j.Nom, Symbole = "plus", Retour = () => Mods(lib, j),
        Elements =
        {
            new("Depuis un dossier", "folder", async () => { if (lib.ChoisirDossier != null && await lib.ChoisirDossier("Le dossier du mod (il contient romfs et/ou exefs)") is { } d) await Poser(lib, j, d); }, "Un dossier qui contient romfs/ et/ou exefs/"),
            new("Depuis une archive", "shippingbox", async () => { if (lib.ChoisirFichier != null && await lib.ChoisirFichier("L'archive du mod (.zip)", ["*.zip"]) is { } zip) await Poser(lib, j, zip); }, "Un fichier .zip"),
        },
    });
    static async Task Poser(Bibliotheque lib, Jeu j, string source)
    {
        try
        {
            var nom = await Task.Run(() => Construction.InstallerMod(j.Dossier, source, Path.GetFileNameWithoutExtension(source.TrimEnd(Path.DirectorySeparatorChar, '/'))));
            if (DeCode(j, nom)) aRecompiler.Add(j.Id);
            Journal.Ecrire($"mod installé : {nom} ({j.Nom})"); Mods(lib, j); lib.Dire(nom + " est installé");
        }
        catch (Exception e) { Journal.Ecrire("installation d'un mod : " + e.Message); lib.Dire("Le mod n'a pas été installé : " + e.Message); }
    }

    // MARK: Réseau — le réglage network= du jeu. Un mod en ligne en a besoin ; ça ne suffit pas à dire qu'il marche.
    // MARK: Souris — la caméra à la souris (mouse_look de ScarletNX, section [Controllers] du .ini du jeu)
    /// Le moteur installé sait-il le faire ? Seul le ScarletNX de Home (versions « home-… ») a la caméra à la souris pour l'instant.
    public static bool MoteurAvecSouris => Moteur.Version?.StartsWith("home-") == true;
    static readonly string[] boutons = ["Aucun", "A", "B", "X", "Y", "L", "R", "ZL", "ZR", "+", "−", "Stick gauche (clic)", "Stick droit (clic)"];
    static int Reglage(Jeu j, string cle, int defaut) => int.TryParse(Ini.Lire(Construction.Reglages(j.Dossier), "Controllers", cle), out var v) ? v : defaut;
    static void Regler(Bibliotheque lib, Jeu j, string cle, int v)
    {
        try { Ini.Ecrire(Construction.Reglages(j.Dossier), "Controllers", cle, v.ToString()); }
        catch (Exception e) { Journal.Ecrire(cle + "= : " + e.Message); lib.Dire("Le réglage n'a pas pu être écrit"); }
    }
    public static void Souris(Bibliotheque lib, Jeu j)
    {
        bool active = Reglage(j, "mouse_look", 0) == 1, inverse = Reglage(j, "mouse_look_invert_y", 0) == 1; var sens = Math.Clamp(Reglage(j, "mouse_look_sensitivity", 50), 1, 100);
        var m = new Menu
        {
            Titre = "Souris", SousTitre = j.Nom, Symbole = "gamecontroller", Roue = true, Retour = lib.OuvrirOptions,
            Alerte = MoteurAvecSouris || Moteur.Version == null ? null : "Il faut mettre le moteur à jour : Menu → Composants → ScarletNX",
            Texte = "La souris tourne la caméra, en plus de la manette. En jeu, Ctrl + G rend la souris, et la reprend.",
        };
        m.Elements.Add(new("Caméra à la souris : " + (active ? "oui" : "non"), "gamecontroller", () => { Regler(lib, j, "mouse_look", active ? 0 : 1); Souris(lib, j); }, "Le pointeur est caché et gardé dans la fenêtre du jeu") { Teinte = active ? Icones.Vert : Icones.Gris });
        m.Elements.Add(new("Sensibilité : " + sens, "slider.horizontal.3", () => lib.Demander("Sensibilité de la souris", "De 1 à 100", v => { if (int.TryParse(v, out var n)) Regler(lib, j, "mouse_look_sensitivity", Math.Clamp(n, 1, 100)); else lib.Dire("Un nombre de 1 à 100"); Souris(lib, j); }, texte: sens.ToString()), "De 1 à 100 · 50 par défaut"));
        m.Elements.Add(new("Axe vertical : " + (inverse ? "inversé" : "normal"), "arrow.up.arrow.down", () => { Regler(lib, j, "mouse_look_invert_y", inverse ? 0 : 1); Souris(lib, j); }, "Inversé : souris vers le haut, caméra vers le bas"));
        foreach (var (nom, cle, defaut, role) in new[] { ("Clic gauche", "mouse_look_left", 4, "Attaque"), ("Clic droit", "mouse_look_right", 8, "Arc : maintenu, puis clic gauche pour tirer"), ("Clic du milieu", "mouse_look_middle", 7, "Cibler") })
        {
            var v = Math.Clamp(Reglage(j, cle, defaut), 0, 12);
            m.Elements.Add(new($"{nom} : {boutons[v]}", "hand.tap", () => BoutonSouris(lib, j, nom, cle, v), v == defaut ? role + " (Zelda)" : "Modifié") { Section = nom == "Clic gauche" ? "Boutons" : null });
        }
        m.Elements.Add(new("Remettre les boutons de Zelda", "arrow.uturn.backward", () => { Regler(lib, j, "mouse_look_left", 4); Regler(lib, j, "mouse_look_right", 8); Regler(lib, j, "mouse_look_middle", 7); Souris(lib, j); }, "Gauche Y, droit ZR, milieu ZL") { Teinte = Icones.Gris });
        lib.Ouvrir(m);
    }
    static void BoutonSouris(Bibliotheque lib, Jeu j, string nom, string cle, int actuel)
    {
        var m = new Menu { Titre = nom, SousTitre = "Quel bouton du jeu ?", Symbole = "hand.tap", Roue = true, Retour = () => Souris(lib, j) };
        for (var i = 0; i < boutons.Length; i++) { var n = i; m.Elements.Add(new(boutons[i], i == actuel ? "checkmark" : "circle", () => { Regler(lib, j, cle, n); Souris(lib, j); }) { Teinte = i == actuel ? Icones.Vert : null }); }
        lib.Ouvrir(m);
    }
    public static bool Internet(Jeu j) => Ini.Lire(Construction.Reglages(j.Dossier), "Network", "network") == "1";
    public static void BasculerInternet(Bibliotheque lib, Jeu j)
    {
        try { Ini.Ecrire(Construction.Reglages(j.Dossier), "Network", "network", Internet(j) ? "0" : "1"); }
        catch (Exception e) { Journal.Ecrire("network= : " + e.Message); lib.Dire("Le réglage n'a pas pu être écrit"); }
        lib.OuvrirOptions();
    }

    // MARK: Libérer de la place — ce qu'une construction laisse et qui ne sert plus
    static long Taille(string d) { try { return Directory.Exists(d) ? Directory.EnumerateFiles(d, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length) : 0; } catch { return 0; } }
    static string Lisible(long o) => o >= 1L << 30 ? $"{o / (double)(1L << 30):0.0} Go" : $"{o / (1L << 20)} Mo";
    public static void LibererPlace(Bibliotheque lib)
    {
        var m = new Menu { Titre = "Libérer de la place", Symbole = "trash", Retour = lib.OuvrirPlus };
        var ouverts = Construction.Chantiers().Count > 0;
        var restes = new List<(string nom, string dossier, string quoi)>();
        // un dossier de jeu sans son tampon de fin : une construction abandonnée (pas pendant qu'un chantier peut encore le reprendre)
        if (!ouverts && Directory.Exists(Construction.Recompiles))
            foreach (var d in Directory.GetDirectories(Construction.Recompiles).Where(d => !Construction.Jeux().Any(j => j.Dossier == d))) restes.Add((Path.GetFileName(d), d, "Construction abandonnée"));
        foreach (var (nom, d, quoi) in new[] { ("Fichiers de travail", Path.Combine(Moteur.Donnees, "work"), "Extractions provisoires de ScarletNX"), ("Téléchargements", Path.Combine(Dossiers.Racine, "telechargements"), "Archives déjà installées") })
            if (!ouverts && Directory.Exists(d) && Directory.EnumerateFileSystemEntries(d).Any()) restes.Add((nom, d, quoi));
        foreach (var (nom, d, quoi) in restes)
        {   // la taille dans le nom, puis une confirmation : rien ne part d'un seul appui
            var taille = Lisible(Taille(d));
            m.Elements.Add(new($"{nom} : {taille}", "trash", () => lib.Ouvrir(new Menu
            {
                Titre = "Mettre à la Corbeille ?", SousTitre = nom, Symbole = "trash", Retour = () => LibererPlace(lib), Elements =
                {
                    new($"Oui, {taille} à la Corbeille", "trash", () => { if (Systeme.Corbeille(d)) lib.Dire(taille + " à la Corbeille : vide-la pour récupérer la place"); else lib.Dire("Ce dossier n'a pas pu être mis à la Corbeille"); LibererPlace(lib); }, "Aucun jeu installé ne s'en sert") { Destructif = true },
                    new("Non", "arrow.uturn.backward", () => LibererPlace(lib)) { Teinte = Icones.Gris },
                },
            }), quoi + " · aucun jeu installé ne s'en sert") { Teinte = Icones.Rouge });
        }
        m.Texte = restes.Count > 0 ? "Rien ici ne sert à tes jeux construits. Ce que tu choisis part à la Corbeille : tu peux encore le reprendre."
            : ouverts ? "Une construction est en cours ou à reprendre : finis-la ou abandonne-la d'abord." : "Rien à enlever : aucune construction n'a laissé de reste.";
        lib.Ouvrir(m);
    }
}
