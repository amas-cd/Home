//! home-steam — Steam dans Home, sans Obelisk : connexion par QR code, bibliothèque, téléchargement d'un jeu Windows et plan de
//! lancement, avec steam-kit (le code Steam d'Obelisk, GPL-3.0). Chaque commande écrit du JSON, une ligne par événement.
//!
//!   home-steam etat                      {"compte": "nom" | null}
//!   home-steam connexion                 {"ev":"qr","url":…} à montrer en QR code, puis {"ev":"connecte","compte":…}
//!   home-steam deconnexion               oublie le compte (trousseau)
//!   home-steam bibliotheque              [{"app": 730, "nom": "…", "windows": true}, …]
//!   home-steam installer APP DOSSIER     télécharge le jeu Windows dans DOSSIER/steam-APP-windows ; {"ev":"progress","frac":…}
//!   home-steam plan APP DOSSIER_DU_JEU   {"exe": …, "args": […], "cwd": …} d'après Steam (PICS)
//!   home-steam identifiants              les identifiants pour l'hôte Steam, en binaire sur la sortie (jamais affichés) : pour un tube
//!
//! Le compte : seuls le nom du compte et le jeton de session (refresh token) sont gardés, dans le trousseau de macOS
//! (service fr.anas.home.steam). Le mot de passe n'est jamais demandé : la connexion se valide dans l'app Steam du téléphone.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use obelisk_core::{OnlineStatus, Platform};
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

async fn installer(app_id: u32, parent: &Path) {
    if !parent.is_absolute() {
        echec("dossier d'installation attendu en chemin absolu");
    }
    let _ = std::fs::create_dir_all(parent);
    let c = std::sync::Arc::new(client().await);
    let suivi = {
        let c = c.clone();
        tokio::spawn(async move {
            let mut dernier = -1.0f64;
            loop {
                tokio::time::sleep(Duration::from_millis(700)).await;
                if let Some(p) = c.progress() {
                    if p.total_bytes > 0 {
                        let f = (p.completed_bytes as f64 / p.total_bytes as f64).clamp(0.0, 1.0);
                        if (f - dernier).abs() >= 0.001 {
                            dernier = f;
                            dire(serde_json::json!({"ev": "progress", "frac": (f * 10000.0).round() / 10000.0}));
                        }
                    }
                }
            }
        })
    };
    let r = c.download(app_id, Platform::Windows, langue(), parent).await;
    suivi.abort();
    match r {
        Ok(i) => dire(serde_json::json!({"ev": "installe", "app": i.app_id, "nom": i.name, "dossier": parent.join(&i.directory), "octets": i.total_bytes})),
        Err(e) => echec(&clair(&e.to_string())),
    }
    c.shutdown();
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
        Some("installer") if a.len() == 3 => installer(app(a.get(1)), Path::new(&a[2])).await,
        Some("plan") if a.len() == 3 => plan(app(a.get(1)), Path::new(&a[2])).await,
        Some("identifiants") => identifiants(),
        _ => echec("commande inconnue : etat | connexion | deconnexion | bibliotheque | installer APP DOSSIER | plan APP DOSSIER | identifiants"),
    }
}
