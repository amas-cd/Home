// Home pour Windows — la présence Discord (`Discord` et `presenceDiscord` dans app/main.swift) : les amis voient « Dans le menu », ou
// le jeu en cours avec sa jaquette. Home parle à l'app Discord par sa porte locale : sur Windows le tube nommé discord-ipc-0 à 9
// (sur Mac et Linux, un socket du même nom dans le dossier temporaire : c'est ce qui permet de l'essayer sans PC).
// Trame : deux entiers de 32 bits petit-boutistes (opération, taille), puis du JSON. Rien ne bloque l'interface : tout passe par une file.
using System.IO.Pipes;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace Home;

public static class Discord
{
    public const string AppID = "1575950465898905620";   // l'identifiant de l'application Discord « Home », le même que sur Mac (public)
    public static readonly DateTime Depuis = DateTime.UtcNow;
    static readonly SemaphoreSlim file = new(1, 1);
    static Stream? tube; static Dictionary<string, object?>? voulue; static bool aEnvoyer, attente;

    /// L'adresse d'où vient une jaquette téléchargée, gardée à côté d'elle (couverture.img → couverture.url) : Discord ne montre pas un
    /// fichier du PC, il lui faut une adresse https publique. null l'efface (image choisie à la main).
    public static void NoterSource(string? url, string fichier)
    {
        var f = Path.ChangeExtension(fichier, ".url");
        try { if (url != null && url.StartsWith("https://") && url.Length < 250) File.WriteAllText(f, url); else if (File.Exists(f)) File.Delete(f); } catch { }
    }
    /// Une adresse publique de la jaquette du jeu : celle d'où Home l'a téléchargée, sinon celle de Steam
    public static string? Jaquette(Jeu j)
    {
        try { var f = Path.ChangeExtension(Images.Fichier(j, "couverture"), ".url"); if (File.Exists(f) && File.ReadAllText(f).Trim() is { Length: > 8 } u) return u; } catch { }
        return j.SteamId is { } s ? $"https://cdn.cloudflare.steamstatic.com/steam/apps/{s}/library_600x900.jpg" : null;
    }

    /// Ce que Discord doit montrer ; null efface la présence
    public static void Montrer(Dictionary<string, object?>? activite) => _ = Task.Run(async () =>
    {
        await file.WaitAsync();
        try { voulue = activite; aEnvoyer = true; await Pousser(); } finally { file.Release(); }
    });
    static async Task Pousser()
    {
        if (!aEnvoyer) return;
        if (tube == null && voulue == null) { aEnvoyer = false; return; }   // rien à effacer : on ne dérange pas Discord
        if (tube == null && !await Relier()) { Reessayer(); return; }
        var ok = await Envoyer(1, new() { ["cmd"] = "SET_ACTIVITY", ["nonce"] = Guid.NewGuid().ToString(), ["args"] = new Dictionary<string, object?> { ["pid"] = Environment.ProcessId, ["activity"] = voulue } }) && await Lire() != null;
        if (ok) aEnvoyer = false; else { Fermer(); Reessayer(); }
    }
    /// Discord fermé : on réessaie toutes les 30 s tant qu'il y a quelque chose à afficher
    static void Reessayer()
    {
        if (attente || voulue == null) return;
        attente = true;
        _ = Task.Delay(30000).ContinueWith(async _ => { await file.WaitAsync(); try { attente = false; await Pousser(); } finally { file.Release(); } });
    }
    static async Task<bool> Relier()
    {
        for (var n = 0; n < 10; n++)
        {
            try
            {
                if (OperatingSystem.IsWindows()) { var p = new NamedPipeClientStream(".", "discord-ipc-" + n, PipeDirection.InOut, PipeOptions.Asynchronous); try { p.Connect(250); tube = p; } catch { p.Dispose(); continue; } }
                else
                {
                    var chemin = new[] { Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR"), Environment.GetEnvironmentVariable("TMPDIR"), "/tmp" }.Where(d => !string.IsNullOrEmpty(d)).Select(d => Path.Combine(d!, "discord-ipc-" + n)).FirstOrDefault(File.Exists);
                    if (chemin == null) continue;
                    var s = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified); await s.ConnectAsync(new UnixDomainSocketEndPoint(chemin)); tube = new NetworkStream(s, true);
                }
                if (await Envoyer(0, new() { ["v"] = 1, ["client_id"] = AppID }) && await Lire() is { } r && r.RootElement.TryGetProperty("evt", out var e) && e.GetString() == "READY") { Journal.Ecrire("Discord : présence reliée"); return true; }
            }
            catch { }
            Fermer();
        }
        return false;
    }
    static void Fermer() { try { tube?.Dispose(); } catch { } tube = null; }
    static async Task<bool> Envoyer(int operation, Dictionary<string, object?> message)
    {
        if (tube == null) return false;
        try
        {
            var corps = JsonSerializer.SerializeToUtf8Bytes(message); var trame = new byte[8 + corps.Length];
            BitConverter.TryWriteBytes(trame.AsSpan(0, 4), operation); BitConverter.TryWriteBytes(trame.AsSpan(4, 4), corps.Length); corps.CopyTo(trame, 8);
            using var limite = new CancellationTokenSource(3000); await tube.WriteAsync(trame, limite.Token); await tube.FlushAsync(limite.Token); return true;
        }
        catch { return false; }
    }
    static async Task<JsonDocument?> Lire()
    {
        if (tube == null) return null;
        try
        {
            using var limite = new CancellationTokenSource(4000);
            var tete = new byte[8]; await tube.ReadExactlyAsync(tete, limite.Token);
            var taille = BitConverter.ToInt32(tete, 4); if (taille is < 0 or > 1 << 20) return null;
            var corps = new byte[taille]; await tube.ReadExactlyAsync(corps, limite.Token);
            return BitConverter.ToInt32(tete, 0) == 2 ? null : JsonDocument.Parse(corps);   // 2 = Discord ferme la liaison
        }
        catch { return null; }
    }
}

public sealed partial class Bibliotheque
{
    /// Ce que les amis voient dans Discord : « Dans le menu », ou le jeu en cours, d'où il vient, depuis quand, et sa jaquette
    public void MajDiscord()
    {
        if (!Config.Discord || (Demo && Environment.GetEnvironmentVariable("HOME_DISCORD") != "1")) { Discord.Montrer(null); return; }   // pas pendant une démonstration ou une capture
        static long Unix(DateTime d) => new DateTimeOffset(d.ToUniversalTime()).ToUnixTimeSeconds();
        if (EnCours is not { } j)
        {
            Discord.Montrer(new() { ["details"] = "Dans le menu", ["timestamps"] = new Dictionary<string, object?> { ["start"] = Unix(Discord.Depuis) }, ["assets"] = new Dictionary<string, object?> { ["large_image"] = "home", ["large_text"] = "Home" } });
            return;
        }
        var images = new Dictionary<string, object?> { ["large_text"] = j.Nom };
        if (Discord.Jaquette(j) is { } jaquette) { images["large_image"] = jaquette; images["small_image"] = "home"; images["small_text"] = "Home"; } else images["large_image"] = "home";
        // le titre de l'activité est le nom du jeu (« Joue à Rocket League »), pas « Home », comme sur Mac
        Discord.Montrer(new() { ["name"] = j.Nom, ["details"] = ConsoleDe(j).nom, ["state"] = "Avec Home", ["timestamps"] = new Dictionary<string, object?> { ["start"] = Unix(EnCoursDepuis) }, ["assets"] = images });
    }
}
