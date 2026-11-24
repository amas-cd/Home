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
    readonly Ecran ecran; Manette? manette;

    public Fenetre()
    {
        Title = "Home"; Background = Brushes.Black; Width = 1600; Height = 900; Content = racine;
        ecran = new Ecran(lib) { Width = 1920, Height = 1080, RenderTransformOrigin = new RelativePoint(0, 0, RelativeUnit.Relative) };
        racine.Children.Add(ecran);
        // Dessiné pour 1920 de large ; la hauteur suit l'écran (1080 en 16:9, 1200 en 16:10) : aucune bande noire, rien ne dépasse
        racine.SizeChanged += (_, e) => { var k = Math.Max(0.3, e.NewSize.Width / 1920); ecran.Height = e.NewSize.Height / k; ecran.RenderTransform = new ScaleTransform(k, k); };
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
            lib.Recharger();
            if (Bibliotheque.Demo) await lib.ChargerDemo(); else _ = Catalogue.Charger();   // le catalogue sert aussi à proposer les mises à jour des recomps
            Scenario();
        };
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
            Key.O => "options", Key.N => "plus", Key.Tab => e.KeyModifiers.HasFlag(KeyModifiers.Shift) ? "catL" : "cat", _ => null,
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
                case "recomps": MenusRecomps.Ouvrir(lib); break;
                case "fiche": if (Catalogue.Par("totk-pc-recomp") is { } r) MenusRecomps.Fiche(lib, r, lib.FermerMenus); break;
                case "saisie": lib.Demander("Rechercher un recomp", "Nom du jeu, au clavier", _ => { }); break;
                case "tache": lib.Tache = new Tache { Titre = "Installation de TotK Recomp", Etape = "Téléchargement… 96 Mo sur 160", Fraction = 0.51 }; lib.Dire("Bibliothèque actualisée"); break;
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
