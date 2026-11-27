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
    static string Archive => RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "ScarletNX-windows-aarch64.zip" : "ScarletNX-windows-x86_64.zip";

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
        if (!derniere && Exe is { } la) return la;
        var reference = Reference(); var tag = reference.GetValueOrDefault("tag", ""); var empreinte = reference.GetValueOrDefault(Archive.Contains("aarch64") ? "aarch64" : "x86_64");
        var zip = Dossiers.Fichier("telechargements", Archive);
        void Avance(long lu, long total) { t.Fraction = total > 0 ? 0.9 * lu / total : null; t.Etape = $"Téléchargement du moteur… {lu / 1048576} Mo" + (total > 0 ? $" sur {total / 1048576}" : ""); Dispatcher.UIThread.Post(signaler); }
        string? recue = null;
        if (!derniere && tag != "")
        {
            try { recue = await Reseau.Telecharger($"https://github.com/{Depot}/releases/download/{tag}/{Archive}", zip, Avance); }
            catch (Exception e) { Journal.Ecrire($"ScarletNX {tag} n'est plus publié ({e.Message}) : on prend la dernière version"); }
        }
        if (recue == null)
        {
            using var d = await Reseau.Json($"https://api.github.com/repos/{Depot}/releases/latest") ?? throw new InvalidOperationException("la liste des versions de ScarletNX n'a pas pu être lue");
            tag = d.RootElement.GetProperty("tag_name").GetString() ?? "";
            var fichier = d.RootElement.GetProperty("assets").EnumerateArray().FirstOrDefault(a => a.GetProperty("name").GetString() == Archive);
            if (fichier.ValueKind != JsonValueKind.Object) throw new InvalidOperationException("la dernière version de ScarletNX n'a pas de build pour ce PC");
            var url = fichier.GetProperty("browser_download_url").GetString() ?? "";
            if (!url.StartsWith($"https://github.com/{Depot}/releases/download/", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("adresse de téléchargement inattendue");
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
    public string Journal { get; set; } = ""; public DateTime Debut { get; set; } = DateTime.Now;
}

public static class Construction
{
    static string Fichier => Dossiers.Fichier("constructions.json");
    public static List<Chantier> Chantiers() => Json.Lire<List<Chantier>>(Fichier);
    static void Noter(List<Chantier> c) => Json.Ecrire(Fichier, c);
    /// Le chantier qui tourne en ce moment (un seul à la fois : une recompilation prend presque tout le processeur)
    public static string? EnCours { get; private set; }
    static Process? processus; static bool abandon;
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
        var t = new Tache { Titre = "Construction de " + c.Titre, Etape = "Préparation du moteur…" };
        lib.Tache = t; EnCours = c.Id; abandon = false; lib.FermerMenus();
        string? dossier = null;
        try
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("un jeu Switch ne se construit que sur Windows");
            if (!File.Exists(c.Dump)) throw new FileNotFoundException("le fichier du jeu n'est plus là : " + c.Dump);
            if (!File.Exists(ClesProd)) throw new FileNotFoundException("les clés (prod.keys) ne sont plus installées dans Home");
            var exe = await Moteur.Preparer(t, lib.Signaler);
            t.Etape = "Lecture du jeu…"; t.Fraction = null; lib.Signaler();
            var avant = Directory.Exists(Recompiles) ? Directory.GetDirectories(Recompiles).ToHashSet() : new HashSet<string>();
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Moteur.Donnees };
            foreach (var a in Arguments(c)) psi.ArgumentList.Add(a);
            string derniere = ""; var verrou = new object(); DateTime vu = DateTime.MinValue;
            await using (var journal = new StreamWriter(c.Journal, false, Encoding.UTF8) { AutoFlush = true })
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
                if (p.ExitCode != 0) throw new InvalidOperationException(derniere != "" ? derniere : $"ScarletNX s'est arrêté (code {p.ExitCode})");
            }
            dossier ??= Directory.GetDirectories(Recompiles).Where(d => !avant.Contains(d)).OrderByDescending(Directory.GetLastWriteTime).FirstOrDefault()
                ?? Directory.GetDirectories(Recompiles).OrderByDescending(Directory.GetLastWriteTime).FirstOrDefault();
            if (dossier == null || !Pret(dossier)) throw new InvalidOperationException("ScarletNX a fini sans produire le jeu : voir le journal");
            if (c.Mod != null)
            {   // un mod demandé avec le jeu : posé dans son dossier, puis le code est recompilé avec lui (un mod en ligne est un mod de code)
                t.Etape = "Installation du mod…"; lib.Signaler();
                var nom = await Task.Run(() => InstallerMod(dossier, c.Mod, Path.GetFileNameWithoutExtension(c.Mod.TrimEnd(Path.DirectorySeparatorChar, '/'))));
                Journal.Ecrire($"mod installé avec le jeu : {nom}");
                if (!string.IsNullOrWhiteSpace(c.Serveur)) { Ini.Ecrire(Reglages(dossier), "Network", "network", "1"); File.WriteAllText(FichierServeur(dossier), c.Serveur.Trim()); }
                if (Directory.Exists(Path.Combine(Mods(dossier), nom, "exefs")))
                {
                    t.Etape = "Recompilation du code avec le mod…"; lib.Signaler();
                    var (code, erreur) = await Executer(exe, ["--data", Moteur.Donnees, "-r", Path.Combine(dossier, Path.GetFileName(dossier))], c.Journal);
                    if (code != 0) throw new InvalidOperationException("le jeu est construit, mais pas avec le mod : " + erreur);
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
            t.Etape = "Construction abandonnée"; t.Erreur = "Construction abandonnée"; t.Fini = true; EnCours = null; lib.Recharger();
        }
        catch (Exception e)
        {
            // le chantier reste : sa tuile propose « Reprendre »
            t.Erreur = e.Message; t.Etape = "Échec : " + e.Message; t.Fini = true; Journal.Ecrire($"construction de {c.Titre} : {e.Message}");
        }
        EnCours = null; processus = null; lib.Signaler();
        _ = Task.Delay(8000).ContinueWith(_ => Dispatcher.UIThread.Post(() => { if (lib.Tache == t) { lib.Tache = null; lib.Signaler(); } }));
    }
    /// Lance ScarletNX et attend la fin, ce qu'il écrit ajouté au journal : son code de sortie et sa dernière ligne
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
    public static string InstallerMod(string dossierJeu, string source, string nom)
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
            if (Directory.Exists(cible)) throw new InvalidDataException($"un mod s'appelle déjà « {nom} » : supprime-le d'abord");
            if (Path.GetFullPath(racine).StartsWith(Path.GetFullPath(mods), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("ce dossier est déjà dans les mods du jeu");
            // copié sous un nom caché puis renommé : une copie coupée ne se montre jamais comme un mod (ScarletNX fait pareil)
            var enCours = Path.Combine(mods, "." + nom + ".adding"); if (Directory.Exists(enCours)) Directory.Delete(enCours, true);
            Copier(racine, enCours); Directory.Move(enCours, cible);
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
    static void Copier(string de, string vers)
    {
        Directory.CreateDirectory(vers);
        foreach (var f in Directory.GetFiles(de)) { if ((File.GetAttributes(f) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("le mod contient un lien : refusé"); File.Copy(f, Path.Combine(vers, Path.GetFileName(f))); }
        foreach (var d in Directory.GetDirectories(de)) { if ((File.GetAttributes(d) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("le mod contient un lien : refusé"); Copier(d, Path.Combine(vers, Path.GetFileName(d))); }
    }

    /// Ce que ScarletNX est en train de faire, en clair. Il n'annonce pas de pourcentage : la pastille montre l'étape, pas un chiffre.
    static string? Etape(string l) =>
        l.StartsWith("Recompiling ", StringComparison.Ordinal) ? "Recompilation du code…" : l.StartsWith("LLVM", StringComparison.Ordinal) ? "Compilation…" :
        l.StartsWith("Built ", StringComparison.Ordinal) ? "Assemblage du jeu…" : l.Contains("xtract", StringComparison.Ordinal) ? "Copie du jeu dans Home…" : null;

    public static void Abandonner(Bibliotheque lib, Chantier c)
    {
        if (EnCours == c.Id && processus is { } p) { abandon = true; try { p.Kill(true); } catch { } return; }   // la suite se fait quand le programme s'arrête
        Noter(Chantiers().Where(x => x.Id != c.Id).ToList()); lib.FermerMenus(); lib.Recharger(); lib.Dire("Construction abandonnée");
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
            foreach (var a in new[] { "--data", Moteur.Donnees, "-r", Path.Combine(j.Dossier, Path.GetFileName(j.Dossier)) }) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("ScarletNX n'a pas démarré");
            var sortie = p.StandardOutput.ReadToEndAsync(); var erreurs = p.StandardError.ReadToEndAsync();
            await p.WaitForExitAsync(); File.WriteAllText(c.Journal, await sortie + await erreurs);
            if (p.ExitCode != 0) throw new InvalidOperationException((await erreurs).Trim().Split('\n').LastOrDefault(x => x.Trim() != "")?.Trim() ?? $"ScarletNX s'est arrêté (code {p.ExitCode})");
            t.Etape = "Mods appliqués"; t.Fraction = 1; t.Fini = true;
        }
        catch (Exception e) { t.Erreur = e.Message; t.Etape = "Échec : " + e.Message; t.Fini = true; Journal.Ecrire($"recompilation de {j.Nom} : {e.Message}"); }
        lib.Signaler();
        _ = Task.Delay(8000).ContinueWith(_ => Dispatcher.UIThread.Post(() => { if (lib.Tache == t) { lib.Tache = null; lib.Signaler(); } }));
    }
}

/// Les écrans des jeux Switch : l'assistant de construction, le chantier, les mods, « Libérer de la place » (les mêmes mots que sur Mac)
public static class MenusSwitch
{
    const string Regle = "Home n'utilise que ce que tu as extrait de ta propre console : ton jeu et tes clés. Il n'en télécharge aucun.";

    // MARK: L'assistant de construction : le jeu, les clés, les mises à jour et DLC, puis « Construire »
    public static async void Ajouter(Bibliotheque lib)
    {
        if (lib.ChoisirFichier == null || await lib.ChoisirFichier("Le jeu extrait de ta console (.xci ou .nsp)", ["*.xci", "*.nsp"]) is not { } dump) return;
        if (!File.Exists(Construction.ClesProd))
        {
            if (await lib.ChoisirFichier("Les clés de ta console (prod.keys)", ["prod.keys", "*.keys"]) is not { } cles) return;
            if (!Installer(lib, cles, Construction.ClesProd)) return;
        }
        if (dump.EndsWith(".nsp", StringComparison.OrdinalIgnoreCase) && !File.Exists(Construction.ClesTitres)) ClesTitres(lib, dump);
        else Ajouts(lib, dump, new());
    }
    /// Les clés sont copiées dans le dossier de Home, sur ce PC seulement : le jeu en a besoin à chaque lancement
    static bool Installer(Bibliotheque lib, string source, string cible)
    {
        try { if (new FileInfo(source).Length > 4 << 20) throw new InvalidDataException("ce fichier est trop gros pour être un fichier de clés"); File.Copy(source, cible, true); return true; }
        catch (Exception e) { Journal.Ecrire("clés : " + e.Message); lib.Dire("Les clés n'ont pas pu être installées : " + e.Message); return false; }
    }
    static void ClesTitres(Bibliotheque lib, string dump) => lib.Ouvrir(new Menu
    {
        Titre = "Clés du jeu", SousTitre = "Un fichier .nsp", Symbole = "key",
        Texte = "Un jeu en .nsp peut demander un second fichier de clés, title.keys, tiré lui aussi de ta console. Sans lui, certains .nsp ne se lisent pas.",
        Elements =
        {
            new("Choisir title.keys", "key", async () => { if (lib.ChoisirFichier != null && await lib.ChoisirFichier("Les clés des jeux (title.keys)", ["title.keys", "*.keys"]) is { } f && Installer(lib, f, Construction.ClesTitres)) Ajouts(lib, dump, new()); }),
            new("Continuer sans", "arrow.right", () => Ajouts(lib, dump, new())),
        },
    });
    static void Ajouts(Bibliotheque lib, string dump, List<string> ajouts)
    {
        var m = new Menu
        {
            Titre = "Construire le jeu", SousTitre = Path.GetFileName(dump), Symbole = "hammer",
            Texte = "Home recompile le jeu en programme Windows et le copie dans son dossier : ensuite il se suffit à lui-même, le fichier d'origine ne sert plus. "
                + "Compte de quelques minutes à plus d'une heure selon le jeu, et la taille du jeu en place libre. " + Regle,
        };
        m.Elements.Add(new("Construire", "hammer", () => Construction.Commencer(lib, dump, ajouts), ajouts.Count == 0 ? "Le jeu seul" : ajouts.Count == 1 ? "Avec 1 mise à jour ou DLC" : $"Avec {ajouts.Count} mises à jour ou DLC"));
        m.Elements.Add(new("Ajouter une mise à jour ou un DLC", "plus", async () =>
        {
            if (lib.ChoisirFichier != null && await lib.ChoisirFichier("Une mise à jour ou un DLC du jeu (.nsp ou .xci)", ["*.nsp", "*.xci"]) is { } f && !ajouts.Contains(f) && f != dump) ajouts.Add(f);
            Ajouts(lib, dump, ajouts);
        }, "Une mise à jour au plus, autant de DLC que tu veux"));
        foreach (var a in ajouts.ToList()) m.Elements.Add(new(Path.GetFileName(a), "xmark", () => { ajouts.Remove(a); Ajouts(lib, dump, ajouts); }, "Retirer de la liste"));
        lib.Ouvrir(m);
    }

    // MARK: Tears of the Kingdom en ligne, préparé d'un coup (windows/outils/totk-online.cmd lance Home avec --totk-online <dossier>)
    // Le dossier donné contient ce qu'Anas envoie à un ami : le mod (dossier ou .zip) et serveur.txt (l'adresse). Ni l'un ni l'autre
    // n'est dans le dépôt : le mod appartient à son auteur, et l'adresse d'un serveur ne va jamais dans un dépôt public.
    // Il ne reste à donner que le jeu et sa mise à jour (et prod.keys une fois, s'il n'est ni dans le dossier ni déjà dans Home).
    public static void TotkOnline(Bibliotheque lib, string dossier, string? mod = null, string? serveur = null)
    {
        try
        {
            if (Directory.Exists(dossier))
            {
                mod ??= Directory.GetDirectories(dossier).FirstOrDefault(d => Construction.Racine(d) != null) ?? Directory.GetFiles(dossier, "*.zip").FirstOrDefault();
                if (serveur == null && Path.Combine(dossier, "serveur.txt") is var f && File.Exists(f)) serveur = File.ReadLines(f).FirstOrDefault(l => l.Trim() != "" && !l.TrimStart().StartsWith('#'))?.Trim();
                if (!File.Exists(Construction.ClesProd) && Path.Combine(dossier, "prod.keys") is var k && File.Exists(k)) Installer(lib, k, Construction.ClesProd);
            }
        }
        catch (Exception e) { Journal.Ecrire("TOTK Online, lecture du dossier : " + e.Message); }
        var cles = File.Exists(Construction.ClesProd);
        var m = new Menu
        {
            Titre = "Zelda en ligne", SousTitre = "Tears of the Kingdom", Symbole = "globe",
            Texte = "Home construit le jeu, installe le mod en ligne et règle le serveur. Il te demande seulement ton jeu et sa mise à jour, tirés de ta console.\n\n"
                + $"Mod : {(mod != null ? Path.GetFileName(mod) : "pas trouvé")}  ·  Serveur : {(string.IsNullOrWhiteSpace(serveur) ? "pas réglé" : "réglé")}  ·  Clés : {(cles ? "installées" : "à donner")}",
        };
        if (mod != null && cles) m.Elements.Add(new("Choisir le jeu et sa mise à jour", "hammer", async () =>
        {
            if (lib.ChoisirFichier == null || await lib.ChoisirFichier("Tears of the Kingdom, extrait de ta console (.xci ou .nsp)", ["*.xci", "*.nsp"]) is not { } dump) return;
            if (await lib.ChoisirFichier("La mise à jour du jeu que le mod demande (.nsp)", ["*.nsp", "*.xci"]) is not { } maj) return;
            Construction.Commencer(lib, dump, [maj], mod, serveur);
        }, "Puis la construction démarre : compte plus d'une heure et environ 40 Go libres"));
        if (!cles) m.Elements.Add(new("Donner les clés", "key", async () => { if (lib.ChoisirFichier != null && await lib.ChoisirFichier("Les clés de ta console (prod.keys)", ["prod.keys", "*.keys"]) is { } k) Installer(lib, k, Construction.ClesProd); TotkOnline(lib, dossier, mod, serveur); }, "prod.keys, tiré de ta console"));
        m.Elements.Add(new(mod == null ? "Choisir le mod" : "Changer de mod", "puzzlepiece", async () => { if (lib.ChoisirFichier != null && await lib.ChoisirFichier("Le mod en ligne (.zip)", ["*.zip"]) is { } z) mod = z; TotkOnline(lib, dossier, mod, serveur); }, "L'archive .zip du mod, avec romfs/ et/ou exefs/"));
        m.Elements.Add(new(string.IsNullOrWhiteSpace(serveur) ? "Régler le serveur" : "Changer de serveur", "globe", () => lib.Demander("Adresse du serveur", "adresse:port", v => TotkOnline(lib, dossier, mod, v)), "L'adresse que t'a donnée celui qui héberge la partie"));
        lib.Ouvrir(m);
    }

    // MARK: Le chantier : la tuile d'un jeu en construction
    public static void Chantier(Bibliotheque lib, Jeu j)
    {
        if (Construction.Chantiers().FirstOrDefault(c => c.Id == j.Id) is not { } c) { lib.Recharger(); return; }
        var m = new Menu { Titre = c.Titre, SousTitre = "En construction", Symbole = "hammer" };
        if (Construction.EnCours == c.Id)
        {
            m.Texte = "La construction tourne. Tu peux continuer à te servir de Home ; évite seulement de lancer un jeu pendant ce temps, la recompilation prend presque tout le processeur.";
            m.Elements.Add(new("Abandonner", "xmark", () => Construction.Abandonner(lib, c), "Arrête la construction et retire la tuile") { Destructif = true });
        }
        else
        {
            m.Texte = "La construction s'est arrêtée avant la fin. Elle peut repartir avec ce qui avait été demandé.";
            m.Elements.Add(new("Reprendre", "play.fill", () => _ = Construction.Lancer(lib, c), "La construction repart de là où elle peut"));
            m.Elements.Add(new("Abandonner", "xmark", () => Construction.Abandonner(lib, c), "Retire la tuile ; « Libérer de la place » enlève ce qui a été fait") { Destructif = true });
        }
        if (File.Exists(c.Journal)) m.Elements.Add(new("Voir le journal", "doc", () => Systeme.Ouvrir(c.Journal), "Ce que ScarletNX a écrit"));
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
        {
            var actif = !eteints.Contains(mod);
            m.Elements.Add(new($"{mod} : {(actif ? "activé" : "désactivé")}", "puzzlepiece", () => UnMod(lib, j, mod), DeCode(j, mod) ? "Mod de code" : "Mod de fichiers") { Section = mod == mods[0] ? "Installés" : null });
        }
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
    static void UnMod(Bibliotheque lib, Jeu j, string mod)
    {
        var actif = !Eteints(j).Contains(mod);
        lib.Ouvrir(new Menu
        {
            Titre = mod, SousTitre = actif ? "Activé" : "Désactivé", Symbole = "puzzlepiece", Retour = () => Mods(lib, j),
            Elements =
            {
                new(actif ? "Désactiver" : "Activer", actif ? "eye.slash" : "checkmark", () =>
                {
                    var e = Eteints(j); if (actif) e.Add(mod); else e.Remove(mod);
                    try { Ini.Ecrire(Construction.Reglages(j.Dossier), "Game", "mods_off", string.Join('/', e.Distinct())); if (DeCode(j, mod)) aRecompiler.Add(j.Id); }
                    catch (Exception x) { Journal.Ecrire("mods_off : " + x.Message); lib.Dire("Le réglage n'a pas pu être écrit"); }
                    Mods(lib, j);
                }, actif ? "Le mod reste installé, le jeu ne s'en sert plus" : "Le jeu s'en sert à nouveau"),
                new("Supprimer", "trash", () =>
                {
                    var d = Path.Combine(Construction.Mods(j.Dossier), mod); var code = DeCode(j, mod);
                    if (!Systeme.Corbeille(d)) { lib.Dire("Le mod n'a pas pu être mis à la Corbeille"); return; }
                    if (code) aRecompiler.Add(j.Id);
                    Journal.Ecrire($"mod supprimé : {mod} ({j.Nom})"); Mods(lib, j); lib.Dire(mod + " est à la Corbeille");
                }, "Le dossier du mod part à la Corbeille") { Destructif = true },
            },
        });
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
            m.Elements.Add(new(nom, "trash", () => { if (Systeme.Corbeille(d)) { lib.Dire(nom + " : à la Corbeille"); LibererPlace(lib); } else lib.Dire("Ce dossier n'a pas pu être mis à la Corbeille"); }, $"{quoi} · {Lisible(Taille(d))} · part à la Corbeille"));
        m.Texte = restes.Count > 0 ? "Rien ici ne sert à tes jeux construits. Ce que tu choisis part à la Corbeille : tu peux encore le reprendre."
            : ouverts ? "Une construction est en cours ou à reprendre : finis-la ou abandonne-la d'abord." : "Rien à enlever : aucune construction n'a laissé de reste.";
        lib.Ouvrir(m);
    }
}
