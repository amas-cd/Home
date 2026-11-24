// Home pour Windows — les recomps : des jeux console recompilés en programmes Windows par leurs auteurs (TotK Recomp, Zelda 64…).
// Ils remplacent ici nxnative et MacNativeGames, qui n'existent que pour Apple. Aucun ne contient de jeu : chacun demande au joueur
// ses propres fichiers (le dump de sa console).
// Source 1 : le catalogue public de RecompLauncher (recomplauncher.com/pc-catalog.json) : dépôt GitHub, fichier Windows, SHA-256.
// Source 2 : si le jeu n'y est pas, une recherche sur GitHub. Là, personne n'a vérifié le fichier : Home le dit avant d'installer.
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace Home;

public sealed class Recomp
{
    public string Id = "", Nom = "", Jeu = "", Origine = "", Depot = "", Version = "", Tag = "", Taille = "", Resume = "", Besoin = "", Auteur = "", Licence = "", Fichier = "", Analyse = "";
    public string? Sha256, Couverture, Fond, Logo, Demarrage, Installeur, Note, Genre, URL;
    public int Etoiles; public bool HorsCatalogue;
    /// Les fichiers d'une release GitHub sont toujours à cette adresse : Home ne télécharge un recomp de nulle part ailleurs
    public string Adresse => URL ?? $"https://github.com/{Depot}/releases/download/{Uri.EscapeDataString(Tag)}/{Uri.EscapeDataString(Fichier)}";
}

public static class Catalogue
{
    const string Source = "https://recomplauncher.com/pc-catalog.json";
    public static List<Recomp> Recomps = new();
    public static List<(string id, string nom)> Origines = new();
    public static List<string> Vedettes = new();
    static string Cache => Dossiers.Fichier("cache", "pc-catalog.json");

    /// Le catalogue fait 7 Mo : téléchargé au plus une fois par jour, et relu depuis le disque quand le réseau manque
    public static async Task<bool> Charger(bool forcer = false)
    {
        if (Recomps.Count > 0 && !forcer) return true;
        var frais = File.Exists(Cache) && DateTime.Now - File.GetLastWriteTime(Cache) < TimeSpan.FromHours(24);
        if (!frais || forcer)
        {
            try
            {
                var octets = await Reseau.Http.GetByteArrayAsync(Source);
                using (JsonDocument.Parse(octets)) { }   // un fichier tronqué ne remplace pas le bon
                await File.WriteAllBytesAsync(Cache + ".tmp", octets); File.Move(Cache + ".tmp", Cache, true);
            }
            catch (Exception e) { Journal.Ecrire("catalogue des recomps : " + e.Message); }
        }
        if (!File.Exists(Cache)) return false;
        try { await Task.Run(Lire); return Recomps.Count > 0; }
        catch (Exception e) { Journal.Ecrire("catalogue illisible : " + e.Message); return false; }
    }
    static string S(JsonElement e, string k) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    static JsonElement? O(JsonElement e, string k) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Object ? v : null;
    static void Lire()
    {
        using var d = JsonDocument.Parse(File.ReadAllBytes(Cache));
        var r = d.RootElement; var liste = new List<Recomp>();
        foreach (var a in r.GetProperty("apps").EnumerateArray())
        {
            var hote = S(a, "host");
            if (hote != "" && !hote.Equals("github", StringComparison.OrdinalIgnoreCase)) continue;
            var depot = S(a, "repo");
            if (depot.Count(c => c == '/') != 1 || depot.Contains(':')) continue;
            if (O(a, "files") is not { } fichiers || O(fichiers, "windows") is not { } win || S(win, "name") == "") continue;
            var boot = O(a, "boot"); var genre = boot is { } b ? S(b, "kind") : "";
            if (genre is "not-a-game" or "source") continue;   // un outil, ou un projet à compiler soi-même
            liste.Add(new Recomp
            {
                Id = S(a, "id"), Nom = S(a, "name"), Jeu = S(a, "game"), Origine = S(a, "origin"), Depot = depot, Version = S(a, "version"), Tag = S(a, "tag"),
                Taille = S(a, "size"), Resume = S(a, "blurb"), Besoin = S(a, "needs"), Auteur = S(a, "author"), Licence = S(a, "license"),
                Fichier = S(win, "name"), Sha256 = S(win, "sha256") is { Length: 64 } h ? h : null, Analyse = S(win, "scan"),
                Couverture = Vide(S(a, "cover")), Fond = Vide(S(a, "hero")), Logo = Vide(S(a, "logo")), Genre = genre,
                Demarrage = boot is { } b1 ? Vide(S(b1, "start")) ?? (O(b1, "installer") is { } ins ? Vide(S(ins, "then_start")) : null) : null,
                Installeur = boot is { } b2 ? Vide(S(b2, "setup")) : null, Note = boot is { } b3 ? Vide(S(b3, "player_note")) : null,
                Etoiles = a.TryGetProperty("stars", out var st) && st.ValueKind == JsonValueKind.Number ? st.GetInt32() : 0,
            });
        }
        var origines = r.TryGetProperty("origins", out var os) ? os.EnumerateArray().Select(o => (S(o, "id"), S(o, "name"))).ToList() : new();
        var vedettes = r.TryGetProperty("banners", out var bn) && bn.TryGetProperty("windows", out var bw) ? bw.EnumerateArray().Select(x => x.GetString() ?? "").ToList() : new();
        Recomps = liste.Where(x => x.Id != "" && x.Tag != "").OrderByDescending(x => x.Etoiles).ToList(); Origines = origines; Vedettes = vedettes;
    }
    static string? Vide(string s) => s == "" ? null : s;
    public static string NomOrigine(string id) => Origines.FirstOrDefault(o => o.id == id).nom ?? id;
    public static Recomp? Par(string id) => Recomps.FirstOrDefault(r => r.Id == id);
    /// Recherche sans accents ni majuscules, dans le nom du recomp et celui du jeu
    public static List<Recomp> Chercher(string q)
    {
        var mots = Simple(q).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return mots.Length == 0 ? new() : Recomps.Where(r => { var t = Simple(r.Nom + " " + r.Jeu + " " + r.Depot); return mots.All(t.Contains); }).ToList();
    }
    public static string Simple(string s) => new(s.Normalize(System.Text.NormalizationForm.FormD).Where(c => System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c) != System.Globalization.UnicodeCategory.NonSpacingMark).Select(char.ToLowerInvariant).ToArray());
}

/// Ce que GitHub sait d'un dépôt trouvé hors catalogue
public sealed class Depot { public string Nom = "", Description = "", Licence = ""; public int Etoiles; public DateTime MisAJour; }

public static class GitHub
{
    const string API = "https://api.github.com/";
    /// Les dépôts qui ressemblent à un recomp de ce jeu : pas les forks (des centaines de copies du même projet), pas les archivés,
    /// les plus suivis d'abord. Sans compte GitHub : 10 recherches par minute, largement assez.
    public static async Task<List<Depot>> Chercher(string q)
    {
        var vus = new Dictionary<string, Depot>(StringComparer.OrdinalIgnoreCase);
        foreach (var mots in new[] { "recomp", "recompiled", "pc port" })
        {
            using var d = await Reseau.Json($"{API}search/repositories?q={Uri.EscapeDataString($"{q} {mots} in:name,description fork:false archived:false")}&sort=stars&per_page=15");
            if (d == null || !d.RootElement.TryGetProperty("items", out var items)) continue;
            foreach (var r in items.EnumerateArray())
            {
                var nom = r.GetProperty("full_name").GetString() ?? "";
                if (nom == "" || vus.ContainsKey(nom)) continue;
                vus[nom] = new Depot
                {
                    Nom = nom, Description = r.TryGetProperty("description", out var de) && de.ValueKind == JsonValueKind.String ? de.GetString()! : "",
                    Etoiles = r.GetProperty("stargazers_count").GetInt32(), MisAJour = r.TryGetProperty("pushed_at", out var pa) && pa.TryGetDateTime(out var dt) ? dt : default,
                    Licence = r.TryGetProperty("license", out var li) && li.ValueKind == JsonValueKind.Object && li.TryGetProperty("spdx_id", out var sp) ? sp.GetString() ?? "" : "",
                };
            }
        }
        var connus = Catalogue.Recomps.Select(r => r.Depot).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return vus.Values.Where(v => !connus.Contains(v.Nom)).OrderByDescending(v => v.Etoiles).Take(20).ToList();
    }
    /// La dernière release d'un dépôt et son fichier pour Windows, s'il y en a un. Mêmes règles de nom que RecompLauncher :
    /// « windows » ou « win » dans le nom, jamais les fichiers de débogage, de sources ou de signature.
    public static async Task<Recomp?> DerniereVersion(Depot dep)
    {
        using var d = await Reseau.Json($"{API}repos/{dep.Nom}/releases?per_page=8");
        if (d == null || d.RootElement.ValueKind != JsonValueKind.Array) return null;
        var releases = d.RootElement.EnumerateArray().Where(r => !(r.TryGetProperty("draft", out var dr) && dr.GetBoolean())).ToList();
        foreach (var rel in releases.Where(r => !r.GetProperty("prerelease").GetBoolean()).Concat(releases.Where(r => r.GetProperty("prerelease").GetBoolean())))
        {
            var fichiers = rel.GetProperty("assets").EnumerateArray().Select(a => (nom: a.GetProperty("name").GetString() ?? "", url: a.GetProperty("browser_download_url").GetString() ?? "",
                taille: a.GetProperty("size").GetInt64(), empreinte: a.TryGetProperty("digest", out var dg) && dg.ValueKind == JsonValueKind.String ? dg.GetString()! : "")).ToList();
            bool Exclu(string n) => new[] { "debug", "symbols", "pdb", "source", "linux", "macos", "darwin", "arm64", "android", ".appimage", ".sha256", ".sig", ".asc", ".dmg", ".deb" }.Any(n.Contains);
            var candidats = fichiers.Where(f => !Exclu(f.nom.ToLowerInvariant()) && (f.nom.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || f.nom.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))).ToList();
            var choix = candidats.Where(f => f.nom.Contains("win", StringComparison.OrdinalIgnoreCase)).OrderByDescending(f => f.nom.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)).FirstOrDefault();
            if (choix.nom == null && candidats.Count == 1) choix = candidats[0];
            if (choix.nom == null) continue;
            var tag = rel.GetProperty("tag_name").GetString() ?? "";
            // Le fichier doit venir des releases de ce dépôt, en https : rien d'autre n'est accepté
            if (!choix.url.StartsWith($"https://github.com/{dep.Nom}/releases/download/", StringComparison.OrdinalIgnoreCase)) continue;
            return new Recomp
            {
                Id = "gh-" + Dossiers.NomSur(dep.Nom.ToLowerInvariant()), Nom = dep.Nom.Split('/')[1], Jeu = dep.Description, Depot = dep.Nom, Version = tag.TrimStart('v'), Tag = tag,
                Taille = $"{choix.taille / 1048576.0:0} Mo", Fichier = choix.nom, URL = choix.url, Sha256 = choix.empreinte.StartsWith("sha256:") ? choix.empreinte[7..] : null,
                Auteur = dep.Nom.Split('/')[0], Licence = dep.Licence, Etoiles = dep.Etoiles, HorsCatalogue = true, Resume = dep.Description,
            };
        }
        return null;
    }
}

public static class Installation
{
    public static string Registre => Dossiers.Fichier("recomps.json");
    /// Télécharge, vérifie l'empreinte, décompresse dans recomps/<id>/ et inscrit le recomp. Une mise à jour se décompresse par-dessus :
    /// les sauvegardes et réglages que le jeu a écrits dans son dossier restent.
    public static async Task Installer(Bibliotheque lib, Recomp r)
    {
        if (lib.Tache is { Fini: false }) { lib.Dire("Une installation est déjà en cours"); return; }
        var ext = Path.GetExtension(r.Fichier).ToLowerInvariant();
        if (ext is not (".zip" or ".exe")) { lib.Dire($"Format {ext} : pas encore pris en charge par Home. La page GitHub s'ouvre."); Systeme.Ouvrir($"https://github.com/{r.Depot}/releases"); return; }
        var t = new Tache { Titre = "Installation de " + r.Nom, Etape = "Téléchargement…", Fraction = 0 };
        lib.Tache = t; lib.FermerMenus();
        var telecharge = Dossiers.Fichier("telechargements", Dossiers.NomSur(r.Id) + ext);
        try
        {
            var empreinte = await Reseau.Telecharger(r.Adresse, telecharge, (lu, total) =>
                { t.Fraction = total > 0 ? 0.85 * lu / total : null; t.Etape = $"Téléchargement… {lu / 1048576} Mo" + (total > 0 ? $" sur {total / 1048576}" : ""); lib.Signaler(); });
            // Le fichier reçu doit être exactement celui que l'auteur a publié
            if (r.Sha256 != null && !empreinte.Equals(r.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("le fichier reçu n'est pas celui que l'auteur a publié (empreinte différente) : rien n'a été installé");
            t.Etape = "Décompression…"; t.Fraction = 0.88; lib.Signaler();
            var dossier = Dossiers.Dossier("recomps", Dossiers.NomSur(r.Id));
            if (ext == ".zip") await Task.Run(() => Extraire(telecharge, dossier));
            else File.Copy(telecharge, Path.Combine(dossier, r.Fichier), true);
            try { File.Delete(telecharge); } catch { }   // l'archive ne sert plus : seul le fichier que Home vient de télécharger est effacé

            var liste = Json.Lire<List<RecompInstalle>>(Registre); liste.RemoveAll(x => x.Id == r.Id);
            var ins = new RecompInstalle
            {
                Id = r.Id, Nom = r.Nom, Jeu = r.Jeu, Depot = r.Depot, Version = r.Version, Dossier = dossier, Installeur = r.Genre == "installer" ? r.Installeur ?? PremierExe(dossier) : null,
                ExeAttendu = r.Demarrage, Couverture = r.Couverture, Fond = r.Fond, Logo = r.Logo, HorsCatalogue = r.HorsCatalogue,
            };
            if (ins.Installeur == null) ins.Exe = (r.Demarrage != null ? Trouver(dossier, r.Demarrage) : null) ?? Deviner(dossier);
            liste.Add(ins); Json.Ecrire(Registre, liste);
            t.Etape = r.Sha256 != null ? "Installé, fichier vérifié" : "Installé (fichier non vérifiable)"; t.Fraction = 1; t.Fini = true;
            Journal.Ecrire($"recomp installé : {r.Id} {r.Version} depuis {r.Depot}, sha256 {empreinte}{(r.Sha256 == null ? " (pas d'empreinte publiée)" : "")}");
            lib.Recharger(selectionner: "recomp:" + r.Id);
        }
        catch (Exception e)
        {
            try { File.Delete(telecharge); } catch { }
            t.Erreur = e.Message; t.Etape = "Échec : " + e.Message; t.Fini = true; Journal.Ecrire($"installation de {r.Id} : {e}");
        }
        lib.Signaler();
        _ = Task.Delay(6000).ContinueWith(_ => Avalonia.Threading.Dispatcher.UIThread.Post(() => { if (lib.Tache == t) { lib.Tache = null; lib.Signaler(); } }));
    }
    /// Décompresse sans jamais écrire hors du dossier (noms d'entrée comme « ..\..\x »), et enlève l'unique dossier du dessus s'il y en a un
    static void Extraire(string zip, string dest)
    {
        using var a = ZipFile.OpenRead(zip);
        var noms = a.Entries.Select(e => e.FullName.Replace('\\', '/')).ToList();
        var hauts = noms.Select(n => n.Split('/')[0]).Distinct().ToList();
        var prefixe = hauts.Count == 1 && noms.All(n => n.Contains('/')) ? hauts[0] + "/" : "";
        var racine = Path.GetFullPath(dest).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        foreach (var e in a.Entries)
        {
            var rel = e.FullName.Replace('\\', '/'); if (prefixe != "") rel = rel[prefixe.Length..];
            if (rel == "" || rel.EndsWith('/')) continue;
            var cible = Path.GetFullPath(Path.Combine(dest, rel));
            if (!cible.StartsWith(racine, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("archive invalide : un fichier sortirait du dossier du jeu");
            Directory.CreateDirectory(Path.GetDirectoryName(cible)!); e.ExtractToFile(cible, true);
        }
    }
    public static string? Trouver(string dossier, string nom)
    {
        try { return Directory.Exists(dossier) ? Directory.EnumerateFiles(dossier, Path.GetFileName(nom), SearchOption.AllDirectories).FirstOrDefault() : null; } catch { return null; }
    }
    static string? PremierExe(string dossier) => Directory.EnumerateFiles(dossier, "*.exe").Select(Path.GetFileName).FirstOrDefault(n => n!.Contains("setup", StringComparison.OrdinalIgnoreCase)) ?? Directory.EnumerateFiles(dossier, "*.exe").Select(Path.GetFileName).FirstOrDefault();
    /// Le programme du jeu quand le catalogue ne le nomme pas : le plus gros .exe du dessus qui n'est ni un désinstalleur ni un outil de plantage
    public static string? Deviner(string dossier)
    {
        try
        {
            bool Outil(string n) => new[] { "unins", "crash", "setup", "vc_redist", "vcredist", "dxsetup", "updater", "launcher-helper" }.Any(x => n.Contains(x, StringComparison.OrdinalIgnoreCase));
            return Directory.EnumerateFiles(dossier, "*.exe").Where(f => !Outil(Path.GetFileName(f))).OrderByDescending(f => new FileInfo(f).Length).FirstOrDefault();
        }
        catch { return null; }
    }
}

/// Les menus du catalogue : par console d'origine, recherche, fiche d'un recomp, recherche GitHub
public static class MenusRecomps
{
    const int ParPage = 24;
    public static async void Ouvrir(Bibliotheque lib)
    {
        if (Catalogue.Recomps.Count == 0)
        {
            lib.Ouvrir(new Menu { Titre = "Recomps", Symbole = "gamecontroller", Texte = "Lecture du catalogue…", Retour = lib.OuvrirAjout });
            if (!await Catalogue.Charger()) { lib.Ouvrir(new Menu { Titre = "Recomps", Symbole = "exclamation", Texte = "Le catalogue n'a pas pu être lu. Vérifie la connexion internet, puis réessaie.", Retour = lib.OuvrirAjout, Elements = { new("Réessayer", "arrow.clockwise", () => Ouvrir(lib)) } }); return; }
            if (lib.Menu?.Titre != "Recomps") return;   // il a fermé le menu pendant le chargement
        }
        var m = new Menu
        {
            Titre = "Recomps", SousTitre = $"{Catalogue.Recomps.Count} jeux console recompilés pour Windows", Symbole = "gamecontroller", Retour = lib.OuvrirAjout,
            Texte = "Chaque recomp vient du GitHub de son auteur. Aucun ne contient de jeu : il te faut tes propres fichiers, tirés de ta console.",
        };
        m.Elements.Add(new("Rechercher un jeu", "magnifyingglass", () => lib.Demander("Rechercher un recomp", "Nom du jeu, au clavier", q => Recherche(lib, q)), "Dans le catalogue, puis sur GitHub s'il n'y est pas"));
        var vedettes = Catalogue.Vedettes.Select(Catalogue.Par).Where(r => r != null).Select(r => r!).ToList();
        if (vedettes.Count > 0) m.Elements.Add(new("En ce moment", "sparkles", () => Liste(lib, "En ce moment", vedettes, 0, () => Ouvrir(lib)), string.Join(", ", vedettes.Take(3).Select(v => v.Nom))));
        var premier = true;
        foreach (var (id, nom) in Catalogue.Origines)
        {
            var jeux = Catalogue.Recomps.Where(r => r.Origine == id).ToList();
            if (jeux.Count == 0) continue;
            m.Elements.Add(new(nom, "gamecontroller", () => Liste(lib, nom, jeux, 0, () => Ouvrir(lib)), jeux.Count == 1 ? "1 jeu" : $"{jeux.Count} jeux") { Section = premier ? "Par console d'origine" : null });
            premier = false;
        }
        lib.Ouvrir(m);
    }
    /// Une grille de jaquettes, 24 par page : les plus suivis d'abord
    static void Liste(Bibliotheque lib, string titre, List<Recomp> jeux, int page, Action retour)
    {
        var pages = (jeux.Count + ParPage - 1) / ParPage;
        var m = new Menu { Titre = titre, SousTitre = pages > 1 ? $"Page {page + 1} sur {pages}" : $"{jeux.Count} jeux", Symbole = "gamecontroller", Grille = true, Retour = retour };
        foreach (var r in jeux.Skip(page * ParPage).Take(ParPage))
            m.Elements.Add(new(r.Nom, "gamecontroller", () => Fiche(lib, r, () => Liste(lib, titre, jeux, page, retour)), r.Jeu) { Image = r.Couverture });
        if (page + 1 < pages) m.Elements.Add(new("Page suivante", "arrow.right", () => Liste(lib, titre, jeux, page + 1, retour), $"{jeux.Count - (page + 1) * ParPage} autres jeux"));
        if (page > 0) m.Elements.Add(new("Page précédente", "arrow.left", () => Liste(lib, titre, jeux, page - 1, retour)));
        lib.Ouvrir(m);
    }
    static void Recherche(Bibliotheque lib, string q)
    {
        var trouves = Catalogue.Chercher(q);
        var m = new Menu { Titre = $"« {q} »", SousTitre = trouves.Count == 0 ? "Rien dans le catalogue" : trouves.Count == 1 ? "1 recomp dans le catalogue" : $"{trouves.Count} recomps dans le catalogue", Symbole = "magnifyingglass", Retour = () => Ouvrir(lib) };
        foreach (var r in trouves.Take(30)) m.Elements.Add(new(r.Nom, "gamecontroller", () => Fiche(lib, r, () => Recherche(lib, q)), $"{r.Jeu} · {Catalogue.NomOrigine(r.Origine)} · ★ {r.Etoiles}"));
        m.Elements.Add(new("Chercher sur GitHub", "link", () => RechercheGitHub(lib, q), "Pour un recomp qui n'est pas dans le catalogue") { Section = trouves.Count > 0 ? "Pas dans la liste ?" : null });
        lib.Ouvrir(m);
    }
    static async void RechercheGitHub(Bibliotheque lib, string q)
    {
        var titre = $"GitHub : « {q} »";
        lib.Ouvrir(new Menu { Titre = titre, Symbole = "link", Texte = "Recherche en cours…", Retour = () => Recherche(lib, q) });
        var depots = await GitHub.Chercher(q);
        if (lib.Menu?.Titre != titre) return;
        var m = new Menu
        {
            Titre = titre, SousTitre = depots.Count == 0 ? "Aucun dépôt trouvé" : $"{depots.Count} dépôts, les plus suivis d'abord", Symbole = "link", Retour = () => Recherche(lib, q),
            Texte = "Ces projets ne sont pas dans le catalogue : personne n'a vérifié leurs fichiers. Regarde le nombre d'étoiles et la page du projet avant d'installer.",
        };
        foreach (var d in depots) m.Elements.Add(new(d.Nom, "link", () => FicheDepot(lib, d, () => RechercheGitHub(lib, q)), $"★ {d.Etoiles} · {(d.Description.Length > 90 ? d.Description[..90] + "…" : d.Description)}"));
        lib.Ouvrir(m);
    }
    static async void FicheDepot(Bibliotheque lib, Depot d, Action retour)
    {
        lib.Ouvrir(new Menu { Titre = d.Nom, Symbole = "link", Texte = "Lecture des versions publiées…", Retour = retour });
        var r = await GitHub.DerniereVersion(d);
        if (lib.Menu?.Titre != d.Nom) return;
        if (r == null)
        {
            lib.Ouvrir(new Menu
            {
                Titre = d.Nom, SousTitre = $"★ {d.Etoiles}", Symbole = "exclamation", Retour = retour, Texte = "Ce projet ne publie pas de version prête pour Windows : il faut le compiler soi-même, ou il est encore en chantier.",
                Elements = { new("Ouvrir la page GitHub", "safari", () => Systeme.Ouvrir("https://github.com/" + d.Nom)) },
            });
            return;
        }
        Fiche(lib, r, retour);
    }
    /// La fiche d'un recomp : ce qu'il est, ce qu'il demande, et le bouton Installer. Un fichier signalé dangereux n'est jamais installé.
    public static void Fiche(Bibliotheque lib, Recomp r, Action retour)
    {
        var installe = lib.Recomps.FirstOrDefault(x => x.Id == r.Id);
        var texte = r.Resume;
        if (r.Besoin != "") texte += (texte == "" ? "" : "\n\n") + "Il te faut : " + r.Besoin;
        if (r.Note != null) texte += "\n\n" + r.Note;
        if (r.HorsCatalogue) texte += (texte == "" ? "" : "\n\n") + "Hors catalogue : personne n'a vérifié ce fichier. Installe-le seulement si tu fais confiance à ce projet.";
        var m = new Menu { Titre = r.Nom, SousTitre = r.HorsCatalogue ? "GitHub · " + r.Depot : $"{r.Jeu} · {Catalogue.NomOrigine(r.Origine)}", Symbole = "gamecontroller", ImageURL = r.Couverture, Texte = texte, Retour = retour };
        var detail = $"Version {r.Version} · {r.Taille}";
        if (r.Analyse == "red") m.Elements.Add(new() { Libelle = "Installation refusée", Detail = "L'analyse antivirus du catalogue signale ce fichier comme dangereux", Icone = "exclamation", Info = true });
        else if (installe != null && installe.Version == r.Version) m.Elements.Add(new() { Libelle = "Déjà installé", Detail = detail, Icone = "checkmark", Info = true });
        else m.Elements.Add(new(installe != null ? "Mettre à jour" : "Installer", "arrow.down.circle", () => _ = Installation.Installer(lib, r), installe != null ? $"{installe.Version} → {r.Version} · {r.Taille}" : detail));
        m.Elements.Add(new("Ouvrir la page GitHub", "safari", () => Systeme.Ouvrir("https://github.com/" + r.Depot), r.Depot));
        m.Elements.Add(new() { Libelle = $"Par {r.Auteur} · ★ {r.Etoiles}" + (r.Licence != "" ? $" · licence {r.Licence}" : ""), Icone = "person", Info = true, Section = "Infos" });
        m.Elements.Add(new()
        {
            Icone = r.Sha256 != null && r.Analyse == "green" ? "shield" : "exclamation", Info = true,
            Libelle = r.Sha256 == null ? "Pas d'empreinte publiée : le fichier ne peut pas être vérifié" : "Fichier vérifié par son empreinte SHA-256 au téléchargement",
            Detail = r.Analyse switch { "green" => "Analyse antivirus du catalogue : rien à signaler", "yellow" => "Analyse antivirus du catalogue : à prendre avec prudence", "red" => "Analyse antivirus du catalogue : dangereux", "pending" => "Analyse antivirus du catalogue : pas encore faite", _ => null },
        });
        lib.Ouvrir(m);
    }
}
