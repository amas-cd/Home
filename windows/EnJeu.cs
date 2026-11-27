// Home pour Windows — le menu en jeu (`HUDView`, `toggleQuick`, `quickAct` sur Mac) : une petite fenêtre toujours devant le jeu, ouverte
// à la manette, avec Fermer le jeu, Retour à Home, le volume du jeu et, pour un jeu en ligne, la liste des joueurs connectés.
// Ce que Windows ne permet pas comme sur Mac : la manette n'est pas retirée au jeu pendant que le menu est ouvert (il reçoit aussi les
// appuis), et une fenêtre ne passe pas devant un jeu en plein écran exclusif.
using System.Runtime.InteropServices;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace Home;

/// Le volume d'un jeu, sans toucher à celui du PC : chaque programme qui joue du son a sa « session » dans le mélangeur de Windows
/// (celui du clic droit sur le haut-parleur). Home règle les sessions des programmes du jeu.
public static class SonJeu
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class Enumerateur { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator { [PreserveSig] int EnumAudioEndpoints(int sens, int etats, out IntPtr appareils); [PreserveSig] int GetDefaultAudioEndpoint(int sens, int role, out IMMDevice appareil); }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int contexte, IntPtr parametres, [MarshalAs(UnmanagedType.IUnknown)] out object objet); }
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 { [PreserveSig] int GetAudioSessionControl(IntPtr a, int b, out IntPtr c); [PreserveSig] int GetSimpleAudioVolume(IntPtr a, int b, out IntPtr c); [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessions); }
    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator { [PreserveSig] int GetCount(out int n); [PreserveSig] int GetSession(int i, [MarshalAs(UnmanagedType.IUnknown)] out object session); }
    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {   // les neuf méthodes d'IAudioSessionControl d'abord, dans l'ordre : seules leurs places comptent
        [PreserveSig] int GetState(out int e); [PreserveSig] int GetDisplayName(out IntPtr n); [PreserveSig] int SetDisplayName(IntPtr n, IntPtr c); [PreserveSig] int GetIconPath(out IntPtr p); [PreserveSig] int SetIconPath(IntPtr p, IntPtr c);
        [PreserveSig] int GetGroupingParam(out Guid g); [PreserveSig] int SetGroupingParam(ref Guid g, IntPtr c); [PreserveSig] int RegisterAudioSessionNotification(IntPtr n); [PreserveSig] int UnregisterAudioSessionNotification(IntPtr n);
        [PreserveSig] int GetSessionIdentifier(out IntPtr id); [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr id); [PreserveSig] int GetProcessId(out uint pid);
    }
    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume { [PreserveSig] int SetMasterVolume(float v, ref Guid contexte); [PreserveSig] int GetMasterVolume(out float v); [PreserveSig] int SetMute(bool m, ref Guid contexte); [PreserveSig] int GetMute(out bool m); }

    static List<ISimpleAudioVolume> Sessions(HashSet<int> pids)
    {
        var r = new List<ISimpleAudioVolume>();
        if (!OperatingSystem.IsWindows() || pids.Count == 0) return r;
        var e = (IMMDeviceEnumerator)new Enumerateur();
        if (e.GetDefaultAudioEndpoint(0, 1, out var sortie) != 0) return r;   // la sortie son par défaut
        var iid = typeof(IAudioSessionManager2).GUID;
        if (sortie.Activate(ref iid, 23, IntPtr.Zero, out var o) != 0 || o is not IAudioSessionManager2 m || m.GetSessionEnumerator(out var sessions) != 0) return r;
        sessions.GetCount(out var n);
        for (var i = 0; i < n; i++)
            if (sessions.GetSession(i, out var s) == 0 && s is IAudioSessionControl2 c && c.GetProcessId(out var pid) == 0 && pids.Contains((int)pid) && s is ISimpleAudioVolume v) r.Add(v);
        return r;
    }
    /// Le volume du jeu (0 à 1) et s'il est muet ; null si aucun de ses programmes ne joue de son pour l'instant
    public static (double volume, bool muet)? Lire(HashSet<int> pids)
    {
        try { foreach (var s in Sessions(pids)) if (s.GetMasterVolume(out var v) == 0) { s.GetMute(out var m); return (v, m); } }
        catch (Exception e) { Journal.Ecrire("volume du jeu : " + e.Message); }
        return null;
    }
    public static bool Regler(HashSet<int> pids, double volume, bool muet)
    {
        try { var vide = Guid.Empty; var s = Sessions(pids); foreach (var x in s) { x.SetMasterVolume((float)Math.Clamp(volume, 0, 1), ref vide); x.SetMute(muet, ref vide); } return s.Count > 0; }
        catch (Exception e) { Journal.Ecrire("volume du jeu : " + e.Message); return false; }
    }
}

/// Les joueurs connectés à un serveur en ligne. Sur Mac, Home lit le journal du serveur par SSH avec la clé de celui qui le tient ; cette
/// clé ne se partage pas. Ici le serveur publie lui-même la liste, en lecture seule (`serveur/totk-etat.py`), sur le port juste après
/// celui du jeu : Home la lit sans clé, depuis l'adresse déjà donnée pour jouer.
public static class JoueursEnLigne
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(4) };
    /// null : la page d'état ne répond pas (pas installée sur ce serveur, ou serveur arrêté)
    public static async Task<List<string>?> Lire(string serveur)
    {
        try
        {
            var i = serveur.LastIndexOf(':'); if (i <= 0 || !int.TryParse(serveur[(i + 1)..], out var port)) return null;
            using var d = JsonDocument.Parse(await http.GetStringAsync($"http://{serveur[..i]}:{port + 1}/joueurs"));
            return d.RootElement.GetProperty("joueurs").EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x != "").Take(64).ToList();
        }
        catch { return null; }
    }
}

public sealed partial class Bibliotheque
{
    // MARK: Menu en jeu
    public bool Rapide, RapideCurseur, RapideJoueurs; public int IndexRapide;
    public double Volume = 1; public bool Muet;
    public List<string>? Joueurs; public bool JoueursLus;   // null après lecture : le serveur ne répond pas
    DateTime appuiRapide; DispatcherTimer? veilleRapide; int toursRapide;
    public System.Diagnostics.Process? Lance;   // le programme que Home a lancé lui-même (jeu Switch, app)
    /// L'adresse du serveur du jeu en cours, s'il joue en ligne (elle a été donnée en construisant le jeu, ou dans Mods)
    public string? ServeurEnCours => EnCours is { Origine: Origine.Switch } j && Construction.Serveur(j.Dossier) is { Length: > 0 } s ? s : null;
    public List<(string nom, string icone)> ChoixRapides
    {
        get
        {
            var c = new List<(string, string)> { ("Fermer le jeu", "xmark.circle"), ("Retour à Home", "house"), ("Volume du jeu", "gamecontroller") };
            if (ServeurEnCours != null) c.Add(("Joueurs", "person.2"));
            return c;
        }
    }
    HashSet<int> PidsDuJeu() { var p = EnCours is { } j ? Systeme.PidsDans(j.Dossier) : new(); try { if (Lance is { HasExited: false } l) p.Add(l.Id); } catch { } return p; }

    public void BasculerRapide()
    {
        if (EnCours == null) { if (Rapide) FermerRapide(); return; }
        if (Rapide) { FermerRapide(); Son("retour"); return; }
        Rapide = true; RapideCurseur = RapideJoueurs = false; IndexRapide = 0; appuiRapide = DateTime.Now; Son("ouvrir"); Signaler();
        _ = Task.Run(() => SonJeu.Lire(PidsDuJeu())).ContinueWith(t => Dispatcher.UIThread.Post(() => { if (t.Result is { } v) { Volume = v.volume; Muet = v.muet; Signaler(); } }));
        veilleRapide ??= new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) =>
        {
            if (!Rapide) { veilleRapide?.Stop(); return; }
            if (EnCours == null || (DateTime.Now - appuiRapide).TotalSeconds > 10 && !RapideJoueurs) { FermerRapide(); return; }   // oublié ouvert : il se referme
            if (RapideJoueurs && toursRapide++ % 5 == 0) LireJoueurs();   // toutes les 5 s, comme sur Mac
            Signaler();   // l'heure et le temps de jeu
        });
        veilleRapide.Start();
    }
    public void FermerRapide() { if (!Rapide) return; Rapide = RapideCurseur = RapideJoueurs = false; Signaler(); }
    async void LireJoueurs() { if (ServeurEnCours is not { } s) return; var j = await JoueursEnLigne.Lire(s); Joueurs = j; JoueursLus = true; Signaler(); }
    void ReglerVolume(double v, bool muet)
    {
        Volume = Math.Clamp(Math.Round(v * 20) / 20, 0, 1); Muet = muet;
        if (EnCours is { } j) { Config.Volumes[j.Id] = Volume; Enregistrer(); }
        var pids = PidsDuJeu(); var (vol, m) = (Volume, Muet); _ = Task.Run(() => SonJeu.Regler(pids, vol, m));
        Signaler();
    }
    /// Au lancement : le jeu retrouve le volume réglé la dernière fois (appelé quand ses programmes sont vus en train de tourner)
    public void RemettreVolume(Jeu j) { if (Config.Volumes.TryGetValue(j.Id, out var v) && v < 0.999) SonJeu.Regler(Systeme.PidsDans(j.Dossier), v, false); }

    public void NavRapide(string k)
    {
        appuiRapide = DateTime.Now;
        if (RapideJoueurs) { if (k is "back" or "ok") { RapideJoueurs = false; Son("retour"); Signaler(); } return; }
        if (RapideCurseur)
        {   // le grand curseur : gauche / droite pour régler, Y pour couper, B pour revenir aux cartes
            if (k is "left" or "right") { ReglerVolume(Volume + (k == "left" ? -0.05 : 0.05), false); Son("volume"); }
            else if (k == "tri") ReglerVolume(Volume, !Muet);
            else if (k is "back" or "ok") { RapideCurseur = false; Son("retour"); Signaler(); }
            return;
        }
        var choix = ChoixRapides;
        switch (k)
        {
            case "left": if (IndexRapide > 0) { IndexRapide--; Son("deplacer"); Signaler(); } break;
            case "right": if (IndexRapide < choix.Count - 1) { IndexRapide++; Son("deplacer"); Signaler(); } break;
            case "back": BasculerRapide(); break;
            case "ok":
                switch (choix[Math.Clamp(IndexRapide, 0, choix.Count - 1)].nom)
                {
                    case "Fermer le jeu":   // Home repasse devant d'abord, le jeu se ferme derrière lui
                        Son("valider"); var j = EnCours; var lance = Lance; FermerRapide(); Dire("Fermeture du jeu…"); Devant?.Invoke();
                        if (j != null) _ = Task.Delay(450).ContinueWith(_ => Systeme.Fermer(j.Dossier, lance));
                        break;
                    case "Retour à Home": FermerRapide(); Devant?.Invoke(); break;
                    case "Volume du jeu": RapideCurseur = true; Son("ouvrir"); Signaler(); break;
                    case "Joueurs": RapideJoueurs = true; JoueursLus = false; toursRapide = 0; Son("ouvrir"); LireJoueurs(); Signaler(); break;
                }
                break;
        }
    }
}

/// Ce que la fenêtre du menu en jeu dessine (`HUDView`) : en haut à droite l'heure et la batterie ; en bas la carte du jeu, les choix,
/// et au-dessus le curseur de volume ou la carte des joueurs. Pas de flou derrière (c'est le jeu) : des fonds sombres presque opaques.
sealed class VueRapide : Panel
{
    readonly Bibliotheque lib; string cle = "";
    public VueRapide(Bibliotheque lib)
    {
        this.lib = lib; IsHitTestVisible = false;
        lib.Change += Mettre; DetachedFromVisualTree += (_, _) => lib.Change -= Mettre;
        Mettre();
    }
    static Border Carte(Control dedans, double rayon, Thickness marge) => new()
    {
        Background = U.Noir(0.78), BorderBrush = U.Blanc(0.14), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(rayon), Padding = marge, Child = dedans,
        HorizontalAlignment = HorizontalAlignment.Center, BoxShadow = BoxShadows.Parse("0 14 34 0 #99000000"),
    };
    void Mettre()
    {
        if (!lib.Rapide || lib.EnCours is not { } j) { if (cle != "") { cle = ""; Children.Clear(); } return; }
        var choix = lib.ChoixRapides; var i = Math.Clamp(lib.IndexRapide, 0, choix.Count - 1);
        var ecoule = (int)(DateTime.Now - lib.EnCoursDepuis).TotalSeconds;
        var nouvelle = $"{i}|{lib.RapideCurseur}|{lib.RapideJoueurs}|{lib.Volume:0.00}|{lib.Muet}|{ecoule / 60}|{DateTime.Now:HHmm}|{lib.Batterie}|{lib.JoueursLus}|{(lib.Joueurs == null ? "-" : string.Join(",", lib.Joueurs))}|{lib.Aides.Ok}";
        if (nouvelle == cle) return;
        var premiere = cle == ""; cle = nouvelle; Children.Clear();

        // haut droite : l'heure et la batterie de la manette
        var haut = U.Ligne(10, U.Texte(DateTime.Now.ToString("HH:mm"), 15, FontWeight.SemiBold));
        if (lib.Batterie is { } pct) { haut.Children.Add(U.Icone(pct < 20 ? "battery.25percent" : pct < 55 ? "battery.50percent" : "battery.100percent", 14)); haut.Children.Add(U.Texte(pct + " %", 13, FontWeight.SemiBold, 0.85)); }
        Children.Add(new Border { Background = U.Noir(0.6), CornerRadius = new CornerRadius(16), Padding = new Thickness(12, 6), Child = haut, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 10, 14, 0) });

        var bas = new StackPanel { Spacing = 12, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 28) };
        if (lib.RapideJoueurs) bas.Children.Add(CarteJoueurs());
        if (lib.RapideCurseur) bas.Children.Add(Curseur());
        // le nom du choix visé, seul texte du menu ; pour le volume, son niveau
        var nom = choix[i].nom; if (nom.StartsWith("Volume")) nom += " · " + (lib.Muet ? "muet" : $"{(int)Math.Round(lib.Volume * 100)} %");
        bas.Children.Add(new Border { Background = Brushes.White, CornerRadius = new CornerRadius(20), Padding = new Thickness(18, 8), HorizontalAlignment = HorizontalAlignment.Center, Opacity = lib.RapideCurseur ? 0.5 : 1,
            Child = new TextBlock { Text = nom, FontSize = 18, FontWeight = FontWeight.Bold, FontFamily = U.Police, Foreground = Brushes.Black } });
        // la carte du jeu, son temps, puis les choix : le choix visé est un disque blanc plus grand
        var rangee = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        if (lib.Arts.GetValueOrDefault(j.Id)?.Couverture is { } jaquette) rangee.Children.Add(new Border { Width = 56, Height = 56, CornerRadius = new CornerRadius(14), ClipToBounds = true, VerticalAlignment = VerticalAlignment.Center, Child = new Image { Source = jaquette, Stretch = Stretch.UniformToFill } });
        rangee.Children.Add(U.Texte($"{ecoule / 3600}:{ecoule % 3600 / 60:00}", 17, FontWeight.SemiBold, 0.8));
        rangee.Children.Add(new Border { Width = 1, Height = 44, Background = U.Blanc(0.18), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0) });
        for (var n = 0; n < choix.Count; n++)
        {
            var ici = n == i; double cote = ici ? 82 : 62; var volume = choix[n].nom.StartsWith("Volume");
            var disque = new Panel { Width = cote, Height = cote, VerticalAlignment = VerticalAlignment.Center, Opacity = lib.RapideCurseur && !ici ? 0.45 : 1 };
            disque.Children.Add(new Ellipse { Fill = ici ? Brushes.White : U.Blanc(0.12), Stroke = ici ? null : U.Blanc(0.16), StrokeThickness = 1 });
            disque.Children.Add(U.Icone(choix[n].icone, ici ? 29 : 23, ici ? Brushes.Black : Brushes.White));
            // autour du volume : un anneau orange qui dit son niveau
            if (volume) disque.Children.Add(new Anneau { Width = cote + 10, Height = cote + 10, Margin = new Thickness(-5), Epaisseur = 4, Couleur = new SolidColorBrush(Icones.Orange), Fraction = lib.Muet ? 0 : Math.Max(0.02, lib.Volume) });
            rangee.Children.Add(disque);
        }
        bas.Children.Add(Carte(rangee, 56, new Thickness(22, 14)));
        var aides = lib.RapideCurseur ? U.Ligne(10, U.Pilule("Y", lib.Muet ? "Son" : "Muet"), U.Pilule(lib.Aides.Retour, "Retour"))
            : lib.RapideJoueurs ? U.Ligne(10, U.Pilule(lib.Aides.Retour, "Fermer")) : U.Ligne(10, U.Pilule(lib.Aides.Ok, i >= 2 ? "Ouvrir" : "Valider"), U.Pilule(lib.Aides.Retour, "Fermer"));
        aides.HorizontalAlignment = HorizontalAlignment.Center; aides.RenderTransformOrigin = U.Centre; aides.RenderTransform = new ScaleTransform(0.86, 0.86);
        bas.Children.Add(aides);
        Children.Add(bas);
        if (premiere)
        {   // il monte du bas en apparaissant
            bas.Opacity = 0; bas.RenderTransform = Mouvement.Deplace(0, 26);
            bas.Transitions = new Avalonia.Animation.Transitions { Mouvement.Opacite(0.3), Mouvement.Transfo(0.35, Mouvement.Glisse) };
            Mouvement.Apres(() => { bas.Opacity = 1; bas.RenderTransform = Mouvement.Deplace(0, 0); });
        }
    }
    Control Curseur()
    {
        var v = lib.Muet ? 0 : lib.Volume;
        var piste = new Panel { Width = 440, Height = 22, VerticalAlignment = VerticalAlignment.Center };
        piste.Children.Add(new Border { Height = 10, CornerRadius = new CornerRadius(5), Background = U.Blanc(0.2), VerticalAlignment = VerticalAlignment.Center });
        piste.Children.Add(new Border { Height = 10, Width = Math.Max(10, 440 * v), CornerRadius = new CornerRadius(5), Background = Brushes.White, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left });
        piste.Children.Add(new Ellipse { Width = 22, Height = 22, Fill = Brushes.White, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(Math.Clamp(440 * v - 11, 0, 418), 0, 0, 0) });
        var pourcent = U.Texte(lib.Muet ? "Muet" : $"{(int)Math.Round(lib.Volume * 100)} %", 22, FontWeight.Bold); pourcent.Width = 84; pourcent.TextAlignment = TextAlignment.Right;
        return Carte(U.Ligne(18, new Panel { Width = 64, Children = { U.Icone(v == 0 ? "speaker.slash" : "speaker.wave.2", 26) } }, piste, pourcent), 40, new Thickness(26, 18));
    }
    Control CarteJoueurs()
    {
        var j = lib.Joueurs; var lu = lib.JoueursLus;
        var tete = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        tete.Children.Add(new Ellipse { Width = 9, Height = 9, Fill = new SolidColorBrush(j == null ? Icones.Orange : Icones.Vert), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        var titre = U.Texte("Joueurs en ligne", 16, FontWeight.Bold); Grid.SetColumn(titre, 1); tete.Children.Add(titre);
        var compte = U.Texte(!lu ? "Lecture…" : j == null ? "Pas de réponse" : j.Count == 1 ? "1 joueur" : j.Count + " joueurs", 14, FontWeight.SemiBold, 0.7); Grid.SetColumn(compte, 2); tete.Children.Add(compte);
        var colonne = U.Colonne(12, tete);
        if (j is { Count: > 0 })
        {
            var noms = new StackPanel { Spacing = 8 };
            foreach (var n in j.Take(8)) noms.Children.Add(U.Ligne(10, U.Icone("person", 20), U.Texte(n, 15, FontWeight.SemiBold)));
            if (j.Count > 8) noms.Children.Add(U.Texte($"et {j.Count - 8} autre{(j.Count - 8 > 1 ? "s" : "")}", 13, FontWeight.Medium, 0.6));
            colonne.Children.Add(noms);
        }
        else colonne.Children.Add(Avec(U.Texte(!lu ? " " : j == null ? "Le serveur ne publie pas sa liste de joueurs, ou il est arrêté." : "Personne", 14, FontWeight.Medium, 0.65), t => { t.TextWrapping = TextWrapping.Wrap; t.MaxWidth = 328; }));
        colonne.Width = 328;
        return Carte(colonne, 32, new Thickness(26, 22));
    }
    static T Avec<T>(T c, Action<T> a) { a(c); return c; }
}

/// La fenêtre du menu en jeu : sans bord, transparente, toujours devant, sur l'écran où est Home. Elle ne prend pas le clavier au jeu.
sealed class FenetreRapide : Window
{
    readonly Canvas racine = new() { Background = Brushes.Transparent };
    public FenetreRapide(Bibliotheque lib, Window home)
    {
        Title = "Home — menu en jeu"; SystemDecorations = SystemDecorations.None; Topmost = true; ShowInTaskbar = false; ShowActivated = false; CanResize = false; Focusable = false;
        Background = Brushes.Transparent; TransparencyLevelHint = [WindowTransparencyLevel.Transparent]; WindowStartupLocation = WindowStartupLocation.Manual; Content = racine;
        var vue = new VueRapide(lib) { Width = 1920, RenderTransformOrigin = new RelativePoint(0, 0, RelativeUnit.Relative) }; racine.Children.Add(vue);
        racine.SizeChanged += (_, e) => { var k = Math.Max(0.3, e.NewSize.Width / 1920); vue.Height = e.NewSize.Height / k; vue.RenderTransform = new ScaleTransform(k, k); };
        lib.Change += () =>
        {
            if (lib.Rapide && !IsVisible)
            {
                var ecran = home.Screens.ScreenFromWindow(home) ?? home.Screens.Primary;
                if (ecran != null) { Position = ecran.Bounds.Position; Width = ecran.Bounds.Width / ecran.Scaling; Height = ecran.Bounds.Height / ecran.Scaling; }
                Show();
            }
            else if (!lib.Rapide && IsVisible) Hide();
        };
    }
}
