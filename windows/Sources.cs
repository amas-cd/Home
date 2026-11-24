// Home pour Windows — d'où viennent les jeux (Steam, Epic Games) et leurs images (Steam, SteamGridDB, catalogue des recomps).
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Avalonia.Media.Imaging;
using Microsoft.Win32;

namespace Home;

public static class Reseau
{
    public static readonly HttpClient Http = Creer();
    static HttpClient Creer()
    {
        var h = new HttpClient { Timeout = TimeSpan.FromSeconds(40) };
        h.DefaultRequestHeaders.UserAgent.ParseAdd("Home-Windows");   // GitHub refuse les requêtes sans User-Agent
        return h;
    }
    /// Télécharge un fichier en donnant l'avancement, et rend son empreinte SHA-256 calculée au passage
    public static async Task<string> Telecharger(string url, string fichier, Action<long, long> avance)
    {
        using var rep = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        rep.EnsureSuccessStatusCode();
        var total = rep.Content.Headers.ContentLength ?? 0; long lu = 0; var tampon = new byte[1 << 17]; var dernier = DateTime.MinValue;
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        await using var entree = await rep.Content.ReadAsStreamAsync();
        await using (var sortie = File.Create(fichier))
        {
            int n;
            while ((n = await entree.ReadAsync(tampon)) > 0)
            {
                await sortie.WriteAsync(tampon.AsMemory(0, n)); sha.AppendData(tampon, 0, n); lu += n;
                if (DateTime.Now - dernier > TimeSpan.FromMilliseconds(200)) { dernier = DateTime.Now; avance(lu, total); }
            }
        }
        return Convert.ToHexString(sha.GetHashAndReset());
    }
    public static async Task<JsonDocument?> Json(string url, string? jeton = null)
    {
        try
        {
            using var q = new HttpRequestMessage(HttpMethod.Get, url);
            if (jeton != null) q.Headers.Authorization = new("Bearer", jeton);
            using var r = await Http.SendAsync(q);
            if (!r.IsSuccessStatusCode) { Journal.Ecrire($"{(int)r.StatusCode} pour {new Uri(url).Host}{new Uri(url).AbsolutePath}"); return null; }
            return JsonDocument.Parse(await r.Content.ReadAsByteArrayAsync());
        }
        catch (Exception e) { Journal.Ecrire($"réseau ({new Uri(url).Host}) : {e.Message}"); return null; }
    }
}

// MARK: - Steam : les bibliothèques (libraryfolders.vdf) et un appmanifest_<id>.acf par jeu installé
public static class Steam
{
    static string? Racine()
    {
        if (!OperatingSystem.IsWindows()) return null;
        try
        {
            return Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string
                ?? Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null) as string;
        }
        catch { return null; }
    }
    public static List<Jeu> Jeux()
    {
        var res = new List<Jeu>();
        if (Racine() is not { } racine || !Directory.Exists(racine)) return res;
        var bibs = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Path.GetFullPath(racine) };
        try
        {
            foreach (Match m in Regex.Matches(File.ReadAllText(Path.Combine(racine, "steamapps", "libraryfolders.vdf")), "\"path\"\\s+\"([^\"]+)\""))
                bibs.Add(Path.GetFullPath(m.Groups[1].Value.Replace(@"\\", @"\")));
        }
        catch { }
        foreach (var b in bibs)
        {
            var apps = Path.Combine(b, "steamapps");
            if (!Directory.Exists(apps)) continue;
            foreach (var f in Directory.EnumerateFiles(apps, "appmanifest_*.acf"))
            {
                try
                {
                    var t = File.ReadAllText(f);
                    string? V(string cle) { var m = Regex.Match(t, $"\"{cle}\"\\s+\"([^\"]*)\""); return m.Success ? m.Groups[1].Value : null; }
                    string? id = V("appid"), nom = V("name"), dir = V("installdir");
                    if (id == null || nom == null || dir == null) continue;
                    // Pas des jeux : les redistribuables, Proton, les runtimes Linux
                    if (id == "228980" || nom.StartsWith("Steamworks") || nom.StartsWith("Proton") || nom.StartsWith("Steam Linux Runtime")) continue;
                    var dossier = Path.Combine(apps, "common", dir);
                    if (!Directory.Exists(dossier)) continue;
                    res.Add(new Jeu { Id = "steam:" + id, Nom = nom, Origine = Origine.Steam, Cible = "steam://rungameid/" + id, Dossier = dossier });
                }
                catch (Exception e) { Journal.Ecrire($"Steam, {Path.GetFileName(f)} : {e.Message}"); }
            }
        }
        return res;
    }
    /// Les images officielles d'un jeu Steam, sans clé. Les jeux récents n'ont pas toujours ces noms de fichiers : on essaie, sinon rien.
    public static string[] Images(string appid, string quoi) => quoi switch
    {
        "couverture" => [$"https://cdn.cloudflare.steamstatic.com/steam/apps/{appid}/library_600x900_2x.jpg", $"https://cdn.cloudflare.steamstatic.com/steam/apps/{appid}/library_600x900.jpg",
                         $"https://shared.steamstatic.com/store_item_assets/steam/apps/{appid}/library_600x900.jpg", $"https://cdn.cloudflare.steamstatic.com/steam/apps/{appid}/header.jpg"],
        "fond" => [$"https://cdn.cloudflare.steamstatic.com/steam/apps/{appid}/library_hero.jpg", $"https://shared.steamstatic.com/store_item_assets/steam/apps/{appid}/library_hero.jpg"],
        _ => [$"https://cdn.cloudflare.steamstatic.com/steam/apps/{appid}/logo.png", $"https://shared.steamstatic.com/store_item_assets/steam/apps/{appid}/logo.png"],
    };
}

// MARK: - Epic Games : un fichier .item (JSON) par jeu installé, écrit par le launcher Epic
public static class Epic
{
    public static List<Jeu> Jeux()
    {
        var res = new List<Jeu>();
        if (!OperatingSystem.IsWindows()) return res;
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Epic", "EpicGamesLauncher", "Data", "Manifests");
        if (!Directory.Exists(dir)) return res;
        foreach (var f in Directory.EnumerateFiles(dir, "*.item"))
        {
            try
            {
                using var d = JsonDocument.Parse(File.ReadAllText(f));
                var r = d.RootElement;
                string S(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
                string app = S("AppName"), nom = S("DisplayName"), dossier = S("InstallLocation");
                if (app == "" || nom == "" || !Directory.Exists(dossier)) continue;
                if (r.TryGetProperty("bIsIncompleteInstall", out var inc) && inc.ValueKind == JsonValueKind.True) continue;
                if (S("MainGameAppName") is { Length: > 0 } principal && principal != app) continue;   // un contenu additionnel, pas un jeu
                if (r.TryGetProperty("AppCategories", out var cats) && cats.ValueKind == JsonValueKind.Array && cats.GetArrayLength() > 0
                    && !cats.EnumerateArray().Any(c => c.GetString() == "games")) continue;
                // L'adresse que le launcher Epic comprend : il vérifie la licence puis lance le jeu
                var cible = $"com.epicgames.launcher://apps/{Uri.EscapeDataString($"{S("CatalogNamespace")}:{S("CatalogItemId")}:{app}")}?action=launch&silent=true";
                res.Add(new Jeu { Id = "epic:" + app, Nom = nom, Origine = Origine.Epic, Cible = cible, Dossier = dossier });
            }
            catch (Exception e) { Journal.Ecrire($"Epic, {Path.GetFileName(f)} : {e.Message}"); }
        }
        return res;
    }
}

// MARK: - SteamGridDB (comme sur Mac : grids carrés = jaquette, heroes = fond, logos = logo). La clé reste dans un fichier à part, jamais dans jeux.json.
public static class SteamGridDB
{
    static string FichierCle => Path.Combine(Dossiers.Racine, "steamgriddb-api-key");
    public static string? Cle { get { try { return File.Exists(FichierCle) ? File.ReadAllText(FichierCle).Trim() is { Length: > 0 } c ? c : null : null; } catch { return null; } } }
    public static void Enregistrer(string cle) { Directory.CreateDirectory(Dossiers.Racine); File.WriteAllText(FichierCle, cle.Trim()); }
    const string API = "https://www.steamgriddb.com/api/v2/";
    static async Task<string?> Premiere(string chemin, string cle)
    {
        using var d = await Reseau.Json(API + chemin, cle);
        if (d == null || !d.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array || data.GetArrayLength() == 0) return null;
        return data[0].TryGetProperty("url", out var u) ? u.GetString() : null;
    }
    public static async Task<string?> Image(Jeu j, string quoi)
    {
        if (Cle is not { } cle) return null;
        string? cible = j.SteamId is { } s ? "steam/" + s : null;
        if (cible == null)
        {
            using var d = await Reseau.Json(API + "search/autocomplete/" + Uri.EscapeDataString(j.Nom), cle);
            if (d == null || !d.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array || data.GetArrayLength() == 0) return null;
            var trouve = data.EnumerateArray().FirstOrDefault(x => x.TryGetProperty("name", out var n) && Titres.Correspond(n.GetString() ?? "", j.Nom) && Titres.MemesNumeros(n.GetString() ?? "", j.Nom));
            if (trouve.ValueKind != JsonValueKind.Object) return null;   // jamais un jeu sans rapport en automatique
            cible = "game/" + trouve.GetProperty("id").GetInt64();
        }
        return quoi switch
        {
            "couverture" => await Premiere($"grids/{cible}?dimensions=1024x1024,512x512", cle),
            "fond" => await Premiere($"heroes/{cible}", cle),
            _ => await Premiere($"logos/{cible}", cle),
        };
    }
}

/// Un résultat de recherche est-il bien le jeu cherché ? (les mêmes règles que `matchesGame` et `memesNumeros` sur Mac)
public static class Titres
{
    static readonly HashSet<string> vides = ["the", "and", "les", "des", "une", "pour", "for", "with", "edition", "remastered", "deluxe", "demo"];
    static string Plat(string s) => new string(s.Normalize(NormalizationForm.FormD).Where(c => System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c) != System.Globalization.UnicodeCategory.NonSpacingMark).ToArray()).ToLowerInvariant();
    static List<string> Mots(string s) => new string(Plat(s).Select(c => char.IsLetterOrDigit(c) ? c : ' ').ToArray()).Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(m => m.Length >= 3 && !vides.Contains(m)).ToList();
    /// Les mots significatifs du nom du jeu (3 lettres au moins, hors « the », « of »…) doivent se retrouver dans le titre proposé
    public static bool Correspond(string titre, string jeu)
    {
        var g = Mots(jeu); var t = Plat(titre);
        return g.Count == 0 || g.Count(t.Contains) >= Math.Max(1, (int)Math.Ceiling(g.Count * 0.6));
    }
    /// Les nombres du nom cherché (« 64 », « 2077 ») doivent être dans le titre proposé : pas de Mario Kart 8 quand on cherche Mario Kart 64
    public static bool MemesNumeros(string titre, string cherche)
    {
        static HashSet<string> Nombres(string s) => new string(s.Select(c => char.IsDigit(c) ? c : ' ').ToArray()).Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
        var n = Nombres(cherche); return n.Count == 0 || n.IsSubsetOf(Nombres(titre));
    }
    /// Parmi des résultats, celui qui est le jeu cherché : le titre le plus court (le jeu lui-même, pas son édition spéciale ni son extension)
    public static T? Meilleur<T>(IEnumerable<T> resultats, Func<T, string> titre, string jeu) where T : class =>
        resultats.Where(r => Correspond(titre(r), jeu) && MemesNumeros(titre(r), jeu)).OrderBy(r => titre(r).Length).FirstOrDefault();
}

/// Les boutiques officielles, sans clé, cherchées par le nom du jeu (comme `EShop` et `PSStore` sur Mac) : elles donnent une jaquette
/// carrée, celle qu'il faut à une tuile, et une grande image pour le fond. Une recherche par jeu, gardée en mémoire.
public sealed record Boutique(string? Carre, string? Fond, string? FondPetit);
public static class Boutiques
{
    static readonly Dictionary<string, Task<Boutique?>> faites = new();
    public static Task<Boutique?> Chercher(string nom)
    {
        lock (faites) return faites.TryGetValue(nom, out var t) ? t : faites[nom] = Trouver(nom);
    }
    static async Task<Boutique?> Trouver(string nom)
    {
        var b = await EShop(nom) ?? await PlayStation(nom);
        Journal.Ecrire($"images de « {nom} » : {(b == null ? "rien dans les boutiques" : b.Carre != null ? "jaquette carrée officielle" : "fond officiel")}");
        return b;
    }
    record Fiche(string Titre, string? Carre, string? Banniere);
    /// Nintendo eShop (Europe) : image carrée 500 px, bannière 2:1 (Switch) ou 16:9 (Switch 2), qui existe en 1600 px pour la plupart
    static async Task<Boutique?> EShop(string nom)
    {
        using var d = await Reseau.Json("https://search.nintendo-europe.com/fr/select?q=" + Uri.EscapeDataString(nom) + "&fq=type%3AGAME&rows=8&wt=json&fl=title,image_url_sq_s,image_url_h2x1_s,image_url_h16x9_s");
        if (d == null || !d.RootElement.TryGetProperty("response", out var r) || !r.TryGetProperty("docs", out var docs) || docs.ValueKind != JsonValueKind.Array) return null;
        static string? Texte(JsonElement e, string cle) => e.TryGetProperty(cle, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        var fiches = docs.EnumerateArray().Select(x => new Fiche(Texte(x, "title") ?? "", Texte(x, "image_url_sq_s"), Texte(x, "image_url_h2x1_s") ?? Texte(x, "image_url_h16x9_s"))).ToList();
        if (Titres.Meilleur(fiches, f => f.Titre, nom) is not { } f) return null;
        var grande = f.Banniere != null && f.Banniere.EndsWith("image500w.jpg") ? f.Banniere[..^"image500w.jpg".Length] + "image1600w.jpg" : null;
        return new Boutique(f.Carre, grande ?? f.Banniere, f.Banniere);
    }
    /// PlayStation Store (l'API du site, sans clé) : images de type 10 = jaquette carrée 1024 px, 12 = image 1920×1080
    static async Task<Boutique?> PlayStation(string nom)
    {
        using var d = await Reseau.Json("https://store.playstation.com/store/api/chihiro/00_09_000/tumbler/BE/fr/999/" + Uri.EscapeDataString(nom) + "?suggested_size=12&mode=game");
        if (d == null || !d.RootElement.TryGetProperty("links", out var liens) || liens.ValueKind != JsonValueKind.Array) return null;
        static string? Image(JsonElement jeu, int type) => jeu.TryGetProperty("images", out var im) && im.ValueKind == JsonValueKind.Array
            ? im.EnumerateArray().Where(i => i.TryGetProperty("type", out var t) && t.ValueKind == JsonValueKind.Number && t.GetInt32() == type && i.TryGetProperty("url", out _)).Select(i => i.GetProperty("url").GetString()).FirstOrDefault() : null;
        var fiches = liens.EnumerateArray().Where(l => l.TryGetProperty("top_category", out var c) && c.GetString() == "downloadable_game" && l.TryGetProperty("name", out _))
            .Select(l => new Fiche(l.GetProperty("name").GetString() ?? "", Image(l, 10), Image(l, 12))).ToList();
        return Titres.Meilleur(fiches, f => f.Titre, nom) is { } f && (f.Carre ?? f.Banniere) != null ? new Boutique(f.Carre, f.Banniere, null) : null;
    }
}

// MARK: - Images : sur disque dans media/<jeu>/ (couverture, fond, logo), sinon téléchargées une fois depuis leur source
public static class Images
{
    static readonly SemaphoreSlim file = new(6);   // pas plus de 6 téléchargements à la fois (les grilles du catalogue en demandent des dizaines)
    static readonly Dictionary<string, Bitmap> memoire = new();
    public static readonly string[] Emplacements = ["couverture", "fond", "logo"];
    public static string Fichier(Jeu j, string quoi) => Dossiers.Fichier("media", Dossiers.NomSur(j.Id), quoi + ".img");

    public static Bitmap? Locale(string fichier, int largeur)
    {
        try { if (!File.Exists(fichier)) return null; using var s = File.OpenRead(fichier); return Bitmap.DecodeToWidth(s, largeur); }
        catch (Exception e) { Journal.Ecrire($"image illisible ({Path.GetFileName(fichier)}) : {e.Message}"); return null; }
    }
    static async Task<bool> Telecharger(string url, string fichier)
    {
        await file.WaitAsync();
        try
        {
            using var r = await Reseau.Http.GetAsync(url);
            if (!r.IsSuccessStatusCode || r.Content.Headers.ContentType?.MediaType?.StartsWith("image/") != true) return false;
            var tmp = fichier + ".tmp";
            await File.WriteAllBytesAsync(tmp, await r.Content.ReadAsByteArrayAsync());
            File.Move(tmp, fichier, true);
            return true;
        }
        catch { return false; }
        finally { file.Release(); }
    }
    /// Une image distante (jaquettes du catalogue) : gardée dans cache/images, puis en mémoire
    public static async Task<Bitmap?> Distante(string url, int largeur)
    {
        var cle = url + "@" + largeur;
        lock (memoire) if (memoire.TryGetValue(cle, out var b)) return b;
        var f = Dossiers.Fichier("cache", "images", Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(url))) + ".img");
        if (!File.Exists(f) && !await Telecharger(url, f)) return null;
        var img = await Task.Run(() => Locale(f, largeur));
        if (img != null) lock (memoire) memoire[cle] = img;
        return img;
    }
    /// Les trois images d'un jeu. Ce qui manque sur disque est cherché à sa source, la plus juste d'abord :
    ///  - jaquette (la tuile est carrée) : SteamGridDB si une clé est enregistrée, puis la jaquette carrée officielle des boutiques
    ///    (eShop, PlayStation Store), puis seulement les jaquettes en hauteur (catalogue des recomps, Steam) ;
    ///  - fond : catalogue, Steam, boutiques, SteamGridDB ; logo : catalogue, Steam, SteamGridDB.
    public static async Task<Art> Charger(Jeu j, RecompInstalle? r)
    {
        var art = new Art();
        foreach (var quoi in Emplacements)
        {
            var f = Fichier(j, quoi);
            if (!File.Exists(f))
            {
                var sources = new List<string?>();
                var catalogue = r == null ? null : quoi == "couverture" ? r.Couverture : quoi == "fond" ? r.Fond : r.Logo;
                var steam = j.SteamId is { } s ? Steam.Images(s, quoi) : [];
                if (quoi == "couverture")
                {
                    sources.Add(await SteamGridDB.Image(j, quoi));
                    if (sources[0] == null && j.SteamId == null) sources.Add((await Boutiques.Chercher(j.Nom))?.Carre);
                    sources.Add(catalogue); sources.AddRange(steam);
                }
                else
                {
                    sources.Add(catalogue); sources.AddRange(steam);
                    if (sources.All(string.IsNullOrEmpty))
                    {
                        if (quoi == "fond" && await Boutiques.Chercher(j.Nom) is { } b) { sources.Add(b.Fond); sources.Add(b.FondPetit); }
                        sources.Add(await SteamGridDB.Image(j, quoi));
                    }
                }
                foreach (var src in sources) if (!string.IsNullOrEmpty(src) && await Telecharger(src, f)) break;
            }
            var img = await Task.Run(() => Locale(f, quoi == "fond" ? 1920 : quoi == "logo" ? 960 : 500));
            if (quoi == "couverture") art.Couverture = img; else if (quoi == "fond") art.Fond = img; else art.Logo = img;
        }
        return art;
    }
}
