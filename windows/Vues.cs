// Home pour Windows — les vues : l'écran d'accueil façon console, recopié de `Screen`, `Tile`, `MenuView`, `NowPlayingView` et
// `TacheView` de app/main.swift (mêmes tailles, mêmes marges, mêmes couleurs). Tout est dessiné pour 1920 de large, puis mis à l'échelle.
using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.Transformation;
using Avalonia.Threading;
using Forme = Avalonia.Controls.Shapes.Path;

namespace Home;

static class U
{
    public static readonly FontFamily Police = new("Segoe UI Variable Display, Segoe UI, SF Pro Rounded, Helvetica Neue, Arial");
    public static IBrush Blanc(double a = 1) => new SolidColorBrush(Colors.White, a);
    public static IBrush Noir(double a = 1) => new SolidColorBrush(Colors.Black, a);
    public static TextBlock Texte(string s, double taille, FontWeight poids = FontWeight.Normal, double opacite = 1) =>
        new() { Text = s, FontSize = taille, FontWeight = poids, Opacity = opacite, FontFamily = Police, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center };
    public static Control Icone(string sf, double taille, IBrush? couleur = null) =>
        new Forme { Data = Icones.De(sf), Fill = couleur ?? Brushes.White, Stretch = Stretch.Uniform, Width = taille, Height = taille, VerticalAlignment = VerticalAlignment.Center };
    public static LinearGradientBrush Degrade(Color a, Color b, bool diagonale = true) => new()
    {
        StartPoint = new RelativePoint(diagonale ? 0 : 0.5, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(diagonale ? 1 : 0.5, 1, RelativeUnit.Relative),
        GradientStops = { new GradientStop(a, 0), new GradientStop(b, 1) },
    };
    public static Color Alpha(Color c, double a) => Color.FromArgb((byte)(255 * a), c.R, c.G, c.B);
    public static StackPanel Ligne(double espace, params Control[] c) { var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = espace }; s.Children.AddRange(c); return s; }
    public static StackPanel Colonne(double espace, params Control[] c) { var s = new StackPanel { Spacing = espace }; s.Children.AddRange(c); return s; }
    public static Control Etiquette(string icone, string texte) => Ligne(7, Icone(icone, 17), Texte(texte, 17, FontWeight.Medium));
    /// Une touche dans une pastille : lettre de la manette ou touche du clavier
    public static Control Touche(string t, IBrush? couleur = null) => new Border
    {
        BorderBrush = couleur ?? Blanc(0.7), BorderThickness = new Thickness(1.5), CornerRadius = new CornerRadius(12), MinWidth = 24, Height = 24, Padding = new Thickness(7, 0), VerticalAlignment = VerticalAlignment.Center,
        Child = new TextBlock { Text = t, FontSize = 12, FontWeight = FontWeight.Bold, FontFamily = Police, Foreground = couleur ?? Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
    };
    public static Control Aide(string touche, string texte) { var l = Ligne(8, Touche(touche), Texte(texte, 16, FontWeight.Medium)); l.Opacity = 0.8; return l; }
    public static async void Distante(Image img, string url, int largeur) { if (await Images.Distante(url, largeur) is { } b) img.Source = b; }
    public static Transitions Fondu(double s = 0.3) => new() { new DoubleTransition { Property = Visual.OpacityProperty, Duration = TimeSpan.FromSeconds(s) } };
}

/// Le fond : l'image du jeu (floutée quand il n'a que sa jaquette), en fondu d'un jeu à l'autre ; sans jeu, des halos de couleur
sealed class FondVue : Panel
{
    readonly Image[] couches = [new(), new()]; int devant; string cle = "?";
    public FondVue()
    {
        ClipToBounds = true; Background = U.Degrade(Color.FromRgb(13, 15, 43), Color.FromRgb(3, 3, 13), false);
        var halos = new Canvas();
        (Color c, double x, double y)[] taches = [(Color.FromRgb(242, 64, 89), 0.14, 0.13), (Color.FromRgb(64, 115, 255), 0.72, 0.30), (Color.FromRgb(51, 217, 140), 0.40, 0.62), (Color.FromRgb(158, 82, 242), 0.86, 0.70)];
        foreach (var (c, x, y) in taches)
        {
            var e = new Avalonia.Controls.Shapes.Ellipse { Width = 1267, Height = 1267, Fill = new RadialGradientBrush { GradientStops = { new GradientStop(U.Alpha(c, 0.5), 0), new GradientStop(U.Alpha(c, 0), 1) } } };
            Canvas.SetLeft(e, 1920 * x - 633); Canvas.SetTop(e, 1080 * y - 633); halos.Children.Add(e);
        }
        Children.Add(halos);
        foreach (var c in couches) { c.Stretch = Stretch.UniformToFill; c.Opacity = 0; c.Transitions = U.Fondu(0.7); c.RenderTransformOrigin = RelativePoint.Center; Children.Add(c); }
        Children.Add(new Border { Background = new LinearGradientBrush { StartPoint = new RelativePoint(0.5, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0.5, 1, RelativeUnit.Relative),
            GradientStops = { new GradientStop(Color.FromArgb(89, 0, 0, 0), 0), new GradientStop(Colors.Transparent, 0.5), new GradientStop(Color.FromArgb(224, 0, 0, 0), 1) } } });
    }
    public void Montrer(string cle, Bitmap? image, bool flou)
    {
        if (cle == this.cle) return;
        this.cle = cle; var ancien = couches[devant]; devant = 1 - devant; var c = couches[devant];
        c.Source = image; c.Effect = flou && image != null ? new BlurEffect { Radius = 70 } : null; c.RenderTransform = flou ? new ScaleTransform(1.3, 1.3) : null;
        c.Opacity = image != null ? 1 : 0; ancien.Opacity = 0;
    }
}

/// Une tuile de jeu : 176 au repos, 250 sélectionnée, contour blanc, ombre portée
sealed class Tuile : Panel
{
    readonly Border ombre = new() { Background = Brushes.Black }, cadre = new() { ClipToBounds = true }, contour = new() { BorderThickness = new Thickness(3) };
    readonly Image image = new() { Stretch = Stretch.UniformToFill }; readonly Panel dedans = new();
    public readonly Jeu? Jeu;
    public Tuile(Jeu? jeu)
    {
        Jeu = jeu; VerticalAlignment = VerticalAlignment.Bottom; Width = Height = 176; Opacity = 0.72;
        if (jeu == null)
        {   // la case + : ajouter un jeu
            ombre.Background = U.Blanc(0.07); contour.BorderBrush = U.Blanc(0.35);
            dedans.Children.Add(U.Colonne(12, U.Icone("plus", 46)) is var c ? c : null!); ((StackPanel)dedans.Children[0]).VerticalAlignment = VerticalAlignment.Center; ((StackPanel)dedans.Children[0]).HorizontalAlignment = HorizontalAlignment.Center;
        }
        else
        {
            var initiales = string.Concat(jeu.Nom.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2).Select(m => char.ToUpper(m[0])));
            dedans.Children.Add(new Border { Background = U.Degrade(Color.FromRgb(56, 56, 56), Color.FromRgb(20, 20, 20), false),
                Child = new TextBlock { Text = initiales, FontSize = 64, FontWeight = FontWeight.Bold, FontFamily = U.Police, Foreground = U.Blanc(0.5), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } });
            dedans.Children.Add(image);
        }
        cadre.Child = dedans; Children.Add(ombre); Children.Add(cadre); Children.Add(contour);
        Coins(14);
        var ressort = new BackEaseOut();
        Transitions = new Transitions
        {
            new DoubleTransition { Property = WidthProperty, Duration = TimeSpan.FromSeconds(0.34), Easing = ressort }, new DoubleTransition { Property = HeightProperty, Duration = TimeSpan.FromSeconds(0.34), Easing = ressort },
            new DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromSeconds(0.25) },
        };
    }
    void Coins(double r) { ombre.CornerRadius = cadre.CornerRadius = contour.CornerRadius = new CornerRadius(r); }
    public void Mettre(Bitmap? couverture, bool selectionnee)
    {
        if (image.Source != couverture) image.Source = couverture;
        Width = Height = selectionnee ? 250 : 176; Opacity = selectionnee ? 1 : 0.72; Coins(selectionnee ? 18 : 14);
        if (Jeu == null) { contour.BorderBrush = U.Blanc(selectionnee ? 0.9 : 0.35); ombre.Background = U.Blanc(selectionnee ? 0.16 : 0.07); }
        else contour.BorderBrush = selectionnee ? U.Blanc(0.95) : Brushes.Transparent;
        ombre.BoxShadow = BoxShadows.Parse(selectionnee ? "0 12 30 0 #99000000" : "0 12 14 0 #99000000");
    }
}

public sealed class Ecran : Panel
{
    readonly Bibliotheque lib;
    readonly FondVue fond = new();
    readonly Grid contenu = new() { RowDefinitions = new RowDefinitions("Auto,*,Auto,Auto,Auto") };
    readonly StackPanel categories = new() { Orientation = Orientation.Horizontal, Spacing = 6 }, droite = new() { Orientation = Orientation.Horizontal, Spacing = 18 };
    readonly StackPanel infos = new() { Spacing = 10, Margin = new Thickness(64, 0, 64, 28) };
    readonly StackPanel rangee = new() { Orientation = Orientation.Horizontal, Spacing = 22 };
    readonly Grid aides = new() { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Thickness(64, 0, 64, 34) };
    readonly Border voile = new() { Background = U.Noir(0.45), IsVisible = false };
    readonly Panel coucheMenu = new(), coucheJeu = new(), coucheSaisie = new(), coucheTache = new(), coucheToast = new();
    readonly DispatcherTimer horloge = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly List<Tuile> tuiles = new();
    string cleTuiles = "?", cleInfos = "?", cleJeu = "?"; Menu? menuMontre; Saisie? saisieMontree; Action<int>? selectionMenu; TextBlock? duree;

    public Ecran(Bibliotheque lib)
    {
        this.lib = lib; ClipToBounds = true;
        var haut = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Thickness(64, 36, 64, 0) };
        haut.Children.Add(categories); Grid.SetColumn(droite, 1); haut.Children.Add(droite);
        var zone = new Canvas { Height = 296 };   // 26 au-dessus, 250 pour la tuile sélectionnée, 20 dessous
        Canvas.SetLeft(rangee, 64); Canvas.SetBottom(rangee, 20); zone.Children.Add(rangee);
        rangee.RenderTransform = TransformOperations.Parse("translateX(0px)");
        rangee.Transitions = new Transitions { new TransformOperationsTransition { Property = RenderTransformProperty, Duration = TimeSpan.FromSeconds(0.3), Easing = new CubicEaseOut() } };
        Grid.SetRow(infos, 2); Grid.SetRow(zone, 3); Grid.SetRow(aides, 4);
        contenu.Children.AddRange([haut, infos, zone, aides]);
        voile.PointerPressed += (_, _) => { if (lib.Saisie == null) lib.FermerMenus(); };
        Children.AddRange([fond, contenu, voile, coucheMenu, coucheTache, coucheJeu, coucheToast, coucheSaisie]);
        lib.Change += Rafraichir;
        horloge.Tick += (_, _) => { Haut(); if (duree != null && lib.EnCours != null) { var s = (int)(DateTime.Now - lib.EnCoursDepuis).TotalSeconds; duree.Text = $"{s / 3600}:{s % 3600 / 60:00}:{s % 60:00}"; } };
        horloge.Start(); Rafraichir();
    }

    void Rafraichir()
    {
        var visibles = lib.Visibles; var j = lib.Selection < visibles.Count ? visibles[lib.Selection] : null; var art = j != null ? lib.Arts.GetValueOrDefault(j.Id) : null;
        fond.Montrer(j == null ? "+" : j.Id + (art?.Fond != null ? "f" : art?.Couverture != null ? "c" : ""), art?.Fond ?? art?.Couverture, art?.Fond == null);
        Haut();
        // Les tuiles : reconstruites quand la liste change, sinon seulement redimensionnées (c'est ce qui les anime)
        var cle = string.Join("|", visibles.Select(v => v.Id));
        if (cle != cleTuiles)
        {
            cleTuiles = cle; rangee.Children.Clear(); tuiles.Clear();
            foreach (var v in visibles.Append(null))
            {
                var t = new Tuile(v); var i = tuiles.Count;
                t.PointerPressed += (_, _) => { if (lib.Menu != null || lib.EnCours != null) return; if (lib.Selection == i) lib.Lancer(); else { lib.Selection = i; lib.Son("deplacer"); lib.Signaler(); } };
                tuiles.Add(t); rangee.Children.Add(t);
            }
        }
        for (var i = 0; i < tuiles.Count; i++) tuiles[i].Mettre(tuiles[i].Jeu is { } tj ? lib.Arts.GetValueOrDefault(tj.Id)?.Couverture : null, i == lib.Selection);
        // Comme scrollTo(anchor: .center) : la tuile choisie au milieu, sans dépasser les bords de la liste
        double centre = 64 + lib.Selection * 198 + 125, largeur = 128 + tuiles.Count * 176 + 74 + (tuiles.Count - 1) * 22;
        rangee.RenderTransform = TransformOperations.Parse($"translateX({-Math.Clamp(centre - 960, 0, Math.Max(0, largeur - 1920)):0}px)");
        Infos(j, art, visibles.Count);
        Aides(j, visibles.Count);
        // Menu : reconstruit quand il change, sinon seule la sélection bouge
        if (lib.Menu != menuMontre)
        {
            menuMontre = lib.Menu; coucheMenu.Children.Clear(); selectionMenu = null;
            if (menuMontre != null) coucheMenu.Children.Add(ConstruireMenu(menuMontre));
        }
        selectionMenu?.Invoke(lib.IndexMenu);
        var voilee = lib.Menu != null || lib.Saisie != null;
        voile.IsVisible = voilee; contenu.Effect = voilee ? new BlurEffect { Radius = 16 } : null;
        Jeu(); TacheEtToast(); MontrerSaisie();
    }

    void Haut()
    {
        if (categories.Children.Count != lib.Categories.Count + 1 || categories.Tag as string != string.Join("|", lib.Categories) + lib.IndexCategorie)
        {
            categories.Tag = string.Join("|", lib.Categories) + lib.IndexCategorie; categories.Children.Clear();
            for (var i = 0; i < lib.Categories.Count; i++)
            {
                var sel = i == lib.IndexCategorie; var n = i;
                var p = new Border { CornerRadius = new CornerRadius(20), Padding = new Thickness(18, 8), Background = sel ? U.Blanc(0.95) : Brushes.Transparent,
                    Child = new TextBlock { Text = lib.Categories[i], FontSize = 20, FontWeight = FontWeight.SemiBold, FontFamily = U.Police, Foreground = sel ? Brushes.Black : U.Blanc(0.6) } };
                p.PointerPressed += (_, _) => { if (lib.Menu != null) return; lib.IndexCategorie = n; lib.Selection = 0; lib.Son("onglet"); lib.Signaler(); };
                categories.Children.Add(p);
            }
            var plus = U.Icone("plus.circle", 23, U.Blanc(0.55)); plus.Margin = new Thickness(10, 0, 0, 0);
            var zonePlus = new Border { Background = Brushes.Transparent, Child = plus }; zonePlus.PointerPressed += (_, _) => { if (lib.Menu == null) lib.OuvrirPlus(); };
            categories.Children.Add(zonePlus);
        }
        droite.Children.Clear();
        droite.Children.Add(U.Texte(DateTime.Now.ToString("HH:mm"), 24, FontWeight.Medium));
        if (lib.Batterie is { } pct) { var b = U.Ligne(5, U.Icone("battery", 16), U.Texte(pct + " %", 14, FontWeight.SemiBold)); b.Opacity = 0.75; droite.Children.Add(b); }
    }

    void Infos(Jeu? j, Art? art, int nombre)
    {
        var cle = (j?.Id ?? "+") + (art?.Logo != null) + lib.Aides.Ok + nombre + (j != null && lib.Stats.TryGetValue(j.Id, out var st) ? st.Minutes + (st.DernierePartie?.Ticks.ToString() ?? "") : "");
        if (cle == cleInfos) return;
        cleInfos = cle; infos.Children.Clear();
        Control Bouton(string touche, string texte, bool plein, Action action)
        {
            var b = new Border { CornerRadius = new CornerRadius(24), Padding = new Thickness(22, 10), Background = plein ? U.Blanc(0.95) : U.Blanc(0.16), BorderBrush = plein ? null : U.Blanc(0.35), BorderThickness = new Thickness(plein ? 0 : 1),
                BoxShadow = plein ? BoxShadows.Parse("0 0 14 0 #55FFFFFF") : default,
                Child = U.Ligne(10, U.Touche(touche, plein ? U.Noir(0.7) : null), new TextBlock { Text = texte, FontSize = 20, FontWeight = FontWeight.SemiBold, FontFamily = U.Police, Foreground = plein ? Brushes.Black : Brushes.White }) };
            b.PointerPressed += (_, _) => { if (lib.Menu == null && lib.EnCours == null) action(); };
            return b;
        }
        if (j == null)
        {
            infos.Children.Add(U.Texte("Ajouter un jeu", 46, FontWeight.Bold));
            var l = U.Ligne(18, U.Etiquette("gamecontroller", "Recomps"), U.Etiquette("pc", "Steam et Epic Games"), U.Etiquette("desktopcomputer", "App Windows")); l.Opacity = 0.85; infos.Children.Add(l);
            if (nombre == 0) infos.Children.Add(U.Texte("Aucun jeu dans cette catégorie pour l'instant", 16, FontWeight.Medium, 0.6));
            var b = U.Ligne(16, Bouton(lib.Aides.Ok, "Ajouter", true, lib.OuvrirAjout)); b.Margin = new Thickness(0, 14, 0, 0); infos.Children.Add(b);
            return;
        }
        if (art?.Logo != null) infos.Children.Add(new Image { Source = art.Logo, MaxWidth = 480, MaxHeight = 140, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left });
        else infos.Children.Add(U.Texte(j.Nom, 46, FontWeight.Bold));
        var ligne = U.Ligne(18); ligne.Opacity = 0.85;
        if (lib.Stats.TryGetValue(j.Id, out var s) && s.DernierePartie is { } d)
        {
            ligne.Children.Add(U.Etiquette("clock", "Dernière partie " + Relatif(d)));
            if (s.Minutes > 0) ligne.Children.Add(U.Etiquette("gamecontroller", s.Minutes >= 60 ? $"{s.Minutes / 60} h {s.Minutes % 60} min de jeu" : $"{s.Minutes} min de jeu"));
        }
        else ligne.Children.Add(U.Etiquette("sparkles", "Jamais joué"));
        ligne.Children.Add(U.Etiquette("tag", j.Categorie));
        if (lib.RecompDe(j) is { } r) ligne.Children.Add(U.Etiquette("hammer", $"{r.Nom} {r.Version}"));
        infos.Children.Add(ligne);
        var boutons = U.Ligne(16, Bouton(lib.Aides.Ok, "Jouer", true, lib.Lancer), Bouton(lib.Aides.Options, "Options", false, lib.OuvrirOptions)); boutons.Margin = new Thickness(0, 14, 0, 0);
        infos.Children.Add(boutons);
    }
    static string Relatif(DateTime d)
    {
        var jours = (DateTime.Today - d.Date).Days;
        return jours == 0 ? "aujourd'hui" : jours == 1 ? "hier" : jours < 7 ? $"il y a {jours} jours" : jours < 60 ? $"il y a {jours / 7} semaine{(jours >= 14 ? "s" : "")}" : $"il y a {jours / 30} mois";
    }
    void Aides(Jeu? j, int nombre)
    {
        aides.Children.Clear();
        var g = U.Ligne(26, U.Aide(lib.Aides.Ok, j == null ? "Ajouter" : "Jouer"));
        if (j != null) g.Children.Add(U.Aide(lib.Aides.Options, "Options"));
        g.Children.Add(U.Aide(lib.Aides.Plus, "Menu")); g.Children.Add(U.Aide(lib.Aides.Cat, "Catégorie"));
        var d = U.Ligne(18);
        if (lib.Aides.Nom is { } nom) { var m = U.Ligne(7, U.Icone("gamecontroller", 16), U.Texte(nom, 15, FontWeight.Medium)); m.Opacity = 0.55; d.Children.Add(m); }
        d.Children.Add(U.Texte(nombre == 1 ? "1 jeu" : $"{nombre} jeux", 16, FontWeight.Medium, 0.6));
        Grid.SetColumn(d, 1); aides.Children.Add(g); aides.Children.Add(d);
    }

    /// Le panneau d'un menu : en-tête (illustration, titre), texte, puis la liste ou la grille. Rend aussi de quoi déplacer la sélection.
    Control ConstruireMenu(Menu m)
    {
        var teinteHero = Icones.Teinte(m.Symbole ?? "");
        Control? hero = null;
        if (m.ImageURL != null) { var img = new Image { Stretch = Stretch.UniformToFill }; U.Distante(img, m.ImageURL, 440); hero = new Border { Width = 124, Height = 124, CornerRadius = new CornerRadius(24), ClipToBounds = true, Background = new SolidColorBrush(teinteHero, 0.4), Child = img }; }
        else if (m.Art != null) hero = new Border { Width = 124, Height = 124, CornerRadius = new CornerRadius(24), ClipToBounds = true, Child = new Image { Source = m.Art, Stretch = Stretch.UniformToFill } };
        else if (m.Symbole != null) hero = new Border { Width = 124, Height = 124, CornerRadius = new CornerRadius(30), Background = U.Degrade(teinteHero, U.Alpha(teinteHero, 0.5)), BoxShadow = BoxShadows.Parse($"0 10 24 0 #73{teinteHero.R:X2}{teinteHero.G:X2}{teinteHero.B:X2}"),
            Child = new Border { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Child = U.Icone(m.Symbole, 56) } };
        var titres = U.Colonne(6); titres.VerticalAlignment = VerticalAlignment.Center;
        var titre = U.Texte(m.Titre, 38, FontWeight.Bold); titre.TextWrapping = TextWrapping.Wrap; titre.MaxLines = 2; titres.Children.Add(titre);
        if (m.SousTitre != null) { var st = U.Texte(m.SousTitre, 18, FontWeight.Medium, 0.65); st.TextWrapping = TextWrapping.Wrap; st.MaxLines = 2; titres.Children.Add(st); }
        var tete = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*") };
        if (hero != null) { hero.Margin = new Thickness(0, 0, 24, 0); tete.Children.Add(hero); }
        Grid.SetColumn(titres, 1); tete.Children.Add(titres);

        var lignes = new List<(Border fond, Control? chevron, ElementMenu e)>();
        Panel liste = m.Grille ? new WrapPanel { Margin = new Thickness(6, 14) } : new StackPanel { Spacing = 6, Margin = new Thickness(0, 6) };
        for (var i = 0; i < m.Elements.Count; i++)
        {
            var e = m.Elements[i]; var n = i; var c = Icones.Teinte(e.Icone, e.Teinte, e.Destructif);
            IBrush couleurTexte = e.Destructif ? new SolidColorBrush(Color.FromRgb(255, 133, 120)) : Brushes.White;
            Border fondLigne; Control? chevron = null;
            if (m.Grille)
            {
                var vignette = new Panel(); vignette.Children.Add(new Border { Background = U.Degrade(U.Alpha(c, 0.85), U.Alpha(c, 0.35)), Child = new Border { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Child = U.Icone(e.Icone, 44) } });
                if (e.Image != null) { var img = new Image { Stretch = Stretch.UniformToFill }; U.Distante(img, e.Image, 440); vignette.Children.Add(img); }
                fondLigne = new Border { Width = 330, Height = 186, CornerRadius = new CornerRadius(18), ClipToBounds = true, Child = vignette, BorderThickness = new Thickness(4) };
                var nom = new TextBlock { Text = e.Libelle, FontSize = 19, FontWeight = FontWeight.SemiBold, FontFamily = U.Police, Foreground = couleurTexte, Width = 330, TextTrimming = TextTrimming.CharacterEllipsis };
                var carte = U.Colonne(8, fondLigne, nom); carte.Margin = new Thickness(0, 0, 24, 26);
                if (e.Detail != null) carte.Children.Add(new TextBlock { Text = e.Detail, FontSize = 14, FontFamily = U.Police, Foreground = U.Blanc(0.62), Width = 330, TextTrimming = TextTrimming.CharacterEllipsis });
                carte.PointerPressed += (_, _) => lib.ChoisirMenu(n);
                liste.Children.Add(carte);
            }
            else
            {
                if (e.Section != null) liste.Children.Add(new TextBlock { Text = e.Section.ToUpper(), FontSize = 13, FontWeight = FontWeight.Heavy, FontFamily = U.Police, Foreground = U.Blanc(0.45), LetterSpacing = 1.3, Margin = new Thickness(16, i == 0 ? 4 : 18, 16, 2) });
                var pastille = new Border { Width = 54, Height = 54, CornerRadius = new CornerRadius(14), Background = e.Info ? U.Blanc(0.08) : U.Degrade(c, U.Alpha(c, 0.62)),
                    Child = new Border { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Child = U.Icone(e.Icone, 24, e.Info ? new SolidColorBrush(c) : Brushes.White) } };
                var textes = U.Colonne(3); textes.VerticalAlignment = VerticalAlignment.Center;
                textes.Children.Add(new TextBlock { Text = e.Libelle, FontSize = e.Info ? 20 : 24, FontWeight = FontWeight.SemiBold, FontFamily = U.Police, Foreground = couleurTexte, TextWrapping = TextWrapping.Wrap, MaxLines = 2 });
                if (e.Detail != null) textes.Children.Add(new TextBlock { Text = e.Detail, FontSize = 16, FontFamily = U.Police, Foreground = U.Blanc(0.65), TextWrapping = TextWrapping.Wrap, MaxLines = 3 });
                chevron = U.Icone("chevron.right", 20, U.Blanc(0.75)); chevron.IsVisible = false;
                var g = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
                textes.Margin = new Thickness(18, 0); Grid.SetColumn(textes, 1); Grid.SetColumn(chevron, 2); g.Children.AddRange([pastille, textes, chevron]);
                fondLigne = new Border { CornerRadius = new CornerRadius(20), Padding = new Thickness(16, 12), BorderThickness = new Thickness(2), Child = g, Background = Brushes.Transparent };
                fondLigne.PointerPressed += (_, _) => lib.ChoisirMenu(n);
                liste.Children.Add(fondLigne);
            }
            lignes.Add((fondLigne, chevron, e));
        }
        var defilement = new ScrollViewer { Content = liste, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Margin = new Thickness(0, 16, 0, 0) };
        selectionMenu = index =>
        {
            for (var i = 0; i < lignes.Count; i++)
            {
                var (f, ch, e) = lignes[i]; var sel = i == index && !e.Info;
                if (m.Grille) f.BorderBrush = U.Blanc(sel ? 0.95 : 0.08);
                else { f.Background = sel ? U.Blanc(0.17) : Brushes.Transparent; f.BorderBrush = sel ? U.Blanc(0.4) : Brushes.Transparent; if (ch != null) ch.IsVisible = sel; }
                if (sel) Dispatcher.UIThread.Post(() => (m.Grille ? f.Parent as Control ?? f : f).BringIntoView(), DispatcherPriority.Background);
            }
        };
        var pied = U.Ligne(22, U.Aide(lib.Aides.Ok, "Choisir"), U.Aide(lib.Aides.Retour, m.Retour == null ? "Fermer" : "Retour")); pied.Margin = new Thickness(0, 18, 0, 0); pied.Opacity = 0.75;
        var corps = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto") };
        corps.Children.Add(tete);
        if (m.Texte != null) { var t = U.Texte(m.Texte, 18, FontWeight.Normal, 0.82); t.TextWrapping = TextWrapping.Wrap; t.Margin = new Thickness(0, 20, 0, 0); Grid.SetRow(t, 1); corps.Children.Add(t); }
        Grid.SetRow(defilement, 2); Grid.SetRow(pied, 3); corps.Children.Add(defilement); corps.Children.Add(pied);
        // Le « matériau » translucide de macOS : ici un panneau sombre presque opaque, posé sur l'écran flouté
        return new Border
        {
            Width = m.Grille ? 1160 : 860, MaxHeight = 940, Padding = new Thickness(36), CornerRadius = new CornerRadius(36), Background = new SolidColorBrush(Color.FromArgb(236, 28, 28, 32)),
            BorderBrush = U.Blanc(0.12), BorderThickness = new Thickness(1), BoxShadow = BoxShadows.Parse("0 24 50 0 #8C000000"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Child = corps,
        };
    }

    /// Home pendant une partie : le fond du jeu très assombri, sa jaquette au centre, le nom, la durée
    void Jeu()
    {
        var cle = lib.EnCours?.Id ?? "";
        if (cle == cleJeu) return;
        cleJeu = cle; coucheJeu.Children.Clear(); duree = null;
        if (lib.EnCours is not { } j) return;
        var art = lib.Arts.GetValueOrDefault(j.Id);
        coucheJeu.Children.Add(new Border { Background = Brushes.Black });
        if ((art?.Fond ?? art?.Couverture) is { } bg) coucheJeu.Children.Add(new Image { Source = bg, Stretch = Stretch.UniformToFill, Opacity = 0.22, Effect = new BlurEffect { Radius = 40 } });
        var jaquette = new Border { Width = 300, Height = 300, CornerRadius = new CornerRadius(26), ClipToBounds = true, Background = U.Degrade(Color.FromRgb(56, 56, 56), Color.FromRgb(20, 20, 20), false),
            Child = art?.Couverture != null ? new Image { Source = art.Couverture, Stretch = Stretch.UniformToFill } : null, HorizontalAlignment = HorizontalAlignment.Center };
        Control nom = art?.Logo != null ? new Image { Source = art.Logo, MaxWidth = 420, MaxHeight = 120, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center } : U.Texte(j.Nom, 40, FontWeight.Bold);
        nom.HorizontalAlignment = HorizontalAlignment.Center;
        duree = U.Texte("0:00:00", 17, FontWeight.Medium, 0.75);
        var etat = U.Ligne(12, new Avalonia.Controls.Shapes.Ellipse { Width = 9, Height = 9, Fill = new SolidColorBrush(Icones.Vert), VerticalAlignment = VerticalAlignment.Center }, U.Texte("En cours de jeu", 17, FontWeight.SemiBold), U.Texte("·", 17, FontWeight.Normal, 0.4), duree);
        etat.HorizontalAlignment = HorizontalAlignment.Center;
        var centre = U.Colonne(26, jaquette, nom, etat); centre.VerticalAlignment = VerticalAlignment.Center;
        coucheJeu.Children.Add(centre);
        var bas = U.Texte("Home revient tout seul quand tu quittes le jeu", 16, FontWeight.Medium, 0.55); bas.HorizontalAlignment = HorizontalAlignment.Center; bas.VerticalAlignment = VerticalAlignment.Bottom; bas.Margin = new Thickness(0, 0, 0, 44);
        coucheJeu.Children.Add(bas);
    }

    void TacheEtToast()
    {
        coucheTache.Children.Clear(); coucheToast.Children.Clear();
        if (lib.Tache is { } t)
        {
            IBrush couleur = t.Erreur != null ? new SolidColorBrush(Icones.Orange) : t.Fini ? new SolidColorBrush(Icones.Vert) : Brushes.White;
            var etape = U.Texte(t.Etape, 15, FontWeight.Normal, 0.75); etape.TextWrapping = TextWrapping.Wrap;
            var barre = new Panel { Height = 6 };
            barre.Children.Add(new Border { Background = U.Blanc(0.22), CornerRadius = new CornerRadius(3) });
            barre.Children.Add(new Border { Background = couleur, CornerRadius = new CornerRadius(3), HorizontalAlignment = HorizontalAlignment.Left, Width = Math.Max(6, 380 * (t.Fraction ?? 0.05)) });
            coucheTache.Children.Add(new Border
            {
                Width = 420, Padding = new Thickness(20), CornerRadius = new CornerRadius(22), Background = new SolidColorBrush(Color.FromArgb(224, 28, 28, 32)), BorderBrush = U.Blanc(0.12), BorderThickness = new Thickness(1),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 64, 92), BoxShadow = BoxShadows.Parse("0 14 30 0 #80000000"),
                Child = U.Colonne(10, U.Texte(t.Titre, 18, FontWeight.SemiBold), barre, etape),
            });
        }
        if (lib.Toast is { } toast)
            coucheToast.Children.Add(new Border
            {
                Padding = new Thickness(20, 12), CornerRadius = new CornerRadius(24), Background = new SolidColorBrush(Color.FromArgb(224, 40, 40, 46)), HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 130), Child = U.Texte(toast, 18, FontWeight.Medium),
            });
    }

    /// Une question au clavier (recherche, clé, nouveau nom) : Entrée valide, Échap annule
    void MontrerSaisie()
    {
        if (lib.Saisie == saisieMontree) return;
        saisieMontree = lib.Saisie; coucheSaisie.Children.Clear();
        if (saisieMontree is not { } s) return;
        var champ = new TextBox { FontSize = 24, FontFamily = U.Police, Padding = new Thickness(16, 12), CornerRadius = new CornerRadius(14), Watermark = s.Aide };
        champ.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; lib.ValiderSaisie(champ.Text ?? ""); } };
        coucheSaisie.Children.Add(new Border
        {
            Width = 760, Padding = new Thickness(32), CornerRadius = new CornerRadius(30), Background = new SolidColorBrush(Color.FromArgb(240, 28, 28, 32)), BorderBrush = U.Blanc(0.12), BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, BoxShadow = BoxShadows.Parse("0 24 50 0 #8C000000"),
            Child = U.Colonne(18, U.Texte(s.Titre, 28, FontWeight.Bold), champ, U.Ligne(22, U.Aide("⏎", "Valider"), U.Aide("Échap", "Annuler"))),
        });
        Dispatcher.UIThread.Post(() => champ.Focus(), DispatcherPriority.Background);
    }
}
