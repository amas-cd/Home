// Home pour Windows — la bibliothèque : l'état de l'interface, la navigation, le lancement des jeux et tous les menus.
// L'équivalent de `Library` dans app/main.swift. Tout se passe sur le fil de l'interface ; le travail long revient par Dispatcher.
using System.Diagnostics;
using System.Reflection;
using Avalonia.Threading;

namespace Home;

public sealed partial class Bibliotheque
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
    public Func<string>? TexteSaisie;   // ce que le champ de saisie contient : la manette valide avec A
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
        .OrderByDescending(j => j.EnConstruction)   // les chantiers en tête : on voit tout de suite ce qui se construit
        .ThenByDescending(j => Stats.TryGetValue(j.Id, out var s) ? s.DernierePartie ?? DateTime.MinValue : DateTime.MinValue).ThenBy(j => j.Nom, StringComparer.CurrentCultureIgnoreCase).ToList();
    public Jeu? Courant { get { var v = Visibles; return Selection < v.Count ? v[Selection] : null; } }
    /// D'où vient un jeu, pour l'afficher à côté de son nom : sa console, ou sa boutique. L'icône est un logo (« logo:switch »,
    /// « logo:steam », « logo:epic » : les images de app/logos) ou un symbole.
    public (string nom, string icone) ConsoleDe(Jeu j) => j.Origine switch
    {
        Origine.Steam => ("Steam", "logo:steam"), Origine.Epic => ("Epic Games", "logo:epic"),
        Origine.Switch => j.EnConstruction ? ("En construction", "hammer") : ("Nintendo Switch", "logo:switch"),
        _ => ("App Windows", "logo:windows"),
    };

    public static readonly string[] CategoriesDeBase = ["Switch", "Steam", "Epic Games", "Apps"];
    // MARK: Catégories à soi (openCategoryMenu, openCategoriesSettings, openRemoveCategoryMenu, addCategory sur Mac)
    void RangerDans(Jeu j, string c)
    {
        if (c == j.CategorieOrigine) Config.CategoriesJeux.Remove(j.Id); else Config.CategoriesJeux[j.Id] = c;
        Enregistrer(); FermerMenus(); Recharger(j.Id);
        var k = Categories.IndexOf(c); if (k >= 0) { IndexCategorie = k; Selection = Math.Max(0, Visibles.FindIndex(x => x.Id == j.Id)); }
        Dire($"{j.Nom} → {c}");
    }
    void OuvrirCategorie(Jeu j)
    {
        var m = new Menu { Titre = "Catégorie", SousTitre = j.Nom, Symbole = "tag", Roue = true, Retour = OuvrirOptions };
        foreach (var c in new[] { j.CategorieOrigine }.Concat(Config.Categories).Distinct())
            m.Elements.Add(new(c, c == j.Categorie ? "checkmark" : "tag", () => RangerDans(j, c), c == j.Categorie ? "Catégorie actuelle" : null) { Teinte = c == j.Categorie ? Icones.Vert : null });
        m.Elements.Add(new("Nouvelle catégorie…", "plus", () => NouvelleCategorie(j), j.Nom + " y sera rangé"));
        Ouvrir(m);
    }
    void NouvelleCategorie(Jeu? j) => Demander("Nouvelle catégorie", "Rétro, Multijoueur, Enfants…", nom =>
    {
        if (nom == "Tous" || CategoriesDeBase.Contains(nom)) { Dire("Ce nom est déjà pris par une catégorie de base"); return; }
        if (!Config.Categories.Contains(nom)) Config.Categories.Add(nom); Enregistrer();
        if (j != null) RangerDans(j, nom); else { FermerMenus(); Recharger(); var k = Categories.IndexOf(nom); if (k >= 0) { IndexCategorie = k; Selection = 0; Signaler(); } }
        Dire($"Catégorie « {nom} » créée");
    });
    void OuvrirCategories() => Ouvrir(new Menu
    {
        Titre = "Catégories", Symbole = "tag", Retour = OuvrirPlus, Elements =
        {
            new("Nouvelle catégorie…", "plus", () => NouvelleCategorie(null), "Elle apparaîtra dans les onglets"),
            new("Supprimer une catégorie", "trash", OuvrirSupprimerCategorie, "Les jeux retournent dans leur catégorie d'origine") { Destructif = true },
        },
    });
    void OuvrirSupprimerCategorie()
    {
        if (Config.Categories.Count == 0) { Dire("Les catégories de base ne se suppriment pas"); return; }
        var m = new Menu { Titre = "Supprimer", SousTitre = "Les jeux retournent dans leur catégorie d'origine", Symbole = "trash", Roue = true, Retour = OuvrirCategories };
        foreach (var c in Config.Categories.ToList())
        {
            var n = Jeux.Count(j => j.Categorie == c);
            m.Elements.Add(new(c, "trash", () =>
            {
                Config.Categories.Remove(c); foreach (var id in Config.CategoriesJeux.Where(p => p.Value == c).Select(p => p.Key).ToList()) Config.CategoriesJeux.Remove(id);
                Enregistrer(); FermerMenus(); Recharger(); Dire($"Catégorie « {c} » supprimée");
            }, n == 1 ? "1 jeu" : n + " jeux") { Destructif = true });
        }
        Ouvrir(m);
    }
    public void Recharger(string? selectionner = null)
    {
        Sons.Actifs = Config.Sons; Mouvement.Reduit = Config.AnimationsReduites;
        var jeux = new List<Jeu>();
        if (ModePC) { jeux.AddRange(Steam.Jeux()); jeux.AddRange(Epic.Jeux()); }
        if (ModeNintendo)
        {
            jeux.AddRange(Construction.Jeux());
            // un jeu en construction a déjà sa tuile : on voit où il en est, et on le reprend si c'est coupé
            foreach (var c in Construction.Chantiers()) jeux.Add(new Jeu { Id = c.Id, Nom = c.Titre, Origine = Origine.Switch });
        }
        if (Demo) jeux.AddRange(Exemples());
        foreach (var e in Config.Jeux.Where(e => ModePC && (Demo || File.Exists(e.Chemin))))
            jeux.Add(new Jeu { Id = "app:" + e.Chemin, Nom = e.Nom ?? Path.GetFileNameWithoutExtension(e.Chemin), Origine = Origine.App, Cible = e.Chemin, Dossier = Path.GetDirectoryName(e.Chemin) ?? "" });
        foreach (var j in jeux) if (Config.Noms.TryGetValue(j.Id, out var n)) j.Nom = n;
        foreach (var j in jeux) if (Config.CategoriesJeux.TryGetValue(j.Id, out var c)) j.CategorieChoisie = c;
        var avant = selectionner ?? Courant?.Id; var categorie = Categories.ElementAtOrDefault(IndexCategorie);
        Jeux = jeux;
        Categories = ["Tous", .. CategoriesDeBase.Where(c => jeux.Any(j => j.Categorie == c && !Config.Masques.Contains(j.Id))), .. Config.Categories];
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
        // pendant la première seconde et demie rien n'est pris en compte : un bouton tenu au moment où Home démarre lançait le premier jeu
        if ((DateTime.Now - demarrage).TotalSeconds < 1.5) return;
        if (PasserOuverture?.Invoke() == true) return;
        if (Bienvenue && !BienvenueFige)
        {   // l'accueil du premier lancement : gauche et droite choisissent une carte, la touche des options l'ignore
            if (k is "left" or "right") { var carte = Math.Clamp(BienvenueIndex + (k == "left" ? -1 : 1), 0, 2); if (carte != BienvenueIndex) { BienvenueIndex = carte; Son("deplacer"); Signaler(); } }
            else if (k == "ok") BienvenueValider(); else if (k == "options") BienvenueIgnorer();
            return;
        }
        if ((DateTime.Now - installationQuittee).TotalSeconds < 0.5) return;   // le même appui n'agit pas aussi sur la bibliothèque qui réapparaît
        if (Installation)
        {   // l'installation du moteur : rien d'autre tant qu'elle tourne ; après un échec, réessayer ou continuer sans
            if (Tache?.Erreur != null) { if (k == "ok") InstallationReessayer(); else if (k is "back" or "options") InstallationPasser(); }
            return;
        }
        // la saisie : la manette valide ou annule, le texte se tape au clavier
        if (Saisie != null) { if (k == "back") { Saisie = null; Son("retour"); Signaler(); } else if (k == "ok" && TexteSaisie != null) { Son("valider"); ValiderSaisie(TexteSaisie()); } return; }
        if (EnCours != null) return;
        if (Menu != null) { NavMenu(k); return; }
        if (Bienvenue) return;   // le choix est fait : la bienvenue attend l'écran suivant
        var n = Visibles.Count;
        switch (k)
        {
            // d'un jeu à l'autre : un tic court et discret (« tuile »), à part de celui des menus
            case "left": if (Selection > 0) { Selection--; Son("tuile"); Signaler(); } break;
            case "right": if (Selection < n) { Selection++; Son("tuile"); Signaler(); } break;
            case "back": if (!FermerTache()) OuvrirQuitter(); break;
            case "ok": Lancer(); break;
            case "options": if (Courant != null) OuvrirOptions(); break;
            case "plus": OuvrirPlus(); break;
            case "cat" or "catR" or "down": IndexCategorie = (IndexCategorie + 1) % Categories.Count; Selection = 0; Son("onglet"); Signaler(); break;
            case "catL" or "up": IndexCategorie = (IndexCategorie + Categories.Count - 1) % Categories.Count; Selection = 0; Son("onglet"); Signaler(); break;
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
            // Options revient d'un niveau, comme B (closeMenu sur Mac) : elle ne ferme plus tout d'un coup
            case "back" or "options": Son("retour"); if (m.Retour != null) { SensMenu = -1; m.Retour(); SensMenu = 1; } else FermerMenus(); return;
            case "plus": return;
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
        if (Pas is { } pas && m.Etapes == 0) { m.Etape = pas.etape; m.Etapes = pas.sur; }
        Menu = m; IndexMenu = Math.Max(0, m.Elements.FindIndex(e => !e.Info));
        if (!m.Grille && derniers.TryGetValue(m.Titre, out var d) && d < m.Elements.Count && !m.Elements[d].Info) IndexMenu = d;
        Signaler();
    }
    /// L'étape de l'assistant en cours (« Ajouter un jeu Switch ») : les menus ouverts d'ici là portent ses points
    public (int etape, int sur)? Pas;
    public void FermerMenus() { Menu = null; Pas = null; Signaler(); }
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
        _ = Task.Delay(3000).ContinueWith(_ => Dispatcher.UIThread.Post(() => { if (Toast == texte) { Toast = null; Signaler(); } }));
    }
    /// `aide` : l'exemple écrit en gris dans le champ vide ; `texte` : ce que le champ contient déjà (le nom actuel, pour renommer)
    public void Demander(string titre, string? aide, Action<string> valider, string texte = "") { Saisie = new Saisie { Titre = titre, Aide = aide, Texte = texte, Valider = valider }; Signaler(); }
    /// Ferme la carte d'une tâche finie ou en échec (B / Échap) ; une tâche en cours reste affichée
    /// La fin d'une tâche. Réussie : sa carte s'en va seule au bout de 8 s. Échouée : son menu s'ouvre tout seul et la carte reste
    /// jusqu'à « Fermer » ou B.
    public void FinTache(Tache t)
    {
        if (t.Erreur == null) { Son("valider"); _ = Task.Delay(8000).ContinueWith(_ => Dispatcher.UIThread.Post(() => { if (Tache == t) { Tache = null; Signaler(); } })); return; }
        Son("retour"); if (Tache == t && EnCours == null && Menu == null && !Bienvenue && !Installation) OuvrirTacheMenu();
    }
    /// Le menu de la carte d'une tâche (openTacheMenu sur Mac)
    public void OuvrirTacheMenu()
    {
        if (Tache is not { } t) return;
        var m = new Menu { Titre = t.Titre, SousTitre = t.Erreur ?? t.Etape, Symbole = t.Erreur != null ? "exclamationmark" : "hammer" };
        var journal = t.Journal != null && File.Exists(t.Journal) ? t.Journal : null;
        if (t.Fini)
        {
            if (journal != null) m.Elements.Add(new("Ouvrir dans le dossier", "folder", () => { FermerMenus(); Systeme.Montrer(journal); }, Path.GetFileName(journal)));
            m.Elements.Add(new("Fermer", "xmark", () => { FermerMenus(); if (Tache == t) { Tache = null; Signaler(); } }) { Teinte = Icones.Gris });
        }
        else
        {
            m.Elements.Add(new("Continuer", "play.fill", FermerMenus, t.Etape));
            if (journal != null) m.Elements.Add(new("Ouvrir le journal dans le dossier", "folder", () => { FermerMenus(); Systeme.Montrer(journal); }, Path.GetFileName(journal)));
            if (t.Arreter is { } arreter) m.Elements.Add(new("Arrêter", "stop", () => { FermerMenus(); arreter(); }) { Destructif = true });
        }
        Ouvrir(m);
    }
    public bool FermerTache() { if (Tache is not { Fini: true }) return false; Son("retour"); Tache = null; Signaler(); return true; }
    public void OuvrirQuitter()
    {
        if (EnCours != null || Menu != null) return;
        Ouvrir(new Menu { Titre = "Quitter Home ?", Symbole = "power", Elements =
        {
            new("Rester", "arrow.uturn.backward", FermerMenus),
            new("Quitter Home", "power", () => { FermerMenus(); Son("retour"); _ = Task.Delay(300).ContinueWith(_ => Dispatcher.UIThread.Post(() => Quitter?.Invoke())); }) { Destructif = true },
        } });
    }
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
                    // un mod en ligne demande l'adresse de son serveur au clavier : ScarletNX répond à sa place (swkbd_text, pour cette partie seulement)
                    if (Moteur.Exe != null && Construction.Serveur(dossier) is { Length: > 0 } serveur) psi.ArgumentList.Add("--swkbd-text=" + serveur);
                    p = Process.Start(psi);
                }
                else p = Process.Start(new ProcessStartInfo(cible) { UseShellExecute = true, WorkingDirectory = File.Exists(cible) ? Path.GetDirectoryName(cible)! : "" });
            }
            else if (!Demo) { Dire("Les jeux ne se lancent que sur Windows"); return; }
            Journal.Ecrire($"lancement : {j.Nom} ({j.Id})");
            Lance = j.Origine is Origine.Switch or Origine.App ? p : null;
            EnCours = j; EnCoursDepuis = DateTime.Now;
            if (!Stats.TryGetValue(j.Id, out var s)) Stats[j.Id] = s = new Stat();
            s.DernierePartie = DateTime.Now; Json.Ecrire(FichierStats, Stats); Signaler(); MajDiscord();
            var vu = await Task.Run(() => Attendre(j, p, dossier, () => RemettreVolume(j)));
            if (vu) { s.Minutes += (int)Math.Round((DateTime.Now - EnCoursDepuis).TotalMinutes); Json.Ecrire(FichierStats, Stats); }
            Journal.Ecrire($"fin : {j.Nom}, {(DateTime.Now - EnCoursDepuis).TotalMinutes:0} min{(vu ? "" : " (le jeu n'a pas été vu en train de tourner)")}");
        }
        catch (Exception e) { Journal.Ecrire($"lancement de {j.Nom} : {e.Message}"); Dire("Impossible de lancer " + j.Nom); }
        EnCours = null; Lance = null; FermerRapide(); MajDiscord();
        var i = Visibles.FindIndex(x => x.Id == j.Id); if (i >= 0) Selection = i;
        Devant?.Invoke(); Son("ouvrir"); Signaler();
    }
    /// Attend la fin de la partie. Une app lancée directement : on attend son processus. Steam, Epic et les jeux Switch : on regarde si un
    /// programme du dossier du jeu tourne (le launcher rend la main tout de suite, et beaucoup de jeux se relancent eux-mêmes).
    static bool Attendre(Jeu j, Process? p, string dossier, Action? vuTourner = null)
    {
        if (!OperatingSystem.IsWindows()) { Thread.Sleep(6000); return false; }   // démonstration sur Mac : l'écran « en cours de jeu » quelques secondes
        if (j.Origine == Origine.App && p != null) { p.WaitForExit(); return true; }
        var debut = DateTime.Now; var vu = false; var absences = 0;
        while (true)
        {
            Thread.Sleep(vu ? 4000 : 2000);
            if (Systeme.TourneDans(dossier)) { if (!vu || (DateTime.Now - debut).TotalSeconds < 40) vuTourner?.Invoke(); vu = true; absences = 0; }   // son volume, dès qu'il joue du son
            else if (vu) { if (++absences >= 2) return true; }   // deux absences de suite : le jeu est fermé (pas juste en train de se relancer)
            else if (DateTime.Now - debut > TimeSpan.FromSeconds(120)) return false;   // jamais démarré (lancement annulé, mise à jour du launcher…)
        }
    }
    // MARK: L'accueil du premier lancement (BienvenueVue) : un écran à part, pas un menu
    public bool Bienvenue; public int BienvenueIndex;
    public bool BienvenueFige;   // le choix est fait : l'écran reste jusqu'au suivant (les clés, l'installation), on ne voit jamais la bibliothèque entre les deux
    readonly DateTime demarrage = DateTime.Now;
    public void FermerBienvenue() { BienvenueFige = false; if (Bienvenue) { Bienvenue = false; Signaler(); } }
    /// L'installation du moteur occupe tout l'écran, comme la mise en route d'une console : pas de bibliothèque avant la fin.
    /// Si elle échoue, on peut réessayer ou continuer sans (Menu → Composants la relance).
    public bool Installation; Action? installationRelance; DateTime installationQuittee = DateTime.MinValue;
    void InstallationReessayer() { if (installationRelance is not { } r) return; Son("valider"); Tache = null; r(); }
    void InstallationPasser() { installationQuittee = DateTime.Now; Son("retour"); Installation = false; Signaler(); }
    /// La suite, dans l'ordre du Mac, chaque étape à valider : les clés de la console (sans elles aucun jeu Switch ne se construit),
    /// puis l'installation des composants, puis seulement les bibliothèques Steam et Epic Games.
    public void BienvenueValider()
    {
        if (BienvenueFige) return;
        Son("valider"); BienvenueFige = true; Config.Mode = new[] { "tout", "nintendo", "pc" }[BienvenueIndex]; Enregistrer(); Recharger();
        void Comptes() { if (ModePC) AccueilBibliotheques(); }
        void Installer() => AppliquerMode(Comptes);
        if (ModeNintendo) MenusSwitch.AccueilCles(this, Installer); else Installer();
    }
    public string ModeResume => Config.Mode switch { "pc" => "Jeux PC", "nintendo" => "Jeux Nintendo", null => "Pas encore choisi", _ => "Jeux Nintendo et jeux PC" };
    /// Télécharge ce qui manque pour le mode choisi ; `ensuite` se fait quand tout est installé. Sur Windows il n'y a que ScarletNX à
    /// installer : Steam et Epic Games sont des programmes que le joueur a déjà.
    void AppliquerMode(Action? ensuite)
    {
        if (!ModeNintendo || Moteur.Exe != null) { FermerBienvenue(); Dire($"Mode d'utilisation : {ModeResume} — tout est déjà installé"); ensuite?.Invoke(); return; }
        if (!OperatingSystem.IsWindows()) { FermerBienvenue(); Dire("Le moteur des jeux Switch ne s'installe que sur Windows"); ensuite?.Invoke(); return; }
        if (Tache is { Fini: false }) { FermerBienvenue(); Dire("Une autre tâche est en cours : attends qu'elle finisse"); return; }
        // en plein écran ; la bienvenue ne part qu'une fois l'installation affichée
        installationRelance = () => AppliquerMode(ensuite); FermerMenus(); Installation = true; Signaler();
        _ = Task.Delay(500).ContinueWith(_ => Dispatcher.UIThread.Post(FermerBienvenue));
        _ = Construction.PreparerMoteur(this, "Installation pour : " + ModeResume, () =>
        {   // « MOTEURS INSTALLÉS » un instant, puis la bibliothèque en fondu, puis la suite (les bibliothèques Steam et Epic)
            _ = Task.Delay(700).ContinueWith(_ => Dispatcher.UIThread.Post(() => { Installation = false; Signaler(); }));
            _ = Task.Delay(1500).ContinueWith(_ => Dispatcher.UIThread.Post(() => ensuite?.Invoke()));
        });
    }
    /// Premier lancement, jeux PC : sur Mac on connecte ses comptes Epic et Steam ; sur Windows il n'y a rien à connecter, Home lit les
    /// jeux que ces boutiques ont installés. L'étape montre ce qu'il a trouvé.
    public void AccueilBibliotheques()
    {
        int steam = Jeux.Count(j => j.Origine == Origine.Steam), epic = Jeux.Count(j => j.Origine == Origine.Epic);
        string Trouves(int n) => n == 0 ? "aucun jeu installé" : n == 1 ? "1 jeu trouvé" : $"{n} jeux trouvés";
        Ouvrir(new Menu
        {
            Titre = "Tes bibliothèques", Symbole = "person", Roue = true,
            Texte = "Sur Windows il n'y a pas de compte à connecter : Home montre les jeux que Steam et Epic Games ont déjà installés sur ce PC. Installe un jeu dans sa boutique, il apparaît ici.",
            Elements =
            {
                new() { Libelle = "Steam · " + Trouves(steam), Icone = "logo:steam", Info = true },
                new() { Libelle = "Epic Games · " + Trouves(epic), Icone = "logo:epic", Info = true },
                new("Continuer", "arrow.right", FermerMenus, "Menu → Actualiser la bibliothèque pour relire") { Teinte = Icones.Vert },
                new("Actualiser", "arrow.clockwise", () => { Recharger(); AccueilBibliotheques(); }, "Relit Steam et Epic Games") { Teinte = Icones.Gris },
            },
        });
    }
    public void BienvenueIgnorer() { if (BienvenueFige) return; Config.Mode = "tout"; Enregistrer(); Son("retour"); Bienvenue = false; Signaler(); }

    // MARK: Mode d'utilisation : ce que Home sert à faire sur ce PC (jeux Nintendo, jeux PC, les deux), comme sur Mac
    public bool ModeNintendo => Config.Mode != "pc";
    public bool ModePC => Config.Mode != "nintendo";
    /// Au premier lancement (« Bienvenue »), puis dans Menu → Composants. Sur Windows il n'y a qu'un moteur Nintendo (ScarletNX) : pas de
    /// seconde étape comme sur Mac. Choisir Nintendo le télécharge tout de suite, pour que le premier jeu n'attende pas.
    public void OuvrirMode(bool premier = false)
    {
        var mode = Config.Mode ?? "tout";
        void Appliquer(string cle) { Config.Mode = cle; Enregistrer(); FermerMenus(); Recharger(); AppliquerMode(null); }
        ElementMenu Choix(string nom, string precision, string symbole, Avalonia.Media.Color teinte, string cle) =>
            new(nom + (!premier && cle == mode ? " : actuel" : ""), symbole, () => Appliquer(cle), precision) { Teinte = teinte };
        var m = new Menu { Titre = premier ? "Bienvenue" : "Composants", SousTitre = premier ? "Que veux-tu faire avec Home ?" : null, Symbole = "sparkles", Roue = true, Retour = premier ? () => Appliquer("tout") : OuvrirPlus };
        m.Elements.Add(Choix("Tout", "Jeux Nintendo et jeux PC", "sparkles", Icones.Violet, "tout"));
        m.Elements.Add(Choix("Nintendo", "Switch, à partir des fichiers de tes jeux", "gamecontroller", Icones.Orange, "nintendo"));
        m.Elements.Add(Choix("PC", "Steam, Epic Games et tes jeux Windows", "desktopcomputer", Icones.Bleu, "pc"));
        if (premier) m.Elements.Add(new("Plus tard", "clock", () => Appliquer("tout")) { Teinte = Icones.Gris });
        // le moteur des jeux Switch : où il en est, et sa mise à jour (ScarletNX sort une version presque chaque jour)
        if (!premier && ModeNintendo)
            m.Elements.Add(new("Clés de la console", "key", () => MenusSwitch.AccueilCles(this, () => OuvrirMode()), File.Exists(Construction.ClesProd) ? "Installées · choisir pour les changer" : "Ton fichier prod.keys") { Teinte = Icones.Jaune, Section = "Jeux Switch" });
        if (!premier && ModeNintendo)
            m.Elements.Add(new("ScarletNX" + (Moteur.Version != null ? " : installé" : ""), "arrow.down.circle", () =>
            {
                FermerMenus();
                if (!OperatingSystem.IsWindows()) { Dire("Le moteur des jeux Switch ne s'installe que sur Windows"); return; }
                _ = Construction.PreparerMoteur(this, Moteur.Version != null ? "Mise à jour du moteur" : "Installation du moteur", derniere: Moteur.Version != null);
            }, Moteur.Version != null ? $"Le moteur des jeux Switch — {Moteur.Version} · choisir pour le mettre à jour" : "Le moteur des jeux Switch — pas encore installé") { Section = "Moteur Nintendo" });
        Ouvrir(m);
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
        if (j.Origine == Origine.Switch) m.Elements.Add(new("Souris", "hand.tap", () => MenusSwitch.Souris(this, j), "La caméra à la souris, la sensibilité, les boutons"));
        m.Elements.Add(new("Apparence", "paintbrush", () => OuvrirApparence(j), "Jaquette, fond, logo et nom"));
        m.Elements.Add(new("Catégorie", "tag", () => OuvrirCategorie(j), j.Categorie));
        if (Directory.Exists(j.Dossier)) m.Elements.Add(new("Ouvrir le dossier du jeu", "folder", () => Systeme.Ouvrir(j.Dossier), j.Dossier));
        m.Elements.Add(new("Masquer ce jeu", "eye.slash", () => { Config.Masques.Add(j.Id); Enregistrer(); FermerMenus(); Recharger(); }, "Le jeu reste installé ; Menu → Jeux masqués pour le remettre"));
        if (j.Origine == Origine.Switch) m.Elements.Add(new("Désinstaller", "trash", () => Ouvrir(new Menu
        {
            Titre = "Désinstaller " + j.Nom + " ?", Symbole = "trash", Retour = OuvrirOptions,
            Texte = $"Le dossier du jeu part à la Corbeille, avec ses mods :\n{j.Dossier}\n\nLes sauvegardes restent. Tant que la Corbeille n'est pas vidée, tu peux remettre le jeu. Ton fichier de jeu d'origine n'est pas touché.",
            Elements =
            {
                new("Annuler", "xmark", OuvrirOptions),
                new("Mettre à la Corbeille", "trash", () => { Construction.GarderSauvegardes(j); if (!Systeme.Corbeille(j.Dossier)) { Dire("Le dossier n'a pas pu être mis à la Corbeille"); return; } Journal.Ecrire($"jeu Switch désinstallé : {j.Id}"); FermerMenus(); Recharger(); Dire(j.Nom + " est désinstallé"); }) { Destructif = true },
            },
        }), "Les sauvegardes restent") { Destructif = true });
        // Steam et Epic tiennent leur propre liste de jeux installés : Home ne supprime pas leurs fichiers lui-même, il ouvre leur désinstallation
        if (j.Origine is Origine.Steam or Origine.Epic)
        {
            var steam = j.Origine == Origine.Steam; var boutique = steam ? "Steam" : "Epic Games";
            m.Elements.Add(new("Désinstaller", "trash", () => Ouvrir(new Menu
            {
                Titre = "Désinstaller " + j.Nom + " ?", SousTitre = boutique, Symbole = "trash", Retour = OuvrirOptions,
                Texte = (steam ? "Home ouvre la désinstallation de Steam, qui te demande de confirmer : c'est Steam qui enlève le jeu."
                               : "Home ouvre le lanceur Epic Games : dans ta bibliothèque, clique sur les trois points du jeu, puis « Désinstaller ». C'est Epic qui enlève le jeu.")
                    + "\nHome ne supprime aucun fichier lui-même. Quand c'est fait : Menu → Actualiser la bibliothèque.",
                Elements =
                {
                    new("Annuler", "xmark", OuvrirOptions),
                    new(steam ? "Ouvrir la désinstallation de Steam" : "Ouvrir Epic Games", "trash", () =>
                    {
                        FermerMenus(); Journal.Ecrire($"désinstallation demandée à {boutique} : {j.Id}");
                        if (!OperatingSystem.IsWindows()) { Dire(boutique + " ne s'ouvre que sur Windows"); return; }
                        Systeme.Ouvrir(steam ? "steam://uninstall/" + j.SteamId : "com.epicgames.launcher://store/library");
                    }) { Destructif = true },
                },
            }), "C'est " + boutique + " qui enlève le jeu") { Destructif = true });
        }
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
                new("Jaquette", "photo", () => _ = ChoisirImage(j, "couverture"), "Depuis un fichier image"),
                new("Fond", "photo.fill", () => _ = ChoisirImage(j, "fond"), "Depuis un fichier image"),
                new("Logo", "textformat", () => _ = ChoisirImage(j, "logo"), "Depuis un fichier image (PNG transparent)"),
                new("Rechercher les images", "magnifyingglass", () => RechercherImages(j), SteamGridDB.Cle != null ? "SteamGridDB, boutiques officielles, Steam" : "Boutiques officielles et Steam (sans clé SteamGridDB)"),
                new("Renommer", "pencil", () => Demander("Nouveau nom", null, n => { Config.Noms[j.Id] = n; Enregistrer(); FermerMenus(); Recharger(); }, texte: j.Nom), j.Nom),
            },
        });
    }
    async Task ChoisirImage(Jeu j, string quoi)
    {
        if (ChoisirFichier == null || await ChoisirFichier("Choisir une image", ["*.png", "*.jpg", "*.jpeg", "*.webp"]) is not { } f) return;
        try { File.Copy(f, Images.Fichier(j, quoi), true); if (quoi == "couverture") Discord.NoterSource(null, Images.Fichier(j, quoi)); ChargerArt(j); Dire("Image changée"); }
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
        var jeux = Jeux.Count(j => !Config.Masques.Contains(j.Id)); var cats = Categories.Count - 1;
        var m = new Menu { Titre = "Home", SousTitre = $"{jeux} jeu{(jeux > 1 ? "x" : "")} · {cats} catégorie{(cats > 1 ? "s" : "")}", Symbole = "gear" };
        if (MiseAJour.Version is { } nouvelle) m.Elements.Add(new("Mettre à jour Home", "arrow.down.circle", () => _ = MiseAJour.Installer(this), $"{Version} → {nouvelle} · Home se ferme, s'installe et se rouvre"));
        m.Elements.Add(new("Ajouter un jeu", "plus", OuvrirAjout, "Jeux Switch, apps et jeux Windows"));
        m.Elements.Add(new("Actualiser la bibliothèque", "arrow.clockwise", () => { FermerMenus(); Recharger(); Dire("Bibliothèque actualisée"); }, "Relit Steam, Epic Games et les jeux Switch"));
        if (Config.Masques.Count > 0) m.Elements.Add(new("Jeux masqués", "eye", OuvrirMasques, $"{Config.Masques.Count} masqué{(Config.Masques.Count > 1 ? "s" : "")}"));
        // « Nom : état » : la roue montre l'état dans une capsule, à côté du choix visé
        m.Elements.Add(new("Sons de Home : " + (Config.Sons ? "Activés" : "Coupés"), Config.Sons ? "speaker.wave.2" : "speaker.slash", () => { Config.Sons = !Config.Sons; Sons.Actifs = Config.Sons; Enregistrer(); OuvrirPlus(); }, "Les sons des menus et de la bibliothèque") { Section = "Réglages" });
        m.Elements.Add(new("Affichage : " + (Config.Fenetre ? "en fenêtre" : "plein écran"), "rectangle", () => { Config.Fenetre = !Config.Fenetre; Enregistrer(); AppliquerFenetre?.Invoke(); OuvrirPlus(); }, "F11 change aussi"));
        m.Elements.Add(new("Écran de démarrage : " + (Config.Ouverture ? "oui" : "non"), "sparkles", () => { Config.Ouverture = !Config.Ouverture; Enregistrer(); OuvrirPlus(); }, "Le logo et le jingle au lancement de Home"));
        m.Elements.Add(new("Animations réduites : " + (Config.AnimationsReduites ? "oui" : "non"), "sparkles", () => { Config.AnimationsReduites = !Config.AnimationsReduites; Mouvement.Reduit = Config.AnimationsReduites; Enregistrer(); Reconstruire?.Invoke(); OuvrirPlus(); },
            "Des fondus courts à la place des mouvements"));
        m.Elements.Add(new("Discord : " + (Config.Discord ? "oui" : "non"), "person.2", () => { Config.Discord = !Config.Discord; Enregistrer(); MajDiscord(); OuvrirPlus(); }, "Tes amis voient « Dans le menu », ou le jeu en cours et sa jaquette") { Teinte = Icones.Violet });
        m.Elements.Add(new("Clé SteamGridDB", "key", OuvrirCle, SteamGridDB.Cle != null ? "Enregistrée" : "Aucune : jaquettes carrées et images des jeux Epic et des apps"));
        if (MiseAJour.Version == null) m.Elements.Add(new("Chercher une mise à jour", "arrow.clockwise", async () => { if (await MiseAJour.Verifier()) OuvrirPlus(); else Dire("Home est à jour (" + Version + ")"); }, "Version " + Version) { Section = "Home" });
        m.Elements.Add(new("Composants", "sparkles", () => OuvrirMode(), Config.Mode switch { "nintendo" => "Jeux Nintendo", "pc" => "Jeux PC", _ => "Jeux Nintendo et jeux PC" }));
        m.Elements.Add(new("Catégories", "tag", OuvrirCategories, Config.Categories.Count == 0 ? "Ranger tes jeux à ta façon" : string.Join(", ", Config.Categories)));
        m.Elements.Add(new("Libérer de la place", "trash", () => MenusSwitch.LibererPlace(this), "Ce que les constructions ont laissé et qui ne sert plus") { Teinte = Icones.Orange });
        m.Elements.Add(new("Ouvrir le dossier de Home", "folder", () => Systeme.Ouvrir(Dossiers.Racine), "Réglages, images, jeux Switch, journal") { Section = MiseAJour.Version == null ? null : "Home" });
        // Home se ferme et se rouvre : la liste, les images et les réglages sont relus
        m.Elements.Add(new("Redémarrer", "arrow.clockwise", () =>
        {
            FermerMenus(); Son("retour");
            if (!OperatingSystem.IsWindows() || Environment.ProcessPath is not { } exe) { Dire("Home ne se redémarre que sur Windows"); return; }
            try { Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true }); Quitter?.Invoke(); } catch (Exception e) { Journal.Ecrire("redémarrage : " + e.Message); Dire("Home n'a pas pu se relancer"); }
        }, "Home se ferme et se rouvre"));
        m.Elements.Add(new("Quitter", "power", () => { FermerMenus(); Son("retour"); _ = Task.Delay(300).ContinueWith(_ => Dispatcher.UIThread.Post(() => Quitter?.Invoke())); }) { Destructif = true });
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
        Pas = null;
        int steam = Jeux.Count(j => j.Origine == Origine.Steam), epic = Jeux.Count(j => j.Origine == Origine.Epic);
        var m = new Menu { Titre = "Ajouter un jeu", SousTitre = "Que veux-tu ajouter ?", Symbole = "plus" };
        if (ModeNintendo) m.Elements.Add(new("Switch", "gamecontroller", () => MenusSwitch.Ajouter(this), "Construire un jeu à partir du fichier de ton jeu et de tes clés") { Teinte = Icones.Rouge });
        if (ModePC)
        {
            m.Elements.Add(new("App ou jeu Windows", "desktopcomputer", () => _ = AjouterApp(), "Choisir un programme (.exe) ou un raccourci"));
            m.Elements.Add(new() { Libelle = "Steam et Epic Games", Detail = $"Leurs jeux installés apparaissent tout seuls : {steam} Steam, {epic} Epic Games", Icone = "pc", Info = true, Section = "Détectés automatiquement" });
        }
        Ouvrir(m);
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
