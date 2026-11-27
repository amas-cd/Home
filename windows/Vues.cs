// Home pour Windows — les vues de la bibliothèque, recopiées de app/main.swift : `Background`, `Tile`, `RangeeJeux`, `Screen`,
// `OuvertureView`, `TacheView`, `NowPlayingView`. Les menus sont dans VuesMenus.cs. Tout est dessiné pour 1920 de large, puis mis à
// l'échelle par la fenêtre. Les mouvements suivent ANIMATIONS.md, valeur pour valeur.
//
// Deux règles tiennent tout le fichier :
//  - une vue reste en place et on change ses propriétés (c'est ce qui l'anime) ; on ne la reconstruit que si son contenu change ;
//  - on n'anime jamais une taille : la taille de dessin est fixe, on anime RenderTransform (déplacement, échelle) et l'opacité ;
//  - aucun flou ni ombre calculés en direct (BlurEffect, DropShadowEffect) : Avalonia les recalcule à chaque image dès que quelque
//    chose bouge dessous, et tout saccade. Un flou est une image minuscule étirée (`U.Flou`), ou une photo réduite de l'écran.
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
using Avalonia.Styling;
using Avalonia.Threading;
using Ellipse = Avalonia.Controls.Shapes.Ellipse;
using FluentIcons.Common;
using Rectangle = Avalonia.Controls.Shapes.Rectangle;

namespace Home;

/// Les mouvements de Home : les mêmes courbes et les mêmes durées que sur Mac (`glisse`, `coule` dans app/main.swift)
static class Mouvement
{
    /// « Animations réduites » : tout devient un fondu très court
    public static bool Reduit;
    static Easing Courbe(double a, double b, double c, double d) => Reduit ? new CubicEaseOut() : new SplineEasing(a, b, c, d);
    public static Easing Glisse => Courbe(0.2, 0.75, 0.2, 1);   // 0,24 s : un choix qui change (pastilles, onglets)
    public static Easing Coule => Courbe(0.32, 0.0, 0.16, 1);   // 0,42 s : la bibliothèque (tuiles, rangées)
    public static Easing Douce => Courbe(0.2, 0.8, 0.2, 1);     // la roue des menus, l'écran de démarrage
    public static TimeSpan S(double s) => TimeSpan.FromSeconds(Reduit ? Math.Min(s, 0.12) : s);
    static TimeSpan Delai(double s) => TimeSpan.FromSeconds(Reduit ? 0 : s);

    public static DoubleTransition Opacite(double s, Easing? e = null, double delai = 0) => new() { Property = Visual.OpacityProperty, Duration = S(s), Easing = e ?? new CubicEaseOut(), Delay = Delai(delai) };
    public static TransformOperationsTransition Transfo(double s, Easing? e = null, double delai = 0) => new() { Property = Visual.RenderTransformProperty, Duration = S(s), Easing = e ?? new CubicEaseOut(), Delay = Delai(delai) };
    public static EffectTransition Flou(double s, Easing? e = null) => new() { Property = Visual.EffectProperty, Duration = S(s), Easing = e ?? new CubicEaseInOut() };

    // Les transformations sont toujours des TransformOperations : c'est le seul type que TransformOperationsTransition sait animer
    public static TransformOperations Deplace(double x, double y) { var b = TransformOperations.CreateBuilder(1); b.AppendTranslate(x, y); return b.Build(); }
    public static TransformOperations Echelle(double x, double? y = null) { var b = TransformOperations.CreateBuilder(1); b.AppendScale(x, y ?? x); return b.Build(); }
    public static TransformOperations Tourne(double degres) { var b = TransformOperations.CreateBuilder(1); b.AppendRotate(degres * Math.PI / 180); return b.Build(); }

    /// Change une valeur sans l'animer (une vue qui prend sa place de départ)
    public static void SansAnimer(Animatable c, Action a) { var t = c.Transitions; c.Transitions = null; a(); c.Transitions = t; }
    /// Après le prochain dessin : une vue qu'on vient de poser doit avoir été vue dans son état de départ pour s'animer vers l'arrivée
    public static void Apres(Action a) => Dispatcher.UIThread.Post(a, DispatcherPriority.Background);
    public static void Dans(double s, Action a) => DispatcherTimer.RunOnce(a, TimeSpan.FromSeconds(Math.Max(0.01, s)));

    /// Un mouvement sans fin entre deux valeurs (zoom lent du fond, anneau qui tourne). Rend de quoi l'arrêter.
    public static CancellationTokenSource Boucle(Animatable c, double duree, bool allerRetour, Easing e, params (AvaloniaProperty p, object de, object vers)[] valeurs)
    {
        var arret = new CancellationTokenSource();
        var a = new Animation { Duration = TimeSpan.FromSeconds(duree), IterationCount = IterationCount.Infinite, PlaybackDirection = allerRetour ? PlaybackDirection.Alternate : PlaybackDirection.Normal, Easing = e };
        KeyFrame debut = new() { Cue = new Cue(0) }, fin = new() { Cue = new Cue(1) };
        foreach (var (p, de, vers) in valeurs) { debut.Setters.Add(new Setter(p, de)); fin.Setters.Add(new Setter(p, vers)); }
        a.Children.Add(debut); a.Children.Add(fin);
        _ = a.RunAsync(c, arret.Token);
        return arret;
    }
}

static class U
{
    /// L'écriture de Home sur Windows : Mona Sans, embarquée dans l'app (SF Pro, celle du Mac, ne peut pas être redistribuée)
    public static readonly FontFamily Police = new("avares://Home/polices#Mona Sans");
    /// Pour les titres : sa version large, en très gras (SF Pro Expanded Black sur Mac)
    public static readonly FontFamily PoliceLarge = new("avares://Home/polices/MonaSansExpanded-Black.ttf#Mona Sans Expanded");
    /// La même en gras seulement, pour les choix de la roue
    public static readonly FontFamily PoliceLargeGras = new("avares://Home/polices/MonaSansExpanded-Bold.ttf#Mona Sans Expanded");
    public static IBrush Blanc(double a = 1) => new SolidColorBrush(Colors.White, a);
    public static IBrush Noir(double a = 1) => new SolidColorBrush(Colors.Black, a);
    public static readonly RelativePoint Centre = RelativePoint.Center, Bas = new(0.5, 1, RelativeUnit.Relative), Gauche = new(0, 0.5, RelativeUnit.Relative);
    public static TextBlock Texte(string s, double taille, FontWeight poids = FontWeight.Normal, double opacite = 1) =>
        new() { Text = s, FontSize = taille, FontWeight = poids, Opacity = opacite, FontFamily = Police, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center };
    /// Un titre dans l'écriture de Home : capitales larges, très grasses. `place` : la largeur à ne pas dépasser, le texte rétrécit pour y tenir.
    public static TextBlock Titre(string s, double taille, double espace = 1, double opacite = 1, double place = 0)
    {
        var t = s.ToUpper();
        if (place > 0) taille = Math.Max(taille * 0.5, Math.Min(taille, place / Math.Max(1, t.Length) / 0.84));   // une capitale large fait environ 0,84 fois sa taille
        return new() { Text = t, FontSize = taille, FontWeight = FontWeight.Black, Opacity = opacite, FontFamily = PoliceLarge, LetterSpacing = espace, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    }
    static readonly Dictionary<int, Typeface> policesIcones = new[] { 16, 20, 24, 28, 32, 48 }.ToDictionary(t => t, t => new Typeface($"avares://FluentIcons.Resources.Avalonia/Assets#Fluent System Icons Size{t}"));
    static readonly Dictionary<(Icon, int), Geometry?> traces = new();
    /// Une icône : le symbole du Mac traduit en icône Fluent pleine, dans un carré de sa taille (donc toujours centrée).
    /// La police d'icônes impose sa couleur (noir) quand on l'écrit comme du texte : on prend le tracé du caractère, qu'on remplit de la
    /// couleur voulue. Le caractère : 0xF0000 + 4 × l'icône + sa variante (1 = pleine). Trois dessins selon la taille, comme chez Microsoft.
    public static Control Icone(string sf, double taille, IBrush? couleur = null)
    {
        var icone = Icones.De(sf); var dessin = taille >= 40 ? 2 : taille >= 26 ? 1 : 0;
        if (!traces.TryGetValue((icone, dessin), out var trace))
        {
            // chaque icône n'existe pas dans toutes les tailles de dessin : la plus proche de celle qu'on veut, parmi celles qui l'ont
            var point = 0xF0000 + 4 * (int)icone + (int)IconVariant.Filled;
            int[] ordre = dessin == 2 ? [48, 32, 28, 24, 20, 16] : dessin == 1 ? [28, 24, 32, 20, 48, 16] : [20, 24, 16, 28, 32, 48];
            var police = ordre.Select(t => policesIcones[t]).FirstOrDefault(p => p.GlyphTypeface.TryGetGlyph((uint)point, out _), policesIcones[20]);
            traces[(icone, dessin)] = trace = new FormattedText(char.ConvertFromUtf32(point), System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight, police, 100, Brushes.White).BuildGeometry(new Point(0, 0));
        }
        // le tracé est dessiné dans un carré de 100 (la taille du caractère), puis mis à l'échelle : l'icône garde ses marges d'origine
        var forme = new Avalonia.Controls.Shapes.Path { Data = trace, Fill = couleur ?? Brushes.White, Width = 100, Height = 100, Stretch = Stretch.None, RenderTransformOrigin = new RelativePoint(0, 0, RelativeUnit.Relative), RenderTransform = new ScaleTransform(taille / 100, taille / 100) };
        return new Canvas { Width = taille, Height = taille, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Children = { forme } };
    }
    // Les repères des services (`Symbole` sur Mac) : des dessins de Home, pas des logos de marques (le dépôt est public). Une console
    // portable pour la Switch, quatre carreaux pour Windows, une bielle pour Steam, un écusson pour Epic Games.
    static Color Rvb(string nom) => nom switch
    {
        "logo:switch" => Color.FromRgb(224, 5, 23), "logo:steam" => Color.FromRgb(18, 43, 97), "logo:windows" => Color.FromRgb(5, 117, 219), _ => Color.FromRgb(41, 41, 48),
    };
    /// Le disque derrière un repère : la couleur du service, plus claire en haut à gauche pour lui donner du volume
    public static IBrush DegradeRepere(string nom)
    {
        var c = Rvb(nom); Color N(double k, double p) => Color.FromRgb((byte)Math.Min(255, c.R * k + p * 255), (byte)Math.Min(255, c.G * k + p * 255), (byte)Math.Min(255, c.B * k + p * 255));
        return Degrade(0, 0, 1, 1, (N(1.18, 0.10), 0), (N(1, 0), 0.5), (N(0.58, 0), 1));
    }
    static Geometry Bielle(double t)
    {
        Geometry Rond(double x, double y, double r) => new EllipseGeometry(new Rect((x - r) * t, (y - r) * t, 2 * r * t, 2 * r * t));
        var bras = new StreamGeometry();
        using (var g = bras.Open()) { g.BeginFigure(new Point(0.537 * t, 0.251 * t), true); g.LineTo(new Point(0.743 * t, 0.469 * t)); g.LineTo(new Point(0.315 * t, 0.838 * t)); g.LineTo(new Point(0.165 * t, 0.682 * t)); g.EndFigure(true); }
        Geometry Plus(Geometry a, Geometry b) => new CombinedGeometry(GeometryCombineMode.Union, a, b);
        Geometry Moins(Geometry a, Geometry b) => new CombinedGeometry(GeometryCombineMode.Exclude, a, b);
        // le volant, son moyeu, le bras qui s'affine, le palier : d'un seul bloc, avec deux découpes
        return Moins(Plus(Moins(Plus(Plus(bras, Rond(0.64, 0.36, 0.285)), Rond(0.24, 0.76, 0.155)), Rond(0.645, 0.355, 0.195)), Rond(0.648, 0.352, 0.112)), Rond(0.238, 0.762, 0.066));
    }
    static Geometry Ecusson(double l, double h)
    {
        var e = new StreamGeometry(); double c = l * 0.14, y = h * 0.58;
        using (var g = e.Open())
        {
            g.BeginFigure(new Point(c, 0), true); g.LineTo(new Point(l - c, 0)); g.QuadraticBezierTo(new Point(l, 0), new Point(l, c)); g.LineTo(new Point(l, y));
            g.QuadraticBezierTo(new Point(l, h * 0.88), new Point(l / 2, h)); g.QuadraticBezierTo(new Point(0, h * 0.88), new Point(0, y)); g.LineTo(new Point(0, c)); g.QuadraticBezierTo(new Point(0, 0), new Point(c, 0)); g.EndFigure(true);
        }
        return e;
    }
    /// Le dessin d'un repère, à l'encre donnée ; `creux` : la couleur de ce qui est découpé dedans (le fond sur lequel il est posé)
    public static Control Repere(string nom, double taille, IBrush encre, IBrush? creux = null)
    {
        creux ??= Noir(0.35);
        switch (nom)
        {
            case "logo:switch":
            {   // une console portable vue de face : l'écran entre ses deux manettes, un stick de chaque côté
                double h = taille * 0.86, l = taille * 1.62, m = l * 0.21, r = h * 0.30;
                Border Manette(bool gauche) => new()
                {
                    Width = m, Height = h, Background = encre, CornerRadius = gauche ? new CornerRadius(r, 3, 3, r) : new CornerRadius(3, r, r, 3),
                    Child = new Border { Width = m * 0.46, Height = m * 0.46, CornerRadius = new CornerRadius(m), Background = Noir(0.42), HorizontalAlignment = HorizontalAlignment.Center,
                        VerticalAlignment = gauche ? VerticalAlignment.Top : VerticalAlignment.Bottom, Margin = gauche ? new Thickness(0, h * 0.20, 0, 0) : new Thickness(0, 0, 0, h * 0.20) },
                };
                var ecran = new Border { Width = l - 2 * m - taille * 0.10, Height = h, CornerRadius = new CornerRadius(4), Background = encre, Child = new Border { Margin = new Thickness(taille * 0.07), CornerRadius = new CornerRadius(2), Background = Noir(0.30) } };
                var s = Ligne(taille * 0.05, Manette(true), ecran, Manette(false)); s.HorizontalAlignment = HorizontalAlignment.Center; s.VerticalAlignment = VerticalAlignment.Center; return s;
            }
            case "logo:windows":
            {   // quatre carreaux nets et serrés
                double t = taille * 1.16, j = t * 0.07, c = (t - j) / 2; var grille = new Canvas { Width = t, Height = t, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
                foreach (var (x, y) in new[] { (0d, 0d), (c + j, 0d), (0d, c + j), (c + j, c + j) }) { var carreau = new Border { Width = c, Height = c, Background = encre }; Canvas.SetLeft(carreau, x); Canvas.SetTop(carreau, y); grille.Children.Add(carreau); }
                return grille;
            }
            case "logo:steam":
            {   var t = taille * 1.42; return new Avalonia.Controls.Shapes.Path { Data = Bielle(t), Fill = encre, Width = t, Height = t, Stretch = Stretch.None, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }; }
            case "logo:epic":
            {   // un écusson plein, l'initiale découpée dedans
                double l = taille * 1.12, h = taille * 1.36;
                return new Panel { Width = l, Height = h, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Children =
                {
                    new Avalonia.Controls.Shapes.Path { Data = Ecusson(l, h), Fill = encre, Stretch = Stretch.None },
                    new TextBlock { Text = "E", FontSize = taille * 0.86, FontWeight = FontWeight.Black, FontFamily = Police, Foreground = creux, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, taille * 0.04, 0, 0) },
                } };
            }
            default: return Icone(nom.StartsWith("logo:") ? "person" : nom, taille, encre);
        }
    }
    /// Le symbole d'un choix de menu : un repère de service (« logo:… »), un peu plus petit comme sur Mac, ou une icône
    public static Control Symbole(string nom, double taille, IBrush encre) => nom.StartsWith("logo:") ? Repere(nom, taille * 0.62, nom == "logo:steam" ? new SolidColorBrush(Color.FromRgb(204, 230, 255)) : encre, new SolidColorBrush(Rvb(nom))) : Icone(nom, taille, encre);
    /// La pastille d'une console ou d'une boutique : son repère sur un disque à sa couleur
    public static Control Console(string icone, double taille)
    {
        IBrush encre = icone == "logo:steam" ? new SolidColorBrush(Color.FromRgb(204, 230, 255)) : Brushes.White;
        var dessin = icone.StartsWith("logo:") ? Repere(icone, taille * (icone == "logo:switch" ? 0.40 : 0.44), encre, new SolidColorBrush(Rvb(icone))) : Icone(icone, taille * 0.58);
        return new Border { Width = taille, Height = taille, CornerRadius = new CornerRadius(taille / 2), ClipToBounds = true, VerticalAlignment = VerticalAlignment.Center, Background = DegradeRepere(icone), Child = dessin };
    }
    public static LinearGradientBrush Degrade(Color a, Color b, bool diagonale = true) => new()
    {
        StartPoint = new RelativePoint(diagonale ? 0 : 0.5, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(diagonale ? 1 : 0.5, 1, RelativeUnit.Relative),
        GradientStops = { new GradientStop(a, 0), new GradientStop(b, 1) },
    };
    /// Un dégradé à plusieurs paliers entre deux points de la vue (0 à 1)
    public static LinearGradientBrush Degrade(double x1, double y1, double x2, double y2, params (Color c, double ou)[] paliers)
    {
        var b = new LinearGradientBrush { StartPoint = new RelativePoint(x1, y1, RelativeUnit.Relative), EndPoint = new RelativePoint(x2, y2, RelativeUnit.Relative) };
        foreach (var (c, ou) in paliers) b.GradientStops.Add(new GradientStop(c, ou));
        return b;
    }
    public static Color Alpha(Color c, double a) => Color.FromArgb((byte)(255 * Math.Clamp(a, 0, 1)), c.R, c.G, c.B);
    public static Color NoirA(double a) => Alpha(Colors.Black, a);
    /// Une lueur : un disque de couleur qui s'efface vers son bord (à la place d'un grand flou, bien plus coûteux à dessiner)
    static readonly Dictionary<(Color, int), Bitmap> lueurs = new();
    /// Une lueur : un disque de couleur qui s'efface vers son bord. Dessinée une fois par Skia avec du tramage, puis gardée : un dégradé
    /// d'Avalonia, sur un fond sombre, fait des anneaux visibles (256 niveaux seulement) au lieu d'un fondu lisse.
    public static Image Lueur(Color c, double diametre, double force)
    {
        var cle = (Alpha(c, force), (int)diametre);
        if (!lueurs.TryGetValue(cle, out var image))
        {
            var cote = Math.Clamp((int)(diametre / 2), 64, 720);   // à demi-taille : une lueur n'a aucun détail
            using var surface = SkiaSharp.SKSurface.Create(new SkiaSharp.SKImageInfo(cote, cote, SkiaSharp.SKColorType.Bgra8888, SkiaSharp.SKAlphaType.Premul));
            SkiaSharp.SKColor K(double a) => new(c.R, c.G, c.B, (byte)(255 * Math.Clamp(a, 0, 1)));
            using var peinture = new SkiaSharp.SKPaint { IsDither = true, IsAntialias = true };
            // un fondu en courbe douce (cinq paliers) plutôt qu'en ligne droite : pas de bord qu'on devine
            peinture.Shader = SkiaSharp.SKShader.CreateRadialGradient(new SkiaSharp.SKPoint(cote / 2f, cote / 2f), cote / 2f,
                [K(force), K(force * 0.78), K(force * 0.45), K(force * 0.16), K(0)], [0f, 0.25f, 0.5f, 0.75f, 1f], SkiaSharp.SKShaderTileMode.Clamp);
            surface.Canvas.Clear(SkiaSharp.SKColors.Transparent); surface.Canvas.DrawRect(0, 0, cote, cote, peinture);
            using var png = surface.Snapshot().Encode(SkiaSharp.SKEncodedImageFormat.Png, 100); using var flux = png.AsStream();
            lueurs[cle] = image = new Bitmap(flux);
        }
        var vue = new Image { Source = image, Width = diametre, Height = diametre, Stretch = Stretch.Fill, IsHitTestVisible = false };
        RenderOptions.SetBitmapInterpolationMode(vue, BitmapInterpolationMode.HighQuality); return vue;
    }
    public static StackPanel Ligne(double espace, params Control[] c) { var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = espace }; s.Children.AddRange(c); return s; }
    public static StackPanel Colonne(double espace, params Control[] c) { var s = new StackPanel { Spacing = espace }; s.Children.AddRange(c); return s; }
    /// Une touche dans une pastille : lettre de la manette ou touche du clavier
    public static Control Touche(string t, IBrush? couleur = null) => new Border
    {
        BorderBrush = couleur ?? Blanc(0.7), BorderThickness = new Thickness(1.5), CornerRadius = new CornerRadius(12), MinWidth = 24, Height = 24, Padding = new Thickness(7, 0), VerticalAlignment = VerticalAlignment.Center,
        Child = new TextBlock { Text = t, FontSize = 12, FontWeight = FontWeight.Bold, FontFamily = Police, Foreground = couleur ?? Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
    };
    /// Une aide dans sa pilule sombre (`Pilule` sur Mac) : la touche, puis ce qu'elle fait
    public static Border Pilule(string touche, string texte) => new()
    {
        Background = Noir(0.45), BorderBrush = Blanc(0.16), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(23), Padding = new Thickness(18, 11),
        Child = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Opacity = 0.8, Children = { Touche(touche), Texte(texte, 17, FontWeight.SemiBold) } },
    };
    /// Un îlot du haut de l'écran (batterie de la manette)
    public static Border Ilot(params Control[] c) => new() { Background = Noir(0.42), BorderBrush = Blanc(0.14), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(22), Height = 44, Padding = new Thickness(16, 0), Child = Ligne(8, c) };
    public static async void Distante(Image img, string url, int largeur, Action? chargee = null) { if (await Images.Distante(url, largeur) is { } b) { img.Source = b; chargee?.Invoke(); } }
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<Bitmap, Bitmap> flous = new();
    /// Une image floue sans rien calculer à l'écran : un vrai flou, fait une seule fois par Skia sur l'image réduite, puis gardé.
    /// (Étirer une image de quelques points, comme avant, donnait de gros pixels.) `cote` : la force, 20 = très flou.
    public static Bitmap Flou(Bitmap b, int cote = 20)
    {
        if (flous.TryGetValue(b, out var f)) return f;
        f = Flouter(b, 240, 240f / cote / 1.6f) ?? b;
        flous.Add(b, f); return f;
    }
    /// Réduit l'image à `largeur` points au plus, la floute (sigma en points de l'image réduite) et la rend. null si Skia n'y arrive pas.
    public static Bitmap? Flouter(Bitmap b, int largeur, float sigma)
    {
        try
        {
            var k = Math.Min(1.0, (double)largeur / Math.Max(1, Math.Max(b.PixelSize.Width, b.PixelSize.Height)));
            int l = Math.Max(2, (int)(b.PixelSize.Width * k)), h = Math.Max(2, (int)(b.PixelSize.Height * k));
            // C'est Skia qui réduit : CreateScaledBitmap refuse une photo de l'écran (« Invalid source bitmap type »), et le flou
            // n'était alors jamais fait : on voyait la photo réduite étirée, en gros pixels.
            using var tampon = new MemoryStream(); b.Save(tampon); tampon.Position = 0;
            using var entiere = SkiaSharp.SKBitmap.Decode(tampon); if (entiere == null) return null;
            using var source = entiere.Width == l && entiere.Height == h ? entiere.Copy() : entiere.Resize(new SkiaSharp.SKImageInfo(l, h), SkiaSharp.SKFilterQuality.High); if (source == null) return null;
            using var surface = SkiaSharp.SKSurface.Create(new SkiaSharp.SKImageInfo(l, h, SkiaSharp.SKColorType.Bgra8888, SkiaSharp.SKAlphaType.Premul));
            // les bords se prolongent (Clamp) : sans ça le flou s'assombrit en approchant du cadre
            using var peinture = new SkiaSharp.SKPaint { IsDither = true, ImageFilter = SkiaSharp.SKImageFilter.CreateBlur(sigma, sigma, SkiaSharp.SKShaderTileMode.Clamp) };
            surface.Canvas.Clear(SkiaSharp.SKColors.Black); surface.Canvas.DrawBitmap(source, 0, 0, peinture);
            using var png = surface.Snapshot().Encode(SkiaSharp.SKEncodedImageFormat.Png, 100); using var flux = png.AsStream();
            return new Bitmap(flux);
        }
        catch (Exception e) { Journal.Ecrire("flou : " + e.Message); return null; }
    }
    public static Image ImageFloue(Bitmap? b) { var i = new Image { Source = b != null ? Flou(b) : null, Stretch = Stretch.UniformToFill }; RenderOptions.SetBitmapInterpolationMode(i, BitmapInterpolationMode.HighQuality); return i; }
}

/// Une vue qui en remplace une autre en fondu : l'ancienne s'efface, la nouvelle arrive (en glissant ou en grandissant si on le demande)
sealed class Echange : Panel
{
    public void Montrer(Control? nouveau, double duree, double dx = 0, double echelle = 1, Easing? e = null)
    {
        foreach (var ancien in Children.ToList())
        {
            if (duree <= 0) { Children.Remove(ancien); continue; }
            ancien.IsHitTestVisible = false; ancien.Opacity = 0;
            Mouvement.Dans(duree + 0.05, () => Children.Remove(ancien));
        }
        if (nouveau == null) return;
        if (duree <= 0) { Children.Add(nouveau); return; }
        nouveau.Opacity = 0; nouveau.RenderTransformOrigin = U.Centre;
        nouveau.RenderTransform = echelle != 1 ? Mouvement.Echelle(echelle) : Mouvement.Deplace(dx, 0);
        nouveau.Transitions = new Transitions { Mouvement.Opacite(duree, e), Mouvement.Transfo(duree, e) };
        Children.Add(nouveau);
        Mouvement.Apres(() => { nouveau.Opacity = 1; nouveau.RenderTransform = echelle != 1 ? Mouvement.Echelle(1) : Mouvement.Deplace(0, 0); });
    }
}

/// Un anneau qui se remplit, départ en haut (avancement d'une tâche, repère des menus). `Fraction` s'anime comme n'importe quelle valeur.
sealed class Anneau : Control
{
    public static readonly StyledProperty<double> FractionProperty = AvaloniaProperty.Register<Anneau, double>(nameof(Fraction));
    public static readonly StyledProperty<IBrush> CouleurProperty = AvaloniaProperty.Register<Anneau, IBrush>(nameof(Couleur), Brushes.White);
    public double Fraction { get => GetValue(FractionProperty); set => SetValue(FractionProperty, value); }
    public IBrush Couleur { get => GetValue(CouleurProperty); set => SetValue(CouleurProperty, value); }
    public double Epaisseur = 4; public IBrush? Piste;
    static Anneau() { AffectsRender<Anneau>(FractionProperty, CouleurProperty); }
    public override void Render(DrawingContext c)
    {
        double r = Math.Min(Bounds.Width, Bounds.Height) / 2 - Epaisseur / 2, f = Math.Clamp(Fraction, 0, 1); var o = new Point(Bounds.Width / 2, Bounds.Height / 2);
        if (r <= 0) return;
        if (Piste != null) c.DrawEllipse(null, new Pen(Piste, Epaisseur), o, r, r);
        if (f <= 0) return;
        if (f >= 0.999) { c.DrawEllipse(null, new Pen(Couleur, Epaisseur), o, r, r); return; }
        var a = f * 2 * Math.PI; var g = new StreamGeometry();
        using (var s = g.Open()) { s.BeginFigure(new Point(o.X, o.Y - r), false); s.ArcTo(new Point(o.X + r * Math.Sin(a), o.Y - r * Math.Cos(a)), new Size(r, r), 0, f > 0.5, SweepDirection.Clockwise); s.EndFigure(false); }
        c.DrawGeometry(null, new Pen(Couleur, Epaisseur, lineCap: PenLineCap.Round), g);
    }
}

/// Le fond : l'image du jeu visé (floutée quand il n'a que sa jaquette), en fondu enchaîné d'un jeu à l'autre.
/// Sur la case + : des halos de couleur et quelques symboles qui flottent (`AddBackground`).
/// Le zoom lent du Mac (1,00 ↔ 1,05 en 30 s) n'est pas repris : sur Avalonia il fait redessiner tout l'écran à chaque image.
sealed class FondVue : Panel
{
    readonly Panel[] couches = [new(), new()]; int devant; string cle = "?";
    readonly Panel plus = new() { Opacity = 0 };
    public FondVue()
    {
        ClipToBounds = true; Background = Brushes.Black; IsHitTestVisible = false;
        plus.Children.Add(new Border { Background = U.Degrade(Color.FromRgb(13, 15, 43), Color.FromRgb(3, 3, 13), false) });
        var halos = new Canvas();
        (Color c, double x, double y)[] taches = [(Color.FromRgb(242, 64, 89), 0.20, 0.20), (Color.FromRgb(64, 115, 255), 0.70, 0.32), (Color.FromRgb(51, 217, 140), 0.44, 0.60), (Color.FromRgb(158, 82, 242), 0.84, 0.66)];
        foreach (var (c, x, y) in taches) { var e = U.Lueur(c, 1267, 0.55); Canvas.SetLeft(e, 1920 * x - 633); Canvas.SetTop(e, 1080 * y - 633); halos.Children.Add(e); }
        (string sf, double x, double y)[] symboles = [("gamecontroller", 0.16, 0.30), ("desktopcomputer", 0.82, 0.24), ("puzzlepiece", 0.70, 0.62), ("leaf", 0.30, 0.66), ("plus.circle", 0.50, 0.18), ("arrow.down.circle", 0.90, 0.55)];
        for (var k = 0; k < symboles.Length; k++)
        {
            var (sf, x, y) = symboles[k]; var taille = 100 + 34 * (k % 3); var i = U.Icone(sf, taille, U.Blanc(0.07)); i.RenderTransform = new TranslateTransform();
            Canvas.SetLeft(i, 1920 * x - taille / 2.0); Canvas.SetTop(i, 1080 * y - taille / 2.0); halos.Children.Add(i);
            double dx = 30 + 6 * k, dy = 24 + 5 * k, duree = 11 + 2.5 * k;
            if (!Mouvement.Reduit) i.AttachedToVisualTree += (_, _) => Mouvement.Boucle(i, duree, true, new SineEaseInOut(), (TranslateTransform.XProperty, -dx, dx), (TranslateTransform.YProperty, dy, -dy));
        }
        plus.Children.Add(halos); plus.Transitions = new Transitions { Mouvement.Opacite(0.35, new CubicEaseInOut()) };
        Children.Add(plus);
        foreach (var c in couches) { c.Opacity = 0; c.Transitions = new Transitions { Mouvement.Opacite(0.35, new CubicEaseInOut()) }; Children.Add(c); }
        Children.Add(new Border { ZIndex = 5, Background = U.Degrade(0.5, 0, 0.5, 1, (U.NoirA(0.35), 0), (Colors.Transparent, 0.5), (U.NoirA(0.88), 1)) });
    }
    public void Montrer(string cle, Bitmap? image, bool flou)
    {
        if (cle == this.cle) return;
        this.cle = cle; var ancien = couches[devant]; devant = 1 - devant; var c = couches[devant];
        // la nouvelle image arrive par-dessus l'ancienne, qui reste pleine jusqu'à la fin du fondu : jamais de creux noir entre deux jeux
        c.Children.Clear(); Mouvement.SansAnimer(c, () => c.Opacity = 0);
        c.ZIndex = 2; ancien.ZIndex = 1; plus.Opacity = image == null ? 1 : 0;
        if (image == null) { ancien.Opacity = 0; return; }
        if (flou) { var i = U.ImageFloue(image); i.RenderTransformOrigin = U.Centre; i.RenderTransform = new ScaleTransform(1.3, 1.3); c.Children.Add(i); }
        else c.Children.Add(new Image { Source = image, Stretch = Stretch.UniformToFill });
        Mouvement.Apres(() => { if (this.cle == cle) c.Opacity = 1; });
        Mouvement.Dans(0.45, () => { if (this.cle == cle) ancien.Opacity = 0; });
    }
}

/// Une tuile de jeu (`Tile`) : un carré de 180 dont la taille de dessin ne change jamais. Visée, elle est agrandie d'un bloc par le bas
/// (échelle 1,34), son bord blanc apparaît, elle s'éclaircit. Sa place dans la rangée est un déplacement, pas une marge : rien n'est remis en page.
/// Une jaquette qui n'est pas carrée (celles de Steam sont en hauteur) est montrée entière, sur sa propre image floutée : rien n'est rogné.
sealed class Tuile : Panel
{
    public const double Cote = 180, Zoom = 1.34;
    readonly Panel carre = new() { Width = Cote, Height = Cote, RenderTransformOrigin = U.Bas };
    readonly Border ombre = new(), cadre = new() { ClipToBounds = true }, sombre = new() { Background = Brushes.Black, IsHitTestVisible = false }, contour = new() { BorderBrush = Brushes.White, BorderThickness = new Thickness(3), Opacity = 0 };
    readonly Image image = new() { Stretch = Stretch.UniformToFill }, entiere = new() { Stretch = Stretch.Uniform }, givre = U.ImageFloue(null);
    readonly Border voile = new() { Background = U.Noir(0.35), IsVisible = false };
    readonly Rectangle? pointille;
    public readonly Jeu? Jeu;
    Bitmap? montree; (bool visee, double x, bool floue)? etat;
    public Tuile(Jeu? jeu)
    {
        Jeu = jeu; Width = Height = Cote; Background = Brushes.Transparent;
        var coins = new CornerRadius(26); ombre.CornerRadius = cadre.CornerRadius = sombre.CornerRadius = contour.CornerRadius = coins;
        var dedans = new Panel();
        if (jeu == null)
        {   // la case + (`AddTile`) : un contour en pointillés, plein quand elle est visée
            cadre.Background = U.Blanc(0.04); sombre.Background = Brushes.White; sombre.Opacity = 0;
            pointille = new Rectangle { RadiusX = 26, RadiusY = 26, Stroke = U.Blanc(0.3), StrokeThickness = 2, StrokeDashArray = [3.5, 3.5] };
            dedans.Children.Add(U.Icone("plus", 44, U.Blanc(0.85)));
        }
        else
        {
            var initiales = string.Concat(jeu.Nom.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2).Select(m => char.ToUpper(m[0])));
            dedans.Children.Add(new Border { Background = U.Degrade(Color.FromRgb(56, 56, 56), Color.FromRgb(20, 20, 20), false),
                Child = new TextBlock { Text = initiales, FontSize = 56, FontWeight = FontWeight.Black, FontFamily = U.PoliceLarge, Foreground = U.Blanc(0.5), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } });
            RenderOptions.SetBitmapInterpolationMode(image, BitmapInterpolationMode.HighQuality); RenderOptions.SetBitmapInterpolationMode(entiere, BitmapInterpolationMode.HighQuality);
            givre.Opacity = 0; givre.Transitions = new Transitions { Mouvement.Opacite(0.42, Mouvement.Coule) };
            dedans.Children.AddRange([image, voile, entiere, givre]);
            ombre.Background = Brushes.Black; ombre.BoxShadow = BoxShadows.Parse("0 5 8 0 #4D000000"); sombre.Opacity = 0.12;
        }
        cadre.Child = dedans;
        carre.Children.AddRange([ombre, cadre, sombre]); if (pointille != null) carre.Children.Add(pointille); carre.Children.Add(contour);
        Children.Add(carre);
        carre.RenderTransform = Mouvement.Echelle(1); RenderTransform = Mouvement.Deplace(0, 0);
        var coule = Mouvement.Coule;
        Transitions = new Transitions { Mouvement.Transfo(0.42, coule) };
        carre.Transitions = new Transitions { Mouvement.Transfo(0.42, coule) };
        contour.Transitions = new Transitions { Mouvement.Opacite(0.42, coule) }; sombre.Transitions = new Transitions { Mouvement.Opacite(0.42, coule) };
        if (pointille != null) pointille.Transitions = new Transitions { Mouvement.Opacite(0.42, coule) };
    }
    /// `floue` : la tuile est dans une rangée voisine, qu'on devine seulement (le flou du Mac, sans flou calculé : la jaquette réduite à quelques points)
    public void Mettre(Bitmap? couverture, bool visee, double x, bool floue)
    {
        if (couverture != montree && Jeu != null)
        {
            montree = couverture;
            var ratio = couverture == null ? 1 : (double)couverture.PixelSize.Width / Math.Max(1, couverture.PixelSize.Height); var carree = ratio is > 0.9 and < 1.12;
            image.Source = couverture == null ? null : carree ? couverture : U.Flou(couverture); entiere.Source = carree ? null : couverture; voile.IsVisible = !carree;
            givre.Source = couverture != null ? U.Flou(couverture) : null;
        }
        // rien n'a changé : on ne touche à rien (réécrire la même valeur relancerait la transition en cours)
        if (etat == (visee, x, floue)) return;
        etat = (visee, x, floue);
        RenderTransform = Mouvement.Deplace(x, 0); carre.RenderTransform = Mouvement.Echelle(visee ? Zoom : 1); contour.Opacity = visee ? 1 : 0; ZIndex = visee ? 1 : 0;
        if (Jeu == null) { sombre.Opacity = visee ? 0.10 : 0; pointille!.Opacity = visee ? 0 : 1; }
        else { sombre.Opacity = visee ? 0 : 0.12; givre.Opacity = floue ? 1 : 0; ombre.BoxShadow = BoxShadows.Parse(visee ? "0 10 16 0 #8C000000" : "0 5 8 0 #4D000000"); }
    }
}

/// Une rangée de jeux : celle d'une catégorie (`RangeeJeux`). Seule la rangée en cours a un jeu visé, et défile pour le garder au centre.
sealed class RangeeJeux : Canvas
{
    const double Marge = 84, Pas = Tuile.Cote + 22, Pousse = Tuile.Cote * (Tuile.Zoom - 1);   // la tuile visée, agrandie, pousse ses voisines de la moitié de chaque côté
    readonly Bibliotheque lib; readonly Canvas piste = new(); readonly List<Tuile> tuiles = new(); string cle = "?"; double decalage, pose;
    public bool Active;
    public RangeeJeux(Bibliotheque lib)
    {
        this.lib = lib; Height = 294;
        piste.RenderTransform = Mouvement.Deplace(0, 0); piste.Transitions = new Transitions { Mouvement.Transfo(0.42, Mouvement.Coule) };
        Children.Add(piste);
    }
    public void Mettre(List<Jeu> jeux, int? visee, bool floue)
    {
        var c = string.Join("|", jeux.Select(j => j.Id)); var neuve = c != cle;
        if (neuve)
        {
            cle = c; piste.Children.Clear(); tuiles.Clear();
            foreach (var j in jeux.Append(null))
            {
                var t = new Tuile(j); var i = tuiles.Count; Canvas.SetTop(t, 90);   // la place de la tuile agrandie, qui dépasse vers le haut
                t.PointerPressed += (_, _) =>
                {
                    if (!Active || lib.Menu != null || lib.EnCours != null) return;
                    if (lib.Selection == i) lib.Lancer(); else { lib.Selection = i; lib.Son("deplacer"); lib.Signaler(); }
                };
                tuiles.Add(t);
            }
        }
        for (var i = 0; i < tuiles.Count; i++)
            tuiles[i].Mettre(tuiles[i].Jeu is { } j ? lib.Arts.GetValueOrDefault(j.Id)?.Couverture : null, i == visee, Marge + i * Pas + (visee is { } v ? i > v ? Pousse : i == v ? Pousse / 2 : 0 : 0), floue);
        if (neuve) piste.Children.AddRange(tuiles);   // posées après avoir pris leur place : elles n'y glissent pas depuis le bord
        // Comme scrollTo(anchor: .center) : la tuile visée au milieu, sans dépasser les bords de la rangée. Une rangée qu'on quitte garde son défilement.
        if (visee is { } s)
        {
            double centre = Marge + s * Pas + Pousse / 2 + Tuile.Cote / 2, largeur = 2 * Marge + tuiles.Count * Pas - 22 + Pousse;
            decalage = Math.Clamp(centre - 960, 0, Math.Max(0, largeur - 1920));
        }
        if (neuve) Mouvement.SansAnimer(piste, () => piste.RenderTransform = Mouvement.Deplace(-decalage, 0)); else if (decalage != pose) piste.RenderTransform = Mouvement.Deplace(-decalage, 0);
        pose = decalage;
    }
}

/// L'écran de démarrage (`OuvertureView`) : trois cartes en éventail, la manette, « HOME », deux anneaux qui partent, puis un fondu
/// vers la bibliothèque. 2,15 s, puis 1 s de sortie. Une touche le passe, sauf pendant la première 1,5 s (manette qui se réveille).
sealed class Ouverture : Panel
{
    readonly DateTime debut = DateTime.Now; readonly Panel bloc = new() { RenderTransformOrigin = U.Centre }; bool part;
    public event Action? Finie;
    static Color C(double r, double v, double b) => Color.FromRgb((byte)(r * 255), (byte)(v * 255), (byte)(b * 255));
    static readonly Color[] Orange = [C(1.0, 0.70, 0.23), C(1.0, 0.42, 0.24)], Bleu = [C(0.19, 0.78, 0.80), C(0.16, 0.38, 1.0)], Violet = [C(0.58, 0.40, 0.98), C(0.33, 0.17, 0.80)];

    public Ouverture(bool fige)
    {
        Background = new SolidColorBrush(Color.FromRgb(5, 5, 13)); ClipToBounds = true;
        var douce = Mouvement.Douce; var sortie = new CubicEaseOut(); var etapes = new List<(double quand, Action quoi)>(); var ondes = new List<Action>();
        // trois lueurs, aux couleurs des cartes, qui s'écartent du centre
        var lueurs = new Panel { Opacity = 0, Transitions = new Transitions { Mouvement.Opacite(1.2, sortie) } };
        (Color c, double d, double x, double y)[] l = [(Violet[0], 0.46, -0.04, -0.12), (Bleu[1], 0.36, 0.22, 0.10), (Orange[1], 0.32, -0.24, 0.14)];
        foreach (var (c, d, x, y) in l)
        {
            var e = U.Lueur(c, 1920 * d * 2.1, 0.5); e.HorizontalAlignment = HorizontalAlignment.Center; e.VerticalAlignment = VerticalAlignment.Center;
            e.RenderTransform = Mouvement.Deplace(0, 0); e.Transitions = new Transitions { Mouvement.Transfo(1.2, sortie) };
            lueurs.Children.Add(e); etapes.Add((0, () => e.RenderTransform = Mouvement.Deplace(1920 * x, 1080 * y)));
        }
        etapes.Add((0, () => lueurs.Opacity = 1));
        // les anneaux qui partent du centre
        var anneaux = new Panel { RenderTransform = new TranslateTransform(0, -60), IsHitTestVisible = false };
        (double trait, double opacite, double de, double vers, double figee)[] a = [(2, 0.5, 0.7, 3.4, 1.9), (1.5, 0.35, 0.5, 2.4, 2.6)];
        foreach (var (trait, opacite, de, vers, figee) in a)
        {
            var e = new Ellipse { Width = 300, Height = 300, Stroke = Brushes.White, StrokeThickness = trait, Opacity = 0, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                RenderTransformOrigin = U.Centre, RenderTransform = Mouvement.Echelle(fige ? figee : de) };
            if (fige) e.Opacity = opacite * 0.2;
            anneaux.Children.Add(e);
            Action onde = () => { Mouvement.SansAnimer(e, () => e.Opacity = opacite); e.Transitions = new Transitions { Mouvement.Transfo(1.3, sortie), Mouvement.Opacite(1.3, sortie) }; e.RenderTransform = Mouvement.Echelle(vers); e.Opacity = 0; };
            ondes.Add(onde); etapes.Add((0.80, onde));
        }
        // les cartes : la violette devant, l'orange et la bleue sortent de derrière elle
        Control Carte(Color[] c) => new Border { Width = 190, Height = 262, CornerRadius = new CornerRadius(34), Background = U.Degrade(c[0], c[1]) };
        var cartes = new Panel { Width = 190, Height = 262, Opacity = 0, RenderTransformOrigin = U.Centre, RenderTransform = Mouvement.Echelle(0.72), Transitions = new Transitions { Mouvement.Transfo(0.7, douce), Mouvement.Opacite(0.7, douce) } };
        foreach (var (c, sens) in new[] { (Orange, -1), (Bleu, 1) })
        {
            var tourne = new Panel { RenderTransformOrigin = U.Centre, RenderTransform = Mouvement.Tourne(0), Transitions = new Transitions { Mouvement.Transfo(0.6, douce) }, Children = { Carte(c) } };
            var glisse = new Panel { RenderTransform = Mouvement.Deplace(0, 0), Transitions = new Transitions { Mouvement.Transfo(0.6, douce) }, Children = { tourne } };
            cartes.Children.Add(glisse);
            etapes.Add((0.50, () => { tourne.RenderTransform = Mouvement.Tourne(15 * sens); glisse.RenderTransform = Mouvement.Deplace(92 * sens, 14); }));
        }
        var manette = U.Icone("gamecontroller", 124); manette.Opacity = 0; manette.RenderTransformOrigin = U.Centre; manette.RenderTransform = Mouvement.Echelle(0.5);
        manette.Transitions = new Transitions { Mouvement.Transfo(0.45, douce), Mouvement.Opacite(0.45, douce) };
        cartes.Children.Add(new Border { CornerRadius = new CornerRadius(34), Background = U.Degrade(Violet[0], Violet[1]), BorderBrush = U.Blanc(0.35), BorderThickness = new Thickness(2), BoxShadow = BoxShadows.Parse("0 16 30 0 #80000000"), Child = manette });
        etapes.Add((0.10, () => { cartes.Opacity = 1; cartes.RenderTransform = Mouvement.Echelle(1); }));
        etapes.Add((0.80, () => { manette.Opacity = 1; manette.RenderTransform = Mouvement.Echelle(1); }));
        // « HOME » : les lettres se resserrent en apparaissant
        var nom = new TextBlock { Text = "HOME", FontSize = 54, FontWeight = FontWeight.Black, FontFamily = U.PoliceLarge, Foreground = Brushes.White, LetterSpacing = 44, Margin = new Thickness(44, 0, 0, 0), Opacity = 0, HorizontalAlignment = HorizontalAlignment.Center,
            Transitions = new Transitions { Mouvement.Opacite(0.7, douce), new DoubleTransition { Property = TextBlock.LetterSpacingProperty, Duration = Mouvement.S(0.7), Easing = douce }, new ThicknessTransition { Property = MarginProperty, Duration = Mouvement.S(0.7), Easing = douce } } };
        etapes.Add((1.00, () => { nom.Opacity = 1; nom.LetterSpacing = 14; nom.Margin = new Thickness(14, 0, 0, 0); }));
        // tout le bloc avance très lentement, du début à la fin : rien ne se fige avant le fondu
        var derive = new Panel { RenderTransformOrigin = U.Centre, RenderTransform = Mouvement.Echelle(1), Transitions = new Transitions { Mouvement.Transfo(3.4, new LinearEasing()) },
            Children = { new StackPanel { Spacing = 54, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Children = { cartes, nom } } } };
        etapes.Add((0, () => derive.RenderTransform = Mouvement.Echelle(1.06)));
        bloc.RenderTransform = Mouvement.Echelle(1); bloc.Children.Add(derive);
        Children.AddRange([lueurs, anneaux, bloc]);
        PointerPressed += (_, e) => { e.Handled = true; Passer(); };
        if (fige) { foreach (var (quand, quoi) in etapes) if (!ondes.Contains(quoi)) quoi(); return; }   // l'image d'arrivée : tout est en place, les anneaux à mi-course
        AttachedToVisualTree += async (_, _) =>
        {
            await Task.Delay(60);   // la fenêtre vient de s'afficher : le premier dessin doit montrer l'état de départ
            double t = 0;
            foreach (var groupe in etapes.GroupBy(x => x.quand).OrderBy(g => g.Key))
            {
                if (groupe.Key > t) { await Task.Delay(TimeSpan.FromSeconds(groupe.Key - t)); t = groupe.Key; }
                if (part) return;
                foreach (var (_, quoi) in groupe) quoi();
            }
            await Task.Delay(TimeSpan.FromSeconds(2.15 - t));
            Sortir();
        };
    }
    /// Une touche, un bouton ou un clic : rend vrai tant que l'écran de démarrage est là (l'appui ne va pas plus loin)
    public bool Passer() { if ((DateTime.Now - debut).TotalSeconds >= 1.5) Sortir(); return true; }
    void Sortir()
    {
        if (part) return;
        part = true; IsHitTestVisible = false;
        bloc.Transitions = new Transitions { Mouvement.Transfo(0.6, new CubicEaseIn()), Mouvement.Opacite(0.6, new CubicEaseIn()) };
        Transitions = new Transitions { Mouvement.Opacite(0.9, new CubicEaseInOut()) };   // le fond s'efface pendant que la bibliothèque apparaît dessous
        bloc.RenderTransform = Mouvement.Echelle(1.12); bloc.Opacity = 0; Opacity = 0;
        Mouvement.Dans(1.0, () => Finie?.Invoke());
    }
}

/// L'accueil du premier lancement (`BienvenueView`). Il ne ressemble pas aux menus : l'ambiance de l'écran de démarrage, trois grandes
/// cartes, un seul grand bouton. On comprend qu'il faut choisir ; « Ignorer » est petit, dans un coin.
sealed class BienvenueVue : Panel
{
    static Color C(double r, double v, double b) => Color.FromRgb((byte)(r * 255), (byte)(v * 255), (byte)(b * 255));
    static readonly (string titre, string ligne, string symbole, Color[] teinte)[] cartes =
    [
        ("Tout", "Jeux Nintendo et jeux PC", "sparkles", [C(0.58, 0.40, 0.98), C(0.33, 0.17, 0.80)]),
        ("Nintendo", "Switch et Switch 2", "logo:switch", [C(1.0, 0.70, 0.23), C(1.0, 0.42, 0.24)]),
        ("PC", "Epic Games, Steam, Windows", "logo:windows", [C(0.19, 0.78, 0.80), C(0.16, 0.38, 1.0)]),
    ];
    readonly Panel[] vues = new Panel[3]; readonly Border[] bords = new Border[3], voiles = new Border[3], halos = new Border[3]; readonly Image[] lueurs = new Image[3];
    int vise = -1;
    public BienvenueVue(Bibliotheque lib)
    {
        Background = new SolidColorBrush(Color.FromRgb(5, 5, 13)); ClipToBounds = true;
        var douce = Mouvement.Douce; var coule = Mouvement.Coule; var paraitre = new List<Action>();
        // les lueurs de l'écran de démarrage, celle de la carte visée plus forte
        var fond = new Canvas { IsHitTestVisible = false };
        for (var i = 0; i < 3; i++)
        {
            var c = cartes[i].teinte[i == 0 ? 0 : 1]; const double d = 1920 * 0.68;
            fond.Children.Add(U.Lueur(c, d, 0.22));
            lueurs[i] = U.Lueur(c, d, 0.40); lueurs[i].Opacity = 0; lueurs[i].Transitions = new Transitions { Mouvement.Opacite(0.5, new CubicEaseInOut()) }; fond.Children.Add(lueurs[i]);
            foreach (var e in fond.Children.TakeLast(2)) { Canvas.SetLeft(e, 1920 * (0.5 + (i - 1) * 0.27) - d / 2); Canvas.SetTop(e, 1080 * (i == 0 ? 0.40 : 0.62) - d / 2); }
        }
        Children.Add(fond);
        var titre = new TextBlock { Text = "BIENVENUE", FontSize = 84, FontWeight = FontWeight.Black, FontFamily = U.PoliceLarge, LetterSpacing = 30, Opacity = 0, HorizontalAlignment = HorizontalAlignment.Center,
            Foreground = U.Degrade(0.5, 0, 0.5, 1, (Colors.White, 0), (U.Alpha(Colors.White, 0.78), 1)),
            Transitions = new Transitions { Mouvement.Opacite(0.8, douce), new DoubleTransition { Property = TextBlock.LetterSpacingProperty, Duration = Mouvement.S(0.8), Easing = douce } } };
        paraitre.Add(() => { titre.Opacity = 1; titre.LetterSpacing = 6; });
        TextBlock Ligne(string texte, double taille, double opacite, double haut)
        {
            var t = U.Texte(texte, taille, FontWeight.Medium, 0); t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, haut, 0, 0); t.Transitions = new Transitions { Mouvement.Opacite(0.8, douce) };
            paraitre.Add(() => t.Opacity = opacite); return t;
        }
        var rangee = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 34, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 54, 0, 0) };
        for (var i = 0; i < 3; i++)
        {
            var c = cartes[i]; var n = i; var coins = new CornerRadius(44);
            var symbole = new Panel { Height = 170, Children = { c.symbole.StartsWith("logo:") ? U.Repere(c.symbole, 96, Brushes.White) : U.Icone(c.symbole, 116) } };
            var recommande = new Border { CornerRadius = new CornerRadius(14), Background = U.Noir(0.28), Padding = new Thickness(12, 5), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 0), Opacity = i == 0 ? 1 : 0, Child = U.Texte("Recommandé", 13, FontWeight.Bold) };
            var texte = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Children = { Centre(U.Titre(c.titre, 30, 1)), Centre(U.Texte(c.ligne, 17, FontWeight.Medium, 0.85), 8), recommande } };
            var dedans = new Grid { RowDefinitions = new RowDefinitions("*,Auto"), Margin = new Thickness(0, 30) }; dedans.Children.Add(new Panel { Children = { Centrer(symbole) } }); Grid.SetRow(texte, 1); dedans.Children.Add(texte);
            halos[i] = new Border { CornerRadius = coins, Background = new SolidColorBrush(c.teinte[1]), BoxShadow = BoxShadows.Parse($"0 18 46 0 #B3{c.teinte[1].R:X2}{c.teinte[1].G:X2}{c.teinte[1].B:X2}"), Opacity = 0, Transitions = new Transitions { Mouvement.Opacite(0.42, coule) } };
            // une carte pas visée est plus terne et plus sombre : un voile, à la place de la saturation et de la luminosité du Mac
            voiles[i] = new Border { CornerRadius = coins, Background = new SolidColorBrush(Color.FromRgb(20, 20, 28)), Opacity = 0.42, IsHitTestVisible = false, Transitions = new Transitions { Mouvement.Opacite(0.42, coule) } };
            bords[i] = new Border { CornerRadius = coins, BorderBrush = Brushes.White, BorderThickness = new Thickness(4), Opacity = 0, IsHitTestVisible = false, Transitions = new Transitions { Mouvement.Opacite(0.42, coule) } };
            var carte = new Panel { Width = 330, Height = 420, RenderTransformOrigin = U.Centre, RenderTransform = Mouvement.Echelle(0.94), Transitions = new Transitions { Mouvement.Transfo(0.42, coule) }, Children =
            {
                halos[i], new Border { CornerRadius = coins, Background = U.Degrade(c.teinte[0], c.teinte[1]), BorderBrush = U.Blanc(0.14), BorderThickness = new Thickness(1.5), Child = dedans }, voiles[i], bords[i],
            } };
            vues[i] = carte;
            // l'arrivée : chaque carte monte de 60 en apparaissant, l'une après l'autre
            var monte = new Panel { Opacity = 0, RenderTransform = Mouvement.Deplace(0, 60), Background = Brushes.Transparent, Children = { carte },
                Transitions = new Transitions { Mouvement.Transfo(0.6, douce, 0.25 + i * 0.09), Mouvement.Opacite(0.6, douce, 0.25 + i * 0.09) } };
            paraitre.Add(() => { monte.Opacity = 1; monte.RenderTransform = Mouvement.Deplace(0, 0); });
            monte.PointerPressed += (_, e) => { e.Handled = true; if (lib.BienvenueIndex == n) lib.BienvenueValider(); else { lib.BienvenueIndex = n; lib.Son("deplacer"); lib.Signaler(); } };
            rangee.Children.Add(monte);
        }
        var bouton = new Border { Height = 68, CornerRadius = new CornerRadius(34), Background = Brushes.White, Padding = new Thickness(54, 0), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 56, 0, 0), Opacity = 0,
            BoxShadow = BoxShadows.Parse("0 0 24 0 #40FFFFFF"), Transitions = new Transitions { Mouvement.Opacite(0.5, null, 0.7) },
            Child = U.Ligne(12, U.Touche(lib.Aides.Ok, U.Noir(0.7)), new TextBlock { Text = "Commencer", FontSize = 24, FontWeight = FontWeight.Bold, FontFamily = U.Police, Foreground = Brushes.Black, VerticalAlignment = VerticalAlignment.Center }) };
        bouton.PointerPressed += (_, e) => { e.Handled = true; lib.BienvenueValider(); };
        paraitre.Add(() => bouton.Opacity = 1);
        Children.Add(dessus = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children =
        {
            titre, Ligne("À quoi vas-tu jouer ? Home installe ce qu'il faut.", 24, 0.72, 14), Ligne("Home ne contient aucun jeu : il utilise ceux que tu possèdes, copiés depuis ta propre console.", 15, 0.45, 8), rangee, bouton,
        } });
        // « Ignorer » : là pour qui le cherche, pas pour qui hésite
        var ignorer = U.Ligne(6, U.Touche(lib.Aides.Options), U.Texte("Ignorer", 13, FontWeight.Medium)); ignorer.Opacity = 0.26; ignorer.HorizontalAlignment = HorizontalAlignment.Right; ignorer.VerticalAlignment = VerticalAlignment.Bottom; ignorer.Margin = new Thickness(0, 0, 44, 30); ignorer.Background = Brushes.Transparent;
        ignorer.PointerPressed += (_, e) => { e.Handled = true; lib.BienvenueIgnorer(); };
        Children.Add(ignorer); bas = ignorer;
        dessus.Transitions = new Transitions { Mouvement.Opacite(0.3, new CubicEaseInOut()) }; bas.Transitions = new Transitions { Mouvement.Opacite(0.3, new CubicEaseInOut()) };
        // tout est en place d'emblée : l'écran est déjà complet sous l'écran de démarrage, qui s'efface dessus. (Sur Mac les cartes
        // arrivent l'une après l'autre ; ici ça faisait attendre avant de pouvoir choisir.)
        foreach (var a in paraitre) a();
        Transitions = new Transitions { Mouvement.Opacite(0.45, new CubicEaseInOut()) };
    }
    static Control Centre(Control c, double haut = 0) { c.HorizontalAlignment = HorizontalAlignment.Center; c.Margin = new Thickness(0, haut, 0, 0); return c; }
    static Control Centrer(Control c) { c.HorizontalAlignment = HorizontalAlignment.Center; c.VerticalAlignment = VerticalAlignment.Center; return c; }
    readonly StackPanel dessus; readonly Control bas; bool efface;
    /// Le choix est fait et l'écran suivant (les clés) est un menu : les cartes s'effacent, le fond de la bienvenue reste dessous.
    /// On ne voit ainsi jamais la bibliothèque entre deux écrans du premier lancement.
    public void Effacer(bool oui) { if (oui == efface) return; efface = oui; dessus.Opacity = oui ? 0 : 1; bas.Opacity = oui ? 0 : 0.26; dessus.IsHitTestVisible = !oui; }
    public void Viser(int i)
    {
        if (i == vise) return;
        vise = i;
        for (var k = 0; k < 3; k++)
        {
            var ici = k == i;
            vues[k].RenderTransform = Mouvement.Echelle(ici ? 1.07 : 0.94); vues[k].ZIndex = ici ? 1 : 0; bords[k].Opacity = ici ? 0.95 : 0; voiles[k].Opacity = ici ? 0 : 0.42; halos[k].Opacity = ici ? 1 : 0; lueurs[k].Opacity = ici ? 1 : 0;
        }
    }
}

/// L'avancement d'une tâche (`TacheView`) : une pastille en bas à droite, sur la ligne des aides. Un anneau qui se remplit, le nom de la
/// tâche en capitales, où elle en est, le pourcentage. Elle arrive en montant, repart en fondu.
sealed class PastilleTache : Border
{
    readonly Anneau anneau = new() { Width = 44, Height = 44, Epaisseur = 4, Piste = U.Blanc(0.16), RenderTransformOrigin = U.Centre };
    readonly Panel symbole = new() { Width = 44, Height = 44 }; readonly TextBlock titre, etape, pourcent;
    Tache? montree; CancellationTokenSource? tourne; string etat = ""; public Action? Clic;
    public PastilleTache()
    {
        Height = 68; CornerRadius = new CornerRadius(34); Padding = new Thickness(10, 0, 22, 0); Background = new SolidColorBrush(Color.FromArgb(215, 84, 84, 88)); BorderThickness = new Thickness(1); BorderBrush = U.Blanc(0.16);
        BoxShadow = BoxShadows.Parse("0 10 22 0 #66000000"); HorizontalAlignment = HorizontalAlignment.Right; VerticalAlignment = VerticalAlignment.Bottom; Margin = new Thickness(0, 0, 84, 30);
        Opacity = 0; IsHitTestVisible = false; RenderTransform = Mouvement.Deplace(0, 16); Cursor = new Cursor(StandardCursorType.Hand);
        PointerPressed += (_, e) => { e.Handled = true; Clic?.Invoke(); };   // la carte ouvre son menu : avancement, journal, arrêter
        anneau.Transitions = new Transitions { new DoubleTransition { Property = Anneau.FractionProperty, Duration = Mouvement.S(0.9), Easing = new CubicEaseInOut() } };
        titre = U.Titre("", 13, 1); etape = U.Texte("", 14, FontWeight.Medium, 0.7); etape.MaxWidth = 380; etape.TextTrimming = TextTrimming.CharacterEllipsis; titre.MaxWidth = 380;
        pourcent = new TextBlock { FontSize = 20, FontWeight = FontWeight.Black, FontFamily = U.PoliceLarge, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
        var textes = U.Colonne(3, titre, etape); textes.VerticalAlignment = VerticalAlignment.Center;
        Child = U.Ligne(14, new Panel { Width = 44, Height = 44, Children = { anneau, symbole } }, textes, pourcent);
    }
    public void Mettre(Tache? t)
    {
        if (t == null)
        {
            IsHitTestVisible = false;
            if (montree != null) { montree = null; Transitions = new Transitions { Mouvement.Opacite(0.5, new CubicEaseInOut()) }; Opacity = 0; }   // elle part en fondu, sans bouger
            return;
        }
        if (t != montree)
        {   // une nouvelle tâche : la pastille arrive en montant
            montree = t; etat = ""; IsHitTestVisible = true;
            Mouvement.SansAnimer(this, () => { Opacity = 0; RenderTransform = Mouvement.Deplace(0, 16); });
            Mouvement.SansAnimer(anneau, () => anneau.Fraction = 0);
            Transitions = new Transitions { Mouvement.Opacite(0.6), Mouvement.Transfo(0.6, new SplineEasing(0.2, 0.9, 0.2, 1)) };
            Mouvement.Apres(() => { if (montree == t) { Opacity = 1; RenderTransform = Mouvement.Deplace(0, 0); } });
        }
        var echec = t.Erreur != null; var teinte = echec ? Icones.Orange : t.Fini ? Icones.Vert : Colors.White; var couleur = new SolidColorBrush(teinte);
        titre.Text = t.Titre.ToUpper(); etape.Text = t.Erreur ?? t.Etape;
        pourcent.IsVisible = !t.Fini && t.Fraction != null; if (t.Fraction is { } f) pourcent.Text = $"{(int)Math.Round(Math.Clamp(f, 0, 1) * 100)} %";
        BorderBrush = t.Fini ? new SolidColorBrush(teinte, 0.55) : U.Blanc(0.16);
        var nouvel = echec ? "echec" : t.Fini ? "fini" : t.Fraction == null ? "vague" : "mesure";
        if (nouvel != etat)
        {
            etat = nouvel; symbole.Children.Clear(); symbole.Children.Add(U.Icone(echec ? "exclamationmark" : t.Fini ? "checkmark" : "arrow.down", 18, couleur));
            tourne?.Cancel(); tourne = null; anneau.RenderTransform = null;
            if (nouvel == "vague")
            {   // pas de mesure : un arc de 28 % qui fait un tour en 1,1 s, sans fin
                Mouvement.SansAnimer(anneau, () => anneau.Fraction = 0.28);
                anneau.RenderTransform = new RotateTransform();
                tourne = Mouvement.Boucle(anneau, 1.1, false, new LinearEasing(), (RotateTransform.AngleProperty, 0d, 360d));
            }
        }
        anneau.Couleur = couleur;
        if (nouvel != "vague") anneau.Fraction = t.Fini ? 1 : Math.Max(0.02, Math.Clamp(t.Fraction ?? 0, 0, 1));
    }
}

/// L'installation du moteur en plein écran (`InstallationView` sur Mac), comme la mise en route d'une console : un titre qui dit ce qui
/// s'installe, un grand anneau blanc avec le pourcentage, et à côté de grands titres cochés un à un. Rien d'autre n'est accessible.
/// Sur Windows il n'y a qu'un moteur à installer (ScarletNX) : deux titres, son téléchargement puis sa mise en place.
sealed class InstallationVue : Panel
{
    static readonly (string nom, string cle, string etape)[] groupes =
        [("Téléchargement", "Téléchargement", "ScarletNX, le moteur des jeux Switch"), ("Mise en place", "Installation", "Vérification et installation")];
    readonly Bibliotheque lib; readonly DateTime debut = DateTime.Now; Tache? tache; int rang; string cle = "";
    readonly Anneau anneau = new() { Width = 380, Height = 380, Epaisseur = 10, Piste = U.Blanc(0.12) };
    readonly Panel centre = new() { Width = 380, Height = 380 };
    readonly TextBlock titre = U.Titre("Installation des moteurs", 46, 4), phrase = U.Texte("", 24, FontWeight.Medium, 0.6), reste = U.Texte(" ", 21, FontWeight.Medium, 0.55);
    readonly TextBlock nombre = new() { FontSize = 120, FontWeight = FontWeight.SemiBold, FontFamily = U.Police, Foreground = Brushes.White };
    readonly StackPanel liste = new() { Spacing = 38, Width = 540, VerticalAlignment = VerticalAlignment.Center }, aides, contenu;
    Border? barre; readonly DispatcherTimer seconde = new() { Interval = TimeSpan.FromSeconds(1) };

    public InstallationVue(Bibliotheque lib)
    {
        this.lib = lib; Background = new SolidColorBrush(Color.FromRgb(5, 5, 13));
        // une seule lueur, basse et discrète ; pas de dégradé de couleurs
        Children.Add(Avec(U.Lueur(Color.FromRgb(84, 43, 204), 1500, 0.22), l => { l.VerticalAlignment = VerticalAlignment.Center; l.HorizontalAlignment = HorizontalAlignment.Center; l.RenderTransform = new TranslateTransform(0, 320); }));
        anneau.Transitions = new Transitions { new DoubleTransition { Property = Anneau.FractionProperty, Duration = Mouvement.S(0.9), Easing = new CubicEaseInOut() } };
        centre.Children.Add(anneau);
        titre.HorizontalAlignment = phrase.HorizontalAlignment = reste.HorizontalAlignment = HorizontalAlignment.Center; phrase.Margin = new Thickness(0, 16, 0, 0); phrase.TextAlignment = TextAlignment.Center; phrase.MaxWidth = 1100; phrase.TextWrapping = TextWrapping.Wrap;
        aides = U.Ligne(12, U.Pilule(lib.Aides.Ok, "Réessayer"), U.Pilule(lib.Aides.Retour, "Continuer sans")); aides.HorizontalAlignment = HorizontalAlignment.Center; aides.Margin = new Thickness(0, 60, 0, 0); aides.Opacity = 0;
        aides.Transitions = new Transitions { Mouvement.Opacite(0.5, new CubicEaseInOut()) };
        var milieu = U.Ligne(120, U.Colonne(30, centre, reste), liste); milieu.HorizontalAlignment = HorizontalAlignment.Center; milieu.Margin = new Thickness(0, 84, 0, 0);
        contenu = U.Colonne(0, titre, phrase, milieu, aides); contenu.VerticalAlignment = VerticalAlignment.Center; contenu.HorizontalAlignment = HorizontalAlignment.Center;
        contenu.Opacity = 0; contenu.RenderTransform = Mouvement.Deplace(0, 18);
        contenu.Transitions = new Transitions { Mouvement.Opacite(0.7, new SplineEasing(0.2, 0.8, 0.2, 1)), Mouvement.Transfo(0.7, new SplineEasing(0.2, 0.8, 0.2, 1)) };
        Children.Add(contenu);
        Opacity = 0; Transitions = new Transitions { Mouvement.Opacite(0.35, new CubicEaseInOut()) };
        PointerPressed += (_, e) => e.Handled = true;   // rien dessous n'est cliquable
        AttachedToVisualTree += (_, _) => Mouvement.Apres(() => { Opacity = 1; contenu.Opacity = 1; contenu.RenderTransform = Mouvement.Deplace(0, 0); });
        seconde.Tick += (_, _) => Restant(); seconde.Start(); DetachedFromVisualTree += (_, _) => seconde.Stop();
    }
    /// La bibliothèque revient en fondu
    public void Partir() { IsHitTestVisible = false; Transitions = new Transitions { Mouvement.Opacite(0.6, new CubicEaseInOut()) }; Opacity = 0; }

    public void Mettre(Tache t)
    {
        tache = t;
        bool echec = t.Erreur != null, fini = t.Fini && !echec;
        var i = Array.FindLastIndex(groupes, g => t.Etape.StartsWith(g.cle)); if (i > rang) rang = i;   // une étape sans titre ne fait pas reculer
        var fr = fini ? 1 : Math.Min(0.995, Math.Max(0, t.Fraction ?? 0));
        anneau.Fraction = Math.Max(0.01, fr); anneau.Couleur = echec ? new SolidColorBrush(Icones.Orange) : Brushes.White;
        nombre.Text = ((int)(fr * 100)).ToString();
        var nouvelle = $"{rang}{echec}{fini}";
        if (nouvelle != cle)
        {
            cle = nouvelle;
            titre.Text = echec ? "INSTALLATION INTERROMPUE" : fini ? "MOTEURS INSTALLÉS" : "INSTALLATION DES MOTEURS";
            phrase.Text = echec ? "Vérifie la connexion à Internet, puis réessaie." : "Home installe le moteur des jeux Switch : ce qui fait tourner tes jeux sur ce PC.";
            aides.Opacity = echec ? 1 : 0;
            while (centre.Children.Count > 1) centre.Children.RemoveAt(1);
            if (echec) centre.Children.Add(U.Icone("exclamationmark", 110, new SolidColorBrush(Icones.Orange)));
            else if (fini) centre.Children.Add(U.Icone("checkmark", 110));
            else centre.Children.Add(Avec(U.Ligne(4, nombre, Avec(U.Texte("%", 42, FontWeight.SemiBold, 0.5), p => { p.VerticalAlignment = VerticalAlignment.Bottom; p.Margin = new Thickness(0, 0, 0, 24); })), l => { l.HorizontalAlignment = HorizontalAlignment.Center; l.VerticalAlignment = VerticalAlignment.Center; }));
            liste.Children.Clear(); barre = null;
            for (var g = 0; g < groupes.Length; g++)
            {
                bool fait = fini || rang > g, dedans = !fini && rang == g, enCours = dedans && !echec, rate = dedans && echec;
                // coche pleine = fait, cercle pointillé = en cours, cercle pâle = à venir
                Control pastille = fait ? new Panel { Children = { new Ellipse { Width = 34, Height = 34, Fill = Brushes.White }, U.Icone("checkmark", 18, Brushes.Black) } }
                    : rate ? new Panel { Children = { new Ellipse { Width = 34, Height = 34, Fill = new SolidColorBrush(Icones.Orange) }, U.Icone("exclamationmark", 18, Brushes.Black) } }
                    : new Ellipse { Width = 34, Height = 34, Stroke = U.Blanc(enCours ? 1 : 0.28), StrokeThickness = 3, StrokeDashArray = enCours ? [0.3, 2.2] : null, StrokeLineCap = PenLineCap.Round };
                pastille.Width = 40; pastille.VerticalAlignment = VerticalAlignment.Top; pastille.Margin = new Thickness(0, 2, 0, 0);
                var nom = new TextBlock { Text = groupes[g].nom, FontSize = 32, FontWeight = enCours || rate ? FontWeight.Bold : FontWeight.SemiBold, FontFamily = U.Police, Foreground = rate ? new SolidColorBrush(Icones.Orange) : Brushes.White, Opacity = fait ? 0.6 : enCours || rate ? 1 : 0.32 };
                var textes = U.Colonne(5, nom);
                if (enCours)
                {   // le détail du titre en cours : quelle étape, laquelle sur combien, et une barre fine quand l'avancement réel est connu
                    textes.Children.Add(U.Texte($"{groupes[g].etape} · 1 sur 1", 19, FontWeight.Medium, 0.55));
                    if (g == 0)
                    {
                        barre = new Border { Width = 420, Height = 6, Background = Brushes.White, HorizontalAlignment = HorizontalAlignment.Left, RenderTransformOrigin = new RelativePoint(0, 0.5, RelativeUnit.Relative), RenderTransform = Mouvement.Echelle(0.015, 1) };
                        barre.Transitions = new Transitions { Mouvement.Transfo(0.6, new CubicEaseInOut()) };
                        textes.Children.Add(new Border { Width = 420, Height = 6, CornerRadius = new CornerRadius(3), ClipToBounds = true, Background = U.Blanc(0.14), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0), Child = barre });
                    }
                }
                if (rate && t.Erreur is { } raison) textes.Children.Add(new TextBlock { Text = raison, FontSize = 19, FontWeight = FontWeight.Medium, FontFamily = U.Police, Foreground = new SolidColorBrush(Icones.Orange), MaxWidth = 460, MaxLines = 3, TextWrapping = TextWrapping.Wrap });
                liste.Children.Add(U.Ligne(20, pastille, textes));
            }
        }
        // la barre suit le téléchargement lui-même (Moteur.Preparer compte 90 % de la tâche pour lui)
        if (barre != null && t.Fraction is { } f) barre.RenderTransform = Mouvement.Echelle(Math.Clamp(f / 0.9, 0.015, 1), 1);
        Restant();
    }
    void Restant()
    {
        if (tache is not { } t) return;
        if (t.Erreur != null) { reste.Text = " "; return; }
        if (t.Fini) { reste.Text = "Tout est prêt"; return; }
        var passe = (DateTime.Now - debut).TotalSeconds;
        if (t.Fraction is not { } f || f < 0.02 || passe < 8) { reste.Text = "Estimation du temps restant…"; return; }
        var r = passe * (1 - f) / f; reste.Text = r < 10 ? "Presque fini" : r < 60 ? "Moins d'une minute" : $"Environ {(int)Math.Ceiling(r / 60)} min";
    }
    static T Avec<T>(T c, Action<T> a) { a(c); return c; }
}

/// L'écran : le fond, la bibliothèque (onglets, nom du jeu, pile de rangées, aides), puis par-dessus les menus, la tâche, « en cours de
/// jeu », les messages, la saisie et l'écran de démarrage (`Screen` sur Mac).
public sealed class Ecran : Panel
{
    readonly Bibliotheque lib;
    readonly FondVue fond = new();
    readonly Grid contenu = new() { RowDefinitions = new RowDefinitions("Auto,*,Auto,Auto,Auto") };
    readonly Panel scene = new();   // le fond et la bibliothèque : ce qu'un menu recouvre
    readonly Image voile = new() { Stretch = Stretch.Fill, Opacity = 0, IsHitTestVisible = false };
    bool voilee, sousVoile, sousJeu; int onglet = -1;
    readonly StackPanel onglets = new() { Orientation = Orientation.Horizontal, Spacing = 10 }, droite = new() { Orientation = Orientation.Horizontal, Spacing = 10 };
    readonly TextBlock heure = new() { FontSize = 26, FontWeight = FontWeight.SemiBold, FontFamily = U.Police, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
    readonly Echange infos = new() { Margin = new Thickness(84, 0, 84, 22) };
    readonly Panel pile = new() { Height = 294 };
    readonly StackPanel aides = new() { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(84, 0, 84, 40) };
    readonly Panel coucheMenu = new(), coucheJeu = new() { Opacity = 0, IsHitTestVisible = false }, coucheSaisie = new() { Opacity = 0, IsHitTestVisible = false }, coucheBienvenue = new(), coucheOuverture = new();
    readonly PastilleTache pastille = new();
    readonly Border toast = new() { Opacity = 0, IsHitTestVisible = false, Padding = new Thickness(20, 12), CornerRadius = new CornerRadius(24), Background = U.Noir(0.6), BorderBrush = U.Blanc(0.16), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 84, 30), MaxWidth = 640, MinHeight = 52 };
    readonly TextBlock texteToast = U.Texte("", 16, FontWeight.SemiBold);
    readonly DispatcherTimer horloge = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly List<RangeeJeux> rangees = new(); readonly List<int?> ecarts = new(); readonly List<(TextBlock texte, Border trait)> vuesOnglets = new();
    readonly List<CancellationTokenSource> boucles = new();
    string cleCategories = "?", cleInfos = "?", cleAides = "?", cleJeu = "", cleBatterie = "?", jeuInfos = "?"; Menu? menuMontre; VueMenu? vueMenu; DateTime menuVu = DateTime.MinValue; Saisie? saisieMontree; TextBlock? duree; Ouverture? ouverture;

    public Ecran(Bibliotheque lib)
    {
        this.lib = lib; ClipToBounds = true; Background = Brushes.Black;
        var haut = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Thickness(84, 44, 84, 0) };
        droite.Children.Add(heure); haut.Children.Add(onglets); Grid.SetColumn(droite, 1); haut.Children.Add(droite);
        Grid.SetRow(infos, 2); Grid.SetRow(pile, 3); Grid.SetRow(aides, 4);
        contenu.Children.AddRange([haut, infos, pile, aides]);
        scene.Children.AddRange([fond, contenu]);
        RenderOptions.SetBitmapInterpolationMode(voile, BitmapInterpolationMode.HighQuality); voile.Transitions = new Transitions { Mouvement.Opacite(0.35, new CubicEaseInOut()) };
        // l'arrivée de la bibliothèque : la pile de rangées monte de 36 en apparaissant
        pile.Opacity = 0; pile.RenderTransform = Mouvement.Deplace(0, 36);
        pile.Transitions = new Transitions { Mouvement.Transfo(0.45, Mouvement.Glisse), Mouvement.Opacite(0.45, Mouvement.Glisse) };
        pile.AttachedToVisualTree += (_, _) => Mouvement.Dans(0.1, () => { pile.Opacity = 1; pile.RenderTransform = Mouvement.Deplace(0, 0); });
        // le message : en bas à droite, un point blanc devant, au-dessus de la carte d'une tâche quand il y en a une
        texteToast.TextWrapping = TextWrapping.Wrap; texteToast.MaxLines = 2; texteToast.MaxWidth = 570; texteToast.VerticalAlignment = VerticalAlignment.Center;
        toast.Padding = new Thickness(22, 8); toast.CornerRadius = new CornerRadius(26);
        toast.Child = U.Ligne(12, new Ellipse { Width = 8, Height = 8, Fill = Brushes.White, VerticalAlignment = VerticalAlignment.Center }, texteToast);
        toast.Transitions = new Transitions { Mouvement.Opacite(0.3, new CubicEaseInOut()), Mouvement.Transfo(0.4, new SplineEasing(0.2, 0.8, 0.2, 1)) };
        pastille.Clic = () => { if (lib.Menu == null && lib.EnCours == null) lib.OuvrirTacheMenu(); };
        coucheJeu.Transitions = new Transitions { Mouvement.Opacite(0.35, new CubicEaseInOut()) }; coucheSaisie.Transitions = new Transitions { Mouvement.Opacite(0.2) };
        // l'installation recouvre tout, messages compris : seuls une saisie et l'écran de démarrage passent devant
        Children.AddRange([scene, voile, coucheBienvenue, coucheMenu, pastille, coucheJeu, toast, coucheInstallation, coucheSaisie, coucheOuverture]);
        lib.Change += Rafraichir;
        lib.PasserOuverture = () => ouverture?.Passer() ?? false;
        horloge.Tick += (_, _) => Seconde(); horloge.Start();
        Rafraichir();
    }
    /// L'écran est remplacé (« Animations réduites » change toutes les durées) : il ne doit plus suivre la bibliothèque
    public void Detacher() { lib.Change -= Rafraichir; horloge.Stop(); foreach (var b in boucles) b.Cancel(); }

    /// L'écran de démarrage, avec le jingle. `fige` : son image d'arrivée, immobile (pour les captures).
    public void Ouvrir(bool fige = false)
    {
        coucheOuverture.Children.Clear();
        ouverture = new Ouverture(fige); var o = ouverture;
        o.Finie += () => { coucheOuverture.Children.Remove(o); if (ouverture == o) ouverture = null; Rafraichir(); };
        coucheOuverture.Children.Add(o);
        if (!fige) lib.Son("lancer");
    }

    void Seconde()
    {
        var h = DateTime.Now.ToString("HH:mm"); if (heure.Text != h) heure.Text = h;
        if (duree != null && lib.EnCours != null) { var s = (int)(DateTime.Now - lib.EnCoursDepuis).TotalSeconds; duree.Text = $"{s / 3600}:{s % 3600 / 60:00}:{s % 60:00}"; }
    }

    void Rafraichir()
    {
        var visibles = lib.Visibles; var j = lib.Selection < visibles.Count ? visibles[lib.Selection] : null; var art = j != null ? lib.Arts.GetValueOrDefault(j.Id) : null;
        fond.Montrer(j == null ? "+" : j.Id + (art?.Fond != null ? "f" : art?.Couverture != null ? "c" : ""), art?.Fond ?? art?.Couverture, art?.Fond == null);
        Haut(); Infos(j, art); Pile(); Aides(j);
        Menus();
        Voiler(lib.Menu != null || lib.Saisie != null);
        Jeu(); pastille.Mettre(lib.Tache); Toast(); MontrerSaisie(); Bienvenue(); Installation();
    }
    /// L'installation du moteur : tout l'écran tant qu'elle dure ; à la fin la bibliothèque revient en fondu
    InstallationVue? installation; readonly Panel coucheInstallation = new();
    void Installation()
    {
        if (lib.Installation)
        {
            if (installation == null) { installation = new InstallationVue(lib); coucheInstallation.Children.Add(installation); }
            if (lib.Tache is { } t) installation.Mettre(t);
        }
        else if (installation is { } i) { installation = null; i.Partir(); Mouvement.Dans(0.7, () => coucheInstallation.Children.Remove(i)); }
    }
    /// L'accueil du premier lancement : posé dès le début, il est là quand l'écran de démarrage s'efface ; il part quand le choix est fait
    BienvenueVue? bienvenue;
    void Bienvenue()
    {
        if (lib.Bienvenue && bienvenue == null) { bienvenue = new BienvenueVue(lib); coucheBienvenue.Children.Add(bienvenue); }   // tout de suite, sous l'écran de démarrage
        if (!lib.Bienvenue && bienvenue is { } b) { bienvenue = null; b.IsHitTestVisible = false; b.Opacity = 0; Mouvement.Dans(0.5, () => coucheBienvenue.Children.Remove(b)); }
        bienvenue?.Viser(lib.BienvenueIndex); bienvenue?.Effacer(lib.BienvenueFige && lib.Menu != null);
    }

    /// La bibliothèque derrière un menu est floue. Pas de flou en direct (il serait refait à chaque image tant que le menu bouge) : une
    /// photo de la bibliothèque à mi-taille, floutée une fois par Skia, qui arrive en fondu. Dessous, la bibliothèque ne se dessine plus.
    void Voiler(bool oui)
    {
        if (oui == voilee) return;
        voilee = oui;
        if (!oui) { sousVoile = false; Scene(); voile.Opacity = 0; return; }
        if (Bounds.Width > 0 && Bounds.Height > 0)
        {
            const int largeur = 960; var k = largeur / Bounds.Width;
            var hauteur = Math.Max(1, (int)(Bounds.Height * k)); var photo = new RenderTargetBitmap(new PixelSize(largeur, hauteur));
            using (var dessin = photo.CreateDrawingContext()) dessin.FillRectangle(new VisualBrush { Visual = scene, Stretch = Stretch.Fill }, new Rect(0, 0, largeur, hauteur));
            var ancienne = voile.Source as IDisposable; voile.Source = U.Flouter(photo, largeur, 9f) is { } floue ? floue : photo; ancienne?.Dispose();
        }
        voile.Opacity = 1;
        Mouvement.Dans(0.4, () => { if (voilee) { sousVoile = true; Scene(); } });
    }
    void Scene() => scene.IsVisible = !sousVoile && !sousJeu;

    /// Les onglets de catégorie, nus : celui en cours est blanc et souligné, les autres s'effacent. À droite, la batterie de la manette et l'heure.
    void Haut()
    {
        var cle = string.Join("|", lib.Categories);
        if (cle != cleCategories)
        {
            cleCategories = cle; onglets.Children.Clear(); vuesOnglets.Clear(); onglet = -1;
            for (var i = 0; i < lib.Categories.Count; i++)
            {
                var n = i;
                var texte = U.Titre(lib.Categories[i], 17, 1.2); texte.Margin = new Thickness(0, 9, 18, 9); texte.Transitions = new Transitions { Mouvement.Opacite(0.24, Mouvement.Glisse) };
                var trait = new Border { Width = 26, Height = 3, CornerRadius = new CornerRadius(1.5), Background = Brushes.White, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom,
                    RenderTransformOrigin = U.Gauche, RenderTransform = Mouvement.Echelle(0, 1), Transitions = new Transitions { Mouvement.Transfo(0.24, Mouvement.Glisse) } };
                var onglet = new Panel { Background = Brushes.Transparent, Children = { texte, trait } };
                onglet.PointerPressed += (_, _) => { if (lib.Menu != null || lib.EnCours != null || lib.IndexCategorie == n) return; lib.IndexCategorie = n; lib.Selection = 0; lib.Son("onglet"); lib.Signaler(); };
                vuesOnglets.Add((texte, trait)); onglets.Children.Add(onglet);
            }
            var menu = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(22), Background = U.Blanc(0.10), Child = U.Icone("ellipsis", 20) };
            menu.PointerPressed += (_, _) => { if (lib.Menu == null && lib.EnCours == null) lib.OuvrirPlus(); };
            onglets.Children.Add(menu);
        }
        if (onglet != lib.IndexCategorie) for (var i = 0; i < vuesOnglets.Count; i++) { var ici = i == lib.IndexCategorie; onglet = lib.IndexCategorie; vuesOnglets[i].texte.Opacity = ici ? 1 : 0.5; vuesOnglets[i].trait.RenderTransform = Mouvement.Echelle(ici ? 1 : 0, 1); }
        var batterie = lib.Batterie?.ToString() ?? "";
        if (batterie != cleBatterie)
        {
            cleBatterie = batterie; while (droite.Children.Count > 1) droite.Children.RemoveAt(0);
            if (lib.Batterie is { } pct) droite.Children.Insert(0, U.Ilot(U.Icone("gamecontroller", 17), U.Icone(pct < 20 ? "battery.25percent" : pct < 55 ? "battery.50percent" : "battery.100percent", 16), U.Texte(pct + " %", 14, FontWeight.SemiBold)));
        }
        Seconde();
    }

    /// Le jeu visé : sa catégorie en petites capitales, son logo (ou son nom dans l'écriture de Home), « Jouer » et les options
    void Infos(Jeu? j, Art? art)
    {
        var console = j != null ? lib.ConsoleDe(j) : default;
        var cle = (j?.Id ?? "+") + (art?.Logo != null) + lib.Aides.Ok + console.nom;
        if (cle == cleInfos) return;
        cleInfos = cle; foreach (var b in boucles) b.Cancel(); boucles.Clear();
        Control Jouer(string texte, Action action)
        {
            var lueur = new Border { CornerRadius = new CornerRadius(28), Background = Brushes.White, BoxShadow = BoxShadows.Parse("0 0 22 0 #73FFFFFF"), Opacity = 0.25 };
            var capsule = new Border { CornerRadius = new CornerRadius(28), Background = Brushes.White, Padding = new Thickness(34, 14),
                Child = U.Ligne(10, U.Touche(lib.Aides.Ok, U.Noir(0.7)), new TextBlock { Text = texte, FontSize = 20, FontWeight = FontWeight.SemiBold, FontFamily = U.Police, Foreground = Brushes.Black, VerticalAlignment = VerticalAlignment.Center }) };
            var bouton = new Panel { RenderTransformOrigin = U.Centre, RenderTransform = new ScaleTransform(1, 1), Children = { lueur, capsule } };
            bouton.PointerPressed += (_, _) => { if (lib.Menu == null && lib.EnCours == null) action(); };
            // le bouton respire : il attire l'œil sans rien demander
            if (!Mouvement.Reduit) bouton.AttachedToVisualTree += (_, _) =>
            {
                boucles.Add(Mouvement.Boucle(bouton, 1.6, true, new SineEaseInOut(), (ScaleTransform.ScaleXProperty, 1d, 1.02), (ScaleTransform.ScaleYProperty, 1d, 1.02)));
                boucles.Add(Mouvement.Boucle(lueur, 1.6, true, new SineEaseInOut(), (OpacityProperty, 0.25, 1d)));
            };
            return bouton;
        }
        var bloc = new StackPanel { Spacing = 10, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left };
        if (j == null)
        {
            bloc.Children.Add(U.Titre("Ajouter un jeu", 52, 1));
            bloc.Children.Add(Avec(U.Ligne(16, Jouer("Ajouter", lib.OuvrirAjout)), l => l.Margin = new Thickness(0, 14, 0, 0)));
        }
        else
        {
            // d'où vient le jeu : la pastille de sa console (ou de sa boutique), puis son nom en petites capitales
            bloc.Children.Add(U.Ligne(10, U.Console(console.icone, 30), new TextBlock { Text = console.nom.ToUpper(), FontSize = 15, FontWeight = FontWeight.ExtraBold, FontFamily = U.Police, LetterSpacing = 2, Foreground = Brushes.White, Opacity = 0.8, VerticalAlignment = VerticalAlignment.Center }));
            if (art?.Logo != null) bloc.Children.Add(new Image { Source = art.Logo, MaxWidth = 560, MaxHeight = 180, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left });
            else bloc.Children.Add(U.Titre(j.Nom, 52, 1, place: 1500));
            var options = new Border { Width = 54, Height = 54, CornerRadius = new CornerRadius(27), Background = U.Noir(0.4), BorderBrush = U.Blanc(0.24), BorderThickness = new Thickness(1.5), Child = U.Icone("ellipsis", 22), VerticalAlignment = VerticalAlignment.Center };
            options.PointerPressed += (_, _) => { if (lib.Menu == null && lib.EnCours == null) lib.OuvrirOptions(); };
            bloc.Children.Add(Avec(U.Ligne(16, Jouer(j.EnConstruction ? "Construction" : "Jouer", lib.Lancer), options), l => l.Margin = new Thickness(0, 14, 0, 0)));
        }
        // un autre jeu : son nom arrive en glissant de 28 ; le même jeu dont le logo vient d'arriver : un simple fondu
        var id = j?.Id ?? "+"; var autre = id != jeuInfos; var premier = jeuInfos == "?"; jeuInfos = id;
        infos.Montrer(bloc, premier ? 0 : 0.40, autre && j != null ? 28 : 0, 1, new CubicEaseInOut());
    }
    static T Avec<T>(T c, Action<T> a) { a(c); return c; }

    /// Les catégories sont des rangées posées l'une sous l'autre : en changer fait monter ou descendre toute la pile, et la rangée d'après
    /// se devine, floue, en bas de l'écran. La pile fait le tour : après la dernière catégorie vient la première.
    void Pile()
    {
        var n = lib.Categories.Count;
        if (rangees.Count != n)
        {
            pile.Children.Clear(); rangees.Clear(); ecarts.Clear();
            for (var c = 0; c < n; c++)
            {
                var r = new RangeeJeux(lib) { IsVisible = false, VerticalAlignment = VerticalAlignment.Top, RenderTransform = Mouvement.Deplace(0, 0) };
                r.Transitions = new Transitions { Mouvement.Transfo(0.42, Mouvement.Coule), Mouvement.Opacite(0.42, Mouvement.Coule), Mouvement.Flou(0.42, Mouvement.Coule) };
                rangees.Add(r); ecarts.Add(null); pile.Children.Add(r);
            }
        }
        for (var c = 0; c < n; c++)
        {
            int tour = ((c - lib.IndexCategorie) % n + n) % n, d = tour > n / 2 ? tour - n : tour; var r = rangees[c];
            if (Math.Abs(d) > 1) { r.IsVisible = false; ecarts[c] = null; continue; }
            r.Active = d == 0; r.Mettre(lib.JeuxDe(c), d == 0 ? lib.Selection : null, floue: false);
            if (ecarts[c] == d) continue;   // déjà à sa place
            // la rangée voisine est floue, comme sur Mac. Ce flou-là est vrai : la rangée ne bouge pas au repos, il n'est donc refait que
            // pendant un changement de catégorie. La rangée en cours n'a aucun effet (un flou de 0 se recalcule quand même à chaque image).
            void Placer()
            {
                r.RenderTransform = Mouvement.Deplace(0, d * 236); r.Opacity = d == 0 ? 1 : d == 1 ? 0.45 : 0;
                if (r.Effect == null && d != 0) Mouvement.SansAnimer(r, () => r.Effect = new BlurEffect { Radius = 0 });
                if (r.Effect != null) r.Effect = new BlurEffect { Radius = d == 0 ? 0 : 14 };
                if (d == 0) Mouvement.Dans(0.5, () => { if (r.Active) Mouvement.SansAnimer(r, () => r.Effect = null); });
            }
            // une rangée qui n'était pas là, ou qui passe d'un bout à l'autre de la pile, prend sa place d'un coup : elle ne traverse pas l'écran
            if (ecarts[c] is { } avant && Math.Abs(avant - d) <= 1) Placer(); else Mouvement.SansAnimer(r, Placer);
            r.IsVisible = true; r.IsHitTestVisible = d == 0; r.ZIndex = d == 0 ? 1 : 0; ecarts[c] = d;
        }
    }

    void Aides(Jeu? j)
    {
        var cle = lib.Aides.Ok + lib.Aides.Cat + (j == null) + (j?.EnConstruction == true);
        if (cle == cleAides) return;
        cleAides = cle; aides.Children.Clear();
        aides.Children.Add(U.Pilule(lib.Aides.Ok, j == null ? "Ajouter" : j.EnConstruction ? "Construction" : "Jouer"));
        if (j != null) aides.Children.Add(U.Pilule(lib.Aides.Options, "Options"));
        aides.Children.Add(U.Pilule(lib.Aides.Plus, "Menu")); aides.Children.Add(U.Pilule(lib.Aides.Cat, "Catégorie"));
    }

    /// Le menu : le nouveau est là tout de suite, l'ancien s'efface dessous. La bibliothèque ne réapparaît pas entre les deux.
    void Menus()
    {
        if (lib.Menu != menuMontre)
        {
            var ancien = vueMenu; var m = lib.Menu;
            // le même menu relu (un réglage qu'on vient de changer) : il ne rejoue pas son arrivée
            var meme = ancien != null && m != null && ancien.Menu.Titre == m.Titre && ancien.Menu.SousTitre == m.SousTitre && ancien.Menu.Genre == m.Genre;
            if (ancien != null)
            {
                menuVu = DateTime.Now;
                if (meme) coucheMenu.Children.Remove(ancien);
                else { ancien.IsHitTestVisible = false; ancien.Opacity = 0; Mouvement.Dans(0.27, () => coucheMenu.Children.Remove(ancien)); }
            }
            vueMenu = null; menuMontre = m;
            if (m != null)
            {
                vueMenu = new VueMenu(lib, m, arrivee: !meme, fonduDuFond: ancien == null && (DateTime.Now - menuVu).TotalSeconds > 0.4, sens: lib.SensMenu);
                vueMenu.Viser(lib.IndexMenu);
                coucheMenu.Children.Add(vueMenu);
            }
        }
        vueMenu?.Viser(lib.IndexMenu);
    }

    /// Home pendant une partie (`NowPlayingView`) : le fond du jeu très assombri et flouté, sa jaquette au centre, son nom, la durée
    void Jeu()
    {
        var cle = lib.EnCours?.Id ?? "";
        if (cle == cleJeu) return;
        cleJeu = cle; duree = null;
        if (lib.EnCours is not { } j)
        {   // la partie est finie : l'écran s'efface, la bibliothèque reprend ses mouvements
            sousJeu = false; Scene(); coucheJeu.Opacity = 0; coucheJeu.IsHitTestVisible = false;
            Mouvement.Dans(0.45, () => { if (lib.EnCours == null) coucheJeu.Children.Clear(); });
            return;
        }
        coucheJeu.Children.Clear();
        var art = lib.Arts.GetValueOrDefault(j.Id);
        coucheJeu.Children.Add(new Border { Background = Brushes.Black });
        if ((art?.Fond ?? art?.Couverture) is { } bg) coucheJeu.Children.Add(Avec(U.ImageFloue(bg), i => i.Opacity = 0.22));
        var jaquette = new Border { Width = 300, Height = 300, CornerRadius = new CornerRadius(40), ClipToBounds = true, Background = U.Degrade(Color.FromRgb(56, 56, 56), Color.FromRgb(20, 20, 20), false),
            Child = art?.Couverture != null ? new Image { Source = art.Couverture, Stretch = Stretch.UniformToFill } : null };
        var cadre = new Panel { Width = 300, Height = 300, HorizontalAlignment = HorizontalAlignment.Center, Children = { new Border { CornerRadius = new CornerRadius(40), Background = Brushes.Black, BoxShadow = BoxShadows.Parse("0 20 40 0 #B3000000, 0 0 60 0 #1FFFFFFF") }, jaquette } };
        Control nom = art?.Logo != null ? new Image { Source = art.Logo, MaxWidth = 420, MaxHeight = 120, Stretch = Stretch.Uniform } : U.Titre(j.Nom, 42, 1, place: 1500);
        nom.HorizontalAlignment = HorizontalAlignment.Center;
        duree = U.Texte("0:00:00", 17, FontWeight.Medium, 0.75);
        var etat = U.Ligne(12, new Border { Width = 9, Height = 9, CornerRadius = new CornerRadius(4.5), Background = new SolidColorBrush(Icones.Vert), BoxShadow = BoxShadows.Parse("0 0 6 0 #CC30D158"), VerticalAlignment = VerticalAlignment.Center }, duree);
        etat.HorizontalAlignment = HorizontalAlignment.Center;
        coucheJeu.Children.Add(Avec(U.Colonne(26, cadre, nom, etat), c => c.VerticalAlignment = VerticalAlignment.Center));
        var bas = U.Pilule(lib.Aides.Ok, "Home revient tout seul quand tu quittes le jeu"); ((StackPanel)bas.Child!).Children.RemoveAt(0);
        bas.Opacity = 0.7; bas.HorizontalAlignment = HorizontalAlignment.Center; bas.VerticalAlignment = VerticalAlignment.Bottom; bas.Margin = new Thickness(0, 0, 0, 44);
        coucheJeu.Children.Add(bas);
        coucheJeu.IsHitTestVisible = true; Mouvement.Apres(() => { if (lib.EnCours != null) coucheJeu.Opacity = 1; });
        // derrière le jeu, plus rien ne bouge : le zoom du fond et le bouton qui respire ne tournent pas pendant toute la partie
        Mouvement.Dans(0.5, () => { if (lib.EnCours != null) { sousJeu = true; Scene(); } });
    }

    void Toast()
    {
        var haut = lib.Tache != null ? -82 : 0;   // la carte de la tâche fait 68 de haut
        if (lib.Toast is { } t) { texteToast.Text = t; toast.Opacity = 1; toast.RenderTransform = Mouvement.Deplace(0, haut); }
        else if (toast.Opacity != 0) { toast.Opacity = 0; }   // le texte reste pendant qu'il s'efface
    }

    /// Une question au clavier (recherche, clé, nouveau nom) : Entrée valide, Échap annule
    void MontrerSaisie()
    {
        if (lib.Saisie == saisieMontree) return;
        saisieMontree = lib.Saisie;
        if (saisieMontree is not { } s) { coucheSaisie.Opacity = 0; coucheSaisie.IsHitTestVisible = false; Mouvement.Dans(0.25, () => { if (lib.Saisie == null) coucheSaisie.Children.Clear(); }); return; }
        coucheSaisie.Children.Clear();
        var champ = new TextBox { FontSize = 24, FontFamily = U.Police, Padding = new Thickness(22, 14), CornerRadius = new CornerRadius(28), Watermark = s.Aide, Text = s.Texte, Background = U.Noir(0.7), BorderBrush = U.Blanc(0.95), BorderThickness = new Thickness(3), Width = 760, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var etat in new[] { "", "PointerOver", "Focused" }) { champ.Resources["TextControlBorderBrush" + etat] = U.Blanc(0.95); champ.Resources["TextControlBackground" + etat] = U.Noir(0.7); }   // pas le bleu de Windows : le blanc de Home
        champ.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; lib.ValiderSaisie(champ.Text ?? ""); } };
        coucheSaisie.Children.Add(new Border { Background = U.Degrade(0, 0.5, 1, 0.5, (U.NoirA(0.92), 0), (U.NoirA(0.80), 0.5), (U.NoirA(0.62), 1)) });
        coucheSaisie.Children.Add(Avec(U.Colonne(26, U.Titre(s.Titre, 38, 1, place: 1500), champ, U.Ligne(12, U.Pilule(lib.Aides.Ok, "Valider"), U.Pilule(lib.Aides.Retour, "Annuler"))),
            c => { c.VerticalAlignment = VerticalAlignment.Center; c.HorizontalAlignment = HorizontalAlignment.Left; c.Margin = new Thickness(96, 0, 96, 0); }));
        coucheSaisie.IsHitTestVisible = true; coucheSaisie.Opacity = 1; lib.TexteSaisie = () => champ.Text ?? "";
        Dispatcher.UIThread.Post(() => { champ.Focus(); champ.SelectAll(); }, DispatcherPriority.Background);
    }
}
