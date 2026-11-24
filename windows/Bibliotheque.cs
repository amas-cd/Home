// Home pour Windows — la bibliothèque : l'état de l'interface, la navigation, le lancement des jeux et tous les menus.
// L'équivalent de `Library` dans app/main.swift. Tout se passe sur le fil de l'interface ; le travail long revient par Dispatcher.
using System.Diagnostics;
using System.Reflection;
using Avalonia.Threading;

namespace Home;

public sealed class Bibliotheque
{
    public event Action? Change;
    public Config Config = Json.Lire<Config>(FichierConfig);
    public Dictionary<string, Stat> Stats = Json.Lire<Dictionary<string, Stat>>(FichierStats);
    public List<Jeu> Jeux = new();
    public readonly Dictionary<string, Art> Arts = new();
    public List<string> Categories = ["Tous"];
    public int IndexCategorie, Selection, IndexMenu;
    public Menu? Menu; public Saisie? Saisie; public string? Toast; public Tache? Tache;
    public Jeu? EnCours; public DateTime EnCoursDepuis;
    public Aides Aides = Aides.Clavier; public int? Batterie;
    // Ce que seule la fenêtre sait faire
    public Func<string, string[], Task<string?>>? ChoisirFichier; public Func<string, Task<string?>>? ChoisirDossier; public Func<Task<string?>>? PressePapiers;
    public Action? Devant, AppliquerFenetre, Quitter, Reconstruire;
    /// L'écran de démarrage est-il là ? Si oui, l'appui le passe et ne va pas plus loin.
    public Func<bool>? PasserOuverture;
    /// 1 = on entre dans un menu (il arrive par la droite), −1 = on revient au précédent (il arrive par la gauche)
    public double SensMenu = 1;
    public const int ColonnesGrille = 5;
    readonly Dictionary<string, int> derniers = new();   // le dernier choix visé de chaque menu : on le retrouve en y revenant

    static string FichierConfig => Dossiers.Fichier("jeux.json");
    static string FichierStats => Dossiers.Fichier("statistiques.json");
    public static readonly bool Demo = Environment.GetEnvironmentVariable("HOME_DEMO") == "1";
    public static string Version => Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0.0.0";

    public void Signaler() => Change?.Invoke();
    public void Son(string nom) => Sons.Jouer(nom);
    public void Enregistrer() => Json.Ecrire(FichierConfig, Config);

    // MARK: Bibliothèque
    /// Les jeux de la catégorie choisie : le dernier joué d'abord, puis par nom
    public List<Jeu> Visibles => JeuxDe(IndexCategorie);
    public List<Jeu> JeuxDe(int categorie) => Jeux.Where(j => !Config.Masques.Contains(j.Id) && (categorie == 0 || j.Categorie == Categories.ElementAtOrDefault(categorie)))
        .OrderByDescending(j => Stats.TryGetValue(j.Id, out var s) ? s.DernierePartie ?? DateTime.MinValue : DateTime.MinValue).ThenBy(j => j.Nom, StringComparer.CurrentCultureIgnoreCase).ToList();
    public Jeu? Courant { get { var v = Visibles; return Selection < v.Count ? v[Selection] : null; } }
    /// D'où vient un jeu, pour l'afficher à côté de son nom : sa console, ou sa boutique. L'icône est un logo (« logo:switch »,
    /// « logo:steam », « logo:epic » : les images de app/logos) ou un symbole.
    public (string nom, string icone) ConsoleDe(Jeu j) => j.Origine switch
    {
        Origine.Steam => ("Steam", "logo:steam"), Origine.Epic => ("Epic Games", "logo:epic"),
        Origine.Switch => j.EnConstruction ? ("En construction", "hammer") : ("Nintendo Switch", "logo:switch"),
        _ => ("App Windows", "pc"),
    };

    public void Recharger(string? selectionner = null)
    {
        Sons.Actifs = Config.Sons; Mouvement.Reduit = Config.AnimationsReduites;
        var jeux = new List<Jeu>();
        jeux.AddRange(Steam.Jeux()); jeux.AddRange(Epic.Jeux()); jeux.AddRange(Construction.Jeux());
        // un jeu en construction a déjà sa tuile : on voit où il en est, et on le reprend si c'est coupé
        foreach (var c in Construction.Chantiers()) jeux.Add(new Jeu { Id = c.Id, Nom = c.Titre, Origine = Origine.Switch });
        if (Demo) jeux.AddRange(Exemples());
        foreach (var e in Config.Jeux.Where(e => Demo || File.Exists(e.Chemin)))
            jeux.Add(new Jeu { Id = "app:" + e.Chemin, Nom = e.Nom ?? Path.GetFileNameWithoutExtension(e.Chemin), Origine = Origine.App, Cible = e.Chemin, Dossier = Path.GetDirectoryName(e.Chemin) ?? "" });
        foreach (var j in jeux) if (Config.Noms.TryGetValue(j.Id, out var n)) j.Nom = n;
        var avant = selectionner ?? Courant?.Id; var categorie = Categories.ElementAtOrDefault(IndexCategorie);
        Jeux = jeux;
        Categories = ["Tous", .. new[] { "Switch", "Steam", "Epic Games", "Apps" }.Where(c => jeux.Any(j => j.Categorie == c && !Config.Masques.Contains(j.Id)))];
        IndexCategorie = selectionner != null ? 0 : Math.Max(0, Categories.IndexOf(categorie ?? "Tous"));
        var i = Visibles.FindIndex(j => j.Id == avant); Selection = i >= 0 ? i : Math.Min(Selection, Visibles.Count);
        Journal.Ecrire($"bibliothèque : {jeux.Count(j => j.Origine == Origine.Steam)} Steam, {jeux.Count(j => j.Origine == Origine.Epic)} Epic, {jeux.Count(j => j.Origine == Origine.Switch)} Switch, {jeux.Count(j => j.Origine == Origine.App)} apps");
        foreach (var j in jeux) if (!Arts.ContainsKey(j.Id)) ChargerArt(j);
        Signaler();
    }
    public async void ChargerArt(Jeu j)
    {
        var art = await Images.Charger(j);
        Arts[j.Id] = art; Signaler();
    }

    // MARK: Navigation
    public void Nav(string k)
    {
        if (PasserOuverture?.Invoke() == true) return;
        if (Saisie != null) { if (k == "back") { Saisie = null; Son("retour"); Signaler(); } return; }
        if (EnCours != null) return;
        if (Menu != null) { NavMenu(k); return; }
        var n = Visibles.Count;
        switch (k)
        {
            case "left": if (Selection > 0) { Selection--; Son("deplacer"); Signaler(); } break;
            case "right": if (Selection < n) { Selection++; Son("deplacer"); Signaler(); } break;
            case "ok": Lancer(); break;
            case "options": if (Courant != null) OuvrirOptions(); break;
            case "plus": OuvrirPlus(); break;
            case "cat" or "catR": IndexCategorie = (IndexCategorie + 1) % Categories.Count; Selection = 0; Son("onglet"); Signaler(); break;
            case "catL": IndexCategorie = (IndexCategorie + Categories.Count - 1) % Categories.Count; Selection = 0; Son("onglet"); Signaler(); break;
        }
    }
    void NavMenu(string k)
    {
        var m = Menu!; var e = m.Elements; var total = e.Count;
        bool Libre(int n) => n >= 0 && n < total && !e[n].Info;
        int Suivant(int de, int pas) { for (var i = de + pas; i >= 0 && i < total; i += pas) if (!e[i].Info) return i; return de; }   // saute les lignes d'information
        var cible = IndexMenu;
        switch (k)
        {
            case "ok": if (Libre(IndexMenu)) { Son("valider"); e[IndexMenu].Action(); } return;
            case "back": Son("retour"); if (m.Retour != null) { SensMenu = -1; m.Retour(); SensMenu = 1; } else FermerMenus(); return;
            case "plus" or "options": Son("retour"); FermerMenus(); return;
        }
        switch (m.Genre)
        {
            case GenreMenu.Rangee:   // la rangée : de gauche à droite
                cible = k is "right" or "down" ? Suivant(IndexMenu, 1) : k is "left" or "up" ? Suivant(IndexMenu, -1) : IndexMenu; break;
            case GenreMenu.Grille:   // la grille d'affiches : quatre directions
                const int c = ColonnesGrille;
                if (k == "right") cible = Suivant(IndexMenu, 1);
                else if (k == "left") cible = Suivant(IndexMenu, -1);
                else if (k == "down")
                {   // la même colonne, un rang plus bas ; sur le dernier rang incomplet, la dernière affiche
                    var n = IndexMenu + c;
                    while (n < total && !Libre(n)) n += c;
                    if (n >= total && IndexMenu / c < (total - 1) / c) { n = total - 1; while (n > IndexMenu && !Libre(n)) n--; }
                    if (Libre(n)) cible = n;
                }
                else if (k == "up") { var n = IndexMenu - c; while (n >= 0 && !Libre(n)) n -= c; if (Libre(n)) cible = n; }
                break;
            default:   // la roue : de haut en bas
                cible = k == "down" ? Suivant(IndexMenu, 1) : k == "up" ? Suivant(IndexMenu, -1) : IndexMenu; break;
        }
        if (cible != IndexMenu && Libre(cible)) ViserMenu(cible, son: true);
    }
    public void Ouvrir(Menu m)
    {
        if (Menu == null) Son("ouvrir");
        Menu = m; IndexMenu = Math.Max(0, m.Elements.FindIndex(e => !e.Info));
        if (!m.Grille && derniers.TryGetValue(m.Titre, out var d) && d < m.Elements.Count && !m.Elements[d].Info) IndexMenu = d;
        Signaler();
    }
    public void FermerMenus() { Menu = null; Signaler(); }
    /// Vise un choix sans le valider (manette, clic sur un choix de la roue, souris qui passe sur une pastille)
    public void ViserMenu(int i, bool son = false)
    {
        if (Menu is not { } m || i == IndexMenu || i < 0 || i >= m.Elements.Count || m.Elements[i].Info) return;
        IndexMenu = i; derniers[m.Titre] = i; if (son) Son("deplacer"); Signaler();
    }
    public void ChoisirMenu(int i) { if (Menu is { } m && i >= 0 && i < m.Elements.Count && !m.Elements[i].Info) { IndexMenu = i; derniers[m.Titre] = i; Son("valider"); Signaler(); m.Elements[i].Action(); } }
    public void Dire(string texte)
    {
        Toast = texte; Signaler();
        _ = Task.Delay(3500).ContinueWith(_ => Dispatcher.UIThread.Post(() => { if (Toast == texte) { Toast = null; Signaler(); } }));
    }
    public void Demander(string titre, string? aide, Action<string> valider) { Saisie = new Saisie { Titre = titre, Aide = aide, Valider = valider }; Signaler(); }
    public void ValiderSaisie(string texte) { var s = Saisie; Saisie = null; Signaler(); if (s != null && texte.Trim() != "") s.Valider(texte.Trim()); }

    // MARK: Lancement
    public void Lancer()
    {
        var j = Courant;
        if (j == null) { OuvrirAjout(); return; }
        if (j.EnConstruction) { MenusSwitch.Chantier(this, j); return; }
        if (EnCours != null) return;
        _ = LancerJeu(j);
    }
    async Task LancerJeu(Jeu j)
    {
        try
        {
            string cible = j.Cible, dossier = j.Dossier;
            Son("valider"); FermerMenus();
            Process? p = null;
            if (OperatingSystem.IsWindows())
            {
                if (j.Origine == Origine.Switch)
                {   // un jeu construit par ScarletNX se lance par le moteur (`--game`), qui recompile de lui-même si ses mods de code ont changé
                    var psi = new ProcessStartInfo(Moteur.Exe ?? cible) { UseShellExecute = false, WorkingDirectory = dossier };
                    foreach (var a in Moteur.Exe != null ? new[] { "--data", Moteur.Donnees, "--game", dossier, "-f" } : new[] { "-f" }) psi.ArgumentList.Add(a);
                    p = Process.Start(psi);
                }
                else p = Process.Start(new ProcessStartInfo(cible) { UseShellExecute = true, WorkingDirectory = File.Exists(cible) ? Path.GetDirectoryName(cible)! : "" });
            }
            else if (!Demo) { Dire("Les jeux ne se lancent que sur Windows"); return; }
            Journal.Ecrire($"lancement : {j.Nom} ({j.Id})");
            EnCours = j; EnCoursDepuis = DateTime.Now;
            if (!Stats.TryGetValue(j.Id, out var s)) Stats[j.Id] = s = new Stat();
            s.DernierePartie = DateTime.Now; Json.Ecrire(FichierStats, Stats); Signaler();
            var vu = await Task.Run(() => Attendre(j, p, dossier));
            if (vu) { s.Minutes += (int)Math.Round((DateTime.Now - EnCoursDepuis).TotalMinutes); Json.Ecrire(FichierStats, Stats); }
            Journal.Ecrire($"fin : {j.Nom}, {(DateTime.Now - EnCoursDepuis).TotalMinutes:0} min{(vu ? "" : " (le jeu n'a pas été vu en train de tourner)")}");
        }
        catch (Exception e) { Journal.Ecrire($"lancement de {j.Nom} : {e.Message}"); Dire("Impossible de lancer " + j.Nom); }
        EnCours = null;
        var i = Visibles.FindIndex(x => x.Id == j.Id); if (i >= 0) Selection = i;
        Devant?.Invoke(); Son("ouvrir"); Signaler();
    }
    /// Attend la fin de la partie. Une app lancée directement : on attend son processus. Steam, Epic et les jeux Switch : on regarde si un
    /// programme du dossier du jeu tourne (le launcher rend la main tout de suite, et beaucoup de jeux se relancent eux-mêmes).
    static bool Attendre(Jeu j, Process? p, string dossier)
    {
        if (!OperatingSystem.IsWindows()) { Thread.Sleep(6000); return false; }   // démonstration sur Mac : l'écran « en cours de jeu » quelques secondes
        if (j.Origine == Origine.App && p != null) { p.WaitForExit(); return true; }
        var debut = DateTime.Now; var vu = false; var absences = 0;
        while (true)
        {
            Thread.Sleep(vu ? 4000 : 2000);
            if (Systeme.TourneDans(dossier)) { vu = true; absences = 0; }
            else if (vu) { if (++absences >= 2) return true; }   // deux absences de suite : le jeu est fermé (pas juste en train de se relancer)
            else if (DateTime.Now - debut > TimeSpan.FromSeconds(120)) return false;   // jamais démarré (lancement annulé, mise à jour du launcher…)
        }
    }
    // MARK: Menus
    /// Les options d'un jeu : un menu court, en rangée de pastilles comme sur Mac. Les images et le nom sont dans « Apparence ».
    public void OuvrirOptions()
    {
        if (Courant is not { } j) return;
        if (j.EnConstruction) { MenusSwitch.Chantier(this, j); return; }
        var m = new Menu { Titre = j.Nom, SousTitre = ConsoleDe(j).nom, Logo = Arts.GetValueOrDefault(j.Id)?.Logo, Symbole = "gamecontroller" };
        m.Elements.Add(new("Jouer", "play.fill", () => { FermerMenus(); Lancer(); }, DerniereFois(j)));
        if (j.Origine == Origine.Switch)
        {
            m.Elements.Add(new("Mods", "puzzlepiece", () => MenusSwitch.Mods(this, j), "Ajouter, activer, désactiver, supprimer"));
            // dit ce que c'est, pas « Jouer en ligne » : aucun mod en ligne n'a encore été essayé avec un vrai jeu
            m.Elements.Add(new("Internet : " + (MenusSwitch.Internet(j) ? "activé" : "coupé"), "globe", () => MenusSwitch.BasculerInternet(this, j), "La connexion du PC pour ce jeu. Un mod en ligne en a besoin"));
        }
        m.Elements.Add(new("Apparence", "paintbrush", () => OuvrirApparence(j), "Jaquette, fond, logo et nom"));
        if (Directory.Exists(j.Dossier)) m.Elements.Add(new("Ouvrir le dossier du jeu", "folder", () => Systeme.Ouvrir(j.Dossier), j.Dossier));
        m.Elements.Add(new("Masquer", "eye.slash", () => { Config.Masques.Add(j.Id); Enregistrer(); FermerMenus(); Recharger(); }, "Le jeu reste installé ; Menu → Jeux masqués pour le remettre"));
        if (j.Origine == Origine.Switch) m.Elements.Add(new("Désinstaller", "trash", () => Ouvrir(new Menu
        {
            Titre = "Désinstaller " + j.Nom + " ?", Symbole = "trash", Retour = OuvrirOptions,
            Texte = $"Le dossier du jeu part à la Corbeille, avec ses mods et les sauvegardes qu'il contient :\n{j.Dossier}\n\nTant que la Corbeille n'est pas vidée, tu peux le remettre. Ton fichier de jeu d'origine n'est pas touché.",
            Elements =
            {
                new("Annuler", "xmark", OuvrirOptions),
                new("Mettre à la Corbeille", "trash", () => { if (!Systeme.Corbeille(j.Dossier)) { Dire("Le dossier n'a pas pu être mis à la Corbeille"); return; } Journal.Ecrire($"jeu Switch désinstallé : {j.Id}"); FermerMenus(); Recharger(); Dire(j.Nom + " est désinstallé"); }) { Destructif = true },
            },
        }), "Le jeu construit part à la Corbeille") { Destructif = true });
        if (j.Origine == Origine.App) m.Elements.Add(new("Retirer de Home", "trash", () => { Config.Jeux.RemoveAll(e => "app:" + e.Chemin == j.Id); Enregistrer(); FermerMenus(); Recharger(); }, "Le programme n'est pas supprimé") { Destructif = true });
        Ouvrir(m);
    }
    /// « Dernière partie hier · 3 h 20 min de jeu » : ce que l'écran d'accueil ne dit plus, sous le choix « Jouer »
    string DerniereFois(Jeu j)
    {
        if (!Stats.TryGetValue(j.Id, out var s) || s.DernierePartie is not { } d) return "Jamais joué";
        var jours = (DateTime.Today - d.Date).Days;
        var quand = jours == 0 ? "aujourd'hui" : jours == 1 ? "hier" : jours < 7 ? $"il y a {jours} jours" : jours < 60 ? $"il y a {jours / 7} semaine{(jours >= 14 ? "s" : "")}" : $"il y a {jours / 30} mois";
        return "Dernière partie " + quand + (s.Minutes > 0 ? " · " + (s.Minutes >= 60 ? $"{s.Minutes / 60} h {s.Minutes % 60} min de jeu" : $"{s.Minutes} min de jeu") : "");
    }
    void OuvrirApparence(Jeu j)
    {
        Ouvrir(new Menu
        {
            Titre = "Apparence", SousTitre = j.Nom, Symbole = "paintbrush", Retour = OuvrirOptions,
            Elements =
            {
                new("Changer la jaquette", "photo", () => _ = ChoisirImage(j, "couverture"), "Depuis un fichier image"),
                new("Changer le fond", "photo.fill", () => _ = ChoisirImage(j, "fond"), "Depuis un fichier image"),
                new("Changer le logo", "textformat", () => _ = ChoisirImage(j, "logo"), "Depuis un fichier image (PNG transparent)"),
                new("Rechercher les images", "magnifyingglass", () => RechercherImages(j), SteamGridDB.Cle != null ? "SteamGridDB, boutiques officielles, Steam" : "Boutiques officielles et Steam (sans clé SteamGridDB)"),
                new("Renommer", "pencil", () => Demander("Nouveau nom", j.Nom, n => { Config.Noms[j.Id] = n; Enregistrer(); FermerMenus(); Recharger(); }), j.Nom),
            },
        });
    }
    async Task ChoisirImage(Jeu j, string quoi)
    {
        if (ChoisirFichier == null || await ChoisirFichier("Choisir une image", ["*.png", "*.jpg", "*.jpeg", "*.webp"]) is not { } f) return;
        try { File.Copy(f, Images.Fichier(j, quoi), true); ChargerArt(j); Dire("Image changée"); }
        catch (Exception e) { Journal.Ecrire("image : " + e.Message); Dire("Cette image n'a pas pu être copiée"); }
    }
    /// Oublie les images téléchargées de ce jeu et les redemande à leurs sources
    void RechercherImages(Jeu j)
    {
        foreach (var quoi in Images.Emplacements) { try { File.Delete(Images.Fichier(j, quoi)); } catch { } }
        FermerMenus(); ChargerArt(j); Dire("Recherche des images…");
    }

    public void OuvrirPlus()
    {
        var m = new Menu { Titre = "Home", SousTitre = "Version " + Version, Symbole = "gear" };
        if (MiseAJour.Version is { } nouvelle) m.Elements.Add(new("Mettre à jour Home", "arrow.down.circle", () => _ = MiseAJour.Installer(this), $"{Version} → {nouvelle} · Home se ferme, s'installe et se rouvre"));
        m.Elements.Add(new("Ajouter un jeu", "plus", OuvrirAjout, "Jeux Switch, apps et jeux Windows"));
        m.Elements.Add(new("Actualiser la bibliothèque", "arrow.clockwise", () => { FermerMenus(); Recharger(); Dire("Bibliothèque actualisée"); }, "Relit Steam, Epic Games et les jeux Switch"));
        if (Config.Masques.Count > 0) m.Elements.Add(new("Jeux masqués", "eye", OuvrirMasques, $"{Config.Masques.Count} masqué{(Config.Masques.Count > 1 ? "s" : "")}"));
        // « Nom : état » : la roue montre l'état dans une capsule, à côté du choix visé
        m.Elements.Add(new("Sons de l'interface : " + (Config.Sons ? "activés" : "coupés"), Config.Sons ? "speaker.wave.2" : "speaker.slash", () => { Config.Sons = !Config.Sons; Sons.Actifs = Config.Sons; Enregistrer(); OuvrirPlus(); }, "Les sons des menus et de la bibliothèque") { Section = "Réglages" });
        m.Elements.Add(new("Affichage : " + (Config.Fenetre ? "en fenêtre" : "plein écran"), "rectangle", () => { Config.Fenetre = !Config.Fenetre; Enregistrer(); AppliquerFenetre?.Invoke(); OuvrirPlus(); }, "F11 change aussi"));
        m.Elements.Add(new("Animations : " + (Config.AnimationsReduites ? "réduites" : "complètes"), "sparkles", () => { Config.AnimationsReduites = !Config.AnimationsReduites; Mouvement.Reduit = Config.AnimationsReduites; Enregistrer(); Reconstruire?.Invoke(); OuvrirPlus(); },
            "Réduites : les mouvements deviennent un fondu très court"));
        m.Elements.Add(new("Clé SteamGridDB", "key", OuvrirCle, SteamGridDB.Cle != null ? "Enregistrée" : "Aucune : jaquettes carrées et images des jeux Epic et des apps"));
        if (MiseAJour.Version == null) m.Elements.Add(new("Chercher une mise à jour", "arrow.clockwise", async () => { if (await MiseAJour.Verifier()) OuvrirPlus(); else Dire("Home est à jour (" + Version + ")"); }, "Version " + Version) { Section = "Home" });
        m.Elements.Add(new("Libérer de la place", "trash", () => MenusSwitch.LibererPlace(this), "Ce que les constructions ont laissé et qui ne sert plus") { Teinte = Icones.Orange });
        m.Elements.Add(new("Ouvrir le dossier de Home", "folder", () => Systeme.Ouvrir(Dossiers.Racine), "Réglages, images, jeux Switch, journal") { Section = MiseAJour.Version == null ? null : "Home" });
        m.Elements.Add(new("Quitter Home", "power", () => Quitter?.Invoke()) { Destructif = true });
        Ouvrir(m);
    }
    void OuvrirMasques()
    {
        var m = new Menu { Titre = "Jeux masqués", Symbole = "eye", Retour = OuvrirPlus };
        foreach (var id in Config.Masques.ToList())
            m.Elements.Add(new(Jeux.FirstOrDefault(j => j.Id == id)?.Nom ?? id, "eye", () => { Config.Masques.Remove(id); Enregistrer(); Recharger(); if (Config.Masques.Count > 0) OuvrirMasques(); else OuvrirPlus(); }, "Remettre dans la bibliothèque"));
        Ouvrir(m);
    }
    void OuvrirCle()
    {
        void Garder(string cle) { SteamGridDB.Enregistrer(cle); Dire("Clé enregistrée"); OuvrirPlus(); }
        Ouvrir(new Menu
        {
            Titre = "Clé SteamGridDB", Symbole = "key", Retour = OuvrirPlus,
            Texte = "SteamGridDB donne des jaquettes carrées, des fonds et des logos. La clé est gratuite : compte sur steamgriddb.com, puis Préférences → API. Elle reste dans un fichier à part sur ce PC.",
            Elements =
            {
                new("Coller la clé", "doc.on.clipboard", async () => { var t = PressePapiers != null ? await PressePapiers() : null; if (t?.Trim() is { Length: >= 20 and <= 64 } c && c.All(char.IsLetterOrDigit)) Garder(c); else Dire("Le presse-papiers ne contient pas une clé"); }, "Depuis le presse-papiers"),
                new("Saisir la clé", "pencil", () => Demander("Clé SteamGridDB", "Au clavier", Garder)),
                new("Ouvrir steamgriddb.com", "safari", () => Systeme.Ouvrir("https://www.steamgriddb.com/profile/preferences/api")),
            },
        });
    }
    public void OuvrirAjout()
    {
        int steam = Jeux.Count(j => j.Origine == Origine.Steam), epic = Jeux.Count(j => j.Origine == Origine.Epic);
        Ouvrir(new Menu
        {
            Titre = "Ajouter un jeu", Symbole = "plus",
            Elements =
            {
                new("Switch", "gamecontroller", () => MenusSwitch.Ajouter(this), "Construire un jeu à partir de ton dump et de tes clés") { Teinte = Icones.Rouge },
                new("App ou jeu Windows", "desktopcomputer", () => _ = AjouterApp(), "Choisir un programme (.exe) ou un raccourci"),
                new() { Libelle = "Steam et Epic Games", Detail = $"Leurs jeux installés apparaissent tout seuls : {steam} Steam, {epic} Epic Games", Icone = "pc", Info = true, Section = "Détectés automatiquement" },
            },
        });
    }
    async Task AjouterApp()
    {
        if (ChoisirFichier == null || await ChoisirFichier("Choisir un programme", ["*.exe", "*.lnk", "*.url"]) is not { } f) return;
        if (Config.Jeux.All(e => !e.Chemin.Equals(f, StringComparison.OrdinalIgnoreCase))) { Config.Jeux.Add(new Entree { Chemin = f }); Enregistrer(); }
        FermerMenus(); Recharger(selectionner: "app:" + f);
    }

    /// Démonstration (HOME_DEMO=1, sur Mac) : des tuiles d'exemple, pour vérifier l'interface sans rien d'installé. Les noms servent à
    /// chercher les images dans les boutiques officielles ; aucun jeu n'est là.
    static IEnumerable<Jeu> Exemples() =>
    [
        new() { Id = "switch:exemple1", Nom = "The Legend of Zelda: Tears of the Kingdom", Origine = Origine.Switch },
        new() { Id = "switch:exemple2", Nom = "Super Mario Odyssey", Origine = Origine.Switch },
        new() { Id = "switch:exemple3", Nom = "Mario Kart 8 Deluxe", Origine = Origine.Switch },
        new() { Id = "epic:exemple", Nom = "Rocket League", Origine = Origine.Epic },
        new() { Id = "epic:exemple2", Nom = "Bloodborne", Origine = Origine.Epic },
        new() { Id = "app:exemple", Nom = "Une app Windows", Origine = Origine.App },
    ];
}
