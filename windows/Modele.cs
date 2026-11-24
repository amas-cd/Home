// Home pour Windows — le modèle : jeux, réglages, menus, dossiers, icônes.
// Les noms suivent app/main.swift (Game → Jeu, SalonMenu → Menu…) pour qu'un changement fait sur Mac se reporte ici sans chercher.
using System.Text.Json;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using FluentIcons.Common;

namespace Home;

/// D'où vient un jeu : décide comment on le lance et où on cherche ses images
public enum Origine { Steam, Epic, Recomp, App, Switch }

public sealed class Jeu
{
    public string Id = "";        // "steam:<appid>", "epic:<AppName>", "recomp:<id>", "app:<chemin>"
    public string Nom = "";
    public Origine Origine;
    public string Cible = "";     // ce qu'on ouvre : une adresse steam:// ou com.epicgames.launcher://, ou un .exe
    public string Dossier = "";   // le dossier du jeu : sert à savoir s'il tourne encore (Steam et Epic rendent la main tout de suite)
    public string Categorie => Origine switch { Origine.Steam => "Steam", Origine.Epic => "Epic Games", Origine.Recomp => "Recomps", Origine.Switch => "Switch", _ => "Apps" };
    /// Un jeu Switch en cours de construction : sa tuile existe déjà, elle ouvre son chantier
    public bool EnConstruction => Id.StartsWith("construction:");
    public string? SteamId => Id.StartsWith("steam:") ? Id[6..] : null;
}

public sealed class Art { public Bitmap? Couverture, Fond, Logo; }
public sealed class Stat { public DateTime? DernierePartie { get; set; } public int Minutes { get; set; } }
public sealed class Entree { public string Chemin { get; set; } = ""; public string? Nom { get; set; } }
public sealed class Config
{
    public List<Entree> Jeux { get; set; } = new();          // les apps ajoutées à la main
    public List<string> Masques { get; set; } = new();       // ids des jeux masqués
    public Dictionary<string, string> Noms { get; set; } = new();   // ids renommés
    public bool Sons { get; set; } = true;
    public bool Fenetre { get; set; }                         // en fenêtre plutôt qu'en plein écran
    public bool AnimationsReduites { get; set; }              // les mouvements de l'interface deviennent un fondu très court
}

/// Un recomp installé par Home : d'où il vient, où il est, comment on le lance
public sealed class RecompInstalle
{
    public string Id { get; set; } = ""; public string Nom { get; set; } = ""; public string Jeu { get; set; } = "";
    public string Depot { get; set; } = ""; public string Version { get; set; } = ""; public string Dossier { get; set; } = "";
    public string? Exe { get; set; }            // chemin complet du jeu, une fois connu
    public string? Installeur { get; set; }     // nom du setup (TotK-Setup.exe) : le jeu se construit avec, à partir des fichiers du joueur
    public string? ExeAttendu { get; set; }     // nom du jeu que le setup produit (totk.exe)
    public string? Couverture { get; set; } public string? Fond { get; set; } public string? Logo { get; set; }
    public bool HorsCatalogue { get; set; }
}

public sealed class ElementMenu
{
    public string Libelle = ""; public string? Detail; public string Icone = "ellipsis"; public string? Section;
    public bool Destructif, Info; public Color? Teinte; public string? Image; public Action Action = () => { };
    public ElementMenu() { }
    public ElementMenu(string libelle, string icone, Action action, string? detail = null) { Libelle = libelle; Icone = icone; Action = action; Detail = detail; }
}
/// La forme d'un menu à l'écran (voir VuesMenus.cs) : une rangée de pastilles, une roue, ou une grille d'affiches
public enum GenreMenu { Rangee, Roue, Grille }
/// Un menu : titre, logo du jeu, image distante ou grand symbole, texte d'explication, et où revenir avec B
public sealed class Menu
{
    public string Titre = ""; public string? SousTitre; public List<ElementMenu> Elements = new();
    public string? Symbole; public Bitmap? Logo; public string? ImageURL; public string? Texte; public Action? Retour; public bool Grille;
    /// Comme sur Mac : un menu court (7 choix au plus, tous actionnables, sans image) est une rangée de pastilles ; les autres, une roue
    public GenreMenu Genre => Grille ? GenreMenu.Grille : Elements.Count is > 0 and <= 7 && Elements.All(e => !e.Info && e.Image == null) ? GenreMenu.Rangee : GenreMenu.Roue;
}
/// Une question posée au clavier (recherche, clé SteamGridDB)
public sealed class Saisie { public string Titre = ""; public string? Aide; public Action<string> Valider = _ => { }; }
/// Une tâche de fond (téléchargement et installation d'un recomp) : son étape, sa progression
public sealed class Tache { public string Titre = ""; public string Etape = "Démarrage…"; public double? Fraction; public bool Fini; public string? Erreur; }

/// Une touche affichée dans les aides : lettre de la manette (A, B…) ou touche du clavier
public sealed record Aides(string Ok, string Retour, string Options, string Plus, string Cat, string? Nom)
{
    public static readonly Aides Clavier = new("Entrée", "Échap", "O", "N", "Tab", null);
    public static readonly Aides Xbox = new("A", "B", "≡", "⧉", "LB RB", "Manette Xbox");
}

public static class Dossiers
{
    /// Tout ce que Home écrit : réglages, images, catalogue, recomps installés. HOME_DONNEES le déplace (tests).
    public static readonly string Racine = Environment.GetEnvironmentVariable("HOME_DONNEES") is { Length: > 0 } d ? d
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Home");
    public static string Fichier(params string[] p) { var c = Path.Combine([Racine, .. p]); Directory.CreateDirectory(Path.GetDirectoryName(c)!); return c; }
    public static string Dossier(params string[] p) { var c = Path.Combine([Racine, .. p]); Directory.CreateDirectory(c); return c; }
    public static string NomSur(string s) => new(s.Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' ? c : '_').ToArray());
}

public static class Journal
{
    static readonly object verrou = new();
    public static void Ecrire(string m)
    {
        try { lock (verrou) File.AppendAllText(Dossiers.Fichier("log", "home.log"), $"{DateTime.Now:dd/MM/yyyy HH:mm:ss}  {m}\n"); } catch { }
    }
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new() { WriteIndented = true, PropertyNameCaseInsensitive = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public static T Lire<T>(string fichier) where T : new()
    {
        try { if (File.Exists(fichier)) return JsonSerializer.Deserialize<T>(File.ReadAllText(fichier), Options) ?? new T(); }
        catch (Exception e) { Journal.Ecrire($"lecture de {Path.GetFileName(fichier)} : {e.Message}"); }
        return new T();
    }
    /// Écrit à côté puis remplace : une coupure pendant l'écriture ne laisse jamais un fichier de réglages à moitié écrit
    public static void Ecrire<T>(string fichier, T valeur)
    {
        try { var tmp = fichier + ".tmp"; File.WriteAllText(tmp, JsonSerializer.Serialize(valeur, Options)); File.Move(tmp, fichier, true); }
        catch (Exception e) { Journal.Ecrire($"écriture de {Path.GetFileName(fichier)} : {e.Message}"); }
    }
}

/// Les menus gardent les noms de symboles de la version Mac (SF Symbols) : ici on les traduit en icônes Fluent (la bibliothèque
/// d'icônes de Microsoft, en version pleine : le dessin le plus proche des symboles du Mac), par préfixe.
public static class Icones
{
    static readonly (string sf, string fluent)[] table =
    [
        ("play", "Play"), ("photo", "Image"), ("paint", "PaintBrush"), ("textformat", "TextFont"), ("tag", "Tag"), ("puzzle", "PuzzlePiece"),
        ("square.and.arrow.down", "ArrowDownload"), ("arrow.down.circle", "ArrowCircleDown"), ("arrow.down", "ArrowDown"), ("arrow.clockwise", "ArrowClockwise"), ("arrow.up", "ArrowUp"), ("arrow.left", "ArrowLeft"), ("arrow", "ArrowRight"),
        ("hammer", "WrenchScrewdriver"), ("folder", "Folder"), ("gamecontroller", "Games"), ("globe", "Globe"), ("magnifying", "Search"),
        ("shippingbox", "Box"), ("pencil", "Edit"), ("ellipsis", "MoreHorizontal"), ("checkmark", "Checkmark"), ("doc.on.clipboard", "ClipboardPaste"), ("doc", "Document"),
        ("bolt", "Flash"), ("safari", "Open"), ("plus.circle", "AddCircle"), ("plus", "Add"), ("desktop", "DesktopTower"), ("pc", "Window"),
        ("mac", "Laptop"), ("key", "Key"), ("power", "Power"), ("speaker.slash", "SpeakerMute"), ("speaker", "Speaker2"), ("display", "Desktop"),
        ("record", "Record"), ("rectangle", "FullScreenMaximize"), ("trash", "Delete"), ("eye.slash", "EyeOff"), ("eye", "Eye"), ("xmark", "Dismiss"),
        ("leaf", "LeafOne"), ("sparkles", "Sparkle"), ("clock", "Clock"), ("gear", "Settings"), ("info", "Info"), ("exclamation", "Warning"),
        ("chevron.right", "ChevronRight"), ("star", "Star"), ("shield", "ShieldCheckmark"), ("link", "Code"), ("person", "Person"), ("battery", "Battery10"),
    ];
    static readonly Dictionary<string, Icon> cache = new();
    public static Icon De(string sf)
    {
        if (cache.TryGetValue(sf, out var s)) return s;
        var nom = table.FirstOrDefault(t => sf.StartsWith(t.sf)).fluent ?? "Circle";
        return cache[sf] = Enum.TryParse<Icon>(nom, out var k) ? k : Icon.Circle;
    }
    /// Pour les tests : les icônes de la table que la bibliothèque ne connaît pas
    public static IEnumerable<string> Inconnues() => table.Where(t => !Enum.TryParse<Icon>(t.fluent, out _)).Select(t => t.fluent);

    /// La couleur de la pastille d'un choix, d'après son symbole (même table que menuTint sur Mac)
    public static Color Teinte(string icone, Color? teinte = null, bool destructif = false)
    {
        if (teinte is { } t) return t;
        if (destructif) return Color.FromRgb(235, 77, 71);
        (string, Color)[] couleurs =
        [
            ("play", Vert), ("photo", Rose), ("paint", Violet), ("textformat", Violet), ("tag", Orange), ("puzzle", Vert), ("square.and.arrow", Bleu), ("arrow", Bleu),
            ("hammer", Orange), ("folder", Cyan), ("gamecontroller", Rouge), ("globe", Sarcelle), ("magnifying", Sarcelle), ("shippingbox", Brun), ("pencil", Jaune),
            ("ellipsis", Gris), ("checkmark", Vert), ("doc", Menthe), ("bolt", Jaune), ("safari", Bleu), ("plus", Vert), ("desktop", Indigo), ("pc", Bleu), ("mac", Bleu),
            ("key", Jaune), ("power", Rouge), ("speaker", Rose), ("display", Bleu), ("record", Rouge), ("rectangle", Bleu), ("trash", Rouge), ("eye", Gris), ("xmark", Gris),
            ("leaf", Vert), ("sparkles", Violet), ("gear", Gris), ("info", Gris), ("exclamation", Orange), ("star", Jaune), ("shield", Vert), ("link", Indigo),
        ];
        foreach (var (k, c) in couleurs) if (icone.StartsWith(k)) return c;
        return Bleu;
    }
    // Les couleurs système de macOS (mode sombre), pour que les pastilles aient les mêmes teintes que sur Mac
    public static readonly Color Vert = Color.FromRgb(48, 209, 88), Rose = Color.FromRgb(255, 55, 95), Violet = Color.FromRgb(191, 90, 242), Orange = Color.FromRgb(255, 159, 10),
        Bleu = Color.FromRgb(10, 132, 255), Cyan = Color.FromRgb(100, 210, 255), Rouge = Color.FromRgb(255, 69, 58), Sarcelle = Color.FromRgb(64, 200, 224),
        Brun = Color.FromRgb(172, 142, 104), Jaune = Color.FromRgb(255, 214, 10), Gris = Color.FromRgb(142, 142, 147), Menthe = Color.FromRgb(102, 212, 207), Indigo = Color.FromRgb(94, 92, 230);
}
