// Home pour Windows — les mises à jour de Home lui-même.
// Le dépôt est public : Home lit la dernière release de amas-cd/Home sans jeton. Aucun secret dans l'app.
using System.Diagnostics;
using System.Text.Json;

namespace Home;

public static class MiseAJour
{
    public const string Depot = "amas-cd/Home";
    /// Le setup dans une release : son nom d'aujourd'hui, puis l'ancien (les releases d'avant la 0.3.0)
    static readonly string[] Fichiers = ["Home-win64-setup.exe", "Home-Setup.exe"];
    public static string? Version { get; private set; }
    static string? adresse, empreinte;

    /// « 0.2.0 » est-il plus récent que « 0.1.1 » ? Une version de développement (0.0.0-dev.12) est plus vieille que toute release.
    public static bool PlusRecente(string a, string b) =>
        System.Version.TryParse(a.TrimStart('v').Split('-')[0], out var va) && (!System.Version.TryParse(b.TrimStart('v').Split('-')[0], out var vb) || va > vb);

    /// Y a-t-il une version plus récente ? Ne retient qu'un setup venu des releases de ce dépôt, avec son empreinte SHA-256.
    public static async Task<bool> Verifier()
    {
        using var d = await Reseau.Json($"https://api.github.com/repos/{Depot}/releases/latest");
        if (d == null || d.RootElement.ValueKind != JsonValueKind.Object || !d.RootElement.TryGetProperty("tag_name", out var tag)) return false;
        var version = (tag.GetString() ?? "").TrimStart('v');
        if (!PlusRecente(version, Bibliotheque.Version)) return false;
        var assets = d.RootElement.GetProperty("assets").EnumerateArray().ToList();
        foreach (var a in Fichiers.SelectMany(nom => assets.Where(x => x.GetProperty("name").GetString() == nom)))
        {
            var url = a.GetProperty("browser_download_url").GetString() ?? "";
            var dg = a.TryGetProperty("digest", out var x) && x.ValueKind == JsonValueKind.String ? x.GetString()! : "";
            if (!url.StartsWith($"https://github.com/{Depot}/releases/download/", StringComparison.OrdinalIgnoreCase) || !dg.StartsWith("sha256:")) continue;
            Version = version; adresse = url; empreinte = dg[7..];
            return true;
        }
        return false;
    }

    /// Télécharge le setup, vérifie son empreinte, le lance en silencieux et ferme Home : le setup rouvre Home à la fin.
    /// Sans empreinte qui correspond, rien n'est lancé : c'est un programme qu'on exécute.
    public static async Task Installer(Bibliotheque lib)
    {
        if (adresse == null || empreinte == null || Version == null) return;
        if (lib.Tache is { Fini: false }) { lib.Dire("Une installation est déjà en cours"); return; }
        var t = new Tache { Titre = "Mise à jour de Home " + Version, Etape = "Téléchargement…", Fraction = 0 };
        lib.Tache = t; lib.FermerMenus();
        var setup = Dossiers.Fichier("telechargements", Fichiers[0]);
        try
        {
            var recue = await Reseau.Telecharger(adresse, setup, (lu, total) => { t.Fraction = total > 0 ? 0.95 * lu / total : null; t.Etape = $"Téléchargement… {lu / 1048576} Mo" + (total > 0 ? $" sur {total / 1048576}" : ""); lib.Signaler(); });
            if (!recue.Equals(empreinte, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("le setup reçu n'est pas celui qui a été publié (empreinte différente) : rien n'a été lancé");
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("le setup ne se lance que sur Windows");
            Journal.Ecrire($"mise à jour : {Bibliotheque.Version} → {Version}, sha256 {recue}");
            t.Etape = "Installation…"; t.Fraction = 1; lib.Signaler();
            Process.Start(new ProcessStartInfo(setup, "/SILENT /CLOSEAPPLICATIONS /NORESTARTAPPLICATIONS") { UseShellExecute = true });
            lib.Quitter?.Invoke();
        }
        catch (Exception e)
        {
            try { File.Delete(setup); } catch { }
            t.Erreur = e.Message; t.Etape = "Échec : " + e.Message; t.Fini = true; Journal.Ecrire("mise à jour de Home : " + e); lib.Signaler();
            lib.FinTache(t);
        }
    }
}
