//! home-steam — Steam dans Home, sans Obelisk : connexion par QR code, bibliothèque, téléchargement d'un jeu Windows et plan de
//! lancement, avec steam-kit (le code Steam d'Obelisk, GPL-3.0). Chaque commande écrit du JSON, une ligne par événement.
//!
//!   home-steam etat                      {"compte": "nom" | null}
//!   home-steam connexion                 {"ev":"qr","url":…} à montrer en QR code, puis {"ev":"connecte","compte":…}
//!   home-steam deconnexion               oublie le compte (trousseau)
//!   home-steam bibliotheque              [{"app": 730, "nom": "…", "windows": true}, …]
//!   home-steam installer APP             télécharge le jeu Windows (et, s'ils manquent, le moteur Voile et les composants de Valve) ;
//!                                        {"ev":"progress","frac":…} puis {"ev":"installe","app":…,"nom":…,"dossier":…}
//!   home-steam jeux                      les jeux Steam installés par Home : [{"app":…,"nom":…,"dossier":…}]
//!   home-steam lancer APP                lance un jeu installé et reste là tant qu'il tourne ; un signal TERM ferme le jeu
//!   home-steam plan APP DOSSIER_DU_JEU   {"exe": …, "args": […], "cwd": …} d'après Steam (PICS)
//!
//! installer et lancer passent par obelisk-bridge, la même porte d'entrée que l'app Obelisk : téléchargement des dépôts, préfixe
//! Windows, hôte Steam (la bibliothèque de Valve, pilotée par obelisk-steam-host), sauvegardes Steam Cloud. Les dossiers sont ceux de
//! Home : <Home>/pc/steam (jeux, reçus, sessions), <Home>/voile, <Home>/pc/prefixes, et l'hôte compilé dans <Home>/moteur/bin/SteamNative.
//!   home-steam identifiants              les identifiants pour l'hôte Steam, en binaire sur la sortie (jamais affichés) : pour un tube
//!
//! Le compte : seuls le nom du compte et le jeton de session (refresh token) sont gardés, dans le trousseau de macOS
//! (service fr.anas.home.steam). Le mot de passe n'est jamais demandé : la connexion se valide dans l'app Steam du téléphone.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use obelisk_bridge as ob;
use obelisk_core::{OnlineStatus, Platform};
use std::path::PathBuf;
use std::sync::Arc;
use steam_kit::auth::{AuthClient, AuthTokens};
use steam_kit::client::{Client, http_client};

const SERVICE: &str = "fr.anas.home.steam";
const COMPTE: &str = "session";

fn dire(v: serde_json::Value) {
    println!("{v}");
    let _ = std::io::stdout().flush();
}

fn echec(message: &str) -> ! {
    println!("ÉCHEC : {message}");
    std::process::exit(1)
}

/// Les messages de steam-kit sont des clés (backend.steam.…) : les plus courantes en clair
fn clair(cle: &str) -> String {
    let c = cle.to_string();
    let t = match cle {
        k if k.contains("gameNotOwned") => "ce jeu n'est pas dans ta bibliothèque Steam",
        k if k.contains("auth.expired") => "le QR code a expiré : recommence la connexion",
        k if k.contains("auth.network") || k.contains("network") => "Steam est injoignable (connexion ?)",
        k if k.contains("rateLimited") => "trop d'essais : Steam demande d'attendre un peu",
        k if k.contains("unsupportedPlatformOrLanguage") || k.contains("platformUnavailable") => "ce jeu n'a pas de version Windows téléchargeable",
        k if k.contains("incompleteInstallation") => "l'installation du jeu est incomplète : relance son téléchargement",
        k if k.contains("noCompatibleConfiguration") => "Steam ne donne pas de programme Windows à lancer pour ce jeu",
        k if k.contains("logon") || k.contains("accessDenied") || k.contains("session") => "Steam a refusé la session : reconnecte ton compte",
        _ => return c,
    };
    format!("{t} ({c})")
}

// ---------- trousseau : « nom du compte \n jeton », en hexadécimal (aucun caractère à protéger dans la commande) ----------
fn hexa(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn dehexa(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

fn garder(tokens: &AuthTokens) -> bool {
    let valeur = hexa(format!("{}\n{}", tokens.account_name, tokens.refresh_token).as_bytes());
    // security -i lit sa commande sur l'entrée : le jeton n'apparaît pas dans la liste des processus
    let Ok(mut p) = Command::new("/usr/bin/security").arg("-i").stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() else {
        return false;
    };
    if let Some(mut entree) = p.stdin.take() {
        let _ = writeln!(entree, "add-generic-password -U -s {SERVICE} -a {COMPTE} -l \"Home — session Steam\" -w {valeur}");
    }
    p.wait().map(|s| s.success()).unwrap_or(false)
}

fn compte() -> Option<AuthTokens> {
    let o = Command::new("/usr/bin/security").args(["find-generic-password", "-s", SERVICE, "-a", COMPTE, "-w"]).stderr(Stdio::null()).output().ok()?;
    if !o.status.success() {
        return None;
    }
    let brut = String::from_utf8(dehexa(&String::from_utf8(o.stdout).ok()?)?).ok()?;
    let (nom, jeton) = brut.split_once('\n')?;
    AuthTokens::restore(nom.to_owned(), jeton.to_owned()).ok()
}

fn oublier() {
    let _ = Command::new("/usr/bin/security").args(["delete-generic-password", "-s", SERVICE, "-a", COMPTE]).stdout(Stdio::null()).stderr(Stdio::null()).status();
}

fn exiger_compte() -> AuthTokens {
    compte().unwrap_or_else(|| {
        println!("ÉCHEC : pas connecté à Steam");
        std::process::exit(2)
    })
}

async fn client() -> Client {
    let t = exiger_compte();
    // Invisible : la session de Home ne te montre pas « en ligne » à tes amis pendant qu'elle lit ta bibliothèque
    match Client::connect(&t.account_name, t.steam_id, &t.refresh_token, OnlineStatus::Invisible).await {
        Ok(c) => c,
        Err(e) => echec(&clair(&format!("{e:?}"))),
    }
}

fn langue() -> &'static str {
    let o = Command::new("/usr/bin/defaults").args(["read", "-g", "AppleLocale"]).output();
    let l = o.ok().and_then(|o| String::from_utf8(o.stdout).ok()).unwrap_or_default();
    steam_kit::language::from_locale(l.trim())
}

fn app(arg: Option<&String>) -> u32 {
    arg.and_then(|a| a.parse().ok()).filter(|a| *a != 0).unwrap_or_else(|| echec("identifiant de jeu Steam attendu (un nombre)"))
}

// ---------- commandes ----------
async fn connexion() {
    let http = http_client().unwrap_or_else(|e| echec(&e.to_string()));
    let auth = AuthClient::new(http);
    let mut session = auth.begin_qr().await.unwrap_or_else(|e| echec(&clair(&e.to_string())));
    let mut montre = String::new();
    let debut = Instant::now();
    loop {
        // Steam renouvelle le QR code de temps en temps : chaque nouvelle adresse est redonnée
        if let Some(url) = session.challenge_url() {
            if url != montre {
                montre = url.to_owned();
                dire(serde_json::json!({"ev": "qr", "url": montre}));
            }
        }
        tokio::time::sleep(session.polling_interval().max(Duration::from_secs(1))).await;
        match auth.poll(&mut session).await {
            Ok(Some(tokens)) => {
                if !garder(&tokens) {
                    echec("le trousseau de macOS a refusé d'enregistrer la session Steam");
                }
                dire(serde_json::json!({"ev": "connecte", "compte": tokens.account_name}));
                return;
            }
            Ok(None) => {}
            Err(e) => echec(&clair(&e.to_string())),
        }
        if debut.elapsed() > Duration::from_secs(300) {
            echec("personne n'a validé la connexion (5 minutes) : recommence");
        }
    }
}

async fn bibliotheque() {
    let c = client().await;
    let jeux = c.games().await.unwrap_or_else(|e| echec(&clair(&e.to_string())));
    let ids: Vec<u32> = jeux.iter().map(|j| j.app_id).collect();
    // les plateformes déclarées (PICS) : sans réponse, le jeu est gardé (inconnu ne veut pas dire absent)
    let plateformes = c.platforms(&ids).await.unwrap_or_default();
    let sortie: Vec<_> = jeux
        .iter()
        .map(|j| {
            let p = plateformes.iter().find(|p| p.app_id == j.app_id).map(|p| p.platforms.clone()).unwrap_or_default();
            let windows = p.is_empty() || p.iter().any(|x| x.eq_ignore_ascii_case("windows"));
            serde_json::json!({"app": j.app_id, "nom": j.name, "windows": windows, "minutes": j.playtime_minutes})
        })
        .collect();
    dire(serde_json::Value::Array(sortie));
    c.shutdown();
}

// ---------- installer et lancer : le circuit complet d'Obelisk, dans les dossiers de Home ----------
fn racine() -> PathBuf {
    PathBuf::from(std::env::var("HOME_RACINE").ok().filter(|r| r.starts_with('/')).unwrap_or_else(|| "/Applications/Home".into()))
}

fn lieux() -> ob::ObeliskLocations {
    let r = racine();
    let chemin = |p: PathBuf| p.to_string_lossy().into_owned();
    let maison = std::env::var("HOME").unwrap_or_else(|_| echec("HOME manque"));
    let mut l = ob::obelisk_locations(chemin(r.join("pc/steam")), chemin(r.join("moteur/bin")), maison);
    let natifs = r.join("moteur/bin/SteamNative");
    l.helper = chemin(natifs.join(game_runtime::package::HOST));
    l.helpers = chemin(natifs);
    let cache = r.join("pc/steam/Cache/SteamRuntime");
    l.steam_runtime_package = chemin(game_runtime::valve::payload(&cache));
    l.steam_runtime_cache = chemin(cache);
    l.voile = chemin(r.join("voile"));               // le même Voile que les jeux Epic de Home
    l.wine_prefixes = chemin(r.join("pc/prefixes"));
    if !Path::new(&l.helper).is_file() {
        echec("l'hôte Steam n'est pas compilé : relance « Préparer Steam »");
    }
    l
}

struct Compte {
    session: Arc<ob::SteamSession>,
    sessions: Arc<ob::StorefrontSessions>,
    installations: Arc<ob::AccountInstallations>,
}

/// La session Steam du compte, ses parties (sessions de jeu) et ses installations, comme l'app Obelisk les assemble
async fn compte_complet(statut: ob::OnlineStatus) -> Compte {
    let t = exiger_compte();
    let l = lieux();
    let _ = std::fs::create_dir_all(&l.library);
    let identifiants = ob::SteamCredentials { account_name: t.account_name.clone(), steam_id: t.steam_id, refresh_token: t.refresh_token.clone() };
    let session = match ob::SteamSession::connect(identifiants.clone(), None, statut).await {
        Ok(s) => s,
        Err(e) => echec(&clair(&e.to_string())),
    };
    let sessions = ob::StorefrontSessions::new(ob::SessionStorefront::Steam, l.clone());
    let recus = Path::new(&l.library).join(format!("steam-installations-{}.json", t.steam_id)).to_string_lossy().into_owned();
    let installations = match ob::AccountInstallations::steam(session.clone(), identifiants, sessions.clone(), recus, l) {
        Ok(i) => i,
        Err(e) => echec(&clair(&e.to_string())),
    };
    Compte { session, sessions, installations }
}

fn installe(etat: &ob::InstallationsState, app_id: u32) -> Option<ob::Installation> {
    etat.installations.iter().find(|i| i.game == app_id.to_string() && i.platform == ob::GamePlatform::Windows).cloned()
}

fn rapport(r: &ob::InstallationReport) -> String {
    match r {
        ob::InstallationReport::Storefront { key } => clair(key),
        ob::InstallationReport::DownloadDirectory { message } => format!("dossier des jeux : {message}"),
        ob::InstallationReport::GamesFolderUnavailable { path } => format!("dossier des jeux inaccessible : {path}"),
        autre => format!("{autre:?}"),
    }
}

async fn installer(app_id: u32) {
    let c = compte_complet(ob::OnlineStatus::Invisible).await;
    let nom = match c.session.games().await {
        Ok(jeux) => jeux.into_iter().find(|j| j.app_id == app_id).map(|j| j.name),
        Err(e) => echec(&clair(&e.to_string())),
    }
    .unwrap_or_else(|| echec("ce jeu n'est pas dans ta bibliothèque Steam"));
    dire(serde_json::json!({"ev": "stage", "k": 1, "n": 1, "name": format!("Téléchargement de {nom}")}));
    c.installations.install(ob::GameOffer::Steam { app_id, name: nom.clone(), language: langue().into() }, Some(ob::GamePlatform::Windows));
    let (mut revision, mut dernier, mut vu) = (0u64, -1.0f64, false);
    loop {
        let e = tokio::time::timeout(Duration::from_secs(2), c.installations.changed(revision)).await.unwrap_or_else(|_| c.installations.state());
        revision = e.revision;
        if let Some(r) = &e.report {
            echec(&rapport(r));
        }
        if let Some(t) = e.transfer.as_ref().filter(|t| t.game == app_id.to_string()) {
            vu = true;
            match t.state {
                ob::TransferState::Failed | ob::TransferState::Cancelled => echec(&clair(&t.message)),
                _ if t.total_bytes > 0 => {
                    let f = (t.completed_bytes as f64 / t.total_bytes as f64).clamp(0.0, 1.0);
                    if (f - dernier).abs() >= 0.001 {
                        dernier = f;
                        dire(serde_json::json!({"ev": "progress", "frac": (f * 10000.0).round() / 10000.0}));
                    }
                }
                _ => {}
            }
        }
        // fini : le Transfert a tourné, plus rien ne télécharge, et le reçu du jeu est là, complet
        if (vu || e.transfer.is_none()) && !e.downloading && e.queued.is_empty() {
            if let Some(i) = installe(&e, app_id).filter(|i| !i.needs_verification) {
                dire(serde_json::json!({"ev": "installe", "app": app_id, "nom": i.name, "dossier": i.directory, "octets": i.total_bytes}));
                c.session.shutdown();
                return;
            }
        }
    }
}

async fn jeux() {
    let l = lieux();
    let Some(t) = compte() else {
        dire(serde_json::json!([]));
        return;
    };
    // les reçus du compte, lus sans se connecter à Steam
    let recus = Path::new(&l.library).join(format!("steam-installations-{}.json", t.steam_id));
    let v: serde_json::Value = std::fs::read(&recus).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(serde_json::json!([]));
    let sortie: Vec<_> = v
        .as_array()
        .into_iter()
        .flatten()
        .filter(|j| j["platform"].as_str().is_some_and(|p| p.eq_ignore_ascii_case("windows")) && j["directory"].as_str().is_some_and(|d| Path::new(d).is_dir()))
        .map(|j| serde_json::json!({"app": j["appId"], "nom": j["name"], "dossier": j["directory"]}))
        .collect();
    dire(serde_json::Value::Array(sortie));
}

async fn lancer(app_id: u32) {
    let c = compte_complet(ob::OnlineStatus::Online).await;
    let Some(i) = installe(&c.installations.state(), app_id) else { echec("ce jeu n'est pas installé par Home") };
    c.installations.launch(i.id.clone());
    let mut terme = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap_or_else(|_| echec("signaux indisponibles"));
    let (mut parti, mut en_jeu, mut etape, mut debut) = (false, false, String::new(), Instant::now());
    loop {
        tokio::select! {
            _ = terme.recv() => {   // Home ferme le jeu : arrêt propre, les sauvegardes Cloud se règlent
                let _ = c.sessions.stop().await;
                debut = Instant::now();
            }
            _ = tokio::time::sleep(Duration::from_millis(500)) => {}
        }
        let e = c.installations.state();
        if let Some(r) = &e.report {
            echec(&rapport(r));
        }
        let s = c.sessions.state();
        if let Some(a) = &s.active {
            parti = true;
            if let Some(offre) = &a.voile_update {   // une version plus récente du moteur : prise si le jeu la demande, sinon passée
                let _ = c.sessions.answer_voile_update(a.id.clone(), if offre.required { ob::VoileUpdateAnswer::Update } else { ob::VoileUpdateAnswer::Skip });
            }
            if let Some(r) = &a.runtime_install {
                dire(serde_json::json!({"ev": "progress", "frac": (r.fraction * 1000.0).round() / 1000.0, "quoi": format!("{:?}", r.component)}));
            }
            let maintenant = format!("{:?}", a.phase);
            if maintenant != etape {
                etape = maintenant;
                dire(serde_json::json!({"ev": "phase", "phase": etape}));
            }
            if matches!(a.phase, ob::GamePhase::Running) {
                en_jeu = true;
            }
        } else if s.rosetta.is_some() {
            echec("Rosetta manque : dans le Terminal, tape  softwareupdate --install-rosetta --agree-to-license  puis relance le jeu");
        } else if parti {
            // la partie est finie : dernier état gardé par les sessions
            let fin = s.last.as_ref().map(|l| format!("{:?}", l.phase)).unwrap_or_default();
            if fin == "Failed" && !en_jeu {
                echec("le jeu n'a pas démarré (journal dans <Home>/pc/steam)");
            }
            dire(serde_json::json!({"ev": "fini", "phase": fin}));
            c.session.shutdown();
            return;
        } else if !e.launching && debut.elapsed() > Duration::from_secs(60) {
            echec("le lancement n'a pas commencé");
        }
    }
}

async fn plan(app_id: u32, dossier: &Path) {
    let c = client().await;
    match c.launch_plan(app_id, Platform::Windows, dossier).await {
        Ok(p) => dire(serde_json::json!({"exe": p.target.executable, "args": p.target.arguments, "cwd": p.target.working_directory})),
        Err(e) => echec(&clair(&e.to_string())),
    }
    c.shutdown();
}

/// Ce que l'hôte Steam d'Obelisk lit sur son entrée (game-runtime/src/protocol.rs) :
/// u64 identifiant Steam | u32 longueur du jeton | u32 longueur du nom | jeton | nom du compte, petit-boutiste
fn identifiants() {
    let t = exiger_compte();
    let mut b = Vec::new();
    b.extend_from_slice(&t.steam_id.to_le_bytes());
    b.extend_from_slice(&(t.refresh_token.len() as u32).to_le_bytes());
    b.extend_from_slice(&(t.account_name.len() as u32).to_le_bytes());
    b.extend_from_slice(t.refresh_token.as_bytes());
    b.extend_from_slice(t.account_name.as_bytes());
    if std::io::IsTerminal::is_terminal(&std::io::stdout()) {
        echec("les identifiants ne s'affichent pas : cette commande s'utilise dans un tube vers l'hôte Steam");
    }
    let _ = std::io::stdout().write_all(&b);
}

#[tokio::main]
async fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    match a.first().map(String::as_str) {
        Some("etat") => dire(serde_json::json!({"compte": compte().map(|t| t.account_name)})),
        Some("connexion") => connexion().await,
        Some("deconnexion") => {
            oublier();
            dire(serde_json::json!({"compte": null}));
        }
        Some("bibliotheque") => bibliotheque().await,
        Some("installer") if a.len() == 2 => installer(app(a.get(1))).await,
        Some("jeux") => jeux().await,
        Some("lancer") if a.len() == 2 => lancer(app(a.get(1))).await,
        Some("plan") if a.len() == 3 => plan(app(a.get(1)), Path::new(&a[2])).await,
        Some("identifiants") => identifiants(),
        _ => echec("commande inconnue : etat | connexion | deconnexion | bibliotheque | installer APP | jeux | lancer APP | plan APP DOSSIER | identifiants"),
    }
}
