// Home pour Windows — le démarrage et la fenêtre : plein écran, mise à l'échelle depuis 1920 de large, clavier.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;
using Avalonia.Threading;

namespace Home;

static class Programme
{
    [STAThread]
    static void Main(string[] args)
    {
        try { AppBuilder.Configure<App>().UsePlatformDetect().StartWithClassicDesktopLifetime(args); }
        catch (Exception e) { Journal.Ecrire("arrêt sur erreur : " + e); throw; }
    }
}

sealed class App : Application
{
    public override void Initialize() { Styles.Add(new FluentTheme()); RequestedThemeVariant = ThemeVariant.Dark; }
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime d) d.MainWindow = new Fenetre();
        base.OnFrameworkInitializationCompleted();
    }
}

sealed class Fenetre : Window
{
    readonly Bibliotheque lib = new();
    readonly Canvas racine = new() { ClipToBounds = true, Background = Brushes.Black };
    Ecran ecran; Manette? manette; double echelle = 1;

    public Fenetre()
    {
        Title = "Home"; Background = Brushes.Black; Width = 1600; Height = 900; Content = racine;
        Mouvement.Reduit = lib.Config.AnimationsReduites;
        ecran = NouvelEcran();
        // Dessiné pour 1920 de large ; la hauteur suit l'écran (1080 en 16:9, 1200 en 16:10) : aucune bande noire, rien ne dépasse
        racine.SizeChanged += (_, e) => { echelle = Math.Max(0.3, e.NewSize.Width / 1920); ecran.Height = e.NewSize.Height / echelle; ecran.RenderTransform = new ScaleTransform(echelle, echelle); };
        // « Animations réduites » change toutes les durées : l'écran est refait avec les nouvelles
        lib.Reconstruire = () => { ecran.Detacher(); racine.Children.Remove(ecran); ecran = NouvelEcran(); };
        lib.ChoisirFichier = async (titre, motifs) =>
        {
            var f = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { Title = titre, AllowMultiple = false, FileTypeFilter = [new FilePickerFileType(titre) { Patterns = motifs }] });
            return f.Count > 0 ? f[0].TryGetLocalPath() : null;
        };
        lib.ChoisirDossier = async titre => { var d = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = titre, AllowMultiple = false }); return d.Count > 0 ? d[0].TryGetLocalPath() : null; };
        lib.PressePapiers = async () => Clipboard != null ? await Avalonia.Input.Platform.ClipboardExtensions.TryGetTextAsync(Clipboard) : null;
        lib.Devant = () => { if (WindowState == WindowState.Minimized) WindowState = lib.Config.Fenetre ? WindowState.Normal : WindowState.FullScreen; Activate(); };
        lib.AppliquerFenetre = AppliquerFenetre; lib.Quitter = Close;
        AppliquerFenetre();
        Opened += async (_, _) =>
        {
            Journal.Ecrire($"Home {Bibliotheque.Version} démarre ({Environment.OSVersion})");
            manette = new Manette(lib, () => IsActive);
            if (Icones.Inconnues().ToList() is { Count: > 0 } inconnues) Journal.Ecrire("icônes inconnues : " + string.Join(", ", inconnues));
            if (Environment.GetEnvironmentVariable("HOME_CAPTURE") == null) ecran.Ouvrir();   // l'écran de démarrage et son jingle, pendant que la bibliothèque se charge dessous
            lib.Recharger();
            Scenario();
            // le tout premier lancement : « Bienvenue », que veux-tu faire avec Home ? (pas pendant une capture ni en démonstration)
            if (lib.Config.Mode == null && !Bibliotheque.Demo && Environment.GetEnvironmentVariable("HOME_CAPTURE") == null) { lib.Bienvenue = true; lib.Signaler(); }
            // Une fois par démarrage, sans rien installer : le menu propose la mise à jour, c'est le joueur qui la lance
            if (OperatingSystem.IsWindows() && await MiseAJour.Verifier()) lib.Dire($"Home {MiseAJour.Version} est disponible : Menu → Mettre à jour Home");
        };
    }
    Ecran NouvelEcran()
    {
        var e = new Ecran(lib) { Width = 1920, Height = racine.Bounds.Height > 0 ? racine.Bounds.Height / echelle : 1080, RenderTransformOrigin = new RelativePoint(0, 0, RelativeUnit.Relative), RenderTransform = new ScaleTransform(echelle, echelle) };
        racine.Children.Add(e); return e;
    }
    void AppliquerFenetre() => WindowState = lib.Config.Fenetre || Environment.GetEnvironmentVariable("HOME_FENETRE") == "1" ? WindowState.Normal : WindowState.FullScreen;

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Handled) return;
        if (lib.Saisie != null) { if (e.Key == Key.Escape) lib.Nav("back"); return; }   // le champ de texte reçoit le reste
        var k = e.Key switch
        {
            Key.Left => "left", Key.Right => "right", Key.Up => "up", Key.Down => "down", Key.Enter or Key.Space => "ok", Key.Escape or Key.Back => "back",
            Key.O or Key.Y => "options", Key.N or Key.OemPlus or Key.Add => "plus", Key.Tab => e.KeyModifiers.HasFlag(KeyModifiers.Shift) ? "catL" : "cat", _ => null,
        };
        if (e.Key == Key.F11) { lib.Config.Fenetre = !lib.Config.Fenetre; lib.Enregistrer(); AppliquerFenetre(); }
        if (k != null) { e.Handled = true; lib.Nav(k); }
    }

    /// Pour vérifier l'interface sans Windows (voir CLAUDE.md) : HOME_SCENARIO ouvre un écran précis, HOME_CAPTURE=<fichier.png>
    /// enregistre ce que la fenêtre dessine au bout de quelques secondes, puis quitte.
    async void Scenario()
    {
        var etapes = (Environment.GetEnvironmentVariable("HOME_SCENARIO") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);
        var capture = Environment.GetEnvironmentVariable("HOME_CAPTURE");
        if (etapes.Length == 0 && capture == null) return;
        await Task.Delay(capture != null ? 7000 : 1500);   // le temps que les images arrivent
        foreach (var s in etapes)
        {
            switch (s)
            {
                case "options": lib.OuvrirOptions(); break;
                case "plus": lib.OuvrirPlus(); break;
                case "ajout": lib.OuvrirAjout(); break;
                case "ouverture": ecran.Ouvrir(fige: true); break;
                case "bienvenue": lib.Bienvenue = true; lib.Signaler(); break;
                case "ajouter": MenusSwitch.Ajouter(lib); break;
                case "essaimaj": if (Environment.GetEnvironmentVariable("HOME_CHERCHER") is { } dossier && Trouvailles.Tout(true).FirstOrDefault(x => Trouvailles.EstDump(x) && Trouvailles.Lire(x).titre == MenusSwitch.ModsEnLigne[0].Tid) is { } jeu)
                    { Journal.Ecrire("essai : " + string.Join(" | ", Trouvailles.Tout().Where(Trouvailles.EstDump).Select(x => Path.GetFileName(x) + " = " + Trouvailles.Lire(x).sorte + " " + Trouvailles.Lire(x).titre)) + " | clés : " + (Trouvailles.Cles("prod.keys") != null) + " | mod : " + Path.GetFileName(Trouvailles.Mod(MenusSwitch.ModsEnLigne[0]) ?? "aucun") + " | dlc : " + Trouvailles.DlcDe(jeu).Count);
                      MenusSwitch.Maj(lib, new MenusSwitch.Demande { Dump = jeu, EnLigne = MenusSwitch.ModsEnLigne[0] }); } break;
                case "mode": MenusSwitch.Mode(lib, new MenusSwitch.Demande { Dump = "Zelda TOTK.xci" }); break;
                case "modeinconnu": MenusSwitch.Mode(lib, new MenusSwitch.Demande { Dump = "Un autre jeu.xci" }); break;
                case "enligne": MenusSwitch.EnLigne(lib, new MenusSwitch.Demande { Dump = "Zelda TOTK.xci" }, MenusSwitch.ModsEnLigne[0]); break;
                case "maj": MenusSwitch.Maj(lib, new MenusSwitch.Demande { Dump = "Zelda TOTK.xci", EnLigne = MenusSwitch.ModsEnLigne[0] }); break;
                case "sur": { var dm = new MenusSwitch.Demande { Dump = "Zelda TOTK.xci", EnLigne = MenusSwitch.ModsEnLigne[0] }; lib.Ouvrir(new Menu { Titre = "Es-tu sûr ?", SousTitre = "Zelda-update.nsp", Symbole = "exclamationmark", Alerte = "Ce fichier doit être la mise à jour 1.2.1", Texte = "Home ne peut pas le vérifier. Avec une autre version, TOTK Online ne marchera pas, et il faudra tout reconstruire.", Elements = { new("Oui, c'est la 1.2.1", "checkmark", () => { }) { Teinte = Icones.Vert }, new("Choisir un autre fichier", "arrow.left", () => { }) { Teinte = Icones.Gris } } }); break; }
                case "recap": MenusSwitch.Recap(lib, new MenusSwitch.Demande { Dump = "Zelda TOTK.xci", Maj = "Zelda-1.2.1.nsp", EnLigne = MenusSwitch.ModsEnLigne[0] }); break;
                case "mods": if (lib.Courant is { } jm) MenusSwitch.Mods(lib, jm); break;
                case "place": MenusSwitch.LibererPlace(lib); break;
                case "saisie": lib.Demander("Nouveau nom", "Au clavier", _ => { }); break;
                case "tache": lib.Tache = new Tache { Titre = "Construction de Zelda", Etape = "Recompilation du code…" }; lib.Dire("Bibliothèque actualisée"); break;
                default: lib.Nav(s); break;
            }
            await Task.Delay(1200);
        }
        if (capture == null) return;
        await Task.Delay(3000);
        var taille = new PixelSize((int)racine.Bounds.Width, (int)racine.Bounds.Height);
        using var image = new RenderTargetBitmap(taille, new Vector(96, 96));
        image.Render(racine); image.Save(capture);
        Close();
    }
}
