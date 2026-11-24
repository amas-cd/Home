// Home pour Windows — les menus, recopiés de `MenuView` (app/main.swift). Monochromes, presque sans texte, trois formes :
//  - un menu court (7 choix au plus, tous actionnables) est une RANGÉE de pastilles rondes en bas à gauche, à la manière de la PS5 :
//    seul le choix visé a son nom et sa précision. Gauche / droite pour choisir ;
//  - un menu long est une ROUE à gauche : le choix visé en grand, les autres de plus en plus petits et effacés autour. À droite, le
//    choix visé en image : son symbole dans un disque de sa couleur (ou sa jaquette), entouré de deux anneaux ;
//  - le catalogue des recomps est une GRILLE d'affiches, cinq par rang.
using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Ellipse = Avalonia.Controls.Shapes.Ellipse;

namespace Home;

sealed class VueMenu : Panel
{
    static readonly IBrush Rouge = new SolidColorBrush(Color.FromRgb(255, 115, 107));
    public readonly Menu Menu;
    readonly Bibliotheque lib; readonly bool arrivee; readonly double sens;
    Action<int, bool> viser = (_, _) => { }; int vise = -1;

    /// `arrivee` : le menu joue son entrée (pas quand c'est le même qu'on relit). `fonduDuFond` : on vient de la bibliothèque, le fond
    /// sombre arrive en fondu ; d'un menu à l'autre il est là tout de suite. `sens` : 1 = on avance (il arrive par la droite), −1 = on revient.
    public VueMenu(Bibliotheque lib, Menu m, bool arrivee, bool fonduDuFond, double sens)
    {
        this.lib = lib; Menu = m; this.arrivee = arrivee; this.sens = sens;
        Background = Brushes.Transparent; Transitions = new Transitions { Mouvement.Opacite(0.22, new CubicEaseInOut()) };
        PointerPressed += (_, e) => { if (!e.Handled && lib.Saisie == null) { e.Handled = true; lib.FermerMenus(); } };   // un clic à côté ferme tout
        var fond = new Border { Background = U.Noir(m.Genre == GenreMenu.Rangee ? 0 : 0.55), IsHitTestVisible = false, Opacity = fonduDuFond ? 0 : 1, Transitions = new Transitions { Mouvement.Opacite(0.25) } };
        Children.Add(fond); if (fonduDuFond) Paraitre(() => fond.Opacity = 1);
        switch (m.Genre) { case GenreMenu.Rangee: Rangee(); break; case GenreMenu.Grille: Grille(); break; default: Roue(); break; }
    }
    void Paraitre(Action a) => AttachedToVisualTree += (_, _) => Mouvement.Dans(0.03, a);
    public void Viser(int i) { if (i == vise) return; var anime = vise >= 0; vise = i; viser(i, anime); }

    Color Teinte(ElementMenu e) => Icones.Teinte(e.Icone, e.Teinte, e.Destructif);
    Control Aides() => U.Ligne(12, U.Pilule(lib.Aides.Ok, "Choisir"), U.Pilule(lib.Aides.Retour, Menu.Retour == null ? "Fermer" : "Retour"));
    /// Le nom d'un choix sans son état : « Sons de l'interface : activés » → (« Sons de l'interface », « Activés »)
    static (string nom, string? etat) NomEtat(ElementMenu e)
    {
        var k = e.Libelle.IndexOf(" : ", StringComparison.Ordinal);
        return k < 0 ? (e.Libelle, null) : (e.Libelle[..k], char.ToUpper(e.Libelle[k + 3]) + e.Libelle[(k + 4)..]);
    }
    /// Le titre de section du choix : celui de la dernière ligne qui en porte un, en remontant
    string? Section(int i) { for (var n = Math.Min(i, Menu.Elements.Count - 1); n >= 0; n--) if (Menu.Elements[n].Section is { Length: > 0 } s) return s; return null; }
    /// Le fil d'Ariane : le nom du menu en capitales grasses, puis ce qu'on donne en plus (la section du choix visé)
    Control Fil(out TextBlock suite)
    {
        suite = U.Titre("", 19, 1.5, 0.55); suite.Margin = new Thickness(8, 12, 0, 0); suite.MaxWidth = 760;
        return U.Ligne(12, U.Titre(Menu.Titre, 38, 1, place: 900), suite);
    }

    // MARK: La rangée de pastilles
    void Rangee()
    {
        var m = Menu; var n = m.Elements.Count; const double Grand = 96, Petit = 76, Espace = 14;
        Children.Add(new Border { IsHitTestVisible = false, Background = U.Degrade(0.5, 0.25, 0.5, 1, (Colors.Transparent, 0), (U.NoirA(0.55), 0.5), (U.NoirA(0.88), 1)) });   // l'ombre qui porte le texte
        var colonne = new StackPanel { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(96, 0, 96, 44) };
        if (m.Logo != null) colonne.Children.Add(new Image { Source = m.Logo, MaxWidth = 480, MaxHeight = 150, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left });
        else
        {
            if (m.SousTitre != null) colonne.Children.Add(new TextBlock { Text = m.SousTitre.ToUpper(), FontSize = 15, FontWeight = FontWeight.ExtraBold, FontFamily = U.Police, LetterSpacing = 2, Foreground = Brushes.White, Opacity = 0.6 });
            var titre = U.Titre(m.Titre, 44, 1, place: 1500); titre.Margin = new Thickness(0, 4, 0, 0); titre.HorizontalAlignment = HorizontalAlignment.Left; colonne.Children.Add(titre);
        }
        // sur Windows, quelques menus courts expliquent ce qu'ils vont faire (désinstaller, construire un recomp) : le texte tient au-dessus des pastilles
        if (m.Texte != null) { var t = U.Texte(m.Texte, 18, FontWeight.Normal, 0.82); t.TextWrapping = TextWrapping.Wrap; t.MaxWidth = 940; t.HorizontalAlignment = HorizontalAlignment.Left; t.Margin = new Thickness(0, 18, 0, 0); colonne.Children.Add(t); }
        var piste = new Canvas { Height = Grand, Width = Grand + (n - 1) * (Petit + Espace), Margin = new Thickness(0, 34, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
        var places = new Panel[n]; var disques = new Panel[n]; var pleins = new Border[n]; var creux = new Border[n];
        for (var i = 0; i < n; i++)
        {
            var e = m.Elements[i]; var k = i; var c = Teinte(e); var teinte = new SolidColorBrush(c);
            // deux états superposés, l'un s'efface quand l'autre vient : au repos, un disque sombre cerclé de la couleur du choix ; visé, plein, cerclé de blanc, avec son halo
            creux[i] = new Border { CornerRadius = new CornerRadius(Grand / 2), Background = U.Noir(0.5), BorderBrush = new SolidColorBrush(c, 0.45), BorderThickness = new Thickness(1.9), Child = U.Icone(e.Icone, 32, teinte), Transitions = new Transitions { Mouvement.Opacite(0.24, Mouvement.Glisse) } };
            pleins[i] = new Border { CornerRadius = new CornerRadius(Grand / 2), Background = U.Degrade(c, U.Alpha(c, 0.62)), BorderBrush = U.Blanc(0.9), BorderThickness = new Thickness(3), Child = U.Icone(e.Icone, 32), Opacity = 0,
                BoxShadow = BoxShadows.Parse($"0 6 26 0 #BF{c.R:X2}{c.G:X2}{c.B:X2}"), Transitions = new Transitions { Mouvement.Opacite(0.24, Mouvement.Glisse) } };
            disques[i] = new Panel { Width = Grand, Height = Grand, RenderTransformOrigin = U.Centre, RenderTransform = Mouvement.Echelle(Petit / Grand), Transitions = new Transitions { Mouvement.Transfo(0.24, Mouvement.Glisse) }, Children = { creux[i], pleins[i] } };
            places[i] = new Panel { RenderTransform = Mouvement.Deplace(0, 0), Transitions = new Transitions { Mouvement.Transfo(0.24, Mouvement.Glisse) }, Children = { disques[i] } };
            // l'arrivée en cascade : chaque pastille monte de 26 en apparaissant, la suivante 0,045 s après la précédente
            var monte = new Panel { Background = Brushes.Transparent, Children = { places[i] } };
            if (arrivee)
            {
                monte.Opacity = 0; monte.RenderTransform = Mouvement.Deplace(0, 26);
                monte.Transitions = new Transitions { Mouvement.Transfo(0.38, Mouvement.Glisse, k * 0.045), Mouvement.Opacite(0.38, Mouvement.Glisse, k * 0.045) };
                Paraitre(() => { monte.Opacity = 1; monte.RenderTransform = Mouvement.Deplace(0, 0); });
            }
            disques[i].PointerPressed += (_, ev) => { ev.Handled = true; lib.ChoisirMenu(k); };
            disques[i].PointerEntered += (_, _) => lib.ViserMenu(k);
            piste.Children.Add(monte);
        }
        var nom = new Echange { Height = 92, Margin = new Thickness(6, 20, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
        colonne.Children.Add(piste); colonne.Children.Add(nom);
        var aides = Aides(); aides.Margin = new Thickness(0, 14, 0, 0); colonne.Children.Add(aides);
        Children.Add(colonne);
        viser = (v, anime) =>
        {
            double x = 0;
            for (var i = 0; i < n; i++)
            {
                var ici = i == v;
                places[i].RenderTransform = Mouvement.Deplace(ici ? x : x - (Grand - Petit) / 2, 0); disques[i].RenderTransform = Mouvement.Echelle(ici ? 1 : Petit / Grand);
                pleins[i].Opacity = ici ? 1 : 0; creux[i].Opacity = ici ? 0 : 1; disques[i].ZIndex = ici ? 1 : 0;
                x += (ici ? Grand : Petit) + Espace;
            }
            if (v < 0 || v >= n) return;
            // le nom du choix visé, et sa précision : la seule ligne de texte du menu
            var e = m.Elements[v];
            var detail = U.Texte(e.Detail ?? " ", 17, FontWeight.Normal, 0.62); detail.TextWrapping = TextWrapping.Wrap; detail.MaxLines = 2; detail.MaxWidth = 900; detail.HorizontalAlignment = HorizontalAlignment.Left;
            var bloc = U.Colonne(5, U.Ligne(10, new Ellipse { Width = 10, Height = 10, Fill = new SolidColorBrush(Teinte(e)), VerticalAlignment = VerticalAlignment.Center }, U.Texte(e.Libelle, 27, FontWeight.SemiBold)), detail);
            bloc.VerticalAlignment = VerticalAlignment.Top;
            nom.Montrer(bloc, anime ? 0.22 : 0);
        };
    }

    // MARK: La roue
    void Roue()
    {
        var m = Menu; var e = m.Elements; var n = e.Count;
        Children.Add(new Border { IsHitTestVisible = false, Background = U.Degrade(0, 0.5, 1, 0.5, (U.NoirA(0.92), 0), (U.NoirA(0.74), 0.5), (U.NoirA(0.50), 1)) });
        // une lueur de la couleur du choix visé, derrière son symbole : le menu change de teinte en bougeant
        var lueurs = new Panel[2]; var devant = 0; Color? couleurLueur = null;
        for (var i = 0; i < 2; i++) { lueurs[i] = new Panel { Opacity = 0, IsHitTestVisible = false, Width = 1400, Height = 1400, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, -250, 0), Transitions = new Transitions { Mouvement.Opacite(0.45, new CubicEaseInOut()) } }; Children.Add(lueurs[i]); }
        var fil = Fil(out var suite); fil.HorizontalAlignment = HorizontalAlignment.Left; fil.VerticalAlignment = VerticalAlignment.Top; fil.Margin = new Thickness(96, 70, 0, 0); Children.Add(fil);
        Children.Add(new TextBlock { Text = DateTime.Now.ToString("HH:mm"), FontSize = 24, FontWeight = FontWeight.SemiBold, FontFamily = U.Police, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 66, 96, 0) });
        // un trait fin sous le haut de l'écran, qui s'efface vers la droite
        Children.Add(new Border { Height = 1.5, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(96, 148, 96, 0), IsHitTestVisible = false, Background = U.Degrade(0, 0.5, 1, 0.5, (U.Alpha(Colors.White, 0.35), 0), (U.Alpha(Colors.White, 0.06), 1)) });

        // le repère (où on en est dans le menu), puis la roue
        var hauteur = Math.Max(26, 300.0 / Math.Max(1, n));
        var pouce = new Border { Width = 4, Height = hauteur, CornerRadius = new CornerRadius(2), Background = Brushes.White, VerticalAlignment = VerticalAlignment.Top, RenderTransform = Mouvement.Deplace(0, 0), Transitions = new Transitions { Mouvement.Transfo(0.22, Mouvement.Douce) } };
        var repere = new Panel { Width = 4, Height = 300, VerticalAlignment = VerticalAlignment.Center, Children = { new Border { Background = U.Blanc(0.14), CornerRadius = new CornerRadius(2) }, pouce } };
        var roue = new Panel { Width = 1040, Height = 300 };
        var lignes = new Panel[n]; var contenus = new StackPanel[n]; var etats = new Control?[n];
        for (var i = 0; i < n; i++)
        {
            var it = e[i]; var k = i; var (nom, etat) = NomEtat(it);
            var taille = nom.Length <= 22 ? 50 : Math.Max(30, 50.0 * 22 / nom.Length);   // un nom long rétrécit pour tenir à gauche du disque
            var texte = new TextBlock { Text = nom, FontSize = taille, FontWeight = FontWeight.Bold, FontFamily = U.PoliceLargeGras, LetterSpacing = -0.5, Foreground = it.Destructif ? Rouge : Brushes.White, MaxWidth = 1000, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            contenus[i] = U.Ligne(16, texte);
            if (it.Icone.StartsWith("checkmark.seal")) contenus[i].Children.Add(new Border { Width = 46, Height = 46, CornerRadius = new CornerRadius(23), Background = new SolidColorBrush(Color.FromRgb(33, 184, 92)), Child = U.Icone("checkmark", 24), VerticalAlignment = VerticalAlignment.Center });
            if (etat != null)
            {   // l'état d'un réglage, dans une capsule : seulement sur le choix visé
                etats[i] = new Border { CornerRadius = new CornerRadius(20), Background = U.Blanc(0.18), Padding = new Thickness(14, 6), VerticalAlignment = VerticalAlignment.Center, Opacity = 0, Child = U.Texte(etat, 22, FontWeight.ExtraBold), Transitions = new Transitions { Mouvement.Opacite(0.22, Mouvement.Douce) } };
                contenus[i].Children.Add(etats[i]!);
            }
            contenus[i].RenderTransformOrigin = U.Gauche; contenus[i].RenderTransform = Mouvement.Echelle(0.46); contenus[i].Transitions = new Transitions { Mouvement.Transfo(0.22, Mouvement.Douce) };
            lignes[i] = new Panel { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Background = Brushes.Transparent, Opacity = 0, RenderTransform = Mouvement.Deplace(0, 0), Children = { contenus[i] },
                Transitions = new Transitions { Mouvement.Transfo(0.22, Mouvement.Douce), Mouvement.Opacite(0.22, Mouvement.Douce) } };
            lignes[i].PointerPressed += (_, ev) => { ev.Handled = true; if (k == vise) lib.ChoisirMenu(k); else lib.ViserMenu(k, son: true); };
            roue.Children.Add(lignes[i]);
        }
        var gauche = U.Ligne(18, repere, roue); gauche.HorizontalAlignment = HorizontalAlignment.Left; gauche.VerticalAlignment = VerticalAlignment.Center; gauche.Margin = new Thickness(60, 0, 0, 0);
        if (arrivee)
        {   // la roue glisse de 46, depuis la droite quand on avance, depuis la gauche quand on revient
            gauche.Opacity = 0; gauche.RenderTransform = Mouvement.Deplace(46 * sens, 0);
            gauche.Transitions = new Transitions { Mouvement.Transfo(0.36, Mouvement.Glisse), Mouvement.Opacite(0.36, Mouvement.Glisse) };
            Paraitre(() => { gauche.Opacity = 1; gauche.RenderTransform = Mouvement.Deplace(0, 0); });
        }
        if (n == 0) repere.IsVisible = false;
        Children.Add(gauche);

        // à droite : deux anneaux autour du symbole, comme une cible, et un arc qui dit où on en est
        var arc = new Anneau { Width = 440, Height = 440, Epaisseur = 3, Couleur = U.Blanc(0.55), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Transitions = new Transitions { new DoubleTransition { Property = Anneau.FractionProperty, Duration = Mouvement.S(0.3), Easing = Mouvement.Douce } } };
        Children.Add(new Panel
        {
            Width = 600, Height = 600, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 150, 0), RenderTransform = new TranslateTransform(0, -65), IsHitTestVisible = false,
            Children =
            {
                new Ellipse { Width = 440, Height = 440, Stroke = U.Blanc(0.10), StrokeThickness = 1.5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
                new Ellipse { Width = 580, Height = 580, Stroke = U.Blanc(0.05), StrokeThickness = 1.5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }, arc,
            },
        });
        var apercu = new Echange { Width = 600, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 150, 0), IsHitTestVisible = false };
        Children.Add(apercu);
        var aides = Aides(); aides.HorizontalAlignment = HorizontalAlignment.Left; aides.VerticalAlignment = VerticalAlignment.Bottom; aides.Margin = new Thickness(96, 0, 0, 44); Children.Add(aides);

        // Le choix visé en image : sa jaquette s'il en a une, sinon son symbole en très grand dans un disque de sa couleur ; dessous, sa précision
        Control Apercu(int v, Color c)
        {
            var it = v >= 0 && v < n ? e[v] : null; var icone = it?.Icone ?? m.Symbole ?? "ellipsis";
            var disque = new Border { Width = 320, Height = 320, CornerRadius = new CornerRadius(160), Background = U.Degrade(c, U.Alpha(c, 0.55)), BoxShadow = BoxShadows.Parse($"0 10 60 0 #99{c.R:X2}{c.G:X2}{c.B:X2}"), Child = U.Icone(icone, 150),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            var visuel = new Panel { Width = 600, Height = 500, VerticalAlignment = VerticalAlignment.Center, RenderTransform = new TranslateTransform(0, -65), Children = { disque } };
            if ((it?.Image ?? m.ImageURL) is { } url)
            {   // le disque attend l'image, puis lui laisse la place
                var img = new Image { Stretch = Stretch.Uniform };
                var cadre = new Border { MaxWidth = 600, MaxHeight = 500, CornerRadius = new CornerRadius(30), ClipToBounds = true, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Child = img, Opacity = 0,
                    BoxShadow = BoxShadows.Parse("0 18 34 0 #99000000"), Transitions = new Transitions { Mouvement.Opacite(0.35) } };
                disque.Transitions = new Transitions { Mouvement.Opacite(0.35) };
                visuel.Children.Add(cadre); U.Distante(img, url, 900, () => { cadre.Opacity = 1; disque.Opacity = 0; });
            }
            // le texte passe sous les anneaux, pas dessus : 241 sous le milieu de l'écran, quelle que soit sa hauteur
            var textes = new StackPanel { Height = 250, Spacing = 10 };
            if (it?.Detail is { } d) { var t = U.Texte(d, 23, FontWeight.Medium, 0.8); t.TextWrapping = TextWrapping.Wrap; t.TextAlignment = TextAlignment.Center; t.MaxLines = 3; textes.Children.Add(t); }
            if (m.Texte is { } long_) { var t = U.Texte(long_, it?.Detail == null ? 20 : 16, FontWeight.Normal, it?.Detail == null ? 0.8 : 0.6); t.TextWrapping = TextWrapping.Wrap; t.TextAlignment = TextAlignment.Center; t.MaxLines = it?.Detail == null ? 9 : 7; t.TextTrimming = TextTrimming.CharacterEllipsis; textes.Children.Add(t); }
            return new Panel { Children = { visuel, new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { new Border { Height = 732 }, textes } } } };
        }

        viser = (v, anime) =>
        {
            for (var i = 0; i < n; i++)
            {
                int d = i - v, ecart = Math.Abs(d);
                lignes[i].RenderTransform = Mouvement.Deplace(0, d == 0 ? 0 : Math.Sign(d) * (74 + (Math.Min(ecart, 7) - 1) * 50));
                contenus[i].RenderTransform = Mouvement.Echelle(d == 0 ? 1 : ecart == 1 ? 0.56 : 0.46);
                lignes[i].Opacity = ecart > 6 ? 0 : d == 0 ? 1 : e[i].Info ? 0.22 : ecart switch { 1 => 0.62, 2 => 0.40, 3 => 0.24, _ => 0.12 };
                lignes[i].IsHitTestVisible = ecart <= 6 && !e[i].Info; lignes[i].ZIndex = d == 0 ? 1 : 0;
                if (etats[i] != null) etats[i]!.Opacity = d == 0 ? 1 : 0;
            }
            pouce.RenderTransform = Mouvement.Deplace(0, (300 - hauteur) * Math.Clamp(v, 0, Math.Max(0, n - 1)) / Math.Max(1, n - 1));
            arc.Fraction = n == 0 ? 0 : (v + 1.0) / n;
            suite.Text = (Section(v) ?? m.SousTitre ?? "").ToUpper();
            var c = v >= 0 && v < n ? Teinte(e[v]) : Icones.Teinte(m.Symbole ?? "ellipsis");
            if (c != couleurLueur)
            {
                couleurLueur = c; lueurs[devant].Opacity = 0; devant = 1 - devant;
                lueurs[devant].Children.Clear(); lueurs[devant].Children.Add(U.Lueur(c, 1400, 0.42)); lueurs[devant].Opacity = 1;
            }
            apercu.Montrer(Apercu(v, c), anime ? 0.18 : 0, echelle: 0.94);
        };
    }

    // MARK: La grille d'affiches
    void Grille()
    {
        var m = Menu; var n = m.Elements.Count; const double Largeur = 349, Hauteur = 205;   // cinq affiches 16:9 sur 1728, 20 entre elles
        Children.Add(new Border { Background = U.Noir(0.32), IsHitTestVisible = false });   // avec le fond du menu : tout l'écran assombri
        var grille = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto"), Margin = new Thickness(96, 70, 96, 44) };
        var fil = Fil(out var suite); grille.Children.Add(fil);
        var cases = new WrapPanel { Margin = new Thickness(-10, 12, -10, 12), Width = Largeur * Bibliotheque.ColonnesGrille };
        var affiches = new Panel[n]; var sombres = new Border[n]; var bords = new Border[n];
        for (var i = 0; i < n; i++)
        {
            var e = m.Elements[i]; var k = i; var dedans = new Panel { Background = U.Blanc(0.07) };
            if (e.Image != null)
            {
                var img = new Image { Stretch = Stretch.UniformToFill, Opacity = 0, Transitions = new Transitions { Mouvement.Opacite(0.35) } }; U.Distante(img, e.Image, 440, () => img.Opacity = 1);   // une image n'apparaît qu'une fois chargée
                dedans.Children.Add(img); dedans.Children.Add(new Border { Background = U.Degrade(0.5, 0.5, 0.5, 1, (Colors.Transparent, 0), (U.NoirA(0.88), 1)) });
            }
            else dedans.Children.Add(new Panel { Opacity = 0.85, RenderTransform = new TranslateTransform(0, -12), Children = { U.Icone(e.Icone, 48) } });
            dedans.Children.Add(new TextBlock { Text = e.Libelle, FontSize = 17, FontWeight = FontWeight.Bold, FontFamily = U.Police, Foreground = e.Destructif ? Rouge : Brushes.White, TextWrapping = TextWrapping.Wrap, MaxLines = 2, Margin = new Thickness(14), VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left });
            sombres[i] = new Border { Background = Brushes.Black, Opacity = 0.10, IsHitTestVisible = false, Transitions = new Transitions { Mouvement.Opacite(0.14) } }; dedans.Children.Add(sombres[i]);
            bords[i] = new Border { CornerRadius = new CornerRadius(24), BorderBrush = Brushes.White, BorderThickness = new Thickness(4), Opacity = 0, IsHitTestVisible = false, BoxShadow = BoxShadows.Parse("0 10 20 0 #99000000"), Transitions = new Transitions { Mouvement.Opacite(0.14) } };
            affiches[i] = new Panel { Margin = new Thickness(10), Width = Largeur - 20, Height = Hauteur - 20, RenderTransformOrigin = U.Centre, RenderTransform = Mouvement.Echelle(1), Transitions = new Transitions { Mouvement.Transfo(0.14) },
                Children = { bords[i], new Border { CornerRadius = new CornerRadius(24), ClipToBounds = true, BorderBrush = U.Blanc(0.08), BorderThickness = new Thickness(1), Child = dedans }, } };
            affiches[i].PointerPressed += (_, ev) => { ev.Handled = true; lib.ChoisirMenu(k); };
            cases.Children.Add(affiches[i]);
        }
        var defilement = new ScrollViewer { Content = cases, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Margin = new Thickness(-10, 10, -10, 0) };
        Grid.SetRow(defilement, 1); grille.Children.Add(defilement);
        var aides = Aides(); aides.Margin = new Thickness(0, 14, 0, 0); aides.HorizontalAlignment = HorizontalAlignment.Left; Grid.SetRow(aides, 2); grille.Children.Add(aides);
        Children.Add(grille);
        viser = (v, _) =>
        {
            for (var i = 0; i < n; i++)
            {
                var ici = i == v;
                affiches[i].RenderTransform = Mouvement.Echelle(ici ? 1.04 : 1); affiches[i].ZIndex = ici ? 1 : 0; sombres[i].Opacity = ici ? 0 : 0.10; bords[i].Opacity = ici ? 1 : 0;
            }
            if (v < 0 || v >= n) return;
            suite.Text = string.Join("  ·  ", new[] { m.SousTitre, m.Elements[v].Detail }.Where(s => !string.IsNullOrEmpty(s))).ToUpper();
            var a = affiches[v]; Dispatcher.UIThread.Post(() => a.BringIntoView(), DispatcherPriority.Background);
        };
    }
}
