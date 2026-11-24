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
            cible = "game/" + data[0].GetProperty("id").GetInt64();
        }
        return quoi switch
        {
            "couverture" => await Premiere($"grids/{cible}?dimensions=1024x1024,512x512", cle),
            "fond" => await Premiere($"heroes/{cible}", cle),
            _ => await Premiere($"logos/{cible}", cle),
        };
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
    /// Les trois images d'un jeu. Ce qui manque sur disque est cherché à sa source : Steam, le catalogue des recomps, puis SteamGridDB si une clé est enregistrée.
    public static async Task<Art> Charger(Jeu j, RecompInstalle? r)
    {
        var art = new Art();
        foreach (var quoi in Emplacements)
        {
            var f = Fichier(j, quoi);
            if (!File.Exists(f))
            {
                var sources = new List<string>();
                if (r != null && (quoi == "couverture" ? r.Couverture : quoi == "fond" ? r.Fond : r.Logo) is { Length: > 0 } u) sources.Add(u);
                // Jaquette carrée de SteamGridDB d'abord (la tuile est carrée) ; celle de Steam est en hauteur
                if (quoi == "couverture" && r == null && await SteamGridDB.Image(j, quoi) is { } carre) sources.Add(carre);
                if (j.SteamId is { } s) sources.AddRange(Steam.Images(s, quoi));
                if (quoi != "couverture" && r == null && j.SteamId == null && await SteamGridDB.Image(j, quoi) is { } g) sources.Add(g);
                foreach (var src in sources) if (await Telecharger(src, f)) break;
            }
            var img = await Task.Run(() => Locale(f, quoi == "fond" ? 1920 : quoi == "logo" ? 960 : 500));
            if (quoi == "couverture") art.Couverture = img; else if (quoi == "fond") art.Fond = img; else art.Logo = img;
        }
        return art;
    }
}
