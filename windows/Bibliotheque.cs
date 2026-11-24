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
    public List<RecompInstalle> Recomps = new();
    public List<Jeu> Jeux = new();
    public readonly Dictionary<string, Art> Arts = new();
    public List<string> Categories = ["Tous"];
    public int IndexCategorie, Selection, IndexMenu;
    public Menu? Menu; public Saisie? Saisie; public string? Toast; public Tache? Tache;
    public Jeu? EnCours; public DateTime EnCoursDepuis;
    public Aides Aides = Aides.Clavier; public int? Batterie;
    // Ce que seule la fenêtre sait faire
    public Func<string, string[], Task<string?>>? ChoisirFichier; public Func<string, Task<string?>>? ChoisirDossier; public Func<Task<string?>>? PressePapiers;
    public Action? Devant, AppliquerFenetre, Quitter;

    static string FichierConfig => Dossiers.Fichier("jeux.json");
    static string FichierStats => Dossiers.Fichier("statistiques.json");
    public static readonly bool Demo = Environment.GetEnvironmentVariable("HOME_DEMO") == "1";
    public static string Version => Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0.0.0";

    public void Signaler() => Change?.Invoke();
    public void Son(string nom) => Sons.Jouer(nom);
    public void Enregistrer() => Json.Ecrire(FichierConfig, Config);

    // MARK: Bibliothèque
    /// Les jeux de la catégorie choisie : le dernier joué d'abord, puis par nom
    public List<Jeu> Visibles => Jeux.Where(j => !Config.Masques.Contains(j.Id) && (IndexCategorie == 0 || j.Categorie == Categories[IndexCategorie]))
        .OrderByDescending(j => Stats.TryGetValue(j.Id, out var s) ? s.DernierePartie ?? DateTime.MinValue : DateTime.MinValue).ThenBy(j => j.Nom, StringComparer.CurrentCultureIgnoreCase).ToList();
    public Jeu? Courant { get { var v = Visibles; return Selection < v.Count ? v[Selection] : null; } }
    public RecompInstalle? RecompDe(Jeu j) => j.Origine == Origine.Recomp ? Recomps.FirstOrDefault(r => "recomp:" + r.Id == j.Id) : null;

    public void Recharger(string? selectionner = null)
    {
        Sons.Actifs = Config.Sons;
        Recomps = Json.Lire<List<RecompInstalle>>(Installation.Registre);
        var jeux = new List<Jeu>();
        jeux.AddRange(Steam.Jeux()); jeux.AddRange(Epic.Jeux());
        foreach (var r in Recomps.Where(r => Demo || Directory.Exists(r.Dossier)))
            jeux.Add(new Jeu { Id = "recomp:" + r.Id, Nom = r.Jeu != "" && !r.HorsCatalogue ? r.Jeu : r.Nom, Origine = Origine.Recomp, Cible = r.Exe ?? "", Dossier = r.Dossier });
        foreach (var e in Config.Jeux.Where(e => Demo || File.Exists(e.Chemin)))
            jeux.Add(new Jeu { Id = "app:" + e.Chemin, Nom = e.Nom ?? Path.GetFileNameWithoutExtension(e.Chemin), Origine = Origine.App, Cible = e.Chemin, Dossier = Path.GetDirectoryName(e.Chemin) ?? "" });
        foreach (var j in jeux) if (Config.Noms.TryGetValue(j.Id, out var n)) j.Nom = n;
        var avant = selectionner ?? Courant?.Id; var categorie = Categories.ElementAtOrDefault(IndexCategorie);
        Jeux = jeux;
        Categories = ["Tous", .. new[] { "Steam", "Epic Games", "Recomps", "Apps" }.Where(c => jeux.Any(j => j.Categorie == c && !Config.Masques.Contains(j.Id)))];
        IndexCategorie = selectionner != null ? 0 : Math.Max(0, Categories.IndexOf(categorie ?? "Tous"));
        var i = Visibles.FindIndex(j => j.Id == avant); Selection = i >= 0 ? i : Math.Min(Selection, Visibles.Count);
        Journal.Ecrire($"bibliothèque : {jeux.Count(j => j.Origine == Origine.Steam)} Steam, {jeux.Count(j => j.Origine == Origine.Epic)} Epic, {jeux.Count(j => j.Origine == Origine.Recomp)} recomps, {jeux.Count(j => j.Origine == Origine.App)} apps");
        foreach (var j in jeux) if (!Arts.ContainsKey(j.Id)) ChargerArt(j);
        Signaler();
    }
    public async void ChargerArt(Jeu j)
    {
        var art = await Images.Charger(j, RecompDe(j));
        Arts[j.Id] = art; Signaler();
    }

    // MARK: Navigation
    public void Nav(string k)
    {
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
        var m = Menu!; var e = m.Elements;
        int Suivant(int de, int pas) { for (var i = de + pas; i >= 0 && i < e.Count; i += pas) if (!e[i].Info) return i; return de; }   // saute les lignes d'information
        var cible = IndexMenu;
        switch (k)
        {
            case "down": cible = m.Grille ? Math.Min(IndexMenu + 3, e.Count - 1) : Suivant(IndexMenu, 1); break;
            case "up": cible = m.Grille ? Math.Max(IndexMenu - 3, 0) : Suivant(IndexMenu, -1); break;
            case "right" when m.Grille: cible = Suivant(IndexMenu, 1); break;
            case "left" when m.Grille: cible = Suivant(IndexMenu, -1); break;
            case "ok": if (IndexMenu < e.Count && !e[IndexMenu].Info) { Son("valider"); e[IndexMenu].Action(); } return;
            case "back": Son("retour"); if (m.Retour != null) m.Retour(); else FermerMenus(); return;
            case "plus" or "options": Son("retour"); FermerMenus(); return;
        }
        if (cible != IndexMenu && cible < e.Count && !e[cible].Info) { IndexMenu = cible; Son("deplacer"); Signaler(); }
    }
    public void Ouvrir(Menu m)
    {
        if (Menu == null) Son("ouvrir");
        Menu = m; IndexMenu = Math.Max(0, m.Elements.FindIndex(e => !e.Info)); Signaler();
    }
    public void FermerMenus() { Menu = null; Signaler(); }
    public void ChoisirMenu(int i) { if (Menu is { } m && i < m.Elements.Count && !m.Elements[i].Info) { IndexMenu = i; Son("valider"); Signaler(); m.Elements[i].Action(); } }
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
        if (EnCours != null) return;
        _ = LancerJeu(j);
    }
    async Task LancerJeu(Jeu j)
    {
        try
        {
            string cible = j.Cible, dossier = j.Dossier;
            if (RecompDe(j) is { } r)
            {
                if (await PreparerRecomp(r) is not { } exe) return;
                cible = exe; if (!exe.StartsWith(r.Dossier, StringComparison.OrdinalIgnoreCase)) dossier = Path.GetDirectoryName(exe)!;
            }
            Son("lancer"); FermerMenus();
            Process? p = null;
            if (OperatingSystem.IsWindows())
                p = Process.Start(new ProcessStartInfo(cible) { UseShellExecute = true, WorkingDirectory = File.Exists(cible) ? Path.GetDirectoryName(cible)! : "" });
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
        Devant?.Invoke(); Signaler();
    }
    /// Attend la fin de la partie. Une app lancée directement : on attend son processus. Steam, Epic et les recomps : on regarde si un
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
    /// Le programme d'un recomp. Certains (TotK Recomp) se construisent d'abord avec leur setup, à partir des fichiers du joueur :
    /// Home lance le setup, puis retrouve le jeu produit.
    async Task<string?> PreparerRecomp(RecompInstalle r)
    {
        if (r.Exe != null && File.Exists(r.Exe)) return r.Exe;
        if (r.ExeAttendu != null && Installation.Trouver(r.Dossier, r.ExeAttendu) is { } e) return Retenir(r, e);
        if (r.Installeur != null && Installation.Trouver(r.Dossier, r.Installeur) is { } setup)
        {
            var cat = Catalogue.Par(r.Id);
            Ouvrir(new Menu
            {
                Titre = r.Nom, SousTitre = "Première fois : le jeu doit être construit", Symbole = "hammer",
                Texte = "Ce jeu se construit une seule fois, sur ce PC, à partir de tes propres fichiers (le dump de ta console). Le setup de l'auteur te les demande, puis fait le travail."
                    + (cat?.Besoin is { Length: > 0 } b ? "\n\nIl te faut : " + b : "") + (cat?.Note is { } n ? "\n\n" + n : "")
                    + $"\n\nConseil : choisis comme dossier d'installation\n{Path.Combine(r.Dossier, "jeu")}\nHome retrouvera le jeu tout seul.",
                Elements =
                {
                    new("Lancer le setup", "hammer", () => _ = LancerSetup(r, setup), r.Installeur),
                    new("Le jeu est déjà construit", "folder", () => _ = MontrerDossier(r), "Montrer à Home le dossier où il est installé"),
                },
            });
            return null;
        }
        if (Installation.Deviner(r.Dossier) is { } devine) return Retenir(r, devine);
        if (ChoisirFichier != null && await ChoisirFichier($"Quel programme lance {r.Nom} ?", ["*.exe"]) is { } choisi) return Retenir(r, choisi);
        return null;
    }
    string Retenir(RecompInstalle r, string exe)
    {
        r.Exe = exe; Json.Ecrire(Installation.Registre, Recomps);
        var j = Jeux.FirstOrDefault(x => x.Id == "recomp:" + r.Id); if (j != null) j.Cible = exe;
        return exe;
    }
    async Task LancerSetup(RecompInstalle r, string setup)
    {
        FermerMenus();
        if (!OperatingSystem.IsWindows()) { Dire("Le setup ne se lance que sur Windows"); return; }
        try
        {
            Directory.CreateDirectory(Path.Combine(r.Dossier, "jeu"));
            using var p = Process.Start(new ProcessStartInfo(setup) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(setup)! });
            Dire("Le setup est ouvert. Reviens ici quand il a fini.");
            if (p != null) await p.WaitForExitAsync();
            Devant?.Invoke();
            if (r.ExeAttendu != null && Installation.Trouver(r.Dossier, r.ExeAttendu) is { } e) { Retenir(r, e); Dire($"{r.Nom} est prêt"); }
            else await MontrerDossier(r);
        }
        catch (Exception e) { Journal.Ecrire($"setup de {r.Id} : {e.Message}"); Dire("Le setup n'a pas pu être lancé"); }
    }
    async Task MontrerDossier(RecompInstalle r)
    {
        FermerMenus();
        if (ChoisirDossier == null || await ChoisirDossier($"Dans quel dossier as-tu installé {r.Nom} ?") is not { } d) return;
        var exe = (r.ExeAttendu != null ? Installation.Trouver(d, r.ExeAttendu) : null) ?? Installation.Deviner(d);
        if (exe != null) { Retenir(r, exe); Dire($"{r.Nom} est prêt"); } else Dire($"{r.ExeAttendu ?? "Le jeu"} n'est pas dans ce dossier");
    }

    // MARK: Menus
    public void OuvrirOptions()
    {
        if (Courant is not { } j) return;
        var r = RecompDe(j); var cat = r != null ? Catalogue.Par(r.Id) : null;
        var m = new Menu { Titre = j.Nom, SousTitre = j.Categorie + (r != null ? $" · {r.Nom} {r.Version}" : ""), Art = Arts.GetValueOrDefault(j.Id)?.Couverture, Symbole = "gamecontroller" };
        m.Elements.Add(new("Jouer", "play.fill", () => { FermerMenus(); Lancer(); }));
        if (r != null && cat != null && cat.Version != r.Version) m.Elements.Add(new("Mettre à jour", "arrow.down.circle", () => MenusRecomps.Fiche(this, cat, OuvrirOptions), $"{r.Version} → {cat.Version}"));
        m.Elements.Add(new("Changer la jaquette", "photo", () => _ = ChoisirImage(j, "couverture"), "Depuis un fichier image") { Section = "Apparence" });
        m.Elements.Add(new("Changer le fond", "photo.fill", () => _ = ChoisirImage(j, "fond"), "Depuis un fichier image"));
        m.Elements.Add(new("Changer le logo", "textformat", () => _ = ChoisirImage(j, "logo"), "Depuis un fichier image (PNG transparent)"));
        m.Elements.Add(new("Rechercher les images", "magnifyingglass", () => RechercherImages(j), SteamGridDB.Cle != null ? "Steam, catalogue, SteamGridDB" : "Sans clé SteamGridDB : Steam et catalogue seulement"));
        m.Elements.Add(new("Renommer", "pencil", () => Demander("Nouveau nom", j.Nom, n => { Config.Noms[j.Id] = n; Enregistrer(); FermerMenus(); Recharger(); })));
        if (Directory.Exists(j.Dossier)) m.Elements.Add(new("Ouvrir le dossier du jeu", "folder", () => Systeme.Ouvrir(j.Dossier)) { Section = "Jeu" });
        if (r != null) m.Elements.Add(new("Page GitHub du recomp", "safari", () => Systeme.Ouvrir("https://github.com/" + r.Depot), r.Depot));
        m.Elements.Add(new("Masquer", "eye.slash", () => { Config.Masques.Add(j.Id); Enregistrer(); FermerMenus(); Recharger(); }, "Le jeu reste installé ; Menu → Jeux masqués pour le remettre"));
        if (r != null) m.Elements.Add(new("Désinstaller", "trash", () => ConfirmerDesinstallation(j, r)) { Destructif = true });
        if (j.Origine == Origine.App) m.Elements.Add(new("Retirer de Home", "trash", () => { Config.Jeux.RemoveAll(e => "app:" + e.Chemin == j.Id); Enregistrer(); FermerMenus(); Recharger(); }, "Le programme n'est pas supprimé") { Destructif = true });
        Ouvrir(m);
    }
    void ConfirmerDesinstallation(Jeu j, RecompInstalle r)
    {
        Ouvrir(new Menu
        {
            Titre = "Désinstaller " + j.Nom + " ?", Symbole = "trash", Retour = OuvrirOptions,
            Texte = $"Le dossier du recomp part à la Corbeille :\n{r.Dossier}\n\nSi le jeu a été construit ailleurs, ce dossier-là n'est pas touché. Tes fichiers de jeu d'origine non plus.",
            Elements =
            {
                new("Annuler", "xmark", OuvrirOptions),
                new("Mettre à la Corbeille", "trash", () =>
                {
                    if (Directory.Exists(r.Dossier) && !Systeme.Corbeille(r.Dossier)) { Dire("Le dossier n'a pas pu être mis à la Corbeille"); return; }
                    Recomps.RemoveAll(x => x.Id == r.Id); Json.Ecrire(Installation.Registre, Recomps); Journal.Ecrire($"recomp désinstallé : {r.Id}");
                    FermerMenus(); Recharger(); Dire(j.Nom + " est désinstallé");
                }) { Destructif = true },
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
        m.Elements.Add(new("Ajouter un jeu", "plus", OuvrirAjout, "Recomps, apps et jeux Windows"));
        m.Elements.Add(new("Actualiser la bibliothèque", "arrow.clockwise", () => { FermerMenus(); Recharger(); Dire("Bibliothèque actualisée"); }, "Relit Steam, Epic Games et les recomps"));
        if (Config.Masques.Count > 0) m.Elements.Add(new("Jeux masqués", "eye", OuvrirMasques, $"{Config.Masques.Count} masqué{(Config.Masques.Count > 1 ? "s" : "")}"));
        m.Elements.Add(new("Sons de l'interface", Config.Sons ? "speaker.wave.2" : "speaker.slash", () => { Config.Sons = !Config.Sons; Sons.Actifs = Config.Sons; Enregistrer(); OuvrirPlus(); }, Config.Sons ? "Activés" : "Coupés") { Section = "Réglages" });
        m.Elements.Add(new("Affichage", "rectangle", () => { Config.Fenetre = !Config.Fenetre; Enregistrer(); AppliquerFenetre?.Invoke(); OuvrirPlus(); }, Config.Fenetre ? "En fenêtre" : "Plein écran"));
        m.Elements.Add(new("Clé SteamGridDB", "key", OuvrirCle, SteamGridDB.Cle != null ? "Enregistrée" : "Aucune : jaquettes carrées et images des jeux Epic et des apps"));
        if (MiseAJour.Version == null) m.Elements.Add(new("Chercher une mise à jour", "arrow.clockwise", async () => { if (await MiseAJour.Verifier()) OuvrirPlus(); else Dire("Home est à jour (" + Version + ")"); }, "Version " + Version) { Section = "Home" });
        m.Elements.Add(new("Ouvrir le dossier de Home", "folder", () => Systeme.Ouvrir(Dossiers.Racine), "Réglages, images, recomps, journal") { Section = MiseAJour.Version == null ? null : "Home" });
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
                new("Recomps", "gamecontroller", () => MenusRecomps.Ouvrir(this), "Jeux console recompilés pour Windows : catalogue, puis GitHub"),
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

    /// Démonstration (HOME_DEMO=1, sur Mac) : les recomps en vedette du catalogue, comme s'ils étaient installés, pour vérifier l'interface
    public async Task ChargerDemo()
    {
        if (!await Catalogue.Charger()) return;
        var liste = Catalogue.Vedettes.Select(Catalogue.Par).Where(r => r != null).Take(8).Select(r => new RecompInstalle
            { Id = r!.Id, Nom = r.Nom, Jeu = r.Jeu, Depot = r.Depot, Version = r.Version, Dossier = Path.Combine(Dossiers.Racine, "recomps", r.Id), Couverture = r.Couverture, Fond = r.Fond, Logo = r.Logo }).ToList();
        Json.Ecrire(Installation.Registre, liste);
        Config.Jeux = [new Entree { Chemin = @"C:\Jeux\Exemple.exe", Nom = "Une app Windows" }];
        Recharger();
    }
}
