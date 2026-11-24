// Salon — launcher de jeux façon PS5 (Mac, Swift/SwiftUI, un seul fichier). Construit par salon-construire.command.
//
// Jeux : les .app de /Applications/Jeux, celles de ~/Library/Application Support/Salon/jeux.json et les apps/alias déposés dans
// ~/Library/Application Support/Salon/jeux/. Catégories : Switch / Switch 2 (lues dans l'Info.plist des apps nxnative, clé DMTitleID),
// Mac, PC, ou la catégorie donnée dans jeux.json.
//
// Illustrations, dans cet ordre (la même logique que NX Library, dont le code public a servi de modèle) :
//   1. tes fichiers : media/<nom du jeu>/cover|fond|logo.(jpg|png), fond.mp4 (fond animé)
//   2. les choix faits dans NX Library : ~/Library/Application Support/NXLibrary/artwork-picks/<title id>/{square,boxart,hero,logo}
//   3. le cache de NX Library : ~/Library/Application Support/NXLibrary/artwork/<title id>/…
//   4. en ligne par title id (jeux Switch) : https://api.nlib.cc/nx/<title id>/icon et /banner
//   5. en ligne par nom, tous les jeux : SteamGridDB (jaquettes carrées, fonds « heroes », logos) avec ta clé API
//      (celle de NX Library, ~/Library/Application Support/NXLibrary/steamgriddb-api-key, ou Salon/steamgriddb-api-key)
//   6. sinon l'icône de l'app.
// Les téléchargements sont gardés dans ~/Library/Application Support/Salon/cache/<jeu>/.
import SwiftUI
import AppKit
import AVKit
import GameController
import UniformTypeIdentifiers
import Combine
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import AudioToolbox
import IOKit
import IOKit.hid
import WebKit

// MARK: - Modèle
struct Game: Identifiable, Equatable {
    let id: String          // chemin de l'app, ou "pc:<identifiant>" pour un jeu Windows de Home
    let name: String
    let url: URL            // l'app à ouvrir (le dossier du jeu pour un jeu Windows)
    let titleID: String?    // DMTitleID des apps nxnative
    let category: String
    let icon: NSImage
    let video: URL?
    /// Un jeu Windows installé par Home lui-même (Epic Games, sans Obelisk) : id "pc:<identifiant Epic>", url = le dossier du jeu
    var viaHome: Bool { id.hasPrefix("pc:") }
    var appPC: String? { viaHome ? String(id.dropFirst(3)) : nil }
    var pc: Bool { viaHome }
    /// Title id Switch connu pour la boutique eShop et l'icône officielle : celui des apps nxnative, sinon celui du jeu d'une app MacNativeGames
    var storeID: String? {
        if let t = titleID { return t }
        return Game.mngStoreID(Bundle(url: url)?.bundleIdentifier ?? "")
    }
    /// Le jeu d'une app MacNativeGames, d'après son identifiant (son Info.plist n'a pas de DMTitleID)
    static func mngStoreID(_ bundle: String) -> String? {
        switch bundle {
        case let b where b.hasPrefix("org.macnativegames.totk"): return "0100F2C0115B6000"
        case let b where b.hasPrefix("org.macnativegames.botw"): return "01007EF00011E000"
        case let b where b.hasPrefix("org.macnativegames.oot"): return "0400486024DEC000"   // Ocarina of Time, Switch 2
        default: return nil
        }
    }
    static func == (a: Game, b: Game) -> Bool { a.id == b.id }
}
struct Art { var cover: NSImage?; var background: NSImage?; var logo: NSImage? }
struct Stat: Codable { var lastPlayed: Date?; var minutes: Int }
struct Entry: Codable { var chemin: String; var nom: String?; var categorie: String?; var masque: Bool? }
struct Config: Codable { var jeux: [Entry]; var categories: [String]?; var sons: Bool?; var capture: Bool?; var espacePleinEcran: Bool?; var volumes: [String: Float]?; var volume: Float?; var ecranJeu: UInt32?; var ecranJeuChoisi: Bool?; var gamebanana: [String: Int]?; var reglages: [String: [String: String]]?; var cles: String?; var discret: Bool?; var garderCaches: Bool?; var nomsArt: [String: String]?; var mode: String?; var moteurs: String?; var ouverture: Bool? }   // mode : "tout" | "nintendo" | "pc" (nil = pas encore choisi) ; moteurs : "tout" | "mng" | "nxnative"
struct Candidate: Identifiable {
    let id: String; let thumb: URL?; let full: URL?; let author: String; var game: String = ""; var source: String = "SteamGridDB"; var width = 0, height = 0
    /// Le même format pour toutes les propositions d'un emplacement : jaquette carrée (la tuile l'est), fond large (≥ 3:2) ; les logos sont filtrés par leur nom (fichiers « logo »)
    func fits(_ slot: Slot) -> Bool {
        guard width > 0, height > 0 else { return true }
        let r = Double(width) / Double(height)
        switch slot { case .cover: return r > 0.9 && r < 1.1; case .background: return r >= 1.5; case .logo: return true }
    }
}
/// Une touche affichée dans les aides : symbole SF de la manette détectée (xmark.circle sur PlayStation, a.circle sur Xbox, b.circle sur Switch…) ou texte clavier
struct Key { var symbol: String? = nil; var text: String }
struct PadHints {
    var ok: Key, back: Key, options: Key, plus: Key, cat: Key, name: String?; var tri: Key = Key(text: "M")
    static let keyboard = PadHints(ok: Key(text: "⏎"), back: Key(text: "Échap"), options: Key(text: "O"), plus: Key(text: "N"), cat: Key(text: "Tab"), name: nil)
}
struct SalonMenuItem { let label: String; var detail: String? = nil; let icon: String; var section: String? = nil; var destructive = false; var tint: Color? = nil; var info = false; var image: URL? = nil; let action: () -> Void }
/// Un menu : titre, illustration (jaquette du jeu ou grand symbole), texte d'explication, étape d'un assistant, et où revenir avec B
struct SalonMenu { let title: String; var subtitle: String? = nil; let items: [SalonMenuItem]; var hero: String? = nil; var art: NSImage? = nil; var text: String? = nil; var step: Int? = nil; var steps: Int? = nil; var back: (() -> Void)? = nil; var roue = false; var rafraichir: (() -> Void)? = nil; var heroURL: URL? = nil; var grid = false }
/// La couleur de la pastille d'un choix, d'après son symbole
func menuTint(_ icon: String, tint: Color? = nil, destructive: Bool = false) -> Color {
    if let tint { return tint }
    if destructive { return Color(red: 0.92, green: 0.3, blue: 0.28) }
    let table: [(String, Color)] = [("play", .green), ("photo", .pink), ("paint", .purple), ("textformat", .purple), ("tag", .orange), ("puzzle", .green), ("square.and.arrow", .blue),
        ("arrow", .blue), ("hammer", .orange), ("folder", .cyan), ("gamecontroller", .red), ("globe", .teal), ("magnifying", .teal), ("shippingbox", .brown), ("pencil", .yellow),
        ("ellipsis", .gray), ("checkmark", .green), ("doc", .mint), ("bolt", .yellow), ("safari", .blue), ("plus", .green), ("desktop", .indigo), ("mac", .blue), ("key", .yellow),
        ("power", .red), ("speaker", .pink), ("display", .blue), ("record", .red), ("rectangle", .blue), ("trash", .red), ("eye", .gray), ("xmark", .gray), ("leaf", .green), ("sparkles", .purple)]
    for (k, c) in table where icon.hasPrefix(k) { return c }
    return .blue
}
enum Slot: String, CaseIterable { case cover = "Jaquette", background = "Fond", logo = "Logo" }

let appSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let salonRoot = appSupport.appendingPathComponent("Salon")
let nxlib = salonRoot.appendingPathComponent("nx-library")   // les illustrations reprises de NX Library (désinstallé) : artwork-picks/, artwork/
/// Les dossiers de Home : ~/Library/Application Support/Home (moteur, constructions, journaux…) et /Applications/Jeux (les apps des jeux), ou ceux que donne
/// Application Support/Salon/dossiers.json ({"home": "...", "jeux": "..."}) sur un Mac où ces emplacements ne conviennent pas.
/// Les scripts les reçoivent par HOME_RACINE et HOME_JEUX.
enum Dossiers {
    static let lus: [String: String] = (try? Data(contentsOf: salonRoot.appendingPathComponent("dossiers.json"))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    static func dossier(_ cle: String, _ defaut: String) -> URL { URL(fileURLWithPath: (lus[cle].map { ($0 as NSString).expandingTildeInPath }).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? defaut) }
    /// Le dossier de Home : ~/Library/Application Support/Home, là où macOS range les données des apps. Une installation d'avant
    /// (/Applications/Home), pas encore déplacée, continue de servir tant que le nouveau dossier n'existe pas.
    static let home: URL = {
        let norme = appSupport.appendingPathComponent("Home").path, ancien = "/Applications/Home"
        let fm = FileManager.default
        return dossier("home", !fm.fileExists(atPath: norme + "/moteur") && fm.fileExists(atPath: ancien + "/moteur") ? ancien : norme)
    }()
    static let jeux = dossier("jeux", "/Applications/Jeux")
    static var env: [String: String] { ["HOME_RACINE": home.path, "HOME_JEUX": jeux.path] }
}
let logURL = Dossiers.home.appendingPathComponent("log/salon.log")
func log(_ m: String) {
    let line = "\(Date().formatted(date: .abbreviated, time: .standard))  \(m)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true); try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}
/// Rogne les bords transparents d'un logo pour qu'il se cale vraiment sur la marge
func trimTransparent(_ img: NSImage) -> NSImage {
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return img }
    let w = cg.width, h = cg.height
    guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return img }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return img }
    let px = data.bindMemory(to: UInt8.self, capacity: w * h)
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w where px[y * w + x] > 16 { if x < minX { minX = x }; if x > maxX { maxX = x }; if y < minY { minY = y }; if y > maxY { maxY = y } } }
    guard maxX >= minX, maxY >= minY, (maxX - minX + 1) * (maxY - minY + 1) < w * h * 95 / 100 else { return img }
    let r = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    guard let cut = cg.cropping(to: r) else { return img }
    return NSImage(cgImage: cut, size: NSSize(width: r.width, height: r.height))
}
func safeName(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }) }
func firstFile(_ dir: URL, _ names: [String]) -> URL? {
    for n in names { let f = dir.appendingPathComponent(n); if FileManager.default.fileExists(atPath: f.path) { return f } }
    return nil
}

// MARK: - Sons d'interface : six sons originaux, créés pour Home (app/sons), embarqués dans l'app. « lancer » est le jingle de Home.
// Remplaçables par les tiens : ~/Library/Application Support/Salon/sons/<nom>.wav|mp3|aiff (nom = deplacer, onglet, ouvrir, retour, valider, lancer).
// La banque « Interface Sounds » de Kenney (CC0) reste dans Home.app/Contents/Resources/sons/banque pour en choisir d'autres.
// Ces sons ont un écho voulu de 1 à 2 s : chaque son a deux lecteurs qui alternent, et un nouveau « deplacer » ou « onglet » éteint
// (fondu très court, sans clic) celui qui résonne encore, pour que les échos ne s'empilent pas en naviguant vite.
// Leur volume est déjà équilibré entre eux : le même niveau pour tous, seul le volume général de Home s'applique.
final class Sounds {
    static let shared = Sounds()
    var enabled = true
    var gain: Float = 1.0                    // suit le volume du jeu sélectionné / en cours (réglage unique du Salon)
    private var players: [String: [AVAudioPlayer]] = [:]
    private var tour: [String: Int] = [:]
    private static let niveau: Float = 0.8   // le même pour les six sons
    private static let navigation: Set<String> = ["deplacer", "onglet", "volume"]   // ceux qui se coupent l'un l'autre
    private static let fallback = ["deplacer": "Tink", "onglet": "Pop", "ouvrir": "Purr", "retour": "Bottle", "valider": "Glass", "lancer": "Hero", "volume": "Tink"]
    private func url(_ name: String) -> URL? {
        for ext in ["wav", "mp3", "aiff", "aif", "m4a"] { let u = salonRoot.appendingPathComponent("sons/\(name).\(ext)"); if FileManager.default.fileExists(atPath: u.path) { return u } }
        if let u = Bundle.main.resourceURL?.appendingPathComponent("sons/\(name).wav"), FileManager.default.fileExists(atPath: u.path) { return u }
        if let f = Sounds.fallback[name] { return URL(fileURLWithPath: "/System/Library/Sounds/\(f).aiff") }
        return nil
    }
    private func eteindre(_ p: AVAudioPlayer) {
        guard p.isPlaying else { return }
        p.setVolume(0, fadeDuration: 0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { if p.volume == 0 { p.stop() } }   // relancé entre-temps : son volume est remonté, il continue
    }
    func play(_ name: String) {
        guard enabled else { return }
        if players[name] == nil, let u = url(name) { players[name] = (0..<2).compactMap { _ in let p = try? AVAudioPlayer(contentsOf: u); p?.prepareToPlay(); return p } }
        guard let paire = players[name], !paire.isEmpty else { return }
        // ce qui résonne encore et doit se taire : le même son, et pour la navigation l'autre son de navigation
        for (n, l) in players where n == name || (Sounds.navigation.contains(name) && Sounds.navigation.contains(n)) { l.forEach(eteindre) }
        let i = ((tour[name] ?? 0) + 1) % paire.count; tour[name] = i
        let p = paire[i]; p.stop(); p.currentTime = 0; p.volume = Sounds.niveau * max(0.15, gain); p.play()
    }
    /// Éteint tout ce qui résonne (le jingle au moment où un jeu prend le son)
    func taire() { players.values.forEach { $0.forEach(eteindre) } }
}

// MARK: - Boutique Nintendo eShop (Europe) : la bannière officielle 2:1 d'un jeu Switch, par title id
// ec.nintendo.com/apps/<tid>/FR renvoie (redirection) vers la fiche avec son nsuid européen ; la recherche Nintendo Europe
// donne l'image H2x1 (image500w), disponible aussi en 1600 px (image1600w). Le carré 500 px sert de vignette.
enum EShop {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    struct Info { var banner: URL?; var bannerThumb: URL?; var bannerSize: (Int, Int) = (0, 0); var square: URL?; var packshot: URL?; var title: String }
    private static var infos: [String: Info?] = [:]
    static func banner(titleID: String) async -> (full: URL, thumb: URL)? { if let i = await info(titleID: titleID), let b = i.banner, let t = i.bannerThumb { return (b, t) }; return nil }
    /// Essaie la version 1600 px d'une image Nintendo (…image500w.jpg → …image1600w.jpg), qui existe pour la plupart des bannières
    private static func big(_ h: String) async -> URL? {
        guard h.hasSuffix("image500w.jpg"), let big = URL(string: String(h.dropLast("image500w.jpg".count)) + "image1600w.jpg") else { return nil }
        var req = URLRequest(url: big); req.httpMethod = "HEAD"
        if let (_, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 { return big }
        return nil
    }
    /// Fiche européenne : bannière 2:1 (Switch) ou 16:9 (Switch 2), en 1600 px si disponible ; image carrée (500 px) ; jaquette « packshot » (500×809)
    static func info(titleID: String) async -> Info? {
        if let c = infos[titleID] { return c }
        var result: Info? = nil
        defer { infos[titleID] = result }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        guard let (_, resp) = try? await session.data(from: URL(string: "https://ec.nintendo.com/apps/\(titleID)/FR")!),
              let loc = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let nsuid = URLComponents(string: loc)?.queryItems?.first(where: { $0.name == "nsuid" })?.value else { log("eShop \(titleID) : pas de fiche européenne"); return nil }
        guard let d = try? await URLSession.shared.data(from: URL(string: "https://search.nintendo-europe.com/fr/select?q=*&fq=nsuid_txt:\(nsuid)&wt=json&fl=title,image_url_h2x1_s,image_url_h16x9_s,image_url_sq_s,image_url")!).0,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let docs = (o["response"] as? [String: Any])?["docs"] as? [[String: Any]], let doc = docs.first else { log("eShop \(titleID) : nsuid \(nsuid) sans fiche"); return nil }
        var info = Info(title: doc["title"] as? String ?? "")
        if let h = doc["image_url_h2x1_s"] as? String, let thumb = URL(string: h) {          // Switch : bannière 2:1
            let b = await big(h); info.banner = b ?? thumb; info.bannerThumb = thumb; info.bannerSize = b != nil ? (1600, 800) : (500, 250)
        } else if let h = doc["image_url_h16x9_s"] as? String, let thumb = URL(string: h) {   // Switch 2 : bannière 16:9
            let b = await big(h); info.banner = b ?? thumb; info.bannerThumb = thumb; info.bannerSize = b != nil ? (1600, 900) : (500, 281)
        }
        info.square = (doc["image_url_sq_s"] as? String).flatMap { URL(string: $0) }; info.packshot = (doc["image_url"] as? String).flatMap { URL(string: $0) }
        log("eShop \(titleID) : \(info.title) — bannière \(info.banner?.lastPathComponent ?? "aucune"), carré \(info.square == nil ? "non" : "oui")")
        result = info; return result
    }
}

// MARK: - SteamGridDB (comme NX Library : grids carrés = jaquette, heroes = fond, logos = logo)
enum SteamGridDB {
    static let api = "https://www.steamgriddb.com/api/v2/"
    static let filters = "types=static&nsfw=false&humor=false&epilepsy=false&limit=12"
    static func key() -> String? {
        for f in [salonRoot.appendingPathComponent("steamgriddb-api-key"), nxlib.appendingPathComponent("steamgriddb-api-key")] {
            if let s = try? String(contentsOf: f, encoding: .utf8) { let k = s.trimmingCharacters(in: .whitespacesAndNewlines); if k.count >= 16 { return k } }
        }
        return nil
    }
    static func get(_ path: String, key: String) async -> Data? {
        guard let u = URL(string: api + path) else { return nil }
        var r = URLRequest(url: u); r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); r.timeoutInterval = 15
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { log("SteamGridDB: pas de réponse pour \(path)"); return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { log("SteamGridDB: HTTP \(code) pour \(path)" + (code == 401 ? " (clé refusée)" : "")); return nil }
        return d
    }
    /// Variantes du nom à essayer : tel quel, puis sans suffixes techniques (MacNativeGames, nxnative, versions, parenthèses), puis les premiers mots
    static func queries(for name: String) -> [String] {
        var v = [name]
        var c = name
        for junk in ["MacNativeGames", "macnativegames", "nxnative", "NX", "Switch", "(", ")", "[", "]", "™", "®"] { c = c.replacingOccurrences(of: junk, with: " ") }
        c = c.replacingOccurrences(of: #"\b[vV]?\d+(\.\d+)+\b"#, with: " ", options: .regularExpression)
        c = c.components(separatedBy: " - ").first ?? c
        c = c.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if !c.isEmpty, c.lowercased() != name.lowercased() { v.append(c) }
        let words = c.split(separator: " ")
        if words.count > 3 { v.append(words.prefix(3).joined(separator: " ")) }
        if words.count > 2 { v.append(words.prefix(2).joined(separator: " ")) }
        return v
    }
    /// Jusqu'à 3 jeux (id, nom) qui ressemblent au nom : l'exact d'abord, puis les plus proches — pour proposer quelque chose plutôt que rien
    static func games(name: String, key: String) async -> [(Int, String)] {
        for q in queries(for: name) {
            let term = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
            guard let d = await get("search/autocomplete/\(term)", key: key),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let list = o["data"] as? [[String: Any]], !list.isEmpty else { log("SteamGridDB: « \(q) » → rien"); continue }
            var found = list.compactMap { i -> (Int, String)? in guard let id = i["id"] as? Int, let n = i["name"] as? String else { return nil }; return (id, n) }
            log("SteamGridDB: « \(q) » → \(found.count) jeux : \(found.prefix(5).map { $0.1 })")
            if let k = found.firstIndex(where: { $0.1.lowercased() == q.lowercased() }), k != 0 { found.swapAt(0, k) }
            return Array(found.prefix(3))
        }
        return []
    }
    static func gameID(name: String, key: String) async -> Int? { await games(name: name, key: key).first(where: { matchesGame($0.1, name) })?.0 }   // jamais un jeu sans rapport en automatique
    static func listing(_ slot: Slot, gameID: Int) -> String {
        switch slot {
        case .cover: return "grids/game/\(gameID)?dimensions=1024x1024,512x512&\(filters)"
        case .background: return "heroes/game/\(gameID)?dimensions=3840x1240,1920x620&\(filters)"
        case .logo: return "logos/game/\(gameID)?\(filters)"
        }
    }
    static func candidates(_ slot: Slot, gameID: Int, key: String) async -> [Candidate] {
        guard let d = await get(listing(slot, gameID: gameID), key: key),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let list = o["data"] as? [[String: Any]] else { return [] }
        // Les images les plus définies d'abord (un fond 1920×620 étiré sur 1080p est flou), à score égal l'ordre de SteamGridDB
        let ranked = list.enumerated().sorted { a, b in
            let wa = (a.element["width"] as? Int) ?? 0, wb = (b.element["width"] as? Int) ?? 0
            return wa != wb ? wa > wb : a.offset < b.offset
        }.map { $0.element }
        return ranked.compactMap { item in
            guard let u = item["url"] as? String, let full = URL(string: u), full.scheme == "https" else { return nil }
            let thumb = URL(string: item["thumb"] as? String ?? u) ?? full
            let author = (item["author"] as? [String: Any])?["name"] as? String ?? ""
            return Candidate(id: u, thumb: thumb, full: full, author: author, width: (item["width"] as? Int) ?? 0, height: (item["height"] as? Int) ?? 0)
        }
    }
}

/// Pertinence d'un résultat par son titre : les mots significatifs du nom du jeu (≥ 3 lettres, hors « the », « of », « de »…) doivent s'y retrouver
func matchesGame(_ title: String, _ game: String) -> Bool {
    func words(_ s: String) -> [String] { s.lowercased().folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 && !["the", "and", "les", "des", "une", "pour", "for", "with", "edition", "remastered", "deluxe", "demo"].contains($0) } }
    let g = words(game), t = title.lowercased().folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    guard !g.isEmpty else { return true }
    let hits = g.filter { t.contains($0) }.count
    return hits >= max(1, Int((Double(g.count) * 0.6).rounded(.up)))
}

/// Les nombres du nom cherché (« FC 27 », « 2077 ») doivent se retrouver dans le titre proposé : pas de FC 24 quand on cherche FC 27
func memesNumeros(_ titre: String, _ cherche: String) -> Bool {
    func nombres(_ s: String) -> Set<String> { Set(s.split(whereSeparator: { !$0.isNumber }).map(String.init)) }
    let n = nombres(cherche); return n.isEmpty || n.isSubset(of: nombres(titre))
}

// MARK: - PlayStation Store (API « chihiro » du site du store, non officielle, sans clé) :
// images de type 10 = jaquette carrée 1024 px, 12 = image 1920×1080 (fond) ; captures d'écran 1920×1080 en fonds
enum PSStore {
    static let base = "https://store.playstation.com/store/api/chihiro/00_09_000/"
    static func json(_ path: String) async -> [String: Any]? {
        guard let u = URL(string: base + path) else { return nil }
        var r = URLRequest(url: u); r.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent"); r.timeoutInterval = 15
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { log("PlayStation Store : pas de réponse (\(path))"); return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    static func candidates(_ slot: Slot, name: String) async -> [Candidate] {
        guard slot != .logo, let q = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let o = await json("tumbler/BE/fr/999/\(q)?suggested_size=12&mode=game"), let links = o["links"] as? [[String: Any]] else { return [] }
        let jeux = links.filter { ($0["top_category"] as? String) == "downloadable_game" && matchesGame(($0["name"] as? String) ?? "", name) && memesNumeros(($0["name"] as? String) ?? "", name) }
        var out: [Candidate] = []; var seen = Set<String>()
        func add(_ url: String, _ w: Int, _ h: Int, _ what: String, _ jeu: String) {
            guard !seen.contains(url), let u = URL(string: url) else { return }
            seen.insert(url); var c = Candidate(id: url, thumb: u, full: u, author: what, source: "PlayStation Store", width: w, height: h); c.game = jeu; out.append(c)
        }
        for l in jeux.prefix(slot == .cover ? 4 : 2) {
            guard let id = l["id"] as? String, let jeu = l["name"] as? String else { continue }
            for i in (l["images"] as? [[String: Any]]) ?? [] {
                guard let t = i["type"] as? Int, let u = i["url"] as? String else { continue }
                if slot == .cover, t == 10 { add(u, 1024, 1024, "jaquette officielle", jeu) }
                if slot == .background, t == 12 { add(u, 1920, 1080, "image officielle", jeu) }
            }
            if slot == .background, let c = await json("container/BE/fr/999/\(id)"), let ml = c["mediaList"] as? [String: Any], let shots = ml["screenshots"] as? [[String: Any]] {
                for sh in shots.prefix(4) { if let u = sh["url"] as? String { add(u, 1920, 1080, "capture", jeu) } }
            }
        }
        log("PlayStation Store : « \(name) » → \(jeux.count) jeux, \(out.count) images (\(slot.rawValue))")
        return out
    }
}

// MARK: - Wikis (MediaWiki) : Wikipédia fr/en et Wikimedia Commons — jaquette = image de l'article, logos et fonds = fichiers trouvés par le nom
enum Wiki {
    static let sites: [(String, String)] = [("Wikipédia (fr)", "https://fr.wikipedia.org/w/api.php"), ("Wikipédia (en)", "https://en.wikipedia.org/w/api.php"), ("Wikimedia Commons", "https://commons.wikimedia.org/w/api.php")]
    private static func get(_ api: String, _ params: [String: String]) async -> [String: Any]? {
        var c = URLComponents(string: api)!; c.queryItems = (params.merging(["format": "json", "formatversion": "2"]) { a, _ in a }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let u = c.url else { return nil }
        var req = URLRequest(url: u); req.setValue("Salon/1.0 (launcher macOS; contact via github)", forHTTPHeaderField: "User-Agent")
        guard let d = try? await URLSession.shared.data(for: req).0 else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    static func candidates(_ slot: Slot, name: String) async -> [Candidate] {
        var out: [Candidate] = []
        for (label, api) in sites {
            if slot == .cover, !label.contains("Commons") {   // l'image principale de l'article (la jaquette, en général)
                if let o = await get(api, ["action": "query", "generator": "search", "gsrsearch": name, "gsrlimit": "3", "prop": "pageimages", "piprop": "original|thumbnail", "pithumbsize": "400"]),
                   let pages = (o["query"] as? [String: Any])?["pages"] as? [[String: Any]] {
                    for pg in pages {
                        guard let orig = pg["original"] as? [String: Any], let u = orig["source"] as? String, let full = URL(string: u) else { continue }
                        let thumb = URL(string: ((pg["thumbnail"] as? [String: Any])?["source"] as? String) ?? u) ?? full
                        let c = Candidate(id: u, thumb: thumb, full: full, author: pg["title"] as? String ?? "", source: label, width: orig["width"] as? Int ?? 0, height: orig["height"] as? Int ?? 0)
                        if c.fits(slot), matchesGame(c.author, name) { out.append(c) }   // l'article doit être celui du jeu
                    }
                }
            } else {   // fichiers (espace de noms 6) : logo / illustration par le nom
                let q = slot == .logo ? "\(name) logo" : slot == .background ? "\(name) artwork OR screenshot OR key art" : "\(name) icon OR square"
                if let o = await get(api, ["action": "query", "generator": "search", "gsrsearch": q, "gsrnamespace": "6", "gsrlimit": "6", "prop": "imageinfo", "iiprop": "url|size|mime", "iiurlwidth": "400"]),
                   let pages = (o["query"] as? [String: Any])?["pages"] as? [[String: Any]] {
                    for pg in pages {
                        guard let ii = (pg["imageinfo"] as? [[String: Any]])?.first, let u = ii["url"] as? String, let full = URL(string: u) else { continue }
                        let mime = ii["mime"] as? String ?? ""; guard mime.hasPrefix("image/") else { continue }
                        let title = (pg["title"] as? String ?? "").replacingOccurrences(of: "File:", with: "").replacingOccurrences(of: "Fichier:", with: "")
                        if slot == .logo, !(title.lowercased().contains("logo") && (mime == "image/png" || mime == "image/svg+xml")) { continue }   // un logo : fichier « logo » détouré
                        let thumb = URL(string: (ii["thumburl"] as? String) ?? u) ?? full
                        let c = Candidate(id: u, thumb: thumb, full: full, author: title, source: label, width: ii["width"] as? Int ?? 0, height: ii["height"] as? Int ?? 0)
                        if c.fits(slot), matchesGame(title, name) { out.append(c) }   // le nom du fichier doit être celui du jeu
                    }
                }
            }
        }
        return out
    }
}

// MARK: - Bibliothèque
final class Library: ObservableObject {
    @Published var games: [Game] = []
    @Published var art: [String: Art] = [:]
    @Published var categories: [String] = []
    @Published var categoryIndex = 0
    @Published var selected = 0
    @Published var running: Game? = nil
    @Published var stats: [String: Stat] = [:]
    @Published var menu: SalonMenu? = nil
    @Published var ouverturePart = false   // l'ouverture est en train de s'effacer
    @Published var bienvenue = false       // l'accueil du premier lancement est affiché
    @Published var bienvenueIndex = 0      // la carte visée : tout, Nintendo, PC
    /// Finir (ou passer) l'ouverture : elle s'efface d'elle-même, puis on la retire une fois invisible
    func passerOuverture() {
        guard ouverture, !ouverturePart else { return }
        ouverturePart = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.ouverture = false; self.ouverturePart = false }
    }
    @Published var ouverture = false   // l'animation d'ouverture (logo et jingle), au vrai lancement de l'app seulement
    var epicNouveau = false   // la prochaine connexion Epic ajoute un compte au lieu de remplacer le compte actif
    var apresTache: (() -> Void)? = nil   // ce que l'assistant fait une fois la tâche en cours réussie (se connecter, ajouter un jeu…)
    @Published var tache: Tache? = nil { didSet { majDock() } }   // la construction / mise à jour en cours, avec sa barre de progression
    /// Ferme la notification d'une tâche terminée (bouton Fermer, B / Échap) : fondu flouté ; une tâche en cours reste affichée
    @discardableResult func fermerTache() -> Bool {
        guard let t = tache, t.fini || t.erreur != nil else { return false }
        Sounds.shared.play("retour"); withAnimation(.easeInOut(duration: 0.5)) { tache = nil }; return true
    }
    var tacheProcess: Process? = nil
    var tacheScript: String? = nil
    /// Les tâches sans mesure d'avancement (recompiler Home, remettre le moteur de TOTK…) : leur durée, retenue d'une fois sur l'autre
    static func cleDuree(_ script: String, _ args: [String]) -> String? {
        if script == "construire-jeu.command", args.contains("mng") { return "construire-jeu+mng" }   // MacNativeGames : des étapes nommées, sans pourcentage ; la durée de la dernière fois
        if script == "construire-jeu.command" || script == "mettre-a-jour-et-rebuild.command" { return nil }   // avancement réel (nxnative)
        if script == "totk-mng-online.command" { return script + (args.isEmpty ? "" : "+mods") }
        return script
    }
    static func dureeAttendue(_ script: String, _ args: [String]) -> Double? {
        guard let cle = cleDuree(script, args) else { return nil }
        let d = (try? Data(contentsOf: salonRoot.appendingPathComponent("durees.json"))).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        let defaut: [String: Double] = ["home-mettre-a-jour.command": 120, "totk-mng-online.command": 100, "totk-mng-online.command+mods": 900, "mng-reconstruire.command": 100,
                                        "mng-mettre-a-jour.command": 160, "construire-jeu+mng": 1800, "mng-mods-appliquer.command": 40, "alleger-build.sh": 20, "journaux.command": 6]
        return d[cle] ?? defaut[cle]
    }
    static func noterDuree(_ cle: String, _ secondes: Double) {
        let u = salonRoot.appendingPathComponent("durees.json")
        var d = (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        d[cle] = d[cle].map { ($0 + secondes) / 2 } ?? secondes
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: u) }
    }
    var showOptions: Bool { menu != nil }
    @Published var picker: (slot: Slot, items: [Candidate], index: Int, game: Game)? = nil
    @Published var toast: String? = nil { didSet { if let t = toast { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.toast == t { self?.toast = nil } } } } }   // s'efface tout seul, même hors écran
    @Published var pickIndex = 0
    var config = Config(jeux: [], categories: [])
    static let all = "Tous"
    static let base = ["Switch", "Switch 2", "Mac", "PC"]
    private var startedAt: Date?
    private var watch: Timer?
    @Published var loading = Set<String>()
    @Published var hints = PadHints.keyboard
    @Published var overlay = false          // HUD par-dessus le jeu
    @Published var quick = false            // menu rapide (dans le HUD)
    @Published var quickIndex = 0
    var captureWarned = false
    @Published var quickSlider = false      // carte Volume ouverte en grand curseur (stick gauche / flèches, ○ pour revenir)
    @Published var quickJoueurs = false     // carte Joueurs ouverte : les joueurs connectés au serveur du jeu en ligne
    var watchedApp: NSRunningApplication? = nil
    var lastInput = Date()                  // pour masquer le HUD après 3 s sans toucher à la manette
    var runningSince: Date? { startedAt }
    @Published var pickerLoading = false
    @Published var pickerNote: String? = nil
    @Published var pickCharges: Set<String> = []   // les images du sélecteur déjà chargées : seules celles-là se montrent (et se parcourent)
    @Published var pickerSaisie = false            // la barre de recherche du sélecteur a le clavier (sinon c'est la rangée d'images)
    /// Une image du sélecteur vient de finir de charger : elle apparaît ; si rien de visible n'était visé, c'est elle
    var pickBouge = false   // on a déjà déplacé le curseur du sélecteur : il ne bouge plus tout seul
    func pickCharge(_ id: String) {
        guard !pickCharges.contains(id) else { return }
        withAnimation(.easeOut(duration: 0.35)) { pickCharges.insert(id) }
        pickCaler()
    }
    /// Tant qu'on n'a touché à rien, le curseur est sur la première image chargée en partant de la gauche ; ensuite il ne quitte une image que si elle n'est plus là
    func pickCaler() {
        guard let p = picker else { return }
        let premiere = p.items.firstIndex { $0.thumb != nil && pickCharges.contains($0.id) }
        if !pickBouge { if let i = premiere, pickIndex != i { pickIndex = i } }
        else if !(p.items.indices.contains(pickIndex) && pickVisible(p.items[pickIndex])), let i = premiere { pickIndex = i }
    }
    func pickVisible(_ c: Candidate) -> Bool { c.thumb == nil || pickCharges.contains(c.id) }
    /// L'image visible suivante dans un sens
    func pickSuivant(_ d: Int) {
        guard let p = picker else { return }
        var n = pickIndex + d
        while p.items.indices.contains(n) { if pickVisible(p.items[n]) { pickBouge = true; pickIndex = n; Sounds.shared.play("deplacer"); return }; n += d }
    }
    /// La barre de recherche du sélecteur : un autre nom sous lequel chercher les images de ce jeu (vide = son nom), puis la recherche repart
    func chercherArt(_ nom: String) {
        guard let p = picker else { return }
        let n = nom.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.nomsArt == nil { config.nomsArt = [:] }
        config.nomsArt?[p.game.id] = (n.isEmpty || n == p.game.name) ? nil : n; saveConfig()
        log("Nom de recherche \(p.game.name) : \(config.nomsArt?[p.game.id] ?? "(nom du jeu)")")
        pickerSaisie = false; Sounds.shared.play("valider"); openPicker(p.game, p.slot)
    }
    let online = ProcessInfo.processInfo.environment["SALON_HORS_LIGNE"] == nil

    var visible: [Game] { let c = categories.indices.contains(categoryIndex) ? categories[categoryIndex] : Library.all; return c == Library.all ? games : games.filter { $0.category == c } }
    var current: Game? { let v = visible; return v.indices.contains(selected) ? v[selected] : nil }
    /// Les jeux d'une catégorie (par son rang dans la barre du haut)
    func jeux(categorie i: Int) -> [Game] { let c = categories.indices.contains(i) ? categories[i] : Library.all; return c == Library.all ? games : games.filter { $0.category == c } }

    func load() {
        let fm = FileManager.default
        for d in ["media", "jeux", "cache"] { try? fm.createDirectory(at: salonRoot.appendingPathComponent(d), withIntermediateDirectories: true) }
        let cfgURL = salonRoot.appendingPathComponent("jeux.json")
        if let d = try? Data(contentsOf: cfgURL), let c = try? JSONDecoder().decode(Config.self, from: d) { config = c }
        if config.ecranJeuChoisi != true, config.ecranJeu != nil { config.ecranJeu = nil; saveConfig(); log("Écran des jeux remis par défaut (écran externe) — réglage hérité effacé") }   // une fois : l'ancien réglage avait pu basculer sans le vouloir
        Sounds.shared.enabled = config.sons ?? true
        let deplacements = (try? Data(contentsOf: Atelier.home.appendingPathComponent("deplacements.json"))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        if !deplacements.isEmpty {
            var change = false
            for i in config.jeux.indices { if let n = deplacements[config.jeux[i].chemin] { config.jeux[i].chemin = n; change = true } }
            for (a, b) in deplacements {
                if let v = config.gamebanana?[a] { config.gamebanana?[b] = v; config.gamebanana?[a] = nil; change = true }
                if let v = config.reglages?[a] { config.reglages?[b] = v; config.reglages?[a] = nil; change = true }
            }
            if change { saveConfig() }
        }
        var urls: [URL] = []
        func addApps(in dir: URL) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
            for u in items.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                let r = u.resolvingSymlinksInPath()
                if r.pathExtension == "app" { urls.append(r) }
                else if let alias = try? URL(resolvingAliasFileAt: u), alias.pathExtension == "app" { urls.append(alias) }
            }
        }
        addApps(in: Atelier.jeux)
        addApps(in: salonRoot.appendingPathComponent("jeux"))
        // Jeux installés ailleurs dans /Applications : uniquement de vrais jeux (catégorie « jeu » de leur Info.plist, ou nom connu),
        // jamais les launchers, émulateurs et outils (NX Library, Obelisk, Steam, Whisky…) — ceux-là ne sont pas des jeux
        let knownGames = ["roblox", "robloxplayer", "minecraft", "league of legends", "fortnite", "genshin impact", "among us", "hades", "stardew valley", "celeste", "terraria", "balatro", "cuphead", "hollow knight", "dead cells", "rocket league", "valorant", "geometry dash", "the sims 4"]
        let notGames = ["nx library", "nxlibrary", "obelisk", "steam", "epic games launcher", "heroic", "whisky", "crossover", "prism launcher", "battle.net", "gog galaxy", "riot client", "ea app", "amazon games", "itch", "parsec", "moonlight", "openemu", "retroarch", "dolphin", "ryujinx", "yuzu", "eden", "pcsx2", "ppsspp", "xcode", "nxnative", "salon", "discord", "porting kit", "crossover", "wine", "playcover", "sideloadly"]
        if let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for u in items where u.pathExtension == "app" {
                let nm = u.deletingPathExtension().lastPathComponent.lowercased()
                if notGames.contains(where: { nm == $0 || nm.hasPrefix($0) }) { continue }
                let info = Bundle(url: u)?.infoDictionary ?? [:]
                let cat = (info["LSApplicationCategoryType"] as? String ?? "").lowercased()
                if cat.hasSuffix("-games") || cat == "public.app-category.games" || knownGames.contains(where: { nm == $0 || nm.hasPrefix($0) }) { urls.append(u.resolvingSymlinksInPath()) }
            }
        }
        for e in config.jeux { let u = URL(fileURLWithPath: (e.chemin as NSString).expandingTildeInPath); if fm.fileExists(atPath: u.path) { urls.append(u) } }
        var seen = Set<String>(); var list: [Game] = []
        for u in urls {
            let key = u.standardizedFileURL.path
            guard !seen.contains(key) else { continue }; seen.insert(key)
            let entry = config.jeux.first { URL(fileURLWithPath: ($0.chemin as NSString).expandingTildeInPath).standardizedFileURL.path == key }
            if entry?.masque == true { continue }
            let info = Bundle(url: u)?.infoDictionary ?? [:]
            if (info["CFBundleIdentifier"] as? String) == "fr.anas.salon" || u.lastPathComponent == "Salon.app" || u.lastPathComponent == "Home.app" { continue }   // pas soi-même
            if ["NX Library.app", "NXLibrary.app", "Obelisk.app"].contains(u.lastPathComponent) { continue }                         // launchers, pas des jeux
            var name = entry?.nom ?? (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? u.deletingPathExtension().lastPathComponent
            if name == "nxnative" || name.isEmpty { name = u.deletingPathExtension().lastPathComponent }
            let tid = (info["DMTitleID"] as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() }
            let sid = tid ?? Game.mngStoreID(info["CFBundleIdentifier"] as? String ?? "")   // une app MacNativeGames : son jeu Switch / Switch 2
            let cat = entry?.categorie ?? (sid.map { $0.hasPrefix("04") ? "Switch 2" : "Switch" } ?? (u.lastPathComponent == "Obelisk.app" ? "PC" : "Mac"))
            let icon = NSWorkspace.shared.icon(forFile: u.path); icon.size = NSSize(width: 1024, height: 1024)
            let media = salonRoot.appendingPathComponent("media").appendingPathComponent(name)
            let video = firstFile(media, ["fond.mp4", "fond.mov", "background.mp4", "background.mov"])
            list.append(Game(id: key, name: name, url: u, titleID: tid, category: cat, icon: icon, video: video))
        }
        // Jeux Windows installés par Home (Epic Games, moteur/pc/pc.py) : <Home>/pc/jeux.json (identifiant, nom, dossier)
        for j in PCHome.jeux() + PCHome.jeuxSteam() {
            let key = "pc:" + j.app
            let entry = config.jeux.first { $0.chemin == key }
            if entry?.masque == true || seen.contains(key) { continue }; seen.insert(key)
            let name = entry?.nom ?? j.nom
            let media = salonRoot.appendingPathComponent("media").appendingPathComponent(name)
            let icon = NSWorkspace.shared.icon(forFile: j.dossier); icon.size = NSSize(width: 1024, height: 1024)
            list.append(Game(id: key, name: name, url: URL(fileURLWithPath: j.dossier), titleID: nil, category: entry?.categorie ?? "PC", icon: icon, video: firstFile(media, ["fond.mp4", "fond.mov"])))
        }
        if let d = try? Data(contentsOf: salonRoot.appendingPathComponent("statistiques.json")), let s = try? JSONDecoder().decode([String: Stat].self, from: d) { stats = s }
        if deplacements.contains(where: { stats[$0.key] != nil }) { for (a, b) in deplacements { if let v = stats[a] { stats[b] = v; stats[a] = nil } }; saveStats() }
        list.sort { (stats[$0.id]?.lastPlayed ?? .distantPast) > (stats[$1.id]?.lastPlayed ?? .distantPast) }   // dernière partie en premier ; jamais joués après, dans l'ordre des noms
        games = list
        let order = Library.base
        let found = Set(list.map { $0.category }).union(config.categories ?? [])
        categories = [Library.all] + Array(found).sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        if categoryIndex >= categories.count { categoryIndex = 0 }
        if selected > visible.count { selected = max(0, visible.count - 1) }
        for g in list { resolveArt(g) }
        log("Bibliothèque : " + list.map { g in "\(g.name) [\(art[g.id]?.cover != nil ? "jaquette" : "-") \(art[g.id]?.background != nil ? "fond" : "-") \(art[g.id]?.logo != nil ? "logo" : "-")]" }.joined(separator: ", "))
    }
    func saveConfig() { if let d = try? JSONEncoder().encode(config) { try? d.write(to: salonRoot.appendingPathComponent("jeux.json")) } }
    func saveStats() { if let d = try? JSONEncoder().encode(stats) { try? d.write(to: salonRoot.appendingPathComponent("statistiques.json")) } }
    func entry(for g: Game) -> Int {
        if let i = config.jeux.firstIndex(where: { $0.chemin == g.id || URL(fileURLWithPath: ($0.chemin as NSString).expandingTildeInPath).standardizedFileURL.path == g.id }) { return i }
        config.jeux.append(Entry(chemin: g.pc ? g.id : g.url.path, nom: nil, categorie: nil, masque: nil)); return config.jeux.count - 1
    }

    // Illustrations : fichiers locaux d'abord, puis en ligne (une fois, mises en cache)
    func resolveArt(_ g: Game) {
        let fm = FileManager.default
        let media = salonRoot.appendingPathComponent("media").appendingPathComponent(g.name)
        let cache = salonRoot.appendingPathComponent("cache").appendingPathComponent(safeName(g.name))
        var dirs = [media, cache]
        if let t = g.titleID { dirs += [nxlib.appendingPathComponent("artwork-picks").appendingPathComponent(safeName(t)), nxlib.appendingPathComponent("artwork").appendingPathComponent(safeName(t))] }
        func find(_ names: [String]) -> NSImage? { for d in dirs { if let f = firstFile(d, names), let i = NSImage(contentsOf: f) { return i } }; return nil }
        var a = Art()
        a.cover = find(["cover.jpg", "cover.png", "jaquette.jpg", "jaquette.png", "square.png", "square.jpg", "boxart.jpg", "boxart.png"])
        a.background = find(["fond.jpg", "fond.png", "background.jpg", "background.png", "hero.jpg", "hero.png"])
        // Un fond automatique trop petit (bannière eShop 1280 px, ancien cache) est flou en 1080p : on le laisse se remplacer par un fond SteamGridDB
        if let b = a.background, b.representations.first.map({ $0.pixelsWide }) ?? 0 < 1500, firstFile(media, ["fond.jpg", "fond.png", "background.jpg", "background.png"]) == nil, SteamGridDB.key() != nil { a.background = nil }
        a.logo = find(["logo.png", "logo.jpg"]).map(trimTransparent)
        art[g.id] = a; donnerIcone(g)
        guard online, a.cover == nil || a.background == nil || a.logo == nil, !loading.contains(g.id) else { return }
        loading.insert(g.id)
        let nomPerso = config.nomsArt?[g.id]   // Apparence → Nom de recherche
        Task.detached { [weak self] in
            guard let self else { return }
            try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
            var got = Art()
            if let t = g.storeID {   // nlib.cc : icône carrée et bannière, par title id
                if a.cover == nil, let d = try? await URLSession.shared.data(from: URL(string: "https://api.nlib.cc/nx/\(t)/icon")!).0, let i = NSImage(data: d) { try? d.write(to: cache.appendingPathComponent("square.jpg")); got.cover = i }
                if a.background == nil, let b = await EShop.banner(titleID: t), let d = try? await URLSession.shared.data(from: b.full).0, let i = NSImage(data: d) { try? d.write(to: cache.appendingPathComponent("hero.jpg")); got.background = i }   // bannière officielle de la boutique
            }
            // Sans clé SteamGridDB, chaque boutique donne quand même ses images : le carré de l'eShop pour un jeu Switch, les images
            // d'Epic (déjà connues de Legendary) ou celles de Steam (par le numéro du jeu) pour un jeu PC
            func prendre(_ u: URL?, _ fichier: String) async -> NSImage? {
                guard let u, let (d, r) = try? await URLSession.shared.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200, let i = NSImage(data: d) else { return nil }
                try? d.write(to: cache.appendingPathComponent(fichier)); return i
            }
            if a.cover == nil, got.cover == nil, let t = g.storeID, let sq = await EShop.info(titleID: t)?.square {
                let grand = URL(string: sq.absoluteString.replacingOccurrences(of: "image500w.jpg", with: "image1600w.jpg"))   // la même image en 1600 px, quand Nintendo l'a
                if let i = await prendre(grand, "square.jpg") { got.cover = i } else if let i = await prendre(sq, "square.jpg") { got.cover = i }
            }
            if let app = g.appPC, !app.hasPrefix("exe:"), a.cover == nil || a.background == nil || a.logo == nil {
                var u: [String: [URL]] = [:]
                if app.hasPrefix("steam:") {
                    let b = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(app.dropFirst(6))/"
                    u = ["jaquette": ["library_600x900_2x.jpg", "library_600x900.jpg", "header.jpg"], "fond": ["library_hero.jpg"], "logo": ["logo.png"]].mapValues { $0.compactMap { URL(string: b + $0) } }
                } else if let j = PCHome.json(PCHome.run(["images", app], timeout: 30)) as? [String: Any] {
                    for (k, v) in j { if let t = v as? String, let x = URL(string: t) { u[k] = [x] } }
                }
                if a.cover == nil, got.cover == nil { for x in u["jaquette"] ?? [] { if let i = await prendre(x, "square.jpg") { got.cover = i; break } } }
                if a.background == nil, got.background == nil { for x in u["fond"] ?? [] { if let i = await prendre(x, "hero.jpg") { got.background = i; break } } }
                if a.logo == nil { for x in u["logo"] ?? [] { if let i = await prendre(x, "logo.png") { got.logo = trimTransparent(i); break } } }
            }
            var nomSGDB = nomPerso ?? g.name   // sinon le titre de la boutique (« The Legend of Zelda: Ocarina of Time – Nintendo Switch 2 Edition »…) plutôt qu'un nom court
            if nomPerso == nil, let t = g.storeID, let i = await EShop.info(titleID: t) { nomSGDB = i.title }
            var gidSGDB: Int? = nil
            if let key = SteamGridDB.key() { gidSGDB = await SteamGridDB.gameID(name: nomSGDB, key: key); if gidSGDB == nil, nomSGDB != g.name { gidSGDB = await SteamGridDB.gameID(name: g.name, key: key) } }
            if let key = SteamGridDB.key(), let gid = gidSGDB {   // ce qui manque encore : SteamGridDB (fonds 3840×1240 d'abord)
                for (slot, have) in [(Slot.cover, a.cover ?? got.cover), (.background, a.background ?? got.background), (.logo, a.logo ?? got.logo)] where have == nil {
                    if let c = await SteamGridDB.candidates(slot, gameID: gid, key: key).first, let full = c.full, let d = try? await URLSession.shared.data(from: full).0, let i = NSImage(data: d) {
                        let name = slot == .cover ? "square.jpg" : slot == .background ? "hero.jpg" : "logo.png"
                        try? d.write(to: cache.appendingPathComponent(name))
                        switch slot { case .cover: got.cover = i; case .background: got.background = i; case .logo: got.logo = trimTransparent(i) }
                    }
                }
            }
            if got.background == nil, a.background == nil, let t = g.storeID, let d = try? await URLSession.shared.data(from: URL(string: "https://api.nlib.cc/nx/\(t)/banner")!).0, let i = NSImage(data: d) { try? d.write(to: cache.appendingPathComponent("hero.jpg")); got.background = i }   // dernier recours : bannière nlib (1280 px)
            await MainActor.run {
                var cur = self.art[g.id] ?? Art()
                if cur.cover == nil { cur.cover = got.cover }; if cur.background == nil { cur.background = got.background }; if cur.logo == nil { cur.logo = got.logo }
                self.art[g.id] = cur; self.loading.remove(g.id); self.donnerIcone(g)
            }
        }
    }
    func cover(_ g: Game) -> NSImage { art[g.id]?.cover ?? vignette(g) }
    /// La tuile d'un jeu qui n'a pas (encore) de jaquette : ses initiales sur un dégradé de Home, jamais l'icône de l'app Mac ni un dossier
    private var vignettes: [String: NSImage] = [:]
    func vignette(_ g: Game) -> NSImage {
        if let v = vignettes[g.id] { return v }
        let teintes = [Library.violet, Library.bleu, Library.orange, [Color(red: 0.20, green: 0.78, blue: 0.52), Color(red: 0.05, green: 0.45, blue: 0.42)], [Color(red: 0.98, green: 0.36, blue: 0.55), Color(red: 0.62, green: 0.14, blue: 0.48)]]
        let c = teintes[abs(g.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }) % teintes.count].map { NSColor($0) }
        let mots = g.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !["the", "of", "la", "le", "les", "de", "du", "and", "et"].contains($0.lowercased()) }
        let sigle = String(mots.prefix(3).compactMap { $0.first }).uppercased()
        let img = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { r in
            NSGradient(starting: c[0], ending: c[1])?.draw(in: r, angle: -55)
            let t = NSAttributedString(string: sigle.isEmpty ? "?" : sigle, attributes: [.font: NSFont.systemFont(ofSize: sigle.count > 2 ? 150 : 190, weight: .black, width: .expanded), .foregroundColor: NSColor.white.withAlphaComponent(0.92), .kern: 4])
            let s = t.size(); t.draw(at: NSPoint(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2)); return true
        }
        vignettes[g.id] = img; return img
    }
    /// Une app construite par Home (nxnative, MacNativeGames) sans icône reçoit sa jaquette comme icône, arrondie comme une app Mac :
    /// dans le Finder et le Dock elle n'est plus une app anonyme. Fait une fois, dès que la jaquette est là.
    func donnerIcone(_ g: Game) {
        guard !g.pc, g.url.pathExtension == "app", g.titleID != nil || (Bundle(url: g.url)?.bundleIdentifier ?? "").hasPrefix("org.macnativegames."),
              let cover = art[g.id]?.cover, let b = Bundle(url: g.url) else { return }
        let fm = FileManager.default
        if b.object(forInfoDictionaryKey: "CFBundleIconFile") != nil || b.object(forInfoDictionaryKey: "CFBundleIconName") != nil || fm.fileExists(atPath: g.url.appendingPathComponent("Icon\r").path) { return }
        let icone = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            let cadre = NSRect(x: 100, y: 100, width: 824, height: 824)
            NSBezierPath(roundedRect: cadre, xRadius: 185, yRadius: 185).addClip()
            let s = cover.size, k = max(cadre.width / max(s.width, 1), cadre.height / max(s.height, 1))
            cover.draw(in: NSRect(x: cadre.midX - s.width * k / 2, y: cadre.midY - s.height * k / 2, width: s.width * k, height: s.height * k)); return true
        }
        if NSWorkspace.shared.setIcon(icone, forFile: g.url.path) { log("Icône : \(g.name) reçoit sa jaquette comme icône") }
    }

    // Navigation
    func move(_ delta: Int) { guard running == nil, !showOptions, picker == nil else { return }; let n = min(max(selected + delta, 0), visible.count); if n != selected { selected = n; Sounds.shared.play("deplacer") } }
    var sensCategorie = 1   // le sens du dernier changement de catégorie (1 = suivante) : la rangée des jeux entre et sort dans ce sens
    func moveCategory(_ delta: Int) { guard running == nil, !showOptions, picker == nil, !categories.isEmpty else { return }; sensCategorie = delta >= 0 ? 1 : -1; categoryIndex = (categoryIndex + delta + categories.count) % categories.count; selected = 0; Sounds.shared.play("onglet") }
    func toggleSounds() { config.sons = !(config.sons ?? true); Sounds.shared.enabled = config.sons ?? true; saveConfig(); toast = Sounds.shared.enabled ? "Sons activés" : "Sons coupés" }
    var sensMenu: CGFloat = 1   // 1 = on entre dans un menu (il arrive par la droite), -1 = on revient au précédent (il arrive par la gauche)
    func closeMenu() {
        if picker == nil, let b = menu?.back { Sounds.shared.play("retour"); sensMenu = -1; b(); DispatchQueue.main.async { self.sensMenu = 1 }; return }
        if menu != nil || picker != nil { Sounds.shared.play("retour") }; menu = nil; picker = nil
    }
    func closeAllMenus() { if menu != nil { Sounds.shared.play("retour") }; menu = nil }

    // Menus : un grand panneau illustré, peu de choix à chaque niveau, une ligne d'explication sous chacun. A choisir, B revenir.
    func openOptions() {
        guard let g = current, running == nil else { return }
        Sounds.shared.play("ouvrir")
        menu = optionsMenu(g)
    }
    func optionsMenu(_ g: Game) -> SalonMenu {
        let a = art[g.id]; let st = stats[g.id]
        let played = st?.lastPlayed.map { "Dernière partie \($0.formatted(.relative(presentation: .named)))" } ?? "Jamais joué"
        var items: [SalonMenuItem] = [
            SalonMenuItem(label: "Jouer", detail: g.viaHome ? (g.appPC?.hasPrefix("exe:") == true ? "Jeu Windows, lancé par Home" : g.appPC?.hasPrefix("steam:") == true ? "Steam, lancé par Home" : "Epic Games, lancé par Home") : nil, icon: "play.fill", action: { self.menu = nil; self.launch() }),
            SalonMenuItem(label: "Apparence", icon: "paintpalette.fill", action: { self.openApparence(g) }),
        ]
        if Atelier.modsPossibles(g) {
            let mods = Atelier.mods(g); let on = mods.filter { $0.actif }.count
            items.append(SalonMenuItem(label: "Mods", detail: mods.isEmpty ? "En ajouter depuis GameBanana ou un fichier" : "\(mods.count) installé\(mods.count > 1 ? "s" : ""), \(on) activé\(on > 1 ? "s" : "")", icon: "puzzlepiece.extension.fill", action: { self.openModsMenu(g) }))
        }
        switch Atelier.moteurDe(g) {
        case .nxnative, .mng: items.append(SalonMenuItem(label: "Mises à jour", icon: "arrow.down.circle.fill", action: { self.openUpdateMenu(g) }))
        case .pc: if g.appPC?.hasPrefix("exe:") != true { items.append(SalonMenuItem(label: "Mises à jour", detail: "Vérifie et télécharge la dernière version", icon: "arrow.down.circle.fill", action: {
            self.menu = nil; if let a = g.appPC { if a.hasPrefix("steam:") { self.lancer("steam.command", ["installer", String(a.dropFirst(6))], titre: "Mise à jour de \(g.name)", jeux: [g.id]) } else { self.lancer("pc.command", ["installer", a], titre: "Mise à jour de \(g.name)", jeux: [g.id]) } } })) }
        case .mac: break
        }
        if g.titleID != nil || Atelier.moteurDe(g) == .mng {
            items.insert(SalonMenuItem(label: "Réglages du jeu", detail: reglagesResume(g), icon: "slider.horizontal.3", tint: .indigo, action: { self.openReglages(g) }), at: 2)
        }
        items.append(SalonMenuItem(label: "Catégorie", detail: g.category, icon: "tag.fill", action: { self.openCategoryMenu(g) }))
        items.append(SalonMenuItem(label: "Plus", icon: "ellipsis.circle.fill", action: { self.openMoreOptions(g) }))
        return SalonMenu(title: g.name, subtitle: "\(g.category) · \(played)", items: items, art: cover(g))
    }
    // MARK: Réglages d'un jeu (ce que faisaient les anciens scripts de réglages)
    func reglagesResume(_ g: Game) -> String {
        if let tid = g.titleID {
            let e = Atelier.env(tid)
            let fps = e["DM_FPS_TARGET"] == "30" ? "30 fps stables" : e["DM_FPS_HOLD"] == "off" ? "jamais retenu" : "images/s par défaut"
            return fps + (e["DM_PRESENT_UPSCALE"] == "off" ? " · sans MetalFX" : "") + (e["DM_COMPANION"] != nil ? " · serveur en ligne" : "")
        }
        return config.reglages?[g.id]?["TOTK_RENDER_RES"] == "1600x900" ? "Rendu comme la Switch (1600×900)" : "Rendu 1080p"
    }
    func openReglages(_ g: Game) {
        let retour: () -> Void = { self.menu = self.optionsMenu(g) }
        var items: [SalonMenuItem] = []
        if let tid = g.titleID {
            let e = Atelier.env(tid)
            let mode = e["DM_FPS_TARGET"] == "30" ? 1 : e["DM_FPS_HOLD"] == "off" ? 2 : 0
            let modes = [("Par défaut", "60 quand ça tient, sinon 30 ; le jeu garde toujours sa vitesse"), ("30 fps stables", "Bloqué à 30 partout : aucun saut, le plus régulier"),
                         ("Jamais retenu", "Chaque image dès qu'elle est prête : plus fluide, le jeu ralentit un peu dans les scènes lourdes")]
            items.append(SalonMenuItem(label: "Images par seconde : \(modes[mode].0)", detail: modes[mode].1, icon: "speedometer", action: {
                let n = (mode + 1) % 3
                Atelier.setEnv(tid, "DM_FPS_TARGET", n == 1 ? "30" : nil); Atelier.setEnv(tid, "DM_FPS_HOLD", n == 2 ? "off" : nil); self.openReglages(g) }))
            let metal = e["DM_PRESENT_UPSCALE"] != "off"
            items.append(SalonMenuItem(label: "Agrandissement MetalFX : \(metal ? "activé" : "désactivé")", detail: metal ? "L'image est agrandie jusqu'à l'écran par MetalFX" : "L'image du jeu telle quelle, sans agrandissement", icon: "arrow.up.left.and.arrow.down.right", action: {
                Atelier.setEnv(tid, "DM_PRESENT_UPSCALE", metal ? "off" : nil); self.openReglages(g) }))
            let serveur = Atelier.outils.appendingPathComponent(tid == "0100000000010000" ? "smoo-server.sh" : "-")
            if FileManager.default.fileExists(atPath: serveur.path) {
                let on = e["DM_COMPANION"] != nil
                items.append(SalonMenuItem(label: "Serveur en ligne : \(on ? "activé" : "désactivé")", detail: on ? "SMO Online : le serveur démarre et s'arrête avec le jeu" : "Le jeu se lance sans son serveur en ligne", icon: "network", tint: .teal, action: {
                    Atelier.setEnv(tid, "DM_COMPANION", on ? nil : serveur.path); self.openReglages(g) }))
            }
            items.append(SalonMenuItem(label: "Fichier des réglages", detail: Atelier.envURL(tid).path, icon: "doc.text", tint: .gray, action: { self.menu = nil; NSWorkspace.shared.open(Atelier.envURL(tid)) }))
        } else if Atelier.moteurDe(g) == .mng {
            let r = config.reglages?[g.id] ?? [:]; let sw = r["TOTK_RENDER_RES"] == "1600x900"
            items.append(SalonMenuItem(label: "Rendu : \(sw ? "comme la Switch (1600×900)" : "1080p")", detail: sw ? "Dessiné en 1600×900 puis agrandi : des bords plus doux, comme sur la télé" : "Dessiné directement à la taille de l'écran : le plus net", icon: "photo.tv", action: {
                var all = self.config.reglages ?? [:]; var m = all[g.id] ?? [:]; m["TOTK_RENDER_RES"] = sw ? nil : "1600x900"; all[g.id] = m; self.config.reglages = all; self.saveConfig(); self.openReglages(g) }))
            let rt = r["TOTK_RT"] == "0"
            items.append(SalonMenuItem(label: "Processeur : \(rt ? "géré par macOS" : "temps réel (d'origine)")", detail: rt ? "Le jeu n'annonce plus son temps de travail : macOS ne le garde plus à basse fréquence dans les scènes chargées" : "Le jeu annonce son temps de travail à macOS (peut le coincer à basse fréquence dehors)", icon: "cpu", action: {
                var all = self.config.reglages ?? [:]; var m = all[g.id] ?? [:]; m["TOTK_RT"] = rt ? nil : "0"; all[g.id] = m; self.config.reglages = all; self.saveConfig(); self.openReglages(g) }))
            items.append(SalonMenuItem(label: "Réglages dans le jeu", detail: "Touche 1 pendant la partie", icon: "keyboard", tint: .gray, info: true, action: {}))
            if Atelier.scriptDedie(g) == "totk-mng-online.command" {
                items.append(SalonMenuItem(label: "Moniteur du jeu en ligne", icon: "waveform.path.ecg", tint: .teal, action: { self.menu = nil; Atelier.terminal("totk-moniteur.command") }))
            }
        }
        menu = SalonMenu(title: "Réglages du jeu", subtitle: g.name, items: items, hero: "slider.horizontal.3", back: retour)
    }
    func openApparence(_ g: Game) {
        let a = art[g.id]
        menu = SalonMenu(title: "Apparence", subtitle: g.name, items: [
            SalonMenuItem(label: "Jaquette", icon: "photo.fill", action: { self.openPicker(g, .cover) }),
            SalonMenuItem(label: "Fond", icon: "photo.artframe", tint: .orange, action: { self.openPicker(g, .background) }),
            SalonMenuItem(label: "Logo", icon: "textformat", action: { self.openPicker(g, .logo) }),
        ], hero: "paintpalette.fill", back: { self.menu = self.optionsMenu(g) })
    }
    /// Le nom tapé sert à chercher les images (SteamGridDB, wikis) à la place du nom du jeu ; vide = revenir au nom du jeu
    func askNomArt(_ g: Game) {
        let a = NSAlert(); a.messageText = "Nom de recherche des images"
        a.informativeText = "Le nom sous lequel chercher jaquette, fond et logo (par ex. le titre anglais ou exact du jeu). Laisse vide pour revenir au nom du jeu."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24)); f.stringValue = config.nomsArt?[g.id] ?? g.name; a.accessoryView = f; a.window.initialFirstResponder = f
        a.addButton(withTitle: "Enregistrer"); a.addButton(withTitle: "Annuler")
        guard a.runModal() == .alertFirstButtonReturn else { openApparence(g); return }
        let n = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.nomsArt == nil { config.nomsArt = [:] }
        config.nomsArt?[g.id] = (n.isEmpty || n == g.name) ? nil : n; saveConfig()
        log("Nom de recherche \(g.name) : \(config.nomsArt?[g.id] ?? "(nom du jeu)")")
        toast = n.isEmpty || n == g.name ? "Recherche par le nom du jeu" : "Recherche : « \(n) » — choisis Jaquette, Fond ou Logo"
        openApparence(g)
    }
    func openMoreOptions(_ g: Game) {
        menu = SalonMenu(title: "Plus", subtitle: g.name, items: [
            SalonMenuItem(label: "Renommer", icon: "pencil", action: { self.menu = nil; self.rename(g) }),
            SalonMenuItem(label: "Afficher dans le Finder", detail: g.viaHome ? g.url.path : g.url.deletingLastPathComponent().path, icon: "folder.fill", action: { self.menu = nil; self.reveal(g) }),
            SalonMenuItem(label: "Masquer ce jeu", icon: "eye.slash", destructive: true, action: { self.menu = nil; self.hide(g) }),
        ] + (g.pc ? [SalonMenuItem]() : [
            SalonMenuItem(label: "Désinstaller", detail: "Les sauvegardes restent", icon: "trash.fill", destructive: true, action: { self.openDesinstaller(g) }),
        ]), hero: "ellipsis.circle.fill", back: { self.menu = self.optionsMenu(g) })
    }

    // MARK: Désinstaller : l'app, sa construction, ses caches, journaux, réglages, mods et illustrations vont à la corbeille ; les sauvegardes restent
    struct Desinstallation { var aJeter: [URL] = []; var garde: [String] = []; var defaults: String? = nil; var roms: [URL] = [] }
    func inventaire(_ g: Game) -> Desinstallation {
        let fm = FileManager.default; let lib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var d = Desinstallation()
        func ajoute(_ u: URL?) { if let u, fm.fileExists(atPath: u.path), !d.aJeter.contains(u) { d.aJeter.append(u) } }
        /// Un dossier qui garde ses sauvegardes : ses autres éléments partent un par un
        func sauf(_ dir: URL, garder: (String) -> Bool) {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                if garder(f.lastPathComponent) { d.garde.append(f.path) } else { ajoute(f) }
            }
        }
        let estSauvegarde: (String) -> Bool = { $0.range(of: #"(?i)save|sauvegarde|account|profile|user|sync"#, options: .regularExpression) != nil }
        let m = Atelier.moteurDe(g); let bid = Bundle(url: g.url)?.bundleIdentifier ?? ""
        let reg = Atelier.registre()[g.url.path]
        ajoute(g.url)
        if m == .nxnative || m == .mng {
            if let t = reg?.travail { ajoute(URL(fileURLWithPath: t)) }
            if m == .nxnative { ajoute(Atelier.dossierBuild(g).map { URL(fileURLWithPath: $0) }) }
            ajoute(Atelier.dossier(g))   // les mods du jeu
            if fm.fileExists(atPath: lib.appendingPathComponent("Preferences/\(bid).plist").path) { d.defaults = bid }   // ses réglages (defaults)
        }
        if let tid = g.titleID {   // nxnative
            sauf(appSupport.appendingPathComponent("nxnative/\(tid)"), garder: estSauvegarde)
            for n in ["\(tid).log", "\(tid).prev.log"] { ajoute(lib.appendingPathComponent("Logs/nxnative/\(n)")) }
            ajoute(salonRoot.appendingPathComponent("cache/icone-\(tid).png"))
        }
        if m == .mng, let f = Atelier.dossiersMNG(bid) {
            // une construction MacNativeGames sans registre (TOTK) : seulement le sous-dossier du jeu, le dossier sert aussi aux autres
            if reg?.travail == nil {
                for c in (try? fm.contentsOfDirectory(at: Atelier.constructions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] { ajoute(c.appendingPathComponent(f.court)) }
            }
            for c in (try? fm.contentsOfDirectory(at: appSupport.appendingPathComponent("MacNativeGames/\(f.donnees)"), includingPropertiesForKeys: nil)) ?? [] {
                if c.lastPathComponent == "profile" { sauf(c) { !["cache", "temp"].contains($0) } }   // le profil : compte et sauvegardes
                else if estSauvegarde(c.lastPathComponent) { d.garde.append(c.path) } else { ajoute(c) }
            }
            for n in ["\(f.journal).log", "\(f.journal).previous.log"] { ajoute(lib.appendingPathComponent("Logs/MacNativeGames/\(n)")) }
        }
        if m != .pc, !bid.isEmpty {
            for p in ["Caches/\(bid)", "Saved Application State/\(bid).savedState", "HTTPStorages/\(bid)", "HTTPStorages/\(bid).binarycookies", "WebKit/\(bid)"] { ajoute(lib.appendingPathComponent(p)) }
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            if confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count) > 0 { ajoute(URL(fileURLWithPath: String(cString: buf)).appendingPathComponent(bid)) }   // le cache Metal des shaders
        }
        ajoute(salonRoot.appendingPathComponent("media").appendingPathComponent(g.name))   // jaquette, fond, logo
        ajoute(salonRoot.appendingPathComponent("cache").appendingPathComponent(safeName(g.name)))
        if let r = reg { d.roms = ([r.base] + r.update + r.dlc).filter { !$0.isEmpty && fm.fileExists(atPath: $0) && !$0.hasPrefix(Atelier.home.path + "/") }.map { URL(fileURLWithPath: $0) } }
        // Les sauvegardes gardées ailleurs : celles de Home, et le dossier save à côté des jeux
        let sauvegardes = Atelier.home.appendingPathComponent("sauvegardes")
        if let id = g.storeID?.uppercased() {
            for f in (try? fm.contentsOfDirectory(at: sauvegardes, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.uppercased().hasPrefix(id) { d.garde.append(f.path) }
        }
        for f in (try? fm.contentsOfDirectory(at: g.url.deletingLastPathComponent().appendingPathComponent("save"), includingPropertiesForKeys: nil)) ?? [] where g.name.localizedCaseInsensitiveContains(f.lastPathComponent) { d.garde.append(f.path) }
        // jamais une sauvegarde, ni un dossier qui en contient une
        let garde = d.garde
        d.aJeter = d.aJeter.filter { u in !u.path.hasPrefix(sauvegardes.path) && !garde.contains { $0 == u.path || $0.hasPrefix(u.path + "/") } }
        return d
    }
    func openDesinstaller(_ g: Game) {
        if running?.id == g.id { toast = "Quitte d'abord le jeu"; return }
        if let t = tache, !t.fini, t.erreur == nil, t.jeux.contains(g.id) { toast = "Une construction de ce jeu est en cours"; return }
        let d = inventaire(g)
        let court: (String) -> String = { $0.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
        var liste = d.aJeter.prefix(10).map { "• " + court($0.path) }
        if d.aJeter.count > 10 { liste.append("• et \(d.aJeter.count - 10) autres") }
        if d.defaults != nil { liste.append("• ses réglages") }
        let gardees = d.garde.isEmpty ? "Aucune sauvegarde trouvée sur ce Mac." : "Gardé : " + d.garde.map(court).joined(separator: ", ")
        var items = [SalonMenuItem(label: "Désinstaller", detail: "Sauvegardes gardées · tes fichiers du jeu (\(d.roms.isEmpty ? "aucun" : d.roms.map { $0.lastPathComponent }.joined(separator: ", "))) gardés", icon: "trash.fill", destructive: true, action: { self.desinstaller(g, d, roms: false) })]
        if !d.roms.isEmpty {
            items.append(SalonMenuItem(label: "Désinstaller avec tes fichiers du jeu", detail: "Sauvegardes gardées · " + d.roms.map { $0.lastPathComponent }.joined(separator: ", ") + " aussi à la corbeille", icon: "trash.slash.fill", destructive: true, action: { self.desinstaller(g, d, roms: true) }))
        }
        menu = SalonMenu(title: "Désinstaller", subtitle: g.name, items: items, hero: "trash.fill", text: "Va à la corbeille :\n" + liste.joined(separator: "\n") + "\n\n" + gardees, back: { self.openMoreOptions(g) })
    }
    func desinstaller(_ g: Game, _ d: Desinstallation, roms: Bool) {
        menu = nil
        let fm = FileManager.default; var rates: [String] = []
        for u in d.aJeter + (roms ? d.roms : []) {
            do { try fm.trashItem(at: u, resultingItemURL: nil) } catch { rates.append(u.lastPathComponent); log("Désinstaller : \(u.path) — \(error.localizedDescription)") }
        }
        if let bid = d.defaults {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults"); p.arguments = ["delete", bid]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
        }
        // Home l'oublie : registre (les autres entrées telles quelles), réglages, statistiques, place dans la bibliothèque
        if let data = try? Data(contentsOf: Atelier.registreURL), var r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], r.removeValue(forKey: g.url.path) != nil,
           let out = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) { try? out.write(to: Atelier.registreURL) }
        config.reglages?[g.id] = nil; config.volumes?[g.id] = nil
        config.jeux.removeAll { $0.chemin == g.id || $0.chemin == g.url.path }
        saveConfig(); stats[g.id] = nil; saveStats(); art[g.id] = nil
        selected = 0; load()
        toast = rates.isEmpty ? "\(g.name) désinstallé · sauvegardes gardées · vide la corbeille pour libérer la place" : "\(g.name) désinstallé, sauf : " + rates.joined(separator: ", ")
    }
    func openPlusMenu() {
        guard running == nil else { return }
        Sounds.shared.play("ouvrir")
        menu = plusMenu()
    }
    func plusMenu() -> SalonMenu {
        let capture = !(config.capture ?? true) ? "Désactivée" : CGPreflightScreenCaptureAccess() ? "Activée" : "Activée — autorisation macOS manquante"
        return SalonMenu(title: "Home", subtitle: "\(games.count) jeux · \(categories.count - 1) catégories", items: [
            SalonMenuItem(label: "Mises à jour", icon: "arrow.down.circle.fill", tint: .blue, action: { self.openMisesAJour() }),
            SalonMenuItem(label: "Ajouter un jeu", icon: "plus.app.fill", action: { self.openAddMenu(back: { self.menu = self.plusMenu() }) }),
            SalonMenuItem(label: "Comptes", detail: "Epic Games, Steam", icon: "person.crop.circle.fill", tint: .purple, action: { self.openPC(back: { self.menu = self.plusMenu() }) }),
            SalonMenuItem(label: "Composants", detail: modeResume, icon: "square.grid.2x2.fill", tint: .purple, action: { self.openModeUtilisation() }),
            SalonMenuItem(label: "Catégories", icon: "tag.fill", action: { self.openCategoriesSettings() }),
            SalonMenuItem(label: "Écrans", icon: "display.2", action: { self.openScreensSettings() }),
            SalonMenuItem(label: "Son", detail: "Général \(Int((macVolume * 100).rounded())) %\(macMuted ? " (muet)" : "") · sons de Home \((config.sons ?? true) ? "activés" : "coupés")", icon: "speaker.wave.2.fill", action: { self.openSoundSettings() }),
            SalonMenuItem(label: "Capture", detail: capture + " · " + Recorder.duree, icon: "record.circle", action: { self.openCapture() }),
            SalonMenuItem(label: "Avancé", icon: "ellipsis.circle.fill", tint: .gray, action: { self.openAdvancedSettings() }),
            SalonMenuItem(label: "Redémarrer", icon: "arrow.clockwise", tint: .cyan, action: {   // Home se ferme et se rouvre : la liste, les images et les réglages sont relus
                self.menu = nil; Sounds.shared.play("retour")
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", Bundle.main.bundlePath]; try? p.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) } }),
            SalonMenuItem(label: "Quitter", icon: "power", destructive: true, action: { self.menu = nil; Sounds.shared.play("retour"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) } }),
        ], hero: "house.fill")
    }
    /// Les logiciels qui font tourner les jeux : chacun mis à jour, puis ses jeux reconstruits
    /// Mises à jour : Home, puis les moteurs (chacun sa section)
    /// Une mise à jour d'un moteur arrêtée parce qu'un changement d'Anas ne s'applique plus sur la nouvelle version (tools/serie.py) :
    /// rien n'a été modifié, un rapport dit quel changement et pourquoi. [(nom du moteur, rapport)]
    func majEnAttente() -> [(String, URL)] {
        [("MacNativeGames", "mng-maj.json"), ("nxnative", "nxnative-maj.json")].compactMap { nom, f in
            guard let d = try? Data(contentsOf: Atelier.home.appendingPathComponent("log/" + f)), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  j["etat"] as? String == "attente", let r = j["rapport"] as? String, FileManager.default.fileExists(atPath: r) else { return nil }
            return (nom, URL(fileURLWithPath: r))
        }
    }
    /// Les choix « en attente » à mettre en tête d'un menu de mises à jour : chacun ouvre son rapport
    func choixEnAttente() -> [SalonMenuItem] {
        majEnAttente().map { nom, rapport in
            SalonMenuItem(label: "\(nom) en attente", detail: "Un de tes changements ne s'applique plus. Ouvrir le rapport", icon: "exclamationmark.triangle.fill", section: "En attente", tint: .orange, action: { NSWorkspace.shared.open(rapport) })
        }
    }
    func openMisesAJour() {
        let app = Bundle.main.bundleURL
        let date = (try? app.appendingPathComponent("Contents/MacOS/Salon").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        menu = SalonMenu(title: "Mises à jour", subtitle: nil, items: choixEnAttente() + [
            SalonMenuItem(label: "Mettre à jour Home", detail: date.map { "Version du \($0.formatted(date: .abbreviated, time: .shortened))" }, icon: "house.fill", section: "Home", tint: .blue, action: {
                self.menu = nil; self.lancer("home-mettre-a-jour.command", titre: "Mise à jour de Home") }),
            SalonMenuItem(label: "Moteurs", detail: "nxnative, MacNativeGames", icon: "cpu", section: "Moteurs", tint: .purple, action: { self.openMoteurs() }),
        ], hero: "arrow.down.circle.fill", back: { self.menu = self.plusMenu() })
    }
    func openMoteurs() {
        func lire(_ cmd: [String]) -> String { Commande.run(cmd[0], Array(cmd.dropFirst())).trimmingCharacters(in: .whitespacesAndNewlines) }
        func version(_ app: String) -> String? { (Bundle(path: app)?.infoDictionary?["CFBundleShortVersionString"] as? String).map { "Version \($0)" } }
        let nx = ((try? String(contentsOf: Atelier.moteur.appendingPathComponent(".upstream-ref"), encoding: .utf8)) ?? "").prefix(7)
        var items: [SalonMenuItem] = [
            SalonMenuItem(label: "Mettre à jour nxnative", detail: nx.isEmpty ? nil : "Version \(nx)", icon: "cpu", section: "nxnative", tint: .purple, action: { self.menu = nil; self.majMoteur() }),
        ]
        items.insert(SalonMenuItem(label: "Composants Mac", detail: "Les outils pour les jeux Switch", icon: "wrench.and.screwdriver.fill", section: "Outils", tint: .teal, action: { self.openPreparation(back: { self.openMoteurs() }) }), at: 0)
        if FileManager.default.fileExists(atPath: Atelier.home.appendingPathComponent("MacNativeGames/build_app.py").path) {
            let v = lire(["/usr/bin/git", "-C", Atelier.home.appendingPathComponent("MacNativeGames").path, "log", "-1", "--format=%h · %cd", "--date=format:%d/%m/%Y"])
            items.append(SalonMenuItem(label: "Mettre à jour MacNativeGames", detail: v.isEmpty ? nil : "Version \(v)", icon: "leaf.fill", section: "MacNativeGames", tint: .green, action: {
                self.menu = nil; self.lancer("mng-mettre-a-jour.command", titre: "Mise à jour de MacNativeGames", jeux: Set(self.games.filter { Atelier.moteurDe($0) == .mng }.map { $0.id })) }))
        }
        if let n = ["/Applications/NX Library.app", "/Applications/NXLibrary.app"].first(where: { FileManager.default.fileExists(atPath: $0) }) {
            items.append(SalonMenuItem(label: "Ouvrir NX Library", detail: version(n), icon: "books.vertical.fill", section: "NX Library", tint: .orange, action: {
                self.menu = nil; NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: n), configuration: NSWorkspace.OpenConfiguration()) { _, _ in } }))
        }
        menu = SalonMenu(title: "Moteurs", subtitle: nil, items: choixEnAttente() + items, hero: "cpu", back: { self.openMisesAJour() })
    }
    func openCategoriesSettings() {
        let custom = (config.categories ?? []).filter { !Library.base.contains($0) }
        menu = SalonMenu(title: "Catégories", subtitle: nil, items: [
            SalonMenuItem(label: "Nouvelle catégorie", icon: "folder.badge.plus", action: { self.menu = nil; self.addCategory(assign: nil) }),
            SalonMenuItem(label: "Supprimer une catégorie", detail: custom.isEmpty ? "Aucune catégorie personnalisée" : custom.joined(separator: ", "), icon: "folder.badge.minus", tint: .red, action: { self.openRemoveCategoryMenu() }),
        ], hero: "tag.fill", back: { self.menu = self.plusMenu() })
    }
    func openScreensSettings() {
        menu = SalonMenu(title: "Écrans", subtitle: nil, items: [
            SalonMenuItem(label: "Écran des jeux", detail: "\(gameScreen.localizedName)\(CGDisplayIsBuiltin(Library.screenID(gameScreen)) != 0 ? " (écran du Mac)" : " (moniteur)")\(NSScreen.screens.count > 1 ? " — choisir pour passer à l'autre écran" : "")", icon: "gamecontroller.fill", action: { self.cycleGameScreen(); self.openScreensSettings() }),
            SalonMenuItem(label: "Écran de Home", icon: "display.2", action: { self.menu = nil; NotificationCenter.default.post(name: .salonNextScreen, object: nil) }),
            SalonMenuItem(label: "Affichage", detail: (config.espacePleinEcran ?? true) ? "Plein écran dédié, sans Dock" : "Fenêtre sur le bureau", icon: "rectangle.on.rectangle", action: { self.menu = nil; NotificationCenter.default.post(name: .salonToggleSpace, object: nil) }),
        ], hero: "display.2", back: { self.menu = self.plusMenu() })
    }
    func openSoundSettings() {
        menu = SalonMenu(title: "Son", subtitle: nil, items: [
            SalonMenuItem(label: "Volume", detail: "Général \(Int((macVolume * 100).rounded())) %\(macMuted ? " (muet)" : "") — stick droit ◀▶, \(hints.tri.text) : muet · Jeux \(Int((volume * 100).rounded())) %", icon: "speaker.wave.2.fill", action: { self.menu = nil; self.flashGeneral = true; self.volumeFlash = Date() }),
            SalonMenuItem(label: "Sons de Home", detail: (config.sons ?? true) ? "Activés" : "Coupés", icon: (config.sons ?? true) ? "speaker.wave.2" : "speaker.slash", tint: .purple, action: { self.toggleSounds(); self.openSoundSettings() }),
        ], hero: "speaker.wave.2.fill", back: { self.menu = self.plusMenu() })
    }
    /// Avancé : trois choix — Système (Home lui-même, et ses images), Construction (les jeux Switch), Journaux
    /// Menu → Capture : l'activer, et choisir combien de temps en arrière le clip remonte
    func openCapture() {
        let oui = config.capture ?? true, n = Recorder.secondes
        menu = SalonMenu(title: "Capture", items: [
            SalonMenuItem(label: "Capture : \(oui ? "oui" : "non")", detail: oui && !CGPreflightScreenCaptureAccess() ? "Autorisation macOS manquante" : "Garde les derniers instants du jeu", icon: oui ? "record.circle.fill" : "record.circle", tint: .red, action: {
                self.config.capture = !oui; self.saveConfig(); self.openCapture() }),
            SalonMenuItem(label: "Qualité : \(Recorder.legere ? "légère" : "haute")", detail: Recorder.legere ? "720p : pèse moins sur le jeu" : "1080p : pèse plus sur le jeu", icon: "sparkles.tv", tint: .blue, action: {
                UserDefaults.standard.set(!Recorder.legere, forKey: "captureLegere"); self.openCapture() }),
            SalonMenuItem(label: "Durée : \(Recorder.duree)", detail: "Le temps en arrière qui est enregistré", icon: "timer", tint: .orange, action: {
                let suite = [15, 30, 60, 120]; UserDefaults.standard.set(suite[((suite.firstIndex(of: n) ?? 0) + 1) % suite.count], forKey: "captureSecondes"); self.openCapture() }),
        ], hero: "record.circle", back: { self.menu = self.plusMenu() })
    }
    func openAdvancedSettings() {
        menu = SalonMenu(title: "Avancé", items: [
            SalonMenuItem(label: "Système", detail: "Démarrage, animations, images", icon: "gearshape.fill", tint: .purple, action: { self.openAvanceHome() }),
            SalonMenuItem(label: "Construction", detail: "Jeux Switch : clés, vitesse, place", icon: "hammer.fill", tint: .red, action: { self.openAvanceSwitch() }),
            SalonMenuItem(label: "Journaux", detail: "Les copie pour Claude", icon: "doc.text.magnifyingglass", tint: .gray, action: { self.menu = nil; self.lancer("journaux.command", titre: "Copie des journaux") }),
        ].filter { i in self.modeNintendo || i.label != "Construction" }, hero: "gearshape.fill", back: { self.menu = self.plusMenu() })
    }
    func openAvanceHome() {
        let veilleOff = salonRoot.appendingPathComponent("veille-off"), reduit = animationsReduites, ici: () -> Void = { self.openAvanceHome() }
        menu = SalonMenu(title: "Système", items: [
            SalonMenuItem(label: "Ouverture à la manette : \(FileManager.default.fileExists(atPath: veilleOff.path) ? "non" : "oui")", detail: "Home s'ouvre quand une manette se connecte", icon: "gamecontroller.fill", tint: .green, action: {
                if FileManager.default.fileExists(atPath: veilleOff.path) { try? FileManager.default.removeItem(at: veilleOff) } else { FileManager.default.createFile(atPath: veilleOff.path, contents: nil) }
                ici() }),
            SalonMenuItem(label: "Écran de démarrage : \((config.ouverture ?? true) ? "oui" : "non")", detail: "L'intro et son jingle", icon: "play.rectangle.fill", tint: .purple, action: {
                self.config.ouverture = !(self.config.ouverture ?? true); self.saveConfig(); ici() }),
            SalonMenuItem(label: "Animations réduites : \(reduit ? "oui" : "non")", detail: "Des fondus courts à la place des mouvements", icon: reduit ? "hand.raised.fill" : "hand.wave.fill", tint: .teal, action: {
                UserDefaults.standard.set(!reduit, forKey: "animationsReduites"); ici() }),
            SalonMenuItem(label: "Images", detail: "Jaquettes, fonds et logos", icon: "photo.fill", tint: .blue, action: { self.openAvanceImages() }),
        ], hero: "gearshape.fill", back: { self.openAdvancedSettings() })
    }
    func openAvanceImages() {
        menu = SalonMenu(title: "Images", items: [
            SalonMenuItem(label: "Clé SteamGridDB", detail: SteamGridDB.key() == nil ? "Absente : pas de jaquettes" : "Enregistrée", icon: "key.fill", tint: .blue, action: { self.menu = nil; self.askKey() }),
            SalonMenuItem(label: "Dossier des images", detail: "L'ouvre dans le Finder", icon: "folder.fill", tint: .orange, action: { self.menu = nil; NSWorkspace.shared.open(salonRoot) }),
        ], hero: "photo.fill", back: { self.openAvanceHome() })
    }
    func openAvanceSwitch() {
        let ici: () -> Void = { self.openAvanceSwitch() }
        menu = SalonMenu(title: "Construction", items: [
            SalonMenuItem(label: "Clés de la console", detail: config.cles ?? "Ton fichier prod.keys", icon: "key.fill", tint: .yellow, action: {
                self.proposer("Quelles clés ?", icone: "key.fill", chercher: {
                    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".switch/prod.keys")   // l'emplacement habituel, dans un dossier caché
                    return (FileManager.default.fileExists(atPath: cache.path) ? [cache] : []) + Library.fichiersCandidats(ext: [], noms: ["prod.keys"])
                }, finder: {
                    let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.message = "Le fichier prod.keys de ta console"
                    p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                    return p.runModal() == .OK ? p.urls : nil
                }, back: ici) { u in self.config.cles = u[0].path; self.saveConfig(); ici() } }),
            SalonMenuItem(label: "Construction silencieuse : \((config.discret ?? false) ? "oui" : "non")", detail: (config.discret ?? false) ? "Plus lente, le Mac reste frais" : "Plus rapide, le Mac chauffe", icon: "thermometer.medium", tint: .teal, action: {
                self.config.discret = !(self.config.discret ?? false); self.saveConfig(); ici() }),
            SalonMenuItem(label: "Garder les caches : \((self.config.garderCaches ?? true) ? "oui" : "non")", detail: (self.config.garderCaches ?? true) ? "Reconstructions courtes" : "Moins de place, reconstructions longues", icon: "externaldrive.fill", tint: .orange, action: {
                self.config.garderCaches = !(self.config.garderCaches ?? true); self.saveConfig(); ici() }),
            SalonMenuItem(label: "Libérer de la place", detail: "Allège les dossiers de construction", icon: "externaldrive.badge.minus", tint: .orange, action: { self.menu = nil; self.lancer("alleger-build.sh", titre: "Allègement des dossiers de construction") }),
        ], hero: "hammer.fill", back: { self.openAdvancedSettings() })
    }
    func openCategoryMenu(_ g: Game) {
        var items = categories.filter { $0 != Library.all }.map { c in SalonMenuItem(label: c, detail: c == g.category ? "Catégorie actuelle" : nil, icon: c == g.category ? "checkmark.circle.fill" : "circle", action: { self.menu = nil; self.setCategory(g, c) }) }
        items.append(SalonMenuItem(label: "Nouvelle catégorie…", detail: "\(g.name) y sera rangé", icon: "plus", action: { self.menu = nil; self.addCategory(assign: g) }))
        menu = SalonMenu(title: "Catégorie", subtitle: g.name, items: items, hero: "tag.fill", back: { self.menu = self.optionsMenu(g) })
    }
    func openRemoveCategoryMenu() {
        let custom = (config.categories ?? []).filter { !Library.base.contains($0) }
        guard !custom.isEmpty else { toast = "Les catégories de base ne se suppriment pas"; return }
        menu = SalonMenu(title: "Supprimer", subtitle: "Les jeux retournent dans leur catégorie d'origine", items: custom.map { c in SalonMenuItem(label: c, detail: "\(games.filter { $0.category == c }.count) jeux", icon: "trash", destructive: true, action: { self.menu = nil; self.removeCategory(c) }) }, hero: "trash.fill", back: { self.openCategoriesSettings() })
    }
    func reveal(_ g: Game) {
        if g.viaHome { NSWorkspace.shared.activateFileViewerSelecting([g.url]); return }
        NSWorkspace.shared.activateFileViewerSelecting([g.url])
    }
    func setCategory(_ g: Game, _ c: String) { let i = entry(for: g); config.jeux[i].categorie = c; saveConfig(); load(); if let k = categories.firstIndex(of: c) { categoryIndex = k }; selected = visible.firstIndex(of: g) ?? 0; toast = "\(g.name) → \(c)" }
    func addCategory(assign g: Game?) {
        let a = NSAlert(); a.messageText = "Nouvelle catégorie"; a.informativeText = g == nil ? "Elle apparaîtra dans les onglets." : "Elle apparaîtra dans les onglets, et « \(g!.name) » y sera rangé."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); f.placeholderString = "Rétro, Multijoueur, Enfants…"; a.accessoryView = f; a.window.initialFirstResponder = f
        a.addButton(withTitle: "Créer"); a.addButton(withTitle: "Annuler")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty, name != Library.all else { return }
        var cats = config.categories ?? []; if !cats.contains(name) { cats.append(name) }; config.categories = cats; saveConfig()
        if let g { setCategory(g, name) } else { load(); if let k = categories.firstIndex(of: name) { categoryIndex = k; selected = 0 } }
        toast = "Catégorie « \(name) » créée"
    }
    func removeCategory(_ c: String) {
        guard !Library.base.contains(c), c != Library.all else { return }
        config.categories = (config.categories ?? []).filter { $0 != c }
        for i in config.jeux.indices where config.jeux[i].categorie == c { config.jeux[i].categorie = nil }
        saveConfig(); categoryIndex = 0; selected = 0; load(); toast = "Catégorie « \(c) » supprimée"
    }
    func hide(_ g: Game) { let i = entry(for: g); config.jeux[i].masque = true; saveConfig(); load(); toast = "\(g.name) masqué (réaffichable dans jeux.json)" }
    func rename(_ g: Game) {
        let a = NSAlert(); a.messageText = "Nom affiché"; let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); f.stringValue = g.name; a.accessoryView = f; a.window.initialFirstResponder = f
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Annuler")
        if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty { let i = entry(for: g); config.jeux[i].nom = f.stringValue; saveConfig(); load() }
    }
    func chooseFile(_ g: Game, _ slot: Slot) {
        let p = NSOpenPanel(); p.allowedContentTypes = slot == .background ? [.image, .movie] : [.image]; p.message = "\(slot.rawValue) pour \(g.name)"
        guard p.runModal() == .OK, let src = p.url else { return }
        let media = salonRoot.appendingPathComponent("media").appendingPathComponent(g.name)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let isVideo = ["mp4", "mov"].contains(src.pathExtension.lowercased())
        let base = slot == .cover ? "cover" : slot == .background ? "fond" : "logo"
        for ext in ["jpg", "png", "mp4", "mov"] { try? FileManager.default.removeItem(at: media.appendingPathComponent("\(base).\(ext)")) }
        let dst = media.appendingPathComponent("\(base).\(isVideo ? src.pathExtension.lowercased() : (slot == .logo ? "png" : "jpg"))")
        if isVideo || slot == .logo || ["jpg", "jpeg"].contains(src.pathExtension.lowercased()) { try? FileManager.default.copyItem(at: src, to: dst) }   // tel quel, sans recompression
        else if let i = NSImage(contentsOf: src), let t = i.tiffRepresentation, let r = NSBitmapImageRep(data: t), let d = r.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) { try? d.write(to: dst) }
        log("\(slot.rawValue) \(g.name) : fichier \(src.path) → \(dst.path)")
        load(); toast = "\(slot.rawValue) mise à jour"
    }
    // Galerie SteamGridDB + une dernière case « Depuis un fichier… »
    func openPicker(_ g: Game, _ slot: Slot) {
        menu = nil; pickCharges = []; pickerSaisie = false; pickBouge = false
        let fileItem = Candidate(id: "file", thumb: nil, full: nil, author: "")
        guard let key = SteamGridDB.key() else { log("Jaquette \(g.name) : pas de clé SteamGridDB"); picker = (slot, [fileItem], 0, g); pickIndex = 0; toast = "Pas de clé SteamGridDB (X → Clé SteamGridDB) : choisis un fichier"; return }
        let nomPerso = config.nomsArt?[g.id]   // le nom de recherche tapé dans Apparence, s'il y en a un
        picker = (slot, [fileItem], 0, g); pickIndex = 0; pickerLoading = true; pickerNote = "Recherche\(nomPerso.map { " « \($0) »" } ?? "") : SteamGridDB, eShop, PlayStation Store, wikis…"
        Task.detached { [weak self] in
            guard let self else { return }
            var nom = nomPerso ?? g.name   // sinon le titre de la boutique quand on le connaît
            if nomPerso == nil, let t = g.storeID, let i = await EShop.info(titleID: t) { nom = i.title }
            var found = await SteamGridDB.games(name: nom, key: key)
            if let exact = found.first(where: { $0.1.lowercased() == nom.lowercased() }) { found = [exact] }   // un nom exact : rien d'autre, pas de jeux « proches » sans rapport
            else { found = found.filter { matchesGame($0.1, nom) } }
            found = found.filter { memesNumeros($0.1, nom) }   // pas d'un autre épisode (FC 24 pour FC 27)
            var items: [Candidate] = []; var seen = Set<String>()
            // ce qui est déjà trouvé est montré tout de suite : chaque source complète la rangée quand elle répond
            func publier(_ liste: [Candidate]) async {
                let vus = liste.filter { $0.fits(slot) }
                await MainActor.run {
                    guard self.picker?.game.id == g.id, self.picker?.slot == slot else { return }
                    let visee = self.picker.flatMap { $0.items.indices.contains(self.pickIndex) ? $0.items[self.pickIndex].id : nil }
                    self.picker = (slot, vus + [fileItem], 0, g)
                    if self.pickBouge, let v = visee, let i = (vus + [fileItem]).firstIndex(where: { $0.id == v }) { self.pickIndex = i } else { self.pickCaler() }
                }
            }
            if let t = g.storeID {   // sources officielles d'abord
                func add(_ c: Candidate) { if !seen.contains(c.id) { seen.insert(c.id); items.append(c) } }
                let info = await EShop.info(titleID: t)
                switch slot {
                case .background:
                    if let b = info, let u = b.banner { add(Candidate(id: u.absoluteString, thumb: b.bannerThumb ?? u, full: u, author: "bannière officielle", source: "Boutique Nintendo eShop", width: b.bannerSize.0, height: b.bannerSize.1)) }
                case .cover:
                    if let u = URL(string: "https://api.nlib.cc/nx/\(t)/icon") { add(Candidate(id: u.absoluteString, thumb: u, full: u, author: "icône officielle du jeu", source: "Icône eShop", width: 1024, height: 1024)) }
                    if let sq = info?.square { add(Candidate(id: sq.absoluteString, thumb: sq, full: sq, author: "image carrée de la fiche", source: "Boutique Nintendo eShop", width: 500, height: 500)) }
                case .logo: break
                }
            }
            await publier(items)
            for c in await PSStore.candidates(slot, name: nom) where !seen.contains(c.id) { seen.insert(c.id); items.append(c) }   // PlayStation Store : visuels officiels
            await publier(items)
            for (gid, gname) in found {
                var list = await SteamGridDB.candidates(slot, gameID: gid, key: key)
                if !found.isEmpty, gname.lowercased() != g.name.lowercased() { list = list.map { var c = $0; c.game = gname; return c } }
                for c in list where !seen.contains(c.id) { seen.insert(c.id); items.append(c) }
                await publier(items)
                if items.count >= 24 { break }
            }
            items = items.filter { $0.fits(slot) }
            for c in await Wiki.candidates(slot, name: nomPerso ?? g.name) where !seen.contains(c.id) { seen.insert(c.id); items.append(c) }   // wikis : souvent la jaquette ou le logo exacts
            log("\(slot.rawValue) \(g.name) : \(found.count) jeux proches \(found.map { $0.1 }), \(items.count) propositions (SteamGridDB + wikis)")
            let note = found.isEmpty ? "Rien trouvé pour « \(nom) » : essaie un autre nom"
                : (found.first?.1.lowercased() == nom.lowercased() || found.first?.1.lowercased() == g.name.lowercased() ? nil : "Pas de correspondance exacte : propositions pour \(found.map { "« \($0.1) »" }.joined(separator: ", "))")
            await MainActor.run { guard self.picker?.game.id == g.id else { return }; self.picker = (slot, items + [fileItem], 0, g); if !(self.picker?.items.indices.contains(self.pickIndex) ?? false) { self.pickIndex = 0 }; self.pickerLoading = false; self.pickerNote = note }
        }
    }
    func pickCandidate() {
        guard let p = picker, p.items.indices.contains(pickIndex) else { return }
        let c = p.items[pickIndex]; picker = nil
        if c.id == "file" { chooseFile(p.game, p.slot); return }
        guard let full = c.full else { return }
        toast = "Téléchargement…"
        Task.detached { [weak self] in
            guard let self, let d = try? await URLSession.shared.data(from: full).0 else { await MainActor.run { self?.toast = "Téléchargement impossible" }; return }
            let media = salonRoot.appendingPathComponent("media").appendingPathComponent(p.game.name)
            try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let base = p.slot == .cover ? "cover" : p.slot == .background ? "fond" : "logo"
            for ext in ["jpg", "png", "mp4", "mov"] { try? FileManager.default.removeItem(at: media.appendingPathComponent("\(base).\(ext)")) }
            let dst = media.appendingPathComponent("\(base).\(p.slot == .logo || full.pathExtension.lowercased() == "png" ? "png" : "jpg")")
            do { try d.write(to: dst); log("\(p.slot.rawValue) \(p.game.name) : écrit \(dst.path) (\(d.count) octets)") } catch { log("\(p.slot.rawValue) \(p.game.name) : écriture impossible \(dst.path) : \(error)") }
            await MainActor.run { self.load(); self.toast = NSImage(data: d) == nil ? "Image illisible, essaie-en une autre" : "\(p.slot.rawValue) mise à jour" }
        }
    }
    func askKey() {
        let a = NSAlert(); a.messageText = "Clé API SteamGridDB"; a.informativeText = "Gratuite : steamgriddb.com → Profil → Préférences → API. Elle sert à trouver jaquettes, fonds et logos de tous tes jeux."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); f.stringValue = SteamGridDB.key() ?? ""; a.accessoryView = f; a.window.initialFirstResponder = f
        a.addButton(withTitle: "Enregistrer"); a.addButton(withTitle: "Annuler")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let k = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        try? k.write(to: salonRoot.appendingPathComponent("steamgriddb-api-key"), atomically: true, encoding: .utf8)
        toast = "Clé enregistrée"; load()
    }
    /// Ajouter une app Mac : Home propose les jeux installés (les apps que leur éditeur range dans « Jeux ») qui ne sont pas encore là
    func addGame(back: (() -> Void)? = nil) {
        let deja = Set(games.map { $0.url.standardizedFileURL.path } + config.jeux.map { URL(fileURLWithPath: $0.chemin).standardizedFileURL.path })
        proposer("Quelle app ?", icone: "app.fill", chercher: {
            let fm = FileManager.default
            let dossiers = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            var apps: [URL] = []
            for d in dossiers { for u in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                if u.pathExtension == "app" { apps.append(u) }
                else if u.hasDirectoryPath { apps += ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { $0.pathExtension == "app" } }
            } }
            return apps.filter { u in
                guard !deja.contains(u.standardizedFileURL.path), let c = Bundle(url: u)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String else { return false }
                return c.contains("games")
            }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        }, finder: {
            let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications"); p.message = "Choisis l'app du jeu à ajouter"
            return p.runModal() == .OK ? p.urls : nil
        }, back: back ?? { self.menu = nil }) { u in
            self.menu = nil; self.config.jeux.append(Entry(chemin: u[0].path, nom: nil, categorie: nil, masque: nil)); self.saveConfig(); self.load()
        }
    }

    // Lancement. Le Salon ne se cache plus : le jeu passe devant (sur son propre espace s'il est en plein écran) et le Salon
    // reprend la main quand le jeu se ferme, ou dès qu'on le ré-active (⌘-tab, Dock).
    func launch() {
        if running == nil, !showOptions, picker == nil, current == nil, selected >= visible.count { openAddMenu(); return }   // la case +
        guard running == nil, !showOptions, picker == nil, let g = current else { return }
        if enFond(g) { Sounds.shared.play("valider"); reprendre(); return }   // il tourne encore derrière : on y retourne
        if let f = fond, f.jeu.id != g.id, f.app?.isTerminated == false || f.direct?.isRunning == true { toast = "\(f.jeu.name) est encore ouvert : ferme-le d'abord"; Sounds.shared.play("retour"); return }   // jamais deux jeux à la fois
        if g.pc, let b = Compat.bloque(g) { openBloque(g.name, b); return }   // un jeu que son éditeur refuse sur Mac et Linux : pas lancé, la raison affichée
        running = g; startedAt = Date(); Sounds.shared.play("valider"); overlay = true; lastInput = Date(); applySavedVolume(g)
        if config.capture ?? true {
            if CGPreflightScreenCaptureAccess() { Recorder.shared.start() }
            else if !captureWarned { captureWarned = true; toast = "Capture inactive : macOS ne reconnaît pas l'autorisation Enregistrement d'écran de cette version de Home (voir X → Réglages → Capture en jeu)" }
        }
        // Le Salon reste derrière le jeu (bureau noir, façon Big Picture) : sa fenêtre descend sous le niveau normal pour que le jeu soit toujours
        // au-dessus (même en cliquant sur le fond), le HUD par-dessus, et il remonte à la fin du jeu
        NotificationCenter.default.post(name: .salonHide, object: nil)
        if let tid = g.titleID { ensureFullscreen(tid) }
        if g.viaHome { launchPC(g); return }
        let conf = NSWorkspace.OpenConfiguration(); conf.activates = true
        log("Écran des jeux : \(gameScreen.localizedName) (\(config.ecranJeu == nil ? "externe par défaut" : "choisi dans Réglages"))")
        if (Bundle(url: g.url)?.bundleIdentifier ?? "").hasPrefix("org.macnativegames.") { conf.environment = ["TOTK_FULLSCREEN": "1", "TOTK_SCREEN_ID": String(Library.screenID(gameScreen)), "TOTK_DEBUG_LOG": "1", "TOTK_ONLINE_LOG": "1"].merging(config.reglages?[g.id] ?? [:]) { _, b in b }
            if Atelier.scriptDedie(g) == "totk-mng-online.command" { conf.environment["TOTK_SWKBD_FIRST"] = Atelier.totkAdresse() } }   // TOTK Online : l'adresse du serveur, sans la demander   // fenêtre pleine taille sans Space (patch du front end MNG) + journal ~/Library/Logs/MacNativeGames/totk.log
        // TOTK Online : le mod se connecte une seule fois au serveur (127.0.0.1:10014) au démarrage ; sans serveur il reste bloqué sur
        // « Syncing saves ». Le Salon démarre donc le serveur, attend qu'il écoute, puis lance le jeu ; il l'arrête à la fin de la partie.
        if Atelier.scriptDedie(g) == "totk-mng-online.command", Atelier.totkLocal() {   // serveur distant (serveurs/totk-adresse.txt) : rien à démarrer ici
            startTotkServer { [weak self] ok in
                guard let self, self.running?.id == g.id else { return }
                if !ok { self.toast = "Serveur TOTK Online pas prêt (journal : log/totk-server.log) — le jeu se lance quand même" }
                self.openGame(g, conf)
            }
            return
        }
        openGame(g, conf)
    }
    private var totkServer: Process? = nil
    private static func portListening(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }; defer { close(fd) }
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
    private func startTotkServer(_ done: @escaping (Bool) -> Void) {
        if Self.portListening(10014) { log("TOTK Online : serveur déjà en marche"); done(true); return }
        let script = Atelier.outils.appendingPathComponent("totk-server.sh").path
        guard FileManager.default.fileExists(atPath: script) else { log("TOTK Online : \(script) introuvable"); done(false); return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = [script]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("TOTK Online : serveur non lancé (\(error.localizedDescription))"); done(false); return }
        totkServer = p; toast = "Démarrage du serveur TOTK Online…"; log("TOTK Online : serveur lancé (pid \(p.processIdentifier))")
        let start = Date()
        func poll() {
            if Self.portListening(10014) { log("TOTK Online : serveur prêt en \(String(format: "%.1f", Date().timeIntervalSince(start))) s"); toast = nil; done(true); return }
            if !p.isRunning || Date().timeIntervalSince(start) > 30 { log("TOTK Online : serveur pas prêt (\(p.isRunning ? "délai dépassé" : "arrêté"))"); done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
        }
        poll()
    }
    private func stopTotkServer() {
        guard let p = totkServer else { return }; totkServer = nil
        // le script lance tail | java | grep : on arrête ses enfants (dont java, qui sauvegarde en quittant) puis le script
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-TERM", "-P", String(p.processIdentifier)]
        try? k.run(); k.waitUntilExit(); if p.isRunning { p.terminate() }
        log("TOTK Online : serveur arrêté")
    }
    private func openGame(_ g: Game, _ conf: NSWorkspace.OpenConfiguration) {
        let before = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        NSWorkspace.shared.openApplication(at: g.url, configuration: conf) { [weak self] app, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let app else { self.running = nil; self.toast = "Impossible de lancer \(g.name)"; log("\(g.name) : lancement refusé par macOS"); return }
                log("\(g.name) : lancé, pid \(app.processIdentifier) (\(app.bundleIdentifier ?? "?"))")
                if g.titleID == nil, !(app.bundleIdentifier ?? "").hasPrefix("org.macnativegames.") { self.forceFullscreen(app, name: g.name) }
                var target: NSRunningApplication? = app; self.watchedApp = target
                self.watch?.invalidate()
                self.watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self, self.running != nil else { self?.watch?.invalidate(); return }
                    let rythme = (self.startedAt.map { Date().timeIntervalSince($0) } ?? 0) < 90 ? 2 : 10   // un jeu lance ses processus dans la première minute ; après, on vérifie de loin
                    if Int(Date().timeIntervalSince1970) % rythme == 0, self.volumeSource == .bgm {   // toutes les 2 s : un processus du jeu apparu (dmhost) reçoit le volume du jeu,
                        // et tant que Background Music n'a pas la valeur voulue on la réécrit : le jeu n'ouvre son son que plusieurs secondes après son lancement,
                        // l'écriture faite avant est refusée (il fallait bouger le curseur pour que le volume s'applique)
                        let p = Set(self.gamePids()); let voulu = Int32(((self.gameMuted ? 0 : self.volume) * 50).rounded())
                        if !p.isEmpty, p != self.bgmApplied || BGM.get(pids: Array(p), bundleID: self.watchedApp?.bundleIdentifier) != voulu {
                            self.bgmApplied = p; self.pidCache = (Array(p), Date()); BGM.set(voulu, pids: Array(p), bundleID: self.watchedApp?.bundleIdentifier)
                        }
                    }
                    if let t = target, t.isTerminated {
                        if let again = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == t.bundleIdentifier && $0.processIdentifier != t.processIdentifier && !$0.isTerminated && $0.bundleIdentifier != nil }) {
                            log("\(g.name) : relancé par lui-même (pid \(again.processIdentifier)), session poursuivie"); target = again; self.watchedApp = again; return
                        }
                        log("\(g.name) : processus terminé (\(t.localizedName ?? "?"))"); self.gameEnded(g, comeBack: true)
                    }
                }
            }
        }
    }
    /// Apps Mac (MacNativeGames, Roblox…) : leur fenêtre est passée en plein écran dès qu'elle apparaît (attribut AXFullScreen ; autorisation Accessibilité)
    private func forceFullscreen(_ app: NSRunningApplication, name: String) {
        guard AXIsProcessTrusted() else { log("\(name) : plein écran impossible sans l'autorisation Accessibilité"); return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        DispatchQueue.global().async {
            for _ in 0..<60 {   // jusqu'à 30 s : certaines apps mettent du temps à ouvrir leur fenêtre de jeu
                Thread.sleep(forTimeInterval: 0.5)
                if app.isTerminated { return }
                guard let wins = AX.attr(ax, "AXWindows") as? [AXUIElement], let w = wins.first(where: { (AX.attr($0, "AXSubrole") as? String) != "AXDialog" }) ?? wins.first else { continue }
                var full: AnyObject?
                if AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &full) == .success {
                    if (full as? Bool) == true { log("\(name) : déjà en plein écran"); return }
                    var sz = CGSize.zero
                    if let v = AX.attr(w, "AXSize"), CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgSize, &sz), sz.width < 300 { continue }   // petite fenêtre de démarrage : on attend la vraie
                    Thread.sleep(forTimeInterval: 1.0)
                    let r = AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanTrue)
                    log("\(name) : passage en plein écran \(r == .success ? "demandé" : "refusé (\(r.rawValue))")"); return
                }
            }
        }
    }
    /// L'écran où les jeux s'ouvrent (et où le HUD s'affiche) : celui choisi dans Réglages → Écran des jeux, sinon l'écran principal (barre des menus)
    static func screenID(_ s: NSScreen) -> UInt32 { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    var gameScreen: NSScreen {
        let all = NSScreen.screens
        if let id = config.ecranJeu, let s = all.first(where: { Library.screenID($0) == id }) { return s }
        // Par défaut : l'écran externe (le moniteur de jeu) plutôt que l'écran intégré du Mac ; sinon l'écran principal de macOS
        return all.first(where: { CGDisplayIsBuiltin(Library.screenID($0)) == 0 }) ?? all.first(where: { Library.screenID($0) == CGMainDisplayID() }) ?? all.first ?? NSScreen.main!
    }
    func cycleGameScreen() {
        let all = NSScreen.screens; guard all.count > 1 else { toast = "Un seul écran branché"; return }
        let i = all.firstIndex(of: gameScreen) ?? 0; let n = all[(i + 1) % all.count]
        config.ecranJeu = Library.screenID(n); config.ecranJeuChoisi = true; saveConfig(); toast = "Les jeux s'ouvriront sur : \(n.localizedName)"; Sounds.shared.play("valider")
    }
    /// Les jeux nxnative démarrent en plein écran « Salon » : DM_FULLSCREEN=2 dans ~/Library/Application Support/nxnative/<id>/env.txt (lu avant celui de l'app)
    private func ensureFullscreen(_ tid: String) {
        let dir = appSupport.appendingPathComponent("nxnative/\(tid)"); let f = dir.appendingPathComponent("env.txt")
        var lines = ((try? String(contentsOf: f, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.hasPrefix("DM_FULLSCREEN=") && !$0.hasPrefix("DM_SCREEN=") && !$0.hasPrefix("DM_ROMFS_OVERLAY=") && !$0.hasPrefix("DM_SAVE=") && !$0.isEmpty }
        lines = lines.map { $0.hasPrefix("DM_COMPANION=") && $0.hasSuffix("/smoo-server.sh") ? "DM_COMPANION=" + Atelier.outils.appendingPathComponent("smoo-server.sh").path : $0 }   // le serveur a rejoint moteur/outils
        lines.append("DM_SAVE=" + Atelier.home.appendingPathComponent("sauvegardes/\(tid)").path)   // les sauvegardes restent dans Home, pas à côté des jeux
        if let o = Atelier.romfsOverlay(cle: tid) { lines.append("DM_ROMFS_OVERLAY=\(o)") }   // les mods RomFS activés (Mods, dans les options du jeu), lus avant le jeu
        lines.append("DM_FULLSCREEN=1")   // 1 = vrai plein écran macOS (sans coins arrondis ni bande en haut) ; le HUD du Salon passe par-dessus
        lines.append("DM_SCREEN=\(Library.screenID(gameScreen))")   // l'écran des jeux (le moteur déplace la fenêtre avant de l'afficher)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
    }
    private var direct: Process?   // le lanceur d'un jeu PC (pc.command lancer), tant qu'il tourne
    private func launchPC(_ g: Game) {
        guard let app = g.appPC else { running = nil; return }
        toast = app.hasPrefix("steam:") ? "Connexion à Steam…" : app.hasPrefix("exe:") ? "\(g.name) se prépare…" : "Connexion à Epic…"
        DispatchQueue.global().async { [weak self] in
            let appId = g.name.replacingOccurrences(of: "/", with: "-").unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }.map(String.init).joined()
            if let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.zagrios.obelisk.game.\(appId)" && !$0.isTerminated }) {   // déjà lancé : un anti-triche refuse une 2e instance
                DispatchQueue.main.async { a.activate(); self?.watchedApp = a; self?.toast = "\(g.name) tourne déjà — je le remets devant" }; return
            }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = app.hasPrefix("steam:") ? [Atelier.outils.appendingPathComponent("steam.command").path, "lancer", String(app.dropFirst(6))] : [Atelier.outils.appendingPathComponent("pc.command").path, "lancer", app]
            p.environment = ProcessInfo.processInfo.environment.merging(Dossiers.env, uniquingKeysWith: { $1 }); p.standardInput = FileHandle.nullDevice
            let logFile = Atelier.home.appendingPathComponent("log/pc-\(safeName(g.name)).log")
            FileManager.default.createFile(atPath: logFile.path, contents: nil); if let h = try? FileHandle(forWritingTo: logFile) { p.standardOutput = h; p.standardError = h }
            p.terminationHandler = { [weak self] proc in DispatchQueue.main.async {
                log("PC \(g.name) : terminé (code \(proc.terminationStatus))")
                if proc.terminationStatus != 0, let l = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").components(separatedBy: "\n").last(where: { $0.hasPrefix("ÉCHEC : ") }) { self?.toast = String(l.dropFirst(8).prefix(160)) }
                if self?.running?.id == g.id { self?.gameEnded(g, comeBack: true) } } }
            do { try p.run(); log("PC \(g.name) : lancé, pid \(p.processIdentifier) (journal \(logFile.path))"); DispatchQueue.main.async { self?.direct = p; self?.toast = "\(g.name) démarre" } }
            catch { log("PC \(g.name) : échec \(error)"); DispatchQueue.main.async { self?.toast = "Lancement impossible"; self?.running = nil; NotificationCenter.default.post(name: .salonShow, object: nil) } }
        }
    }
    // Menu rapide en jeu (Home, ou ⌥ Espace) : liste courte, navigation à la manette
    @Published var volume: Float = SystemVolume.get() ?? 0.5
    @Published var macVolume: Float = SystemVolume.get() ?? 0.5   // volume général (sortie du Mac), séparé du volume des jeux
    @Published var macMuted = false
    @Published var gameMuted = false
    @Published var flashGeneral = false                            // la barre de volume affichée concerne le général (sinon les jeux)
    private var macPrev: Float = 0.5, gamePrev: Float = 1
    /// barre: false = réglé depuis le curseur du haut de l'écran, qui montre déjà le niveau : la barre de volume ne s'affiche pas en plus
    func macStep(_ d: Float, quiet: Bool = false, barre: Bool = true) {
        let n = min(1, max(0, quiet ? macVolume + d : ((macVolume + d) * 20).rounded() / 20))
        SystemVolume.set(n); macVolume = n; macMuted = false; lastInput = Date(); if barre { flashGeneral = true; volumeFlash = Date() }
    }
    func toggleMacMute() {
        if macMuted { macMuted = false; SystemVolume.set(macPrev); macVolume = macPrev } else { macPrev = macVolume > 0 ? macVolume : 0.5; macMuted = true; SystemVolume.set(0); macVolume = 0 }
        flashGeneral = true; lastInput = Date(); volumeFlash = Date(); Sounds.shared.play(macMuted ? "retour" : "valider")
    }
    func toggleGameMute() {
        if gameMuted { gameMuted = false; writeVolume(gamePrev, save: false) } else { gamePrev = volume > 0 ? volume : (config.volume ?? 1); gameMuted = true; writeVolume(0, save: false) }
        Sounds.shared.play(gameMuted ? "retour" : "valider")
    }
    var gameVolumeFile: URL { appSupport.appendingPathComponent("nxnative/volume.txt") }
    @Published var volumeFlash: Date = .distantPast     // la barre de volume du Salon s'affiche 1,5 s après un réglage
    var volumeTarget: Game? { running ?? current }
    enum VolumeSource { case engine, bgm, mac }
    var volumeSource: VolumeSource { if let g = volumeTarget, g.titleID != nil, engineVolume(g) { return .engine }; return BGM.available ? .bgm : .mac }
    /// Le moteur du jeu lit-il ~/Library/Application Support/nxnative/volume.txt ? (patch 0070 de notre nxnative ; pas les forks comme kid-with-sword, ni MNG) — sinon Background Music
    private var engineVolCache: [String: Bool] = [:]
    func engineVolume(_ g: Game) -> Bool {
        if let v = engineVolCache[g.url.path] { return v }
        let needle = Data("nxnative/volume.txt".utf8); var ok = false
        for f in (try? FileManager.default.contentsOfDirectory(at: g.url.appendingPathComponent("Contents/MacOS"), includingPropertiesForKeys: nil)) ?? [] {
            if let d = try? Data(contentsOf: f, options: .alwaysMapped), d.range(of: needle) != nil { ok = true; break }
        }
        engineVolCache[g.url.path] = ok; log("\(g.name) : volume \(ok ? "par le moteur (volume.txt)" : "par Background Music")"); return ok
    }
    var bgmApplied: Set<pid_t> = []
    func savedVolume(_ g: Game) -> Float { config.volume ?? config.volumes?.values.first ?? 1.0 }   // volume général des jeux : le même pour toutes les apps
    /// Au lancement : le volume mémorisé du jeu est appliqué (moteur tout de suite ; Background Music dès que ses processus existent) et les sons du Salon le suivent
    func applySavedVolume(_ g: Game) { volume = savedVolume(g); Sounds.shared.gain = volume; writeVolume(volume, save: false) }
    var usesGameVolume: Bool { volumeSource != .mac }
    var volumeLabel: String { switch volumeSource { case .engine: return "Volume du jeu"; case .bgm: return "Volume du jeu (BGM)"; case .mac: return "Volume (Mac)" } }
    /// Les processus qui jouent le son du jeu en cours : l'app surveillée, le lanceur d'un jeu PC et ses processus (wine)
    func gamePids() -> [pid_t] {
        var p: [pid_t] = []
        if let a = watchedApp { p.append(a.processIdentifier) }
        if let g = running, !g.pc {   // les processus lancés par l'app (dmhost de nxnative, qui joue le son)
            let out = Commande.run("/usr/bin/pgrep", ["-f", g.url.path + "/Contents/"], timeout: 3)
            p += out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        }
        if let d = direct, d.isRunning { p.append(d.processIdentifier) }
        if let g = running, g.pc {
            let exe = g.name
            let out = Commande.run("/usr/bin/pgrep", ["-f", "\(exe)|obelisk-apps/.*\(g.name.prefix(6))"], timeout: 3)
            p += out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        }
        return Array(Set(p))
    }
    func readVolume() -> Float { config.volume ?? 1.0 }
    func writeVolume(_ v: Float, save: Bool = true) {
        let c = min(1, max(0, v))
        if save { config.volume = c; saveConfig() }
        switch volumeSource {
        case .engine: try? FileManager.default.createDirectory(at: gameVolumeFile.deletingLastPathComponent(), withIntermediateDirectories: true); try? String(Int((c * 100).rounded())).write(to: gameVolumeFile, atomically: true, encoding: .utf8)
        case .bgm: if running != nil { BGM.set(Int32((c * 50).rounded()), pids: cachedPids(), bundleID: watchedApp?.bundleIdentifier) }
        case .mac: if running != nil { SystemVolume.set(c) }
        }
        volume = c; Sounds.shared.gain = c; lastInput = Date(); volumeFlash = Date(); flashGeneral = false; if c > 0 { gameMuted = false }
    }
    var quickItems: [(String, String)] { [("Enregistrer : \(Recorder.duree)", Recorder.shared.active ? "record.circle" : "record.circle.fill"), ("Fermer le jeu", "xmark.circle"), ("Retour à Home", "house"),
                                          (volumeLabel, volume == 0 ? "speaker.slash" : volume < 0.5 ? "speaker.wave.1" : "speaker.wave.3"),
                                          ("Volume du Mac", macVolume == 0 ? "speaker.slash" : macVolume < 0.5 ? "speaker.wave.1" : "speaker.wave.3")]
                                          + (enLigne() != nil ? [("Joueurs", "person.2.fill")] : []) }
    /// Le jeu en cours joue-t-il en ligne : TOTK Online (serveur Kirbymimi, port 10014) ou un jeu nxnative avec le serveur Super Mario Odyssey: Online (port 1027)
    func enLigne() -> (nom: String, journal: URL, port: UInt16, smo: Bool)? {
        guard let g = running else { return nil }
        if Atelier.scriptDedie(g) == "totk-mng-online.command" { return ("TOTK Online", Atelier.home.appendingPathComponent(Atelier.totkLocal() ? "log/totk-server.log" : "log/totk-server-distant.log"), 10014, false) }
        if let tid = g.titleID, let c = Atelier.env(tid)["DM_COMPANION"], c.hasSuffix("smoo-server.sh") { return ("Super Mario Odyssey: Online", Atelier.home.appendingPathComponent("log/smoo-server.log"), 1027, true) }
        return nil
    }
    private var joueursCache: (URL?, Date?, [String]) = (nil, nil, [])
    private static var ecouteCache: [UInt16: (Bool, Date)] = [:]
    /// Un serveur écoute-t-il sur ce port : lsof, sans s'y connecter (une connexion de test chaque seconde apparaissait comme un joueur qui arrive et repart) ; gardé 5 s
    static func ecoute(_ port: UInt16) -> Bool {
        if let c = ecouteCache[port], Date().timeIntervalSince(c.1) < 5 { return c.0 }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof"); p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
        var r = false; if (try? p.run()) != nil { p.waitUntilExit(); r = !o.fileHandleForReading.readDataToEndOfFile().isEmpty }
        ecouteCache[port] = (r, Date()); return r
    }
    /// Les joueurs connectés : le journal du serveur rejoué depuis son démarrage (connexions et départs) ; nil si le serveur ne tourne pas
    /// Serveur TOTK distant (Azure) : son journal est relu par SSH toutes les 5 s, en arrière-plan, et copié dans log/totk-server-distant.log ;
    /// la clé est serveurs/totk-cle.pem. Faux si la machine ne répond pas ou si le service totk est arrêté (« Serveur arrêté »)
    private var distantDate = Date.distantPast, distantEnCours = false, distantOK = false
    func rafraichirJournalDistant(_ journal: URL) -> Bool {
        if !distantEnCours, Date().timeIntervalSince(distantDate) > 5 {
            distantEnCours = true
            let hote = String(Atelier.totkAdresse().split(separator: ":").first ?? "")
            let cle = Atelier.home.appendingPathComponent("serveurs/totk-cle.pem").path
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = ["-i", cle, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
                               "-o", "StrictHostKeyChecking=accept-new", "azureuser@" + hote, "systemctl is-active --quiet totk && sudo -n journalctl -u totk -o cat -n 5000 --no-pager"]
                let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                var ok = false
                if (try? p.run()) != nil {
                    let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                    ok = p.terminationStatus == 0
                    if ok { try? d.write(to: journal, options: .atomic) }
                }
                DispatchQueue.main.async { self?.distantOK = ok; self?.distantDate = Date(); self?.distantEnCours = false }
            }
        }
        return distantOK
    }
    func joueursConnectes() -> [String]? {
        guard let e = enLigne() else { return nil }
        if e.journal.lastPathComponent == "totk-server-distant.log" { guard rafraichirJournalDistant(e.journal) else { return nil } }
        else if !Self.ecoute(e.port) { return nil }
        let date = (try? FileManager.default.attributesOfItem(atPath: e.journal.path))?[.modificationDate] as? Date
        if joueursCache.0 == e.journal, joueursCache.1 == date { return joueursCache.2 }
        guard let h = try? FileHandle(forReadingFrom: e.journal) else { return [] }; defer { try? h.close() }
        let fin = (try? h.seekToEnd()) ?? 0; try? h.seek(toOffset: fin > 2_000_000 ? fin - 2_000_000 : 0)
        let texte = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        var noms: [String: String] = [:], ordre: [String] = [], adresses: [String: String] = [:]
        func ajoute(_ cle: String, _ nom: String) { if noms[cle] == nil { ordre.append(cle) }; noms[cle] = nom }
        func retire(_ cle: String) { noms[cle] = nil; ordre.removeAll { $0 == cle } }
        for ligne in texte.split(separator: "\n") {
            let l = String(ligne).trimmingCharacters(in: .whitespaces)
            if e.smo {
                if let m = l.firstMatch(of: #/Client (.+) \(([0-9A-Fa-f-]+)\/(.+)\) connected\.$/#) { ajoute(String(m.2), String(m.1)); adresses[String(m.3)] = String(m.2) }
                else if let m = l.firstMatch(of: #/Client .+ \(.*\/([0-9A-Fa-f-]+)\) disconnected from the server/#) { retire(String(m.1)) }
                else if let m = l.firstMatch(of: #/Client (\S+) disconnected from the server/#), let id = adresses[String(m.1)] { retire(id) }
                else if l.contains("Server] Listening") || l.contains("Server] Started") { noms = [:]; ordre = [] }
            } else {
                if let m = l.firstMatch(of: #/TOTKServer: (.+) connected$/#) { ajoute(String(m.1), String(m.1)) }
                else if let m = l.firstMatch(of: #/TOTKServer: (.+) left$/#) { retire(String(m.1)) }
                else if l.contains("TOTKServer: Initialized") { noms = [:]; ordre = [] }
            }
        }
        let r = ordre.compactMap { noms[$0] }; joueursCache = (e.journal, date, r); return r
    }
    private var pidCache: ([pid_t], Date) = ([], .distantPast)
    func cachedPids() -> [pid_t] { if Date().timeIntervalSince(pidCache.1) > 2 { pidCache = (gamePids(), Date()) }; return pidCache.0 }
    func volumeStep(_ d: Float, quiet: Bool = false) { let v = quiet ? volume + d : ((volume + d) * 20).rounded() / 20; writeVolume(v) }
    func toggleQuick() {
        guard running != nil else { return }
        quick.toggle(); lastInput = Date(); quickSlider = false; quickJoueurs = false
        if quick { overlay = true; quickIndex = 0; volume = readVolume(); NotificationCenter.default.post(name: .salonTakeInput, object: nil) }
        else { NotificationCenter.default.post(name: .salonGiveInput, object: nil) }
        Sounds.shared.play(quick ? "ouvrir" : "retour")
    }
    /// Ferme le menu rapide en rendant toujours la manette (saisie HID libérée) — sinon le Salon ne répondrait plus
    func closeQuick() { guard quick else { return }; quick = false; quickSlider = false; quickJoueurs = false; NotificationCenter.default.post(name: .salonGiveInput, object: nil) }
    func quickAct() {
        lastInput = Date()
        switch quickIndex {
        case 0:
            guard let g = running else { return }
            guard Recorder.shared.active else {   // la mémoire tampon ne tournait pas : rien de passé à sauver
                if CGPreflightScreenCaptureAccess() { Recorder.shared.start(); toast = "La capture vient de démarrer : le clip sera disponible dans \(Recorder.duree)" }
                else { toast = "Pas d'autorisation Enregistrement d'écran pour cette version de Home — signe Home avec le certificat « Salon Dev » puis réactive-le dans Réglages → Confidentialité" }
                Sounds.shared.play("retour"); return }
            Sounds.shared.play("valider"); toast = "Enregistrement du clip…"
            Recorder.shared.saveLast(seconds: Double(Recorder.secondes), game: g.name) { [weak self] url in DispatchQueue.main.async { self?.toast = url.map { "Clip enregistré : Vidéos/Salon/\($0.lastPathComponent)" } ?? "Clip impossible (voir salon.log)"; Sounds.shared.play(url == nil ? "retour" : "lancer") } }
            closeQuick()
        case 1:   // fermer le jeu : Home repasse devant d'abord, le jeu se ferme derrière lui (sinon macOS montrait le bureau entre les deux)
            Sounds.shared.play("valider"); closeQuick(); toast = "Fermeture du jeu…"
            let d = direct, app = watchedApp
            NotificationCenter.default.post(name: .salonShow, object: nil); NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { if let d, d.isRunning { d.terminate() } else { app?.terminate() } }
        case 2: closeQuick(); backToSalon(); NSApp.activate(ignoringOtherApps: true)
        case 5: quickJoueurs.toggle(); Sounds.shared.play(quickJoueurs ? "ouvrir" : "retour")
        default: quickSlider.toggle(); Sounds.shared.play(quickSlider ? "ouvrir" : "retour")
        }
    }
    /// Le Salon redevient actif alors qu'un jeu tourne : on reprend la main sans attendre la fin du jeu
    /// « Retour à Home » ne ferme pas le jeu : il reste ouvert derrière. Home garde de quoi le retrouver (son app, son processus), et dès
    /// qu'il repasse devant — par sa tuile, par ⌘Tab, par le Dock — la session reprend, avec le menu rapide et le volume (reprendre()).
    private var fond: (jeu: Game, app: NSRunningApplication?, direct: Process?)?
    func backToSalon() {
        guard let g = running else { return }
        let app = watchedApp, d = direct
        gameEnded(g, comeBack: false, garde: true)
        if app?.isTerminated == false || d?.isRunning == true { fond = (g, app, d); log("\(g.name) : laissé ouvert derrière Home") }
    }
    /// Le jeu surveillé vient de se fermer (signal immédiat de macOS, sans attendre la vérification de chaque seconde) : Home repasse
    /// devant aussitôt. Un jeu qui se relance lui-même (lanceur puis jeu) garde sa session : la vérification de chaque seconde s'en occupe.
    func appTerminee(_ a: NSRunningApplication) {
        guard let g = running, let w = watchedApp, w.processIdentifier == a.processIdentifier else { return }
        if let b = a.bundleIdentifier, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == b && $0.processIdentifier != a.processIdentifier && !$0.isTerminated }) { return }
        log("\(g.name) : fermé (signal de macOS)"); gameEnded(g, comeBack: true)
    }
    /// Le jeu laissé derrière est-il celui-ci ? (encore en vie)
    func enFond(_ g: Game) -> Bool { guard let f = fond, f.jeu.id == g.id else { return false }; return f.app?.isTerminated == false || f.direct?.isRunning == true }
    /// L'app qui vient de passer devant est-elle le jeu laissé derrière ? Alors la session reprend.
    func appActivee(_ a: NSRunningApplication) {
        guard running == nil, let f = fond else { return }
        let lui = f.app.map { $0.processIdentifier == a.processIdentifier || ($0.bundleIdentifier != nil && $0.bundleIdentifier == a.bundleIdentifier) } ?? false
        let direct = f.direct?.isRunning == true && (a.bundleIdentifier ?? "").hasPrefix("com.zagrios.obelisk.game.")
        if lui || direct { reprendre(app: a) }
    }
    func reprendre(app activee: NSRunningApplication? = nil) {
        guard running == nil, let f = fond else { return }
        fond = nil
        guard f.app?.isTerminated == false || f.direct?.isRunning == true else { return }
        let g = f.jeu, app = activee ?? f.app
        running = g; startedAt = Date(); overlay = true; lastInput = Date(); watchedApp = app; direct = f.direct; applySavedVolume(g)
        if config.capture ?? true, CGPreflightScreenCaptureAccess() { Recorder.shared.start() }
        NotificationCenter.default.post(name: .salonHide, object: nil)
        log("\(g.name) : session reprise (le jeu était resté ouvert)")
        if activee == nil { app?.activate() }
        // la fin du jeu : son app qui se ferme (un jeu lancé par un processus de Home a déjà son propre signal de fin)
        watch?.invalidate()
        if let app, f.direct == nil {
            watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.running?.id == g.id else { self?.watch?.invalidate(); return }
                if app.isTerminated { log("\(g.name) : processus terminé"); self.gameEnded(g, comeBack: true) }
            }
        }
    }
    private func gameEnded(_ g: Game, comeBack: Bool, garde: Bool = false) {
        log("Fin de session \(g.name) (retour auto : \(comeBack)\(garde ? ", jeu gardé ouvert" : ""))")
        if !garde, fond?.jeu.id == g.id { fond = nil }
        watch?.invalidate(); watch = nil
        var s = stats[g.id] ?? Stat(lastPlayed: nil, minutes: 0)
        s.lastPlayed = Date(); if let t = startedAt { s.minutes += Int(Date().timeIntervalSince(t) / 60) }
        stats[g.id] = s; saveStats(); closeQuick(); running = nil; startedAt = nil; overlay = false; watchedApp = nil; direct = nil; bgmApplied = []; Sounds.shared.play("ouvrir")
        if !garde { stopTotkServer() }   // le jeu gardé ouvert a encore besoin de son serveur
        Recorder.shared.stop()
        NotificationCenter.default.post(name: .salonShow, object: nil)
        if comeBack { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - Capture continue (ScreenCaptureKit) : segments de 5 s en mémoire tampon sur disque, les 4 derniers gardés ; « Enregistrer » assemble les 15 dernières secondes
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = Recorder()
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "salon.capture")
    private var writer: AVAssetWriter?; private var vIn: AVAssetWriterInput?; private var aIn: AVAssetWriterInput?
    private var segStart = CMTime.invalid; private var segURL: URL?
    private var segments: [URL] = []
    private let segLen = 5.0
    /// La durée du clip gardé, en secondes (Menu → Capture → Durée) : 15 par défaut
    static var secondes: Int { let n = UserDefaults.standard.integer(forKey: "captureSecondes"); return [15, 30, 60, 120].contains(n) ? n : 15 }
    /// Capture légère (720p, par défaut) : elle tourne pendant tout le jeu, autant qu'elle pèse le moins possible. Sinon 1080p.
    static var legere: Bool { UserDefaults.standard.object(forKey: "captureLegere") as? Bool ?? true }
    static var duree: String { secondes < 60 ? "\(secondes) s" : secondes == 60 ? "1 min" : "\(secondes / 60) min" }
    private var keep: Int { Int((Double(Recorder.secondes) / segLen).rounded(.up)) + 1 }   // un segment de plus : celui en cours n'est pas fini
    private var size = CGSize(width: 1920, height: 1080)
    private let tmp = salonRoot.appendingPathComponent("captures/tmp")
    var active: Bool { stream != nil }
    func start(ask: Bool = false) {
        guard stream == nil else { return }
        if !CGPreflightScreenCaptureAccess() { if ask { _ = CGRequestScreenCaptureAccess() }; log("Capture : autorisation Enregistrement d'écran absente, capture non démarrée"); return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return }
                let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])   // le HUD du Salon n'apparaît pas dans les clips
                let cfg = SCStreamConfiguration()
                let k = min(1.0, (Recorder.legere ? 1280.0 : 1920.0) / Double(display.width))
                cfg.width = Int(Double(display.width) * k) / 2 * 2; cfg.height = Int(Double(display.height) * k) / 2 * 2
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30); cfg.queueDepth = 6; cfg.showsCursor = false
                cfg.capturesAudio = true; cfg.excludesCurrentProcessAudio = true; cfg.sampleRate = 48000; cfg.channelCount = 2
                size = CGSize(width: cfg.width, height: cfg.height)
                try? FileManager.default.removeItem(at: tmp); try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try await s.startCapture()
                stream = s; log("Capture : démarrée \(cfg.width)×\(cfg.height), 30 i/s, audio système")
            } catch { log("Capture : impossible (\(error.localizedDescription)) — autorise Home dans Réglages → Confidentialité et sécurité → Enregistrement d'écran") }
        }
    }
    func stop() {
        guard let s = stream else { return }; stream = nil
        Task { try? await s.stopCapture() }
        queue.async { self.finishSegment(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.queue.async { for u in self.segments { try? FileManager.default.removeItem(at: u) }; self.segments = [] } } }
        log("Capture : arrêtée")
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { self.stream = nil; log("Capture : flux arrêté (\(error.localizedDescription))") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, CMSampleBufferDataIsReady(sb) else { return }
        if type == .screen {
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let st = atts.first?[.status] as? Int, st == SCFrameStatus.complete.rawValue else { return }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if type == .screen, writer == nil || CMTimeGetSeconds(CMTimeSubtract(pts, segStart)) >= segLen { finishSegment(); startSegment(at: pts) }
        guard let w = writer, w.status == .writing else { return }
        if type == .screen, let v = vIn, v.isReadyForMoreMediaData { v.append(sb) }
        else if type == .audio, let a = aIn, a.isReadyForMoreMediaData, CMTimeCompare(pts, segStart) >= 0 { a.append(sb) }
    }
    private func startSegment(at pts: CMTime) {
        let url = tmp.appendingPathComponent("seg-\(Int(Date().timeIntervalSince1970 * 1000)).mp4")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                                                                        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Recorder.legere ? 6_000_000 : 14_000_000, AVVideoMaxKeyFrameIntervalKey: 30, AVVideoExpectedSourceFrameRateKey: 30]])
        v.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
        a.expectsMediaDataInRealTime = true
        if w.canAdd(v) { w.add(v) }; if w.canAdd(a) { w.add(a) }
        guard w.startWriting() else { log("Capture : écriture impossible \(w.error?.localizedDescription ?? "")"); return }
        w.startSession(atSourceTime: pts)
        writer = w; vIn = v; aIn = a; segStart = pts; segURL = url
    }
    private func finishSegment() {
        guard let w = writer, let url = segURL else { return }
        writer = nil; segStart = .invalid; segURL = nil
        if vIn?.isReadyForMoreMediaData == true { vIn?.markAsFinished() }; if aIn?.isReadyForMoreMediaData == true { aIn?.markAsFinished() }
        vIn = nil; aIn = nil
        w.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                if w.status == .completed { self.segments.append(url); while self.segments.count > self.keep { try? FileManager.default.removeItem(at: self.segments.removeFirst()) } }
                else { try? FileManager.default.removeItem(at: url) }
            }
        }
    }
    /// Assemble les derniers segments et exporte les `seconds` dernières secondes dans ~/Movies/Salon
    func saveLast(seconds: Double, game: String, done: @escaping (URL?) -> Void) {
        queue.async {
            self.finishSegment()                                   // le segment en cours en fait partie
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.queue.async {
                    let segs = self.segments
                    guard !segs.isEmpty else { log("Capture : aucun segment"); done(nil); return }
                    let comp = AVMutableComposition()
                    guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { done(nil); return }
                    let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    var cursor = CMTime.zero
                    for u in segs {
                        let asset = AVURLAsset(url: u); let d = asset.duration
                        guard d.isValid, CMTimeGetSeconds(d) > 0.1, let sv = asset.tracks(withMediaType: .video).first else { continue }
                        try? vt.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: sv, at: cursor)
                        if let sa = asset.tracks(withMediaType: .audio).first { try? at?.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: sa, at: cursor) }
                        cursor = CMTimeAdd(cursor, d)
                    }
                    let total = CMTimeGetSeconds(cursor); guard total > 0.5 else { done(nil); return }
                    let start = max(0, total - seconds)
                    let outDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Salon")
                    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
                    let out = outDir.appendingPathComponent("\(safeName(game)) \(f.string(from: Date())).mp4")
                    guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { done(nil); return }
                    ex.outputURL = out; ex.outputFileType = .mp4; ex.shouldOptimizeForNetworkUse = true
                    ex.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: min(seconds, total), preferredTimescale: 600))
                    ex.exportAsynchronously {
                        if ex.status == .completed { log("Capture : clip \(Int(min(seconds, total))) s → \(out.path)"); done(out) }
                        else { log("Capture : export échoué \(ex.error?.localizedDescription ?? "")"); done(nil) }
                    }
                }
            }
        }
    }
}

// Volume de sortie du Mac (CoreAudio), pour le régler depuis le HUD sans quitter le jeu
enum SystemVolume {
    private static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }
    private static var volAddr: AudioObjectPropertyAddress { AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain) }
    static func get() -> Float? { guard let d = device() else { return nil }; var v = Float32(0); var size = UInt32(MemoryLayout<Float32>.size); var a = volAddr; return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr ? Float(v) : nil }
    static func set(_ v: Float) { guard let d = device() else { return }; var val = Float32(min(1, max(0, v))); var a = volAddr; AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &val) }
    static func step(_ delta: Float) -> Float? { guard let v = get() else { return nil }; let n = (((v + delta) * 20).rounded()) / 20; set(n); return min(1, max(0, n)) }
    static func nudge(_ delta: Float) -> Float? { guard let v = get() else { return nil }; let n = min(1, max(0, v + delta)); set(n); return n }
}

// Background Music (kyleneideck/BackgroundMusic) : volume par application, via la propriété CoreAudio 'apvs' de son périphérique virtuel
// BGMDevice — exactement ce que fait BGMApp (BGMBackgroundMusicDevice::SendAppVolumeOrPanToBGMDevice), sans AppleScript ni autorisation.
// Échelle BGM : 0…100, 50 = volume normal (au-delà : amplification). Le curseur du Salon va de 0 à 100 % = 0…50.
enum BGM {
    private static let appVolumes = AudioObjectPropertyAddress(mSelector: 0x61707673 /* 'apvs' */, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static func device(_ uid: String) -> AudioDeviceID? {
        var cf = uid as CFString; var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = withUnsafeMutablePointer(to: &cf) { p in AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &id) }
        return st == noErr && id != 0 ? id : nil
    }
    static var available: Bool { device("BGMDevice") != nil }
    /// Volume BGM (0…100) pour des processus : un dictionnaire par pid, comme BGMApp
    static func set(_ raw: Int32, pids: [pid_t], bundleID: String?) {
        guard !pids.isEmpty else { return }
        var changes: [[String: Any]] = pids.map { var d: [String: Any] = ["pid": Int32($0), "rvol": raw]; if let b = bundleID { d["bid"] = b }; return d }
        if let b = bundleID { changes.append(["pid": Int32(-1), "bid": b, "rvol": raw]) }
        var plist: CFPropertyList = changes as CFArray
        for uid in ["BGMDevice", "BGMDevice_UISounds"] {
            guard let d = device(uid) else { continue }
            var a = appVolumes
            let st = withUnsafeMutablePointer(to: &plist) { AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0) }
            if st != noErr { log("Background Music : écriture du volume refusée (\(st)) sur \(uid)") }
        }
    }
    static func get(pids: [pid_t], bundleID: String?) -> Int32? {
        guard let d = device("BGMDevice") else { return nil }
        var a = appVolumes; var size = UInt32(MemoryLayout<CFPropertyList>.size); var plist: CFPropertyList? = nil
        let st = withUnsafeMutablePointer(to: &plist) { AudioObjectGetPropertyData(d, &a, 0, nil, &size, $0) }
        guard st == noErr, let arr = plist as? [[String: Any]] else { return nil }
        for e in arr {
            let pid = (e["pid"] as? Int32) ?? -2; let bid = e["bid"] as? String
            if pids.contains(pid) || (bundleID != nil && bid == bundleID) { return e["rvol"] as? Int32 }
        }
        return nil
    }
}

// Connexion à Epic Games dans une fenêtre de Home : la page de connexion d'Epic (la vraie, chargée depuis son site) s'affiche dans
// une vue web ; une fois connecté, Epic renvoie une page qui contient le code de connexion, que Home lit tout seul — rien à copier.
// Home ne lit ni l'identifiant ni le mot de passe : seule cette dernière page est regardée.
/// La fenêtre de connexion à Steam : une petite page web dessinée par Home (pas une invite de macOS), avec le nom du compte et le mot
/// de passe, ou le code Steam Guard. Ce qui est tapé revient par un message de la page, jamais par une adresse, et n'est écrit nulle part.
final class FormulaireSteam: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    static var enCours: FormulaireSteam?
    private var fenetre: NSWindow?; private var fin: (([String]?) -> Void)?; private weak var web: WKWebView?
    /// code == nil : nom du compte et mot de passe (fin reçoit [nom, mot de passe]) ; sinon le texte qui demande le code (fin reçoit [code])
    static func ouvrir(code: String? = nil, _ fin: @escaping ([String]?) -> Void) {
        enCours?.terminer(nil)
        let c = FormulaireSteam(); c.fin = fin; enCours = c
        let conf = WKWebViewConfiguration(); conf.userContentController.add(c, name: "home")
        let h: CGFloat = code == nil ? 520 : 440
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: h), configuration: conf); c.web = web
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: h), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Connexion à Steam"; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.appearance = NSAppearance(named: .darkAqua); w.backgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1)
        w.identifier = NSUserInterfaceItemIdentifier("connexion"); w.contentView = web; w.isReleasedWhenClosed = false; w.delegate = c; w.level = .floating; w.center(); c.fenetre = w
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(web)
        let logo = (Bundle.main.resourceURL?.appendingPathComponent("logos/steam.png")).flatMap { try? Data(contentsOf: $0) }.map { "<img src='data:image/png;base64,\($0.base64EncodedString())'>" } ?? ""
        let texte = (code ?? "").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let champs = code == nil
            ? "<input id='a' name='username' autocomplete='username' placeholder='Nom du compte' autofocus><input id='b' name='password' type='password' autocomplete='current-password' placeholder='Mot de passe'>"
            : "<p>\(texte)</p><input id='a' name='code' autocomplete='one-time-code' placeholder='Code' autofocus style='text-align:center;letter-spacing:6px;text-transform:uppercase'>"
        web.loadHTMLString("""
        <html><head><meta charset='utf-8'><style>
        *{box-sizing:border-box;font-family:-apple-system,system-ui;-webkit-user-select:none}
        body{margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;color:#fff;padding:0 54px;
          background:radial-gradient(circle at 80% 0%,#1b4f9c 0%,transparent 55%),radial-gradient(circle at 0% 100%,#3a1d6e 0%,transparent 50%),#0a0d17}
        img{width:84px;height:84px;border-radius:50%;margin-bottom:6px}
        h1{margin:0 0 12px;font-size:22px;font-weight:900;letter-spacing:2px;font-stretch:expanded;text-transform:uppercase}
        p{margin:0 0 4px;text-align:center;opacity:.7;font-size:14px;line-height:1.4}
        input{width:100%;height:50px;border-radius:25px;border:1.5px solid rgba(255,255,255,.18);background:rgba(0,0,0,.45);color:#fff;font-size:16px;padding:0 22px;outline:none;-webkit-user-select:text}
        input:focus{border-color:#fff}
        button{width:100%;height:50px;border-radius:25px;border:0;background:#fff;color:#000;font-size:16px;font-weight:700;margin-top:8px}
        button:active{opacity:.8}
        a{font-size:13px;opacity:.65;cursor:default;text-decoration:underline}
        </style></head><body><form onsubmit="event.preventDefault();var v=[document.getElementById('a').value];var b=document.getElementById('b');if(b)v.push(b.value);if(v.every(function(x){return x.length>0}))webkit.messageHandlers.home.postMessage(['ok'].concat(v))" style='display:contents'>
        \(logo)<h1>Steam</h1>\(champs)<button type='submit'>\(code == nil ? "Se connecter" : "Valider")</button></form></body></html>
        """, baseURL: nil)
    }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let t = m.body as? [String], let quoi = t.first else { return }
        if quoi == "ok" { terminer(Array(t.dropFirst())) }
    }
    func windowWillClose(_ n: Notification) { terminer(nil) }
    private func terminer(_ v: [String]?) {
        guard let f = fin else { return }; fin = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "home")
        fenetre?.delegate = nil; fenetre?.close(); fenetre = nil; FormulaireSteam.enCours = nil
        f(v)
    }
}
final class ConnexionEpic: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static var enCours: ConnexionEpic?
    private var fenetre: NSWindow?; private var fin: ((String?) -> Void)?
    static func ouvrir(_ fin: @escaping (String?) -> Void) {
        enCours?.terminer(nil)
        let c = ConnexionEpic(); c.fin = fin; enCours = c
        // la page d'Epic telle quelle : si macOS propose ses mots de passe dans les pages des apps, il le fait ici tout seul
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 800)); web.navigationDelegate = c
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Connexion à Epic Games"; w.identifier = NSUserInterfaceItemIdentifier("connexion"); w.contentView = web; w.isReleasedWhenClosed = false; w.delegate = c
        w.level = .floating; w.center(); c.fenetre = w
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "https://legendary.gl/epiclogin")!))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.path.contains("/id/api/redirect") == true else { return }   // la page de fin : {"authorizationCode": "…"}
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] r, _ in
            guard let t = r as? String, let m = t.range(of: #""authorizationCode"\s*:\s*"[0-9a-fA-F]+""#, options: .regularExpression) else { return }
            let code = t[m].components(separatedBy: "\"").dropLast().last ?? ""
            if !code.isEmpty { self?.terminer(code) }
        }
    }
    func windowWillClose(_ n: Notification) { terminer(nil) }
    private func terminer(_ code: String?) {
        guard let f = fin else { return }; fin = nil
        fenetre?.delegate = nil; fenetre?.close(); fenetre = nil; ConnexionEpic.enCours = nil
        f(code)
    }
}

// Connexion à Steam par QR code : outils/steam.command connexion (home-steam, au-dessus du code Steam d'Obelisk) demande une session à
// Steam et donne une adresse, montrée ici en QR code ; on la scanne avec l'app Steam du téléphone, qui valide. Aucun mot de passe, aucun
// code à copier. Le jeton de session est gardé par l'outil dans le trousseau de macOS : Home ne le voit pas.
final class ConnexionSteam: NSObject, NSWindowDelegate {
    static var enCours: ConnexionSteam?
    private var fenetre: NSWindow?; private var image: NSImageView?; private var processus: Process?; private var fin: ((String?, String?) -> Void)?
    private var tampon = Data(); private var erreur: String?
    /// fin(compte, erreur) : le nom du compte connecté, ou nil avec la raison (nil aussi si la fenêtre a été fermée)
    static func ouvrir(_ fin: @escaping (String?, String?) -> Void) {
        enCours?.terminer(nil)
        let c = ConnexionSteam(); c.fin = fin; enCours = c
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Connexion à Steam"; w.identifier = NSUserInterfaceItemIdentifier("connexion"); w.isReleasedWhenClosed = false; w.delegate = c; w.level = .floating
        let vue = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 520))
        let img = NSImageView(frame: NSRect(x: 60, y: 170, width: 300, height: 300)); img.imageScaling = .scaleProportionallyUpOrDown; vue.addSubview(img); c.image = img
        let t = NSTextField(wrappingLabelWithString: "Ouvre l'app Steam sur ton téléphone, touche le bouclier (Steam Guard) en bas, puis « Scanner un QR code » et vise ce code. Valide ensuite la connexion sur le téléphone.")
        t.frame = NSRect(x: 30, y: 30, width: 360, height: 120); t.alignment = .center; t.font = .systemFont(ofSize: 14); vue.addSubview(t)
        w.contentView = vue; w.center(); c.fenetre = w
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [Atelier.outils.appendingPathComponent("steam.command").path, "connexion"]
        p.environment = ProcessInfo.processInfo.environment.merging(Dossiers.env, uniquingKeysWith: { $1 }); p.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { DispatchQueue.main.async { c.recu(d) } } }
        p.terminationHandler = { _ in DispatchQueue.main.async { pipe.fileHandleForReading.readabilityHandler = nil; if c.fin != nil { c.terminer(nil) } } }
        c.processus = p
        if (try? p.run()) == nil { c.erreur = "L'outil Steam ne démarre pas"; c.terminer(nil) }
    }
    private func recu(_ d: Data) {
        tampon.append(d)
        while let r = tampon.firstIndex(of: 0x0a) {
            let ligne = String(decoding: tampon[tampon.startIndex..<r], as: UTF8.self); tampon.removeSubrange(tampon.startIndex...r)
            if ligne.hasPrefix("ÉCHEC : ") { erreur = String(ligne.dropFirst(8)); continue }
            guard let j = (try? JSONSerialization.jsonObject(with: Data(ligne.utf8))) as? [String: Any] else { continue }
            if j["ev"] as? String == "qr", let u = j["url"] as? String { image?.image = ConnexionSteam.qr(u) }
            if j["ev"] as? String == "connecte" { terminer(j["compte"] as? String ?? "") }
            if j["absent"] != nil { erreur = "L'outil Steam n'est pas encore préparé" }
        }
    }
    /// Le QR code d'une adresse, net à n'importe quelle taille
    static func qr(_ texte: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(texte.utf8), forKey: "inputMessage"); f.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci); let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }
    func windowWillClose(_ n: Notification) { terminer(nil) }
    private func terminer(_ compte: String?) {
        guard let f = fin else { return }; fin = nil
        if let p = processus, p.isRunning { p.terminate() }
        fenetre?.delegate = nil; fenetre?.close(); fenetre = nil; ConnexionSteam.enCours = nil
        f(compte, compte == nil ? erreur : nil)
    }
}

// Jeux PC installés par Home lui-même (Epic Games, sans Obelisk) : moteur/pc/pc.py fait le travail, lancé par outils/pc.command
enum PCHome {
    struct Jeu { let app: String; let nom: String; let dossier: String }
    /// Les jeux installés : <Home>/pc/jeux.json, écrit par pc.py après un téléchargement ; ceux dont le dossier a disparu sont ignorés
    static func jeux() -> [Jeu] {
        guard let d = try? Data(contentsOf: Atelier.home.appendingPathComponent("pc/jeux.json")), let l = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return l.compactMap { j in
            guard let a = j["app"] as? String, let n = j["nom"] as? String, let dos = j["dossier"] as? String, FileManager.default.fileExists(atPath: dos) else { return nil }
            return Jeu(app: a, nom: n.replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "").trimmingCharacters(in: .whitespaces), dossier: dos) }
    }
    /// Les jeux Steam installés par Home : les reçus de home-steam (<Home>/pc/steam/steam-installations-<compte>.json), lus tels quels
    static func jeuxSteam() -> [Jeu] {
        let d = Atelier.home.appendingPathComponent("pc/steam")
        let fichiers = ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("steam-installations-") && $0.pathExtension == "json" }
        var vus = Set<Int>(); var out: [Jeu] = []
        for f in fichiers {
            guard let data = try? Data(contentsOf: f), let l = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for j in l {
                guard let a = j["appId"] as? Int, let n = j["name"] as? String, let dos = j["directory"] as? String, (j["platform"] as? String)?.lowercased() == "windows",
                      FileManager.default.fileExists(atPath: dos), vus.insert(a).inserted else { continue }
                out.append(Jeu(app: "steam:\(a)", nom: n.replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "").trimmingCharacters(in: .whitespaces), dossier: dos))
            }
        }
        return out
    }
    /// pc.command <arguments> : sa sortie (la dernière ligne JSON pour etat et bibliotheque)
    static func run(_ args: [String], timeout: TimeInterval = 40) -> String {
        setenv("HOME_RACINE", Dossiers.home.path, 1); setenv("HOME_JEUX", Dossiers.jeux.path, 1)   // Commande.run reprend l'environnement de Home
        return Commande.run("/bin/bash", [Atelier.outils.appendingPathComponent("pc.command").path] + args, timeout: timeout)
    }
    static func json(_ sortie: String) -> Any? {
        guard let l = sortie.split(separator: "\n").last(where: { $0.hasPrefix("{") || $0.hasPrefix("[") }), let d = String(l).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
    static func echec(_ sortie: String) -> String? { sortie.split(separator: "\n").last(where: { $0.hasPrefix("ÉCHEC : ") }).map { String($0.dropFirst(8)) } }
    /// steam.command <arguments> (home-steam) : sa sortie
    static func steam(_ args: [String], timeout: TimeInterval = 40) -> String {
        setenv("HOME_RACINE", Dossiers.home.path, 1); setenv("HOME_JEUX", Dossiers.jeux.path, 1)
        return Commande.run("/bin/bash", [Atelier.outils.appendingPathComponent("steam.command").path] + args, timeout: timeout)
    }
    static var steamPret: Bool { FileManager.default.isExecutableFile(atPath: Atelier.moteur.appendingPathComponent("bin/home-steam").path) }
}

// Compatibilité des jeux PC : moteur/compat/pc.json, une liste vérifiée avec ses sources. « bloque » = l'éditeur ou l'anti-triche du jeu
// refuse Linux et Mac : Home ne l'installe pas et ne le lance pas. Un jeu absent de la liste n'est jamais bloqué, et un anti-triche ne
// suffit pas à bloquer : Rocket League (Easy Anti-Cheat) fonctionne, la liste le dit « verifie ».
enum Compat {
    struct Jeu { let nom: String; let epic: String?; let espace: String?; let steam: String?; let etat: String; let raison: String?; let preuve: String? }
    static let jeux: [Jeu] = {
        let ici = [Atelier.moteur.appendingPathComponent("compat/pc.json"), Bundle.main.resourceURL?.appendingPathComponent("moteur/compat/pc.json")].compactMap { $0 }
        for u in ici {
            guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let l = o["jeux"] as? [[String: Any]] else { continue }
            return l.compactMap { j in
                guard let n = j["nom"] as? String, let e = j["etat"] as? String else { return nil }
                return Jeu(nom: n, epic: j["epic"] as? String, espace: j["epic_namespace"] as? String, steam: (j["steam"] as? Int).map(String.init) ?? (j["steam"] as? String), etat: e, raison: j["raison"] as? String, preuve: j["preuve"] as? String) }
        }
        return []
    }()
    static func norme(_ s: String) -> String {
        s.replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// L'entrée d'un jeu : par identifiant de boutique d'abord, sinon par nom exact (jamais par ressemblance : un doute ne bloque pas)
    static func entree(epic: String? = nil, steam: String? = nil, nom: String) -> Jeu? {
        if let e = epic?.lowercased(), !e.isEmpty, let j = jeux.first(where: { $0.epic?.lowercased() == e }) { return j }
        if let s = steam, !s.isEmpty, let j = jeux.first(where: { $0.steam == s }) { return j }
        let n = norme(nom); return n.isEmpty ? nil : jeux.first { norme($0.nom) == n }
    }
    static func entree(_ g: Game) -> Jeu? {
        if let a = g.appPC { return a.hasPrefix("steam:") ? entree(steam: String(a.dropFirst(6)), nom: g.name) : entree(epic: a, nom: g.name) }
        return nil
    }
    static func bloque(_ g: Game) -> Jeu? { entree(g).flatMap { $0.etat == "bloque" ? $0 : nil } }
}

// Lancer une commande et lire ce qu'elle écrit
enum Commande {
    static var gardes: [Process] = []   // des processus suivis par leurs seuls tubes (connexion Steam) : gardés en vie jusqu'à leur fin
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 40) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        var env = ProcessInfo.processInfo.environment; env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin"; p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "erreur: \(error)" }
        var data = Data(); let q = DispatchQueue(label: "legendary-read")
        let group = DispatchGroup(); group.enter()
        q.async { data = pipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return "délai dépassé" }
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// Accessibilité : parcours en largeur de l'arbre d'une app, limité pour rester rapide
enum AX {
    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil }
    static func texts(_ e: AXUIElement) -> [String] { ["AXTitle", "AXDescription", "AXHelp", "AXValue"].compactMap { attr(e, $0) as? String } }
    static func press(_ e: AXUIElement) { AXUIElementPerformAction(e, "AXPress" as CFString) }
    static func find(_ root: AXUIElement, role: String, containing: String? = nil, equals: [String]? = nil, limit: Int = 6000) -> AXUIElement? {
        var queue = [root]; var seen = 0
        let needle = containing?.lowercased()
        while !queue.isEmpty, seen < limit {
            let e = queue.removeFirst(); seen += 1
            if (attr(e, "AXRole") as? String) == role {
                let t = texts(e)
                if let n = needle, t.contains(where: { $0.lowercased().contains(n) }) { return e }
                if let eq = equals, t.contains(where: { s in eq.contains(where: { $0.caseInsensitiveCompare(s.trimmingCharacters(in: .whitespaces)) == .orderedSame }) }) { return e }
            }
            if let kids = attr(e, "AXChildren") as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return nil
    }
}

// MARK: - Vues
struct LoopingVideo: NSViewRepresentable {
    let url: URL
    final class Coord { var looper: AVPlayerLooper? }
    func makeCoordinator() -> Coord { Coord() }
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView(); v.controlsStyle = .none; v.videoGravity = .resizeAspectFill
        let q = AVQueuePlayer(); q.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: url)); v.player = q; q.play(); return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
}
/// Le fond de la case + : des halos de couleur qui dérivent lentement, et quelques symboles (Switch, PC, mods) qui flottent
struct AddBackground: View {
    private static let symbols: [(String, Double, Double, Double)] = [("gamecontroller.fill", 0.16, 0.30, 0.0), ("desktopcomputer", 0.82, 0.24, 1.7), ("puzzlepiece.extension.fill", 0.70, 0.62, 3.1),
                                                                      ("leaf.fill", 0.30, 0.66, 4.4), ("plus.circle.fill", 0.50, 0.18, 2.3), ("arrow.down.circle.fill", 0.90, 0.55, 5.2)]
    private func blob(_ c: Color, _ t: Double, _ ph: Double, _ v: Double, _ size: CGSize) -> some View {
        let w = size.width, h = size.height
        return Circle().fill(RadialGradient(colors: [c.opacity(0.55), c.opacity(0)], center: .center, startRadius: 0, endRadius: w * 0.33))
            .frame(width: w * 0.66, height: w * 0.66)
            .position(x: w * (0.5 + 0.36 * cos(t * v + ph)), y: h * (0.45 + 0.32 * sin(t * v * 1.3 + ph * 1.7)))
            .blendMode(.plusLighter)
    }
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.17), Color(red: 0.01, green: 0.01, blue: 0.05)], startPoint: .top, endPoint: .bottom)
                    blob(Color(red: 0.95, green: 0.25, blue: 0.35), t, 0.0, 0.11, geo.size)
                    blob(Color(red: 0.25, green: 0.45, blue: 1.0), t, 2.1, 0.08, geo.size)
                    blob(Color(red: 0.2, green: 0.85, blue: 0.55), t, 4.2, 0.095, geo.size)
                    blob(Color(red: 0.62, green: 0.32, blue: 0.95), t, 1.3, 0.07, geo.size)
                    ForEach(0..<AddBackground.symbols.count, id: \.self) { k in
                        let s = AddBackground.symbols[k]
                        Image(systemName: s.0).font(.system(size: 90 + 30 * CGFloat(k % 3), weight: .semibold)).foregroundStyle(.white.opacity(0.07))
                            .rotationEffect(.degrees(8 * sin(t * 0.3 + s.3)))
                            .position(x: geo.size.width * s.1 + 30 * cos(t * 0.21 + s.3), y: geo.size.height * s.2 + 24 * sin(t * 0.27 + s.3))
                    }
                }
            }
        }.ignoresSafeArea()
    }
}
struct Background: View {
    let image: NSImage?; let video: URL?; let blurred: Bool
    @State private var zoom: CGFloat = 1.0
    var body: some View {
        Color.black.overlay {
            if let v = video { LoopingVideo(url: v) }
            else if let i = image {
                Image(nsImage: i).interpolation(.high).resizable().scaledToFill().blur(radius: blurred ? 70 : 0).saturation(blurred ? 1.3 : 1.0).scaleEffect(blurred ? 1.3 : zoom)
                    .onAppear { zoom = 1.0; if !blurred { withAnimation(.linear(duration: 30).repeatForever(autoreverses: true)) { zoom = 1.05 } } }
            }
        }
        .overlay(LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom))
        .clipped().ignoresSafeArea()
    }
}
/// Le mouvement de Home quand on se déplace (pastilles, tuiles de l'accueil) : court, net, sans rebond
/// « Animations réduites » (Avancé → Animations) : les mouvements de l'interface deviennent un fondu très court
var animationsReduites: Bool { UserDefaults.standard.bool(forKey: "animationsReduites") }
var glisse: Animation { animationsReduites ? .easeOut(duration: 0.10) : .timingCurve(0.2, 0.75, 0.2, 1, duration: 0.24) }
/// Le mouvement de la bibliothèque : plus ample, doux au départ comme à l'arrivée
var coule: Animation { animationsReduites ? .easeOut(duration: 0.12) : .timingCurve(0.32, 0.0, 0.16, 1, duration: 0.42) }
struct Tile: View {
    let image: NSImage; let selected: Bool; var isIcon = false
    static let cote: CGFloat = 180, zoom: CGFloat = 1.34
    var body: some View {
        Color.black.overlay {
            if isIcon { ZStack { LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)], startPoint: .top, endPoint: .bottom); Image(nsImage: image).resizable().scaledToFit().padding(28) } }
            else { Image(nsImage: image).resizable().interpolation(.high).scaledToFill() }
        }
        .frame(width: Tile.cote, height: Tile.cote).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(selected ? 1 : 0), lineWidth: 3))
        .shadow(color: .black.opacity(selected ? 0.55 : 0.3), radius: selected ? 16 : 8, y: selected ? 10 : 5)
        .brightness(selected ? 0 : -0.12)
        // la taille de dessin ne change jamais (redessiner l'image à chaque étape saccadait) : la tuile est agrandie d'un bloc, par le bas
        .scaleEffect(selected ? Tile.zoom : 1, anchor: .bottom)
        .padding(.horizontal, selected ? Tile.cote * (Tile.zoom - 1) / 2 : 0)
        .animation(coule, value: selected)
    }
}
/// Une rangée de jeux : celle d'une catégorie. Seule la rangée en cours a un jeu visé et suit ce jeu en défilant.
struct RangeeJeux: View {
    @ObservedObject var lib: Library
    let categorie: Int
    var body: some View {
        let jeux = lib.jeux(categorie: categorie), active = categorie == lib.categoryIndex
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 22) {
                    ForEach(Array(jeux.enumerated()), id: \.element.id) { i, game in
                        Tile(image: lib.cover(game), selected: active && i == lib.selected)
                            .overlay { if let t = lib.tache, !t.fini, t.jeux.contains(game.id) { EnMiseAJour(fraction: t.fraction, grand: active && i == lib.selected) } }
                            .overlay(alignment: .bottomTrailing) { if lib.loading.contains(game.id) { ProgressView().controlSize(.small).tint(.white).padding(10) } }
                            .id(game.id).onTapGesture { guard active else { return }; if lib.selected == i { lib.launch() } else { lib.selected = i } }
                    }
                    AddTile(selected: active && lib.selected >= jeux.count).id("salon-plus")
                        .onTapGesture { guard active else { return }; if lib.selected >= jeux.count { lib.openAddMenu() } else { lib.selected = jeux.count; Sounds.shared.play("deplacer") } }
                }
                .padding(.horizontal, 84).padding(.bottom, 24).padding(.top, 90)   // la place de la tuile agrandie, qui dépasse vers le haut
            }.scrollClipDisabled().scrollDisabled(!active)
             .onChange(of: lib.selected) { _, _ in guard active else { return }; withAnimation(coule) { if jeux.indices.contains(lib.selected) { proxy.scrollTo(jeux[lib.selected].id, anchor: .center) } else { proxy.scrollTo("salon-plus", anchor: .center) } } }
        }
    }
}
struct Hint: View {
    let k: Key; let t: String
    init(k: Key, t: String) { self.k = k; self.t = t }
    init(b: String, t: String) { self.k = Key(text: b); self.t = t }
    var body: some View {
        HStack(spacing: 8) {
            if let sym = k.symbol { Image(systemName: sym).font(.system(size: 22, weight: .medium)) }
            else { Text(k.text).font(.system(size: 12, weight: .bold)).padding(.horizontal, 7).frame(minWidth: 24, minHeight: 24).overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 1.5)) }
            Text(t)
        }.font(.system(size: 16, weight: .medium, design: .rounded)).opacity(0.8)
    }
}

// MARK: - Ouverture : au lancement de l'app, le logo de Home au centre sur fond noir, avec le jingle (« lancer »), puis un fondu vers
// la grille des jeux. Environ 1,9 s en tout, courbes douces ; n'importe quelle touche la passe (AppDelegate.nav), un clic aussi.
// L'écran de démarrage est animé par Core Animation, pas par SwiftUI : ses animations tournent dans le serveur de rendu de macOS, à part.
// Au démarrage le fil principal est occupé (la bibliothèque se construit, les images arrivent) et une animation SwiftUI saccadait ;
// celles-ci ne dépendent plus de lui. Les lueurs sont des dégradés, pas un flou recalculé à chaque image.
final class OuvertureCouches: NSView {
    private let bloc = CALayer(); private var monte = false
    private static let douce = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = CGColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1) }
    required init?(coder: NSCoder) { fatalError() }
    /// Une animation d'une propriété, qui part après `delai` et laisse la couche sur sa valeur d'arrivée
    private func anime(_ l: CALayer, _ cle: String, de: Any, a: Any, duree: Double, delai: Double = 0, courbe: CAMediaTimingFunction = OuvertureCouches.douce) {
        let an = CABasicAnimation(keyPath: cle); an.fromValue = de; an.toValue = a; an.duration = duree; an.timingFunction = courbe
        an.beginTime = CACurrentMediaTime() + delai; an.fillMode = .backwards
        l.setValue(a, forKeyPath: cle); l.add(an, forKey: cle)
    }
    private func cg(_ c: Color, _ alpha: CGFloat = 1) -> CGColor { (NSColor(c).usingColorSpace(.sRGB) ?? .white).withAlphaComponent(alpha).cgColor }
    override func layout() {
        super.layout()
        guard !monte, bounds.width > 100, let fond = layer else { return }; monte = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let w = bounds.width, h = bounds.height, centre = CGPoint(x: w / 2, y: h / 2 + 60)   // y vers le haut : le bloc est un peu au-dessus du milieu
        // trois lueurs aux couleurs des cartes : des dégradés ronds qui s'allument en s'écartant
        for (couleur, taille, dx, dy) in [(Library.violet[0], w * 0.9, -w * 0.04, h * 0.12), (Library.bleu[1], w * 0.72, w * 0.22, -h * 0.10), (Library.orange[1], w * 0.64, -w * 0.24, -h * 0.14)] {
            let g = CAGradientLayer(); g.type = .radial; g.colors = [cg(couleur, 0.42), cg(couleur, 0.16), cg(couleur, 0)]; g.locations = [0, 0.45, 1]
            g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1)
            g.bounds = CGRect(x: 0, y: 0, width: taille, height: taille); fond.addSublayer(g)
            anime(g, "position", de: NSValue(point: CGPoint(x: w / 2, y: h / 2)), a: NSValue(point: CGPoint(x: w / 2 + dx, y: h / 2 + dy)), duree: 1.2, courbe: CAMediaTimingFunction(name: .easeOut))
            anime(g, "opacity", de: 0, a: 1, duree: 1.2, courbe: CAMediaTimingFunction(name: .easeOut))
        }
        // les deux anneaux qui partent du centre
        for (de, a, alpha, trait) in [(0.7, 3.4, 0.5, 2.0), (0.5, 2.4, 0.35, 1.5)] {
            let o = CAShapeLayer(); o.path = CGPath(ellipseIn: CGRect(x: -150, y: -150, width: 300, height: 300), transform: nil)
            o.fillColor = nil; o.strokeColor = CGColor(gray: 1, alpha: alpha); o.lineWidth = trait; o.position = centre; fond.addSublayer(o)
            anime(o, "transform.scale", de: de, a: a, duree: 1.3, delai: 0.8, courbe: CAMediaTimingFunction(name: .easeOut))
            anime(o, "opacity", de: 1, a: 0, duree: 1.3, delai: 0.8, courbe: CAMediaTimingFunction(name: .easeOut))
            let avant = CABasicAnimation(keyPath: "opacity"); avant.fromValue = 0; avant.toValue = 0; avant.duration = 0.8; o.add(avant, forKey: "avant")   // invisible jusqu'à son départ
        }
        // le bloc : les trois cartes, la manette, le nom ; il avance très lentement du début à la fin, pour que rien ne se fige
        bloc.bounds = CGRect(x: 0, y: 0, width: w, height: h); bloc.position = CGPoint(x: w / 2, y: h / 2); fond.addSublayer(bloc)
        anime(bloc, "transform.scale", de: 1, a: 1.06, duree: 3.4, courbe: CAMediaTimingFunction(name: .linear))
        let pile = CALayer(); pile.bounds = CGRect(x: 0, y: 0, width: 400, height: 320); pile.position = centre; bloc.addSublayer(pile)
        func carte(_ c: [Color]) -> CAGradientLayer {
            let g = CAGradientLayer(); g.colors = [cg(c[0]), cg(c[1])]; g.startPoint = CGPoint(x: 0, y: 1); g.endPoint = CGPoint(x: 1, y: 0)
            g.bounds = CGRect(x: 0, y: 0, width: 190, height: 262); g.cornerRadius = 34; g.cornerCurve = .continuous; g.position = CGPoint(x: 200, y: 160); pile.addSublayer(g); return g
        }
        for (c, signe) in [(Library.orange, -1.0), (Library.bleu, 1.0)] {        // les deux cartes de derrière sortent en éventail
            let g = carte(c)
            let fin = CATransform3DRotate(CATransform3DMakeTranslation(signe * 92, -14, 0), -signe * 15 * .pi / 180, 0, 0, 1)
            anime(g, "transform", de: NSValue(caTransform3D: CATransform3DIdentity), a: NSValue(caTransform3D: fin), duree: 0.6, delai: 0.5)
        }
        let devant = carte(Library.violet); devant.borderWidth = 2; devant.borderColor = CGColor(gray: 1, alpha: 0.35)
        devant.shadowColor = .black; devant.shadowOpacity = 0.5; devant.shadowRadius = 30; devant.shadowOffset = CGSize(width: 0, height: -16)
        if let img = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 84, weight: .medium).applying(.init(paletteColors: [.white]))) {
            let m = CALayer(); m.contents = img; m.contentsGravity = .resizeAspect; m.bounds = CGRect(x: 0, y: 0, width: 130, height: 100); m.position = CGPoint(x: 95, y: 131); devant.addSublayer(m)
            anime(m, "transform.scale", de: 0.5, a: 1, duree: 0.45, delai: 0.8); anime(m, "opacity", de: 0, a: 1, duree: 0.45, delai: 0.8)
        }
        anime(pile, "transform.scale", de: 0.72, a: 1, duree: 0.7, delai: 0.1); anime(pile, "opacity", de: 0, a: 1, duree: 0.7, delai: 0.1)
        let nom = CATextLayer(); nom.contentsScale = window?.backingScaleFactor ?? 2; nom.alignmentMode = .center
        nom.string = NSAttributedString(string: "HOME", attributes: [.font: NSFont.systemFont(ofSize: 54, weight: .black, width: .expanded), .foregroundColor: NSColor.white, .kern: 14])
        nom.bounds = CGRect(x: 0, y: 0, width: 700, height: 72); nom.position = CGPoint(x: centre.x + 7, y: centre.y - 131 - 54 - 36); bloc.addSublayer(nom)
        anime(nom, "transform.scale.x", de: 1.5, a: 1, duree: 0.7, delai: 1.0); anime(nom, "opacity", de: 0, a: 1, duree: 0.7, delai: 1.0)   // les lettres se resserrent
        CATransaction.commit()
    }
    /// La sortie : le bloc grossit et s'efface, puis le fond laisse voir la bibliothèque
    func partir() {
        guard monte, let fond = layer, fond.animation(forKey: "sortie") == nil else { return }
        let ici = (bloc.presentation()?.value(forKeyPath: "transform.scale") as? Double) ?? 1.06
        bloc.removeAnimation(forKey: "transform.scale")
        let g = CABasicAnimation(keyPath: "transform.scale"); g.fromValue = ici; g.toValue = ici * 1.12; g.duration = 0.6; g.timingFunction = CAMediaTimingFunction(name: .easeIn); bloc.setValue(ici * 1.12, forKeyPath: "transform.scale"); bloc.add(g, forKey: "sortie")
        let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = 1; o.toValue = 0; o.duration = 0.6; o.timingFunction = CAMediaTimingFunction(name: .easeIn); bloc.opacity = 0; bloc.add(o, forKey: "fondu")
        let f = CABasicAnimation(keyPath: "opacity"); f.fromValue = 1; f.toValue = 0; f.duration = 0.9; f.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); fond.opacity = 0; fond.add(f, forKey: "sortie")
    }
}
struct OuvertureCA: NSViewRepresentable {
    let part: Bool
    func makeNSView(context: Context) -> OuvertureCouches { OuvertureCouches(frame: .zero) }
    func updateNSView(_ v: OuvertureCouches, context: Context) { if part { v.partir() } }
}
/// L'accueil du premier lancement. Il ne ressemble pas aux menus : l'ambiance de l'écran de démarrage, trois grandes cartes, un seul
/// grand bouton. On comprend qu'il faut choisir ; « Ignorer » est petit, dans un coin.
struct BienvenueView: View {
    @ObservedObject var lib: Library
    var apercu = false
    @State private var paru = false
    private let cartes: [(titre: String, ligne: String, symbole: String, teinte: [Color])] = [
        ("Tout", "Jeux Nintendo et jeux PC", "sparkles", Library.violet),
        ("Nintendo", "Switch et Switch 2", "logo:switch", Library.orange),
        ("PC", "Epic Games, Steam, Windows", "logo:windows", Library.bleu)]
    var body: some View {
        let la = paru || apercu
        ZStack {
            Color(red: 0.02, green: 0.02, blue: 0.05)
            GeometryReader { g in   // les lueurs de l'écran de démarrage, celle de la carte visée plus forte
                let w = g.size.width, h = g.size.height
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let c = cartes[i].teinte[i == 0 ? 0 : 1]
                        Circle().fill(RadialGradient(colors: [c.opacity(i == lib.bienvenueIndex ? 0.55 : 0.22), c.opacity(0)], center: .center, startRadius: 0, endRadius: w * 0.34))
                            .frame(width: w * 0.68, height: w * 0.68).position(x: w * (0.5 + CGFloat(i - 1) * 0.27), y: h * (i == 0 ? 0.40 : 0.62))
                    }
                }.animation(.easeInOut(duration: 0.5), value: lib.bienvenueIndex)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text("BIENVENUE").font(.system(size: 84, weight: .black).width(.expanded)).tracking(la ? 6 : 30)
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.78)], startPoint: .top, endPoint: .bottom)).opacity(la ? 1 : 0)
                Text("À quoi vas-tu jouer ? Home installe ce qu'il faut.").font(.system(size: 24, weight: .medium)).opacity(la ? 0.72 : 0).padding(.top, 14)
                HStack(spacing: 34) {
                    ForEach(0..<3, id: \.self) { i in
                        let c = cartes[i], sel = i == lib.bienvenueIndex
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Symbole(nom: c.symbole, taille: c.symbole.hasPrefix("logo:") ? 96 : 104, clair: true).foregroundStyle(.white).frame(height: 170).shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                            Spacer(minLength: 0)
                            Text(c.titre.uppercased()).font(.system(size: 30, weight: .black).width(.expanded)).tracking(1)
                            Text(c.ligne).font(.system(size: 17, weight: .medium)).opacity(0.85).padding(.top, 8)
                            Text("Recommandé").font(.system(size: 13, weight: .bold)).padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(.black.opacity(0.28))).padding(.top, 14).opacity(i == 0 ? 1 : 0)
                        }
                        .padding(.vertical, 30).frame(width: 330, height: 420).foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(LinearGradient(colors: c.teinte, startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(.white.opacity(sel ? 0.95 : 0.14), lineWidth: sel ? 4 : 1.5))
                        .shadow(color: c.teinte[1].opacity(sel ? 0.7 : 0), radius: 46, y: 18)
                        .saturation(sel ? 1 : 0.55).brightness(sel ? 0 : -0.22).scaleEffect(sel ? 1.07 : 0.94)
                        .animation(coule, value: lib.bienvenueIndex)
                        .offset(y: la ? 0 : 60).opacity(la ? 1 : 0).animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6).delay(0.25 + Double(i) * 0.09), value: paru)
                        .contentShape(Rectangle()).onTapGesture { if sel { lib.bienvenueValider() } else { lib.bienvenueIndex = i; Sounds.shared.play("deplacer") } }
                    }
                }.padding(.top, 54)
                HStack(spacing: 12) {
                    if let sym = lib.hints.ok.symbol { Image(systemName: sym.replacingOccurrences(of: ".circle", with: ".circle.fill")).font(.system(size: 26)) }
                    Text("Commencer").font(.system(size: 24, weight: .bold))
                }
                .foregroundStyle(.black).padding(.horizontal, 54).frame(height: 68).background(Capsule().fill(.white)).shadow(color: .white.opacity(0.25), radius: 24)
                .padding(.top, 56).opacity(la ? 1 : 0).animation(.easeOut(duration: 0.5).delay(0.7), value: paru)
                .onTapGesture { lib.bienvenueValider() }
                Spacer(minLength: 0)
            }.foregroundStyle(.white).animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.8), value: paru)
            // « Ignorer » : là pour qui le cherche, pas pour qui hésite
            HStack(spacing: 6) { if let sym = lib.hints.options.symbol { Image(systemName: sym).font(.system(size: 12)) }; Text("Ignorer").font(.system(size: 13, weight: .medium)) }
                .foregroundStyle(.white).opacity(0.26).padding(.trailing, 44).padding(.bottom, 30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .contentShape(Rectangle()).onTapGesture { lib.bienvenueIgnorer() }
        }
        .ignoresSafeArea().onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { paru = true } }
    }
}
/// L'écran de démarrage : les couches ci-dessus, un appui pour le passer, et la sortie au bout de 2,15 s
struct OuvertureView: View {
    @ObservedObject var lib: Library
    var body: some View {
        OuvertureCA(part: lib.ouverturePart).ignoresSafeArea().contentShape(Rectangle())
            .onTapGesture { lib.passerOuverture() }
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 2.15) { lib.passerOuverture() } }
    }
}
/// La même image, figée, dessinée par SwiftUI : pour l'aperçu (HOME_APERCU), qui ne sait pas rendre des couches animées
struct OuvertureApercu: View {
    @ObservedObject var lib: Library
    var fige = false
    @State private var lueurs = false    // le fond s'allume
    @State private var carte = false     // la carte centrale arrive
    @State private var eventail = false  // les deux autres sortent de derrière elle
    @State private var manette = false   // la manette se pose
    @State private var nom = false       // HOME apparaît
    @State private var onde = false      // les anneaux partent
    @State private var derive = false    // tout avance très lentement, du début à la fin : rien ne se fige avant le fondu
    private func carteDe(_ c: [Color]) -> some View { RoundedRectangle(cornerRadius: 34, style: .continuous).fill(LinearGradient(colors: c, startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 190, height: 262) }
    var body: some View {
        let l = lueurs || fige, ca = carte || fige, ev = eventail || fige, ma = manette || fige, no = nom || fige, part = lib.ouverturePart
        ZStack {
            Color(red: 0.02, green: 0.02, blue: 0.05)
            // trois lueurs, aux couleurs des cartes
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    Circle().fill(Library.violet[0]).frame(width: w * 0.46).offset(x: l ? -w * 0.04 : 0, y: l ? -h * 0.12 : 0)
                    Circle().fill(Library.bleu[1]).frame(width: w * 0.36).offset(x: l ? w * 0.22 : 0, y: l ? h * 0.10 : 0)
                    Circle().fill(Library.orange[1]).frame(width: w * 0.32).offset(x: l ? -w * 0.24 : 0, y: l ? h * 0.14 : 0)
                }.frame(width: w, height: h).blur(radius: 170).opacity(l ? 0.50 : 0)
            }
            // les anneaux qui partent du centre
            ZStack {
                Circle().stroke(.white.opacity(onde || fige ? (fige ? 0.10 : 0) : 0.5), lineWidth: 2).frame(width: 300, height: 300).scaleEffect(onde ? 3.4 : (fige ? 1.9 : 0.7))
                Circle().stroke(.white.opacity(onde || fige ? (fige ? 0.06 : 0) : 0.35), lineWidth: 1.5).frame(width: 300, height: 300).scaleEffect(onde ? 2.4 : (fige ? 2.6 : 0.5))
            }.offset(y: -60)
            VStack(spacing: 54) {
                ZStack {
                    carteDe(Library.orange).rotationEffect(.degrees(ev ? -15 : 0)).offset(x: ev ? -92 : 0, y: ev ? 14 : 0).opacity(ca ? 1 : 0)
                    carteDe(Library.bleu).rotationEffect(.degrees(ev ? 15 : 0)).offset(x: ev ? 92 : 0, y: ev ? 14 : 0).opacity(ca ? 1 : 0)
                    carteDe(Library.violet).overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 2))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                        .overlay(Image(systemName: "gamecontroller.fill").font(.system(size: 84, weight: .medium)).foregroundStyle(.white).scaleEffect(ma ? 1 : 0.5).opacity(ma ? 1 : 0))
                }
                .scaleEffect(ca ? 1 : 0.72).opacity(ca ? 1 : 0)
                Text("HOME").font(.system(size: 54, weight: .black).width(.expanded)).tracking(no ? 14 : 44).foregroundStyle(.white).opacity(no ? 1 : 0).padding(.leading, no ? 14 : 44)
            }
            .scaleEffect(derive ? 1.06 : 1)
            .scaleEffect(part ? 1.12 : 1).opacity(part ? 0 : 1).animation(.easeIn(duration: 0.6), value: part)
        }
        .opacity(part ? 0 : 1).animation(.easeInOut(duration: 0.9), value: part)   // le fond s'efface pendant que la bibliothèque apparaît
        .ignoresSafeArea().contentShape(Rectangle())
        .onTapGesture { lib.passerOuverture() }
        .onAppear {
            guard !fige else { return }
            let douce = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7)
            withAnimation(.easeOut(duration: 1.2)) { lueurs = true }
            withAnimation(.linear(duration: 3.4)) { derive = true }
            withAnimation(douce.delay(0.10)) { carte = true }
            withAnimation(Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6).delay(0.50)) { eventail = true }
            withAnimation(Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45).delay(0.80)) { manette = true }
            withAnimation(.easeOut(duration: 1.3).delay(0.80)) { onde = true }
            withAnimation(Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7).delay(1.00)) { nom = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.15) { lib.passerOuverture() }
        }
    }
}

/// Le symbole d'un choix : un symbole système, ou le logo d'un service (« logo:epic », « logo:steam » : les images de app/logos)
struct Symbole: View {
    let nom: String; let taille: CGFloat
    var clair = false   // le logo de Windows en blanc, pour une carte de couleur
    static var logos: [String: NSImage] = [:]
    /// Le disque derrière un logo : le rouge de la Switch, sombre pour les autres
    static func fond(_ nom: String) -> Color { nom == "logo:switch" ? Color(red: 0.90, green: 0.0, blue: 0.07) : nom == "logo:steam" ? Color(red: 0.03, green: 0.08, blue: 0.20) : Color(white: 0.12) }
    static func logo(_ n: String) -> NSImage? {
        if let i = logos[n] { return i }
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("logos/\(n).png"), let i = NSImage(contentsOf: u) else { return nil }
        logos[n] = i; return i
    }
    var body: some View {
        if nom == "logo:windows" {
            let c = taille * 0.56, e = taille * 0.07, bleu = clair ? Color.white : Color(red: 0.0, green: 0.55, blue: 0.95)
            VStack(spacing: e) { HStack(spacing: e) { bleu.frame(width: c, height: c); bleu.frame(width: c, height: c) }; HStack(spacing: e) { bleu.frame(width: c, height: c); bleu.frame(width: c, height: c) } }
        }
        else if nom.hasPrefix("logo:"), let i = Symbole.logo(String(nom.dropFirst(5))) { Image(nsImage: i).resizable().interpolation(.high).scaledToFit().frame(width: taille * 1.5, height: taille * 1.5) }
        else { Image(systemName: nom.hasPrefix("logo:") ? "person.crop.circle.fill" : nom).font(.system(size: taille, weight: .medium)) }
    }
}
// Les menus, dans le style de Home : monochromes (la couleur vient du jeu derrière), presque sans texte.
//  - Un menu court (7 choix au plus, tous actionnables) est une RANGÉE de pastilles rondes en bas à gauche, à la manière de la PS5 :
//    seul le choix visé a son nom, et sa précision s'il en a une. Gauche / droite pour choisir.
//  - Un menu long (bibliothèque, mods, réglages) est une LISTE nue à gauche : du texte, un fond clair discret sous la ligne visée,
//    dont la précision est la seule affichée. Les mods avec aperçu gardent leur grille.
struct Pilule: View {
    let k: Key; let t: String
    var body: some View { Hint(k: k, t: t).font(.system(size: 17, weight: .semibold, design: .rounded)).padding(.horizontal, 18).padding(.vertical, 11).background(.black.opacity(0.45), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1)) }
}
struct MenuView: View {
    @ObservedObject var lib: Library; let menu: SalonMenu
    var apercu: Int? = nil   // pour l'aperçu en image : le choix visé, sans attendre onAppear
    @State private var index = 0
    @State private var pop = false
    @State private var paru = false   // les choix arrivent en cascade à l'ouverture du menu
    @State private var sens: CGFloat = 1   // d'où le menu arrive : de la droite quand on avance, de la gauche quand on revient
    @State private var fond = false        // son fond sombre : en fondu depuis la bibliothèque, immédiat d'un menu à l'autre
    static var vu = Date.distantPast       // la dernière fois qu'un menu était à l'écran
    static var dernier: [String: Int] = [:]   // le dernier choix visé de chaque menu : on le retrouve en y revenant
    private var vise: Int { apercu ?? index }
    private func press() { pop = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pop = false } }
    /// Le choix suivant dans un sens, en sautant les lignes d'information
    private func next(_ from: Int, _ d: Int) -> Int {
        var n = from + d
        while menu.items.indices.contains(n) { if !menu.items[n].info { return n }; n += d }
        return from
    }
    private static let rouge = Color(red: 1, green: 0.45, blue: 0.42)
    /// Un menu court (les options d'un jeu) est une rangée de pastilles ; tous les autres sont une grille de tuiles
    private var rangee: Bool { !menu.grid && !menu.roue && menu.step == nil && menu.items.count <= 7 && !menu.items.isEmpty && menu.items.allSatisfy { !$0.info && $0.image == nil } }
    private func choisir(_ i: Int) { guard menu.items.indices.contains(i), !menu.items[i].info else { return }; index = i; Sounds.shared.play("valider"); press(); menu.items[i].action() }
    /// Le nom d'un choix sans son état : « Construction silencieuse : activée » → (« Construction silencieuse », « Activée »)
    private func nomEtat(_ it: SalonMenuItem) -> (String, String?) {
        let m = it.label.components(separatedBy: " : "); return (m[0], m.count > 1 ? m.dropFirst().joined(separator: " : ").prefix(1).uppercased() + m.dropFirst().joined(separator: " : ").dropFirst() : nil)
    }
    /// Le titre de section du choix (celui de la dernière ligne qui en porte un, en remontant)
    private func section(_ i: Int) -> String? {
        var n = i
        while n >= 0 { if let t = menu.items[n].section?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }; n -= 1 }
        return nil
    }
    private static let colsAffiches = 5
    /// Une affiche de la grille des mods : l'aperçu la remplit, le nom vient par-dessus ; un choix sans aperçu montre son symbole
    @ViewBuilder private func affiche(_ i: Int, _ it: SalonMenuItem) -> some View {
        let sel = i == vise && !it.info
        Color.white.opacity(0.07).aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let u = it.image {
                    AsyncImage(url: u) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else if phase.error != nil { Image(systemName: it.icon).font(.system(size: 34)).opacity(0.5) } else { ProgressView().controlSize(.small).tint(.white) }
                    }
                } else { Image(systemName: it.icon).font(.system(size: 44, weight: .medium)).opacity(0.85).offset(y: -12) }
            }
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .bottomLeading) {
                    if it.image != nil { LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .center, endPoint: .bottom) }
                    Text(it.label).font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(2).padding(14)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(sel ? 1 : 0.08), lineWidth: sel ? 4 : 1))
            .foregroundStyle(it.destructive ? MenuView.rouge : .white)
            .shadow(color: .black.opacity(sel ? 0.6 : 0), radius: 20, y: 10)
            .scaleEffect(sel ? 1.04 : 1).brightness(sel ? 0 : -0.10).animation(.easeOut(duration: 0.14), value: index)
            .contentShape(Rectangle()).onTapGesture { choisir(i) }
    }
    @ViewBuilder private var affiches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: MenuView.colsAffiches), spacing: 20) {
            ForEach(Array(menu.items.enumerated()), id: \.offset) { i, it in affiche(i, it).id(i) }
        }.padding(.vertical, 22)
    }
    /// Le fil d'Ariane des menus : le nom du menu en capitales grasses, puis ce qu'on donne en plus (la section du choix visé)
    @ViewBuilder private func fil(_ suite: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let st = menu.step, let n = menu.steps, n > 0 { HStack(spacing: 8) { ForEach(1...n, id: \.self) { k in Capsule().fill(.white.opacity(k == st ? 0.95 : 0.25)).frame(width: k == st ? 34 : 10, height: 10) } } }
            HStack(spacing: 12) {
                Text(menu.title.uppercased()).font(.system(size: 38, weight: .black).width(.expanded)).tracking(1)
                if let suite { Text(suite.uppercased()).font(.system(size: 19, weight: .black).width(.expanded)).tracking(1.5).opacity(0.55).lineLimit(1).padding(.leading, 8).padding(.top, 12).id(suite).transition(.opacity) }
            }
        }
    }
    /// La roue : le choix visé en grand, les autres de plus en plus petits et effacés autour ; tout glisse quand on bouge
    @ViewBuilder private var roue: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(menu.items.enumerated()), id: \.offset) { i, it in
                let d = i - vise, e = abs(d)
                if e <= 6 {
                    let sel = d == 0 && !it.info
                    let y: CGFloat = d == 0 ? 0 : CGFloat(d > 0 ? 1 : -1) * (74 + CGFloat(e - 1) * 50)
                    HStack(spacing: 16) {
                        Text(nomEtat(it).0).font(.system(size: 50, weight: .bold).width(.expanded)).tracking(-0.5).lineLimit(1).fixedSize()
                        if it.icon == "checkmark.seal.fill" { Image(systemName: "checkmark.seal.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(.white).frame(width: 46, height: 46).background(Circle().fill(Color(red: 0.13, green: 0.72, blue: 0.36))) }
                        if sel, let etat = nomEtat(it).1 { Text(etat).font(.system(size: 22, weight: .heavy, design: .rounded)).padding(.horizontal, 14).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.18))).transition(.opacity) }
                    }
                    .foregroundStyle(it.destructive ? MenuView.rouge : .white)
                    .scaleEffect(d == 0 ? 1 : e == 1 ? 0.56 : 0.46, anchor: .leading)
                    .opacity(d == 0 ? 1 : it.info ? 0.22 : e == 1 ? 0.62 : e == 2 ? 0.40 : e == 3 ? 0.24 : 0.12)
                    .offset(y: y)
                    .contentShape(Rectangle()).onTapGesture { if d == 0 { choisir(i) } else if !it.info { index = i; Sounds.shared.play("deplacer") } }
                }
            }
        }
        .frame(maxWidth: 900, maxHeight: .infinity, alignment: .leading)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22), value: index)
        .offset(x: paru || apercu != nil ? 0 : 46 * sens).opacity(paru || apercu != nil ? 1 : 0)
        .animation(.timingCurve(0.2, 0.75, 0.2, 1, duration: 0.36), value: paru)
    }
    /// À droite : le choix visé en image — son aperçu s'il en a un (mods), sinon son symbole en très grand — et sa précision
    /// Le disque d'un choix : un logo de service tel quel sur un disque sombre ; un symbole, en blanc sur la couleur du choix
    private func disque(_ it: SalonMenuItem, _ c: Color) -> some View {
        Symbole(nom: it.icon, taille: it.icon.hasPrefix("logo:") ? 130 : 150).foregroundStyle(.white)
            .frame(width: 320, height: 320).background(Circle().fill(it.icon.hasPrefix("logo:") ? AnyShapeStyle(Symbole.fond(it.icon)) : AnyShapeStyle(LinearGradient(colors: [c, c.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))))
            .shadow(color: c.opacity(0.6), radius: 60, y: 10)
    }
    @ViewBuilder private var apercuChoix: some View {
        if menu.items.indices.contains(vise) {
            let it = menu.items[vise]; let c = menuTint(it.icon, tint: it.tint, destructive: it.destructive)
            VStack(spacing: 34) {
                if let u = it.image {
                    AsyncImage(url: u) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1.5))
                                .shadow(color: .black.opacity(0.6), radius: 34, y: 18).shadow(color: c.opacity(0.35), radius: 60)
                        } else if phase.error != nil { disque(it, c) }
                        else { ProgressView().tint(.white).frame(width: 320, height: 320) }
                    }.frame(width: 600, height: 500)
                } else { disque(it, c) }
                Text(it.detail ?? menu.text ?? " ").font(.system(size: 23, weight: .medium)).multilineTextAlignment(.center).opacity(0.8).lineLimit(3).frame(width: 600, height: 96, alignment: .top)
                    .offset(y: it.image == nil ? 112 : 0)   // sous les anneaux qui entourent le disque, pas dessus
            }
            .id(vise).transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94)), removal: .opacity))
            .animation(.easeOut(duration: 0.18), value: index)
        }
    }
    /// L'en-tête commun : l'étape d'un assistant, le sous-titre en petites capitales, le titre fin
    @ViewBuilder private var entete: some View {
        if let st = menu.step, let n = menu.steps, n > 0 {
            HStack(spacing: 8) { ForEach(1...n, id: \.self) { k in Capsule().fill(.white.opacity(k == st ? 0.95 : 0.25)).frame(width: k == st ? 34 : 10, height: 10) } }.padding(.bottom, 16)
        }
        if menu.art != nil, let g = lib.current, g.name == menu.title, let l = lib.art[g.id]?.logo {
            Image(nsImage: l).resizable().scaledToFit().frame(maxWidth: 480, maxHeight: 150, alignment: .leading).shadow(radius: 12)
        } else {
            if let st = menu.subtitle { Text(st.uppercased()).font(.system(size: 15, weight: .heavy, design: .rounded)).tracking(2).opacity(0.6).lineLimit(1) }
            Text(menu.title.uppercased()).font(.system(size: rangee ? 44 : 40, weight: .black).width(.expanded)).tracking(1).lineLimit(1).minimumScaleFactor(0.6).padding(.top, 4)
        }
    }
    private var aides: some View {
        HStack(spacing: 12) { Pilule(k: lib.hints.ok, t: "Choisir"); if menu.rafraichir != nil { Pilule(k: lib.hints.tri, t: "Actualiser") }; Pilule(k: lib.hints.back, t: menu.back == nil ? "Fermer" : "Retour") }
    }
    var body: some View {
        ZStack(alignment: rangee ? .bottomLeading : .topLeading) {
            // l'ombre qui porte le texte : en bas pour la rangée ; la grille assombrit tout l'écran
            if rangee { LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.88)], startPoint: .init(x: 0.5, y: 0.25), endPoint: .bottom) }
            else if menu.grid { Color.black.opacity(0.72) }
            else { LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.74), .black.opacity(0.50)], startPoint: .leading, endPoint: .trailing) }
            if rangee {
                VStack(alignment: .leading, spacing: 0) {
                    entete
                    HStack(spacing: 14) {
                        ForEach(Array(menu.items.enumerated()), id: \.offset) { i, it in
                            let sel = i == vise
                            let c = menuTint(it.icon, tint: it.tint, destructive: it.destructive)
                            let logo = it.icon.hasPrefix("logo:")
                            Symbole(nom: it.icon, taille: logo ? (sel ? 38 : 30) : (sel ? 32 : 26)).fontWeight(.semibold).frame(width: sel ? 96 : 76, height: sel ? 96 : 76)
                                .background(Circle().fill(logo ? AnyShapeStyle(Symbole.fond(it.icon)) : sel ? AnyShapeStyle(LinearGradient(colors: [c, c.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(.black.opacity(0.5))))
                                .saturation(logo && !sel ? 0.7 : 1).brightness(logo && !sel ? -0.12 : 0)
                                .overlay(Circle().strokeBorder(sel ? .white.opacity(0.9) : c.opacity(0.45), lineWidth: sel ? 3 : 1.5))
                                .foregroundStyle(sel ? .white : c)
                                .shadow(color: c.opacity(sel ? 0.75 : 0), radius: 26, y: 6)
                                .animation(glisse, value: index)
                                .offset(y: paru || apercu != nil ? 0 : 26).opacity(paru || apercu != nil ? 1 : 0)
                                .animation(.timingCurve(0.2, 0.75, 0.2, 1, duration: 0.38).delay(Double(i) * 0.045), value: paru)
                                .contentShape(Circle()).onTapGesture { choisir(i) }
                                .onHover { dedans in if dedans, index != i { index = i } }
                        }
                    }.padding(.top, 34)
                    // le nom du choix visé, et sa précision : la seule ligne de texte du menu
                    if menu.items.indices.contains(vise) {
                        let it = menu.items[vise]
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) { Circle().fill(menuTint(it.icon, tint: it.tint, destructive: it.destructive)).frame(width: 10, height: 10); Text(it.label).font(.system(size: 27, weight: .semibold)).lineLimit(1) }
                            Text(it.detail ?? menu.text ?? " ").font(.system(size: 17)).opacity(0.62).lineLimit(2).frame(maxWidth: 900, alignment: .leading)
                        }.padding(.top, 20).padding(.leading, 6).id(vise).transition(.opacity).frame(height: 92, alignment: .topLeading)
                    }
                    aides.padding(.top, 14)
                }.padding(.leading, 96).padding(.bottom, 44)
            } else if menu.grid {
                // les mods : le titre et la grille partagent la même marge, la grille va jusqu'à l'autre bord
                VStack(alignment: .leading, spacing: 0) {
                    fil(menu.items.indices.contains(vise) ? menu.items[vise].detail : nil)
                    if apercu != nil { affiches; Spacer(minLength: 0) }
                    else {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) { affiches }.scrollClipDisabled()
                                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04), .init(color: .black, location: 0.95), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom).padding(.horizontal, -40))
                                .onChange(of: index) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) } }
                        }
                    }
                    aides.padding(.top, 14)
                }.padding(.horizontal, 96).padding(.top, 70).padding(.bottom, 44)
            } else {
                fil(section(vise)).padding(.leading, 96).padding(.top, 70)
                // une lueur de la couleur du choix visé, derrière son symbole : le menu change de teinte en bougeant
                if menu.items.indices.contains(vise) {
                    Circle().fill(menuTint(menu.items[vise].icon, tint: menu.items[vise].tint, destructive: menu.items[vise].destructive)).frame(width: 760, height: 760).blur(radius: 190).opacity(0.38)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 20).animation(.easeInOut(duration: 0.45), value: index).allowsHitTesting(false)
                }
                // le repère : où on en est dans le menu
                HStack(spacing: 18) {
                    ZStack(alignment: .top) {
                        Capsule().fill(.white.opacity(0.14)).frame(width: 4, height: 300)
                        Capsule().fill(.white).frame(width: 4, height: max(26, 300 / CGFloat(max(1, menu.items.count))))
                            .offset(y: (300 - max(26, 300 / CGFloat(max(1, menu.items.count)))) * CGFloat(vise) / CGFloat(max(1, menu.items.count - 1)))
                            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22), value: index)
                    }
                    roue
                }.padding(.leading, 60)
                HStack(spacing: 18) {
                    Text(Date(), format: .dateTime.hour().minute()).font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.trailing, 96).padding(.top, 66)
                // un trait fin sous le haut de l'écran, qui s'efface vers la droite
                LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)], startPoint: .leading, endPoint: .trailing).frame(height: 1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.horizontal, 96).padding(.top, 148)
                // deux anneaux autour du symbole, comme une cible
                ZStack {
                    Circle().stroke(.white.opacity(0.10), lineWidth: 1.5).frame(width: 440, height: 440)
                    Circle().stroke(.white.opacity(0.05), lineWidth: 1.5).frame(width: 580, height: 580)
                    Circle().trim(from: 0, to: CGFloat(vise + 1) / CGFloat(max(1, menu.items.count))).stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 440, height: 440).rotationEffect(.degrees(-90))
                        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: index)
                }.offset(y: -65).frame(width: 600).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 150).allowsHitTesting(false)
                apercuChoix.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 150)
                aides.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, 96).padding(.bottom, 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.white)
        .background(Color.black.opacity(fond || apercu != nil ? (rangee ? 0 : 0.55) : 0).animation(.easeOut(duration: 0.25), value: fond))
        .ignoresSafeArea()
        .scaleEffect(pop ? 0.995 : 1.0).animation(.spring(response: 0.18, dampingFraction: 0.7), value: pop)
        .transition(.asymmetric(insertion: .identity, removal: .opacity))   // le nouveau menu est là tout de suite, l'ancien s'efface dessous : la bibliothèque ne réapparaît pas entre les deux
        .onDisappear { MenuView.vu = Date() }
        .onAppear {
            sens = lib.sensMenu
            if Date().timeIntervalSince(MenuView.vu) < 0.4 { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { fond = true } } else { fond = true }
            let f = next(-1, 1); index = f < 0 ? 0 : f
            if !menu.grid, let d = MenuView.dernier[menu.title], menu.items.indices.contains(d), !menu.items[d].info { index = d }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { paru = true }
        }
        .onChange(of: index) { _, n in MenuView.dernier[menu.title] = n }
        .onReceive(NotificationCenter.default.publisher(for: .salonNav)) { n in
            guard let k = n.object as? String else { return }
            if k == "tri" { if let r = menu.rafraichir { Sounds.shared.play("valider"); r() }; return }   // triangle : relire la liste
            var cible = index
            if rangee { cible = (k == "right" || k == "down") ? next(index, 1) : (k == "left" || k == "up") ? next(index, -1) : index }   // la rangée : de gauche à droite
            else if menu.grid {   // la grille d'affiches : quatre directions
                let c = MenuView.colsAffiches, total = menu.items.count
                func libre(_ n: Int) -> Bool { menu.items.indices.contains(n) && !menu.items[n].info }
                switch k {
                case "right": cible = next(index, 1)
                case "left": cible = next(index, -1)
                case "down":
                    // la même colonne, un rang plus bas (en sautant les cases d'information) ; sur le dernier rang incomplet, la dernière affiche
                    var n = index + c
                    while n < total, !libre(n) { n += c }
                    if n >= total, index / c < (total - 1) / c { n = total - 1; while n > index, !libre(n) { n -= 1 } }
                    if libre(n), n != index { cible = n }
                case "up":
                    var n = index - c
                    while n >= 0, !libre(n) { n -= c }
                    if libre(n) { cible = n }
                default: break
                }
            }
            else { cible = k == "down" ? next(index, 1) : k == "up" ? next(index, -1) : index }   // la roue : de haut en bas
            if cible != index { index = cible; Sounds.shared.play("deplacer") }
            else if k == "ok", menu.items.indices.contains(index), !menu.items[index].info { Sounds.shared.play("valider"); press(); menu.items[index].action() }
        }
    }
}
/// L'avancement d'une construction entière (pas étape par étape) : nxnative en JSON (--progress json : étape k/n, fraction de
/// l'étape), MacNativeGames « 1/4 code: … ». Les étapes ne pèsent pas pareil (les shaders et les pipelines prennent l'essentiel du
/// temps) : chacune a un poids, celles pas encore commencées sont estimées. Un résumé court de l'étape en cours.
final class Avancement {
    private var faites: [String] = []; private var nom = ""; private var k = 0; private var n = 0; private var frac = 0.0
    private static let standard = ["rewrite", "shader split", "mac shaders", "mac host", "pipeline", "mac app"]
    private static func poids(_ s: String) -> Double {
        let l = s.lowercased()
        for (cle, p) in [("mac shaders", 38.0), ("pipeline", 26), ("shader split", 8), ("unpack", 7), ("extract", 7), ("mac app", 6), ("rewrite", 5), ("mac host", 4), ("nx_extract", 2)] where l.contains(cle) { return p }
        return 3
    }
    static func resume(_ s: String) -> String {
        let l = s.lowercased()
        let table: [(String, String)] = [("mac shaders", "Shaders Metal"), ("shader split", "Préparation des shaders"), ("pipeline", "Pipelines"), ("mac app", "Assemblage de l'app"),
            ("mac host", "Moteur du jeu"), ("rewrite", "Réécriture du code"), ("nx_extract", "Outils"), ("dlc", "Contenus additionnels"), ("unpack", "Lecture du jeu"), ("extract", "Lecture du jeu"),
            ("heap", "Vérification"), ("region", "Vérification"), ("capture", "Capture des shaders")]
        for (cle, f) in table where l.contains(cle) { return f }
        let court = s.components(separatedBy: " (").first ?? s
        return String(court.prefix(36))
    }
    private func globale() -> Double? {
        guard n > 0 else { return nil }
        let wf = faites.map(Avancement.poids).reduce(0, +), wc = nom.isEmpty ? 0 : Avancement.poids(nom)
        let vues = (faites + [nom]).map { $0.lowercased() }
        let manquantes = Avancement.standard.filter { s in !vues.contains { $0.contains(s) } }
        let reste = max(0, n - k)
        var wr = manquantes.prefix(reste).map(Avancement.poids).reduce(0, +)
        if reste > manquantes.count { wr += Double(reste - manquantes.count) * 3 }
        let tot = wf + wc + wr
        return tot > 0 ? min(0.99, (wf + wc * frac) / tot) : nil
    }
    func lire(_ brut: String) -> (etape: String?, fraction: Double?) {
        let l = brut.trimmingCharacters(in: .whitespacesAndNewlines)
        if l.hasPrefix("{"), let d = l.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let ev = j["ev"] as? String {
            switch ev {
            case "stage":
                if (j["k"] as? Int) == 1 { faites = [] }   // une nouvelle construction (la mise à jour du moteur en refait plusieurs)
                else if !nom.isEmpty, !faites.contains(nom) { faites.append(nom) }
                nom = j["name"] as? String ?? ""; k = j["k"] as? Int ?? k; n = j["n"] as? Int ?? n; frac = 0
                return (Avancement.resume(nom), globale())
            case "progress":
                if let f = j["frac"] as? Double { frac = f }
                return (nil, globale())
            case "stage_end":
                frac = 1; if !nom.isEmpty, !faites.contains(nom) { faites.append(nom) }; nom = ""
                return (nil, globale())
            case "say":
                if let m = j["msg"] as? String, m.hasPrefix("done:") { return ("Terminé", 1) }
                return (nil, nil)
            default: return (nil, nil)
            }
        }
        // MacNativeGames : « 1/4 code: … » à « 4/4 app: … »
        if let m = l.range(of: #"^([1-4])/4 ([a-z]+):"#, options: .regularExpression) {
            let mots = l[m].components(separatedBy: CharacterSet(charactersIn: "/ :"))
            if let i = Int(mots.first ?? "") {
                let avant = [0.0, 0.15, 0.32, 0.75][i - 1]
                let quoi = mots.count > 2 ? mots[2] : ""
                let r = ["code": "Réécriture du code", "data": "Données du jeu", "update": "Données du jeu", "shaders": "Shaders", "app": "Assemblage de l'app"][quoi] ?? quoi.capitalized
                return (r, avant)
            }
        }
        if l.hasPrefix("done in") { return ("Terminé", 1) }
        // MacNativeGames, Ocarina of Time (games/oot/build.py) : une ligne par étape, son nom seul ; la part de la construction déjà faite à son début
        let oot: [(String, String, Double)] = [("python-environment", "Préparation", 0.01), ("python-dependencies", "Préparation", 0.02),
            ("import-original-nup", "Lecture du jeu", 0.03), ("import-original-dump", "Lecture du jeu", 0.03), ("verify-original-modules", "Vérification du jeu", 0.12),
            ("rewrite-", "Réécriture du code", 0.14), ("verify-rewrite-", "Réécriture du code", 0.20), ("prepare_runtime", "Moteur du jeu", 0.24),
            ("prepare_romfs_backend", "Données du jeu", 0.26), ("prepare-shared-fonts", "Polices", 0.30), ("native-runtime", "Moteur du jeu", 0.31),
            ("app-icon", "Icône", 0.36), ("prepare-shader-seed", "Traduction des shaders", 0.37), ("compile-shader-libraries", "Shaders Metal", 0.62)]
        for (cle, r, f) in oot where l.hasPrefix(cle) && !l.contains(" ") { return (r, f) }
        if l.hasPrefix("Preparing "), l.contains(" compute pipelines and ") { return ("Pipelines Metal", 0.96) }   // après les shaders, quelques minutes
        if l.hasPrefix("Built ") && l.hasSuffix(".app; native gameplay validation is recorded separately.") { return ("Assemblage de l'app", 0.99) }
        let reperes: [(String, String, Double)] = [("building the runtime", "Moteur du jeu", 0.10), ("assembling the updated app", "Assemblage de l'app", 0.30),
            ("making the pipeline archive", "Pipelines", 0.40), (" pipelines for ", "Pipelines", 0.85), ("signed (", "Signature", 0.90), ("installed, its seal", "Installation", 0.95),
            ("== compilation", "Compilation", 0.05), ("signé avec", "Signature", 0.85), ("signature ad hoc", "Signature", 0.85), ("Home installé", "Installation", 0.97)]
        for (cle, r, f) in reperes where l.contains(cle) { return (r, f) }
        if l.contains("déjà à jour") { return (l, 1) }   // « Home est déjà à jour », « nxnative est déjà à jour »…
        if l.hasPrefix("== ") { return (Avancement.resume(String(l.dropFirst(3))), nil) }
        return (nil, nil)
    }
}
/// Une tâche de fond (construction, reconstruction, mise à jour) : son étape, sa progression, son journal
struct Tache {
    let titre: String; let log: URL; var jeux: Set<String> = []; var debut = Date()
    var etape = "Démarrage…"; var fraction: Double? = nil
    var fini = false; var erreur: String? = nil
    var attendu: Double? = nil   // la durée de la dernière fois (ou une estimation) : barre et temps restant d'après le temps passé
}
final class TamponLignes { var data = Data() }
struct TacheView: View {
    @ObservedObject var lib: Library; let t: Tache
    @State private var vague = false
    private var couleur: Color { t.erreur != nil ? .orange : t.fini ? .green : .white }
    /// L'avancement affiché : celui que la tâche donne, ou le temps passé sur la durée attendue (jamais 100 % avant la fin)
    /// Une étape longue qui compte dans son propre journal (MacNativeGames : constructions/<jeu>/logs/<étape>.log) :
    /// « 3500 / 41220 » (compilation des shaders), « translated 42700: » et « 85 translations left (911 s) » (traduction).
    /// Le journal le plus récent, modifié depuis moins de 2 min ; relu au plus toutes les 3 s.
    struct Compteur { let fait: Int; let total: Int; let restant: Double? }
    private static var compteurCache: (Date, Compteur?) = (.distantPast, nil)
    private static var compteurBase: (fichier: URL, fait: Int, quand: Date)? = nil
    static func compteur(_ now: Date) -> Compteur? {
        if now.timeIntervalSince(compteurCache.0) < 3 { return compteurCache.1 }
        var res: Compteur? = nil
        let fm = FileManager.default, cons = Atelier.home.appendingPathComponent("constructions")
        let logs = ((try? fm.contentsOfDirectory(at: cons, includingPropertiesForKeys: nil)) ?? []).flatMap { d in
            (try? fm.contentsOfDirectory(at: d.appendingPathComponent("logs"), includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey])) ?? [] }
        let dates = logs.compactMap { u -> (URL, Date, Date)? in
            guard u.pathExtension == "log", let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]), let m = v.contentModificationDate else { return nil }
            return (u, m, v.creationDate ?? m) }
        if let dernier = dates.max(by: { $0.1 < $1.1 }), now.timeIntervalSince(dernier.1) < 120, let h = try? FileHandle(forReadingFrom: dernier.0) {
            let fin = (try? h.seekToEnd()) ?? 0; try? h.seek(toOffset: fin > 6000 ? fin - 6000 : 0)
            let texte = String(decoding: h.readDataToEndOfFile(), as: UTF8.self); try? h.close()
            let lignes = texte.split(separator: "\n").map(String.init)
            if let l = lignes.last(where: { $0.range(of: #"^\s*\d+ / \d+\s*$"#, options: .regularExpression) != nil }) {
                let n = l.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
                if n.count == 2, n[1] > 0 {
                    // la vitesse depuis que Home voit ce compteur (le journal est réécrit à chaque construction : sa date de création ne dit rien)
                    if compteurBase == nil || compteurBase!.fichier != dernier.0 || n[0] < compteurBase!.fait { compteurBase = (dernier.0, n[0], now) }
                    let b = compteurBase!, dt = now.timeIntervalSince(b.quand), faits = n[0] - b.fait
                    res = Compteur(fait: n[0], total: n[1], restant: faits > 0 && dt > 30 ? dt * Double(n[1] - n[0]) / Double(faits) : nil)
                }
            } else if let l = lignes.last(where: { $0.contains("translations left (") }),
                      let r = l.range(of: #"(\d+) translations left \((\d+) s\)"#, options: .regularExpression) {
                let nums = l[r].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
                let fait = lignes.last(where: { $0.contains("[shader] translated ") }).flatMap { x in
                    x.components(separatedBy: "translated ").last?.components(separatedBy: ":").first.flatMap { Int($0) } } ?? 0
                if nums.count >= 2 { res = Compteur(fait: fait, total: fait + nums[0], restant: Double(nums[1])) }
            }
        }
        compteurCache = (now, res); return res
    }
    /// La part de la construction où commence l'étape qui compte, et sa largeur (games/oot/build.py ; voir Avancement)
    static func plageEtape(_ etape: String) -> (Double, Double)? {
        switch etape { case "Shaders Metal": return (0.62, 0.34); case "Traduction des shaders": return (0.37, 0.25); default: return nil }
    }
    static func fraction(_ t: Tache, _ now: Date) -> Double? {
        if t.fini { return t.erreur == nil ? 1 : t.fraction }
        if let pl = plageEtape(t.etape), let c = compteur(now), c.total > 0 { return pl.0 + pl.1 * Double(c.fait) / Double(c.total) }
        guard let a = t.attendu, a > 0 else { return t.fraction }
        return max(t.fraction ?? 0, min(0.97, now.timeIntervalSince(t.debut) / a))
    }
    static func duree(_ r: Double) -> String {
        if r < 60 { return "Moins d'une minute" }
        let m = Int((r / 60).rounded())
        if m < 60 { return "Environ \(m) min restante\(m > 1 ? "s" : "")" }
        return "Environ \(m / 60) h \(String(format: "%02d", m % 60)) restantes"
    }
    /// Le temps restant estimé : d'après la durée attendue, sinon le temps passé × (1 − avancement) / avancement
    static func restant(_ t: Tache, _ now: Date) -> String {
        let passe = now.timeIntervalSince(t.debut)
        if plageEtape(t.etape) != nil, let c = compteur(now) {   // l'étape longue d'après sa propre vitesse, plus l'assemblage
            if let r = c.restant { return duree(r + 120) }
            return "\(c.fait) / \(c.total)"
        }
        if let a = t.attendu, a > 0 { let r = a - passe; return r < 10 ? "Presque fini" : duree(r) }
        guard let f = t.fraction, f >= 0.02, passe >= 20 else {
            let s = Int(passe); return t.fraction == nil ? "En cours · \(s / 60):\(String(format: "%02d", s % 60))" : "Estimation du temps restant…"
        }
        return duree(passe * (1 - f) / f)
    }
    // Une pastille posée dans l'interface, en bas à droite, sur la ligne des aides et dans leur style : un anneau qui se remplit,
    // le nom de la tâche en capitales, et dessous où elle en est. Finie ou en échec, elle porte ses boutons.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in contenu(TacheView.fraction(t, tl.date), tl.date) }
        .padding(.leading, 10).padding(.trailing, 22).frame(height: 68)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(couleur.opacity(t.fini || t.erreur != nil ? 0.55 : 0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10).foregroundStyle(.white)
        .contentShape(Capsule()).onTapGesture { if !t.fini { lib.openTacheMenu() } }
        .animation(.easeInOut(duration: 0.35), value: t.fini)
    }
    @ViewBuilder private func contenu(_ fr: Double?, _ now: Date) -> some View {
        let f = fr.map { min(max($0, 0), 1) }
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 4)
                if t.erreur == nil, !t.fini {
                    if let f { Circle().trim(from: 0, to: max(0.02, f)).stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).animation(.easeInOut(duration: 0.9), value: f) }
                    else {   // pas de mesure : un arc qui tourne
                        Circle().trim(from: 0, to: 0.28).stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(vague ? 360 : 0))
                            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: vague).onAppear { vague = true }
                    }
                } else { Circle().stroke(couleur, lineWidth: 4) }
                Image(systemName: t.erreur != nil ? "exclamationmark" : t.fini ? "checkmark" : "arrow.down").font(.system(size: 17, weight: .black)).foregroundStyle(couleur)
            }.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.titre.uppercased()).font(.system(size: 13, weight: .black).width(.expanded)).tracking(1).lineLimit(1)
                Group {
                    if let e = t.erreur { Text(e) }
                    else if t.fini { Text(t.etape.contains("déjà à jour") ? t.etape : "Terminé") }
                    else { Text(TacheView.restant(t, now)) }
                }.font(.system(size: 14, weight: .medium).monospacedDigit()).opacity(0.7).lineLimit(1)
            }.frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            if t.erreur != nil || t.fini {
                HStack(spacing: 8) {
                    if t.erreur != nil {
                        let rapport = (t.erreur ?? "").contains("en attente") ? lib.majEnAttente().first(where: { t.titre.contains($0.0) || (t.erreur ?? "").contains($0.0) })?.1 : nil
                        Text(rapport == nil ? "Journal" : "Rapport").font(.system(size: 14, weight: .bold)).foregroundStyle(.black).padding(.horizontal, 16).frame(height: 38).background(Capsule().fill(.white))
                            .onTapGesture { if let rapport { NSWorkspace.shared.open(rapport) } else { NSWorkspace.shared.activateFileViewerSelecting([t.log]) } }
                    }
                    Image(systemName: "xmark").font(.system(size: 14, weight: .black)).frame(width: 38, height: 38).background(Circle().fill(.white.opacity(0.16)))
                        .onTapGesture { lib.fermerTache() }
                }.padding(.leading, 6).transition(.opacity)
            } else if let f {
                Text("\(Int((f * 100).rounded())) %").font(.system(size: 20, weight: .black).width(.expanded).monospacedDigit()).padding(.leading, 10)
                    .contentTransition(.numericText()).animation(.easeOut(duration: 0.4), value: Int(f * 100))
            }
        }
    }
}
/// Disparition d'une notification : elle s'efface en se floutant
struct Flou: ViewModifier {
    let actif: Bool
    func body(content: Content) -> some View { content.blur(radius: actif ? 20 : 0).opacity(actif ? 0 : 1).scaleEffect(actif ? 0.97 : 1) }
}
extension AnyTransition { static var flou: AnyTransition { .modifier(active: Flou(actif: true), identity: Flou(actif: false)) } }
/// Sur la tuile d'un jeu qu'on reconstruit ou met à jour : l'image voilée, un anneau qui se remplit, comme une mise à jour de console
struct EnMiseAJour: View {
    let fraction: Double?; let grand: Bool
    @State private var tourne = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: grand ? 18 : 14, style: .continuous).fill(.black.opacity(0.55))
            Circle().stroke(.white.opacity(0.22), lineWidth: grand ? 7 : 5).frame(width: grand ? 92 : 62, height: grand ? 92 : 62)
            if let f = fraction {
                Circle().trim(from: 0, to: CGFloat(min(max(f, 0.02), 1))).stroke(.white, style: StrokeStyle(lineWidth: grand ? 7 : 5, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: grand ? 92 : 62, height: grand ? 92 : 62).animation(.easeInOut(duration: 0.8), value: f)
                Text("\(Int((min(max(f, 0), 1) * 100).rounded())) %").font(.system(size: grand ? 20 : 14, weight: .bold, design: .rounded).monospacedDigit())
            } else {
                Circle().trim(from: 0, to: 0.25).stroke(.white, style: StrokeStyle(lineWidth: grand ? 7 : 5, lineCap: .round))
                    .frame(width: grand ? 92 : 62, height: grand ? 92 : 62).rotationEffect(.degrees(tourne ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: tourne).onAppear { tourne = true }
                Image(systemName: "arrow.down").font(.system(size: grand ? 26 : 18, weight: .bold))
            }
        }
        .foregroundStyle(.white).transition(.opacity)
    }
}
/// L'icône de Home dans le Dock pendant une tâche : une barre de progression dessous, comme un téléchargement
struct DockProgression: View {
    let fraction: Double?
    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.55)).frame(width: 104, height: 16)
                Capsule().fill(.white).frame(width: max(12, 100 * CGFloat(min(max(fraction ?? 0.04, 0), 1))), height: 12).padding(.leading, 2)
            }.padding(.bottom, 10)
        }.frame(width: 128, height: 128)
    }
}
/// La dernière case de la rangée : ajouter un jeu
struct AddTile: View {
    let selected: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.white.opacity(selected ? 0.14 : 0.04))
            RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(selected ? 1 : 0.3), style: StrokeStyle(lineWidth: selected ? 3 : 2, dash: selected ? [] : [7, 7]))
            Image(systemName: "plus").font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(selected ? 1 : 0.7))
        }
        .frame(width: Tile.cote, height: Tile.cote)
        .scaleEffect(selected ? Tile.zoom : 1, anchor: .bottom)
        .padding(.horizontal, selected ? Tile.cote * (Tile.zoom - 1) / 2 : 0)
        .animation(coule, value: selected)
    }
}
struct PickerView: View {
    @ObservedObject var lib: Library
    @State private var recherche = ""
    @FocusState private var saisie: Bool
    var body: some View {
        if let p = lib.picker {
            let h: CGFloat = p.slot == .background ? 220 : 280
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.25), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Text(p.slot.rawValue.uppercased()).font(.system(size: 21, weight: .black).width(.expanded)).tracking(1.5)
                        Text("·").opacity(0.5); Text(p.game.name.uppercased()).font(.system(size: 21, weight: .black).width(.expanded)).tracking(1.5).opacity(0.55).lineLimit(1)
                        if lib.pickerLoading { ProgressView().controlSize(.small).tint(.white).padding(.leading, 6) }
                    }
                    Spacer(minLength: 0)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .bottom, spacing: 22) {
                                ForEach(Array(p.items.enumerated()), id: \.element.id) { i, c in
                                    let sel = i == lib.pickIndex && !lib.pickerSaisie, la = lib.pickVisible(c)
                                    Group {
                                        // une image ne prend sa place qu'une fois entièrement chargée : pas de case vide en attendant
                                        if let t = c.thumb { AsyncImage(url: t) { ph in if let img = ph.image { img.resizable().scaledToFit().padding(p.slot == .logo ? 26 : 0).onAppear { lib.pickCharge(c.id) } } else { Color.clear } } }   // un logo est posé avec une marge, pas collé aux bords
                                        else { Image(systemName: "folder.fill").font(.system(size: 54, weight: .light)).frame(width: h * 0.9, height: h).background(.white.opacity(0.10)) }
                                    }
                                    .frame(height: h).frame(minWidth: la ? 150 : 0).frame(width: la ? nil : 0)
                                    .background(LinearGradient(colors: [Color(white: 0.60), Color(white: 0.44)], startPoint: .top, endPoint: .bottom))   // un gris moyen derrière les images transparentes : un logo noir s'y lit aussi bien qu'un logo blanc
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(sel && la ? 1 : 0), lineWidth: 4))
                                    .shadow(color: .black.opacity(sel ? 0.6 : 0.3), radius: sel ? 22 : 10, y: sel ? 14 : 6)
                                    .scaleEffect(sel ? 1.06 : 1, anchor: .bottom).brightness(sel ? 0 : -0.15).animation(.easeOut(duration: 0.14), value: lib.pickIndex)
                                    .animation(.easeOut(duration: 0.22), value: lib.pickerSaisie)
                                    .opacity(la ? 1 : 0).padding(.trailing, la ? 0 : -22)
                                    .id(c.id).onTapGesture { lib.pickIndex = i; lib.pickCandidate() }
                                }
                            }.padding(.horizontal, 96).padding(.top, 30).padding(.bottom, 8)
                        }.scrollClipDisabled()
                         .onChange(of: lib.pickIndex) { _, _ in if p.items.indices.contains(lib.pickIndex) { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(p.items[lib.pickIndex].id, anchor: .center) } } }
                    }.padding(.horizontal, -96).opacity(lib.pickerSaisie ? 0.55 : 1).animation(.easeOut(duration: 0.22), value: lib.pickerSaisie)
                    // l'image visée : d'où elle vient et sa taille, en une ligne
                    Text(p.items.indices.contains(lib.pickIndex) ? { let c = p.items[lib.pickIndex]; return c.thumb == nil ? "Depuis un fichier" : c.source + (c.width > 0 ? "  ·  \(c.width) × \(c.height)" : "") }() : " ")
                        .font(.system(size: 20, weight: .semibold)).padding(.top, 20).padding(.leading, 6)
                    // la recherche : on tape un autre nom, Entrée relance la recherche des images sous ce nom
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .semibold)).opacity(0.7)
                        TextField("", text: $recherche, prompt: Text(lib.config.nomsArt?[p.game.id] ?? p.game.name).foregroundColor(.white.opacity(0.45)))
                            .textFieldStyle(.plain).font(.system(size: 21, weight: .medium)).focused($saisie)
                            .onSubmit { lib.chercherArt(recherche); recherche = "" }
                            .onExitCommand { lib.pickerSaisie = false }
                            .onKeyPress(.upArrow) { lib.pickerSaisie = false; return .handled }
                    }
                    .padding(.horizontal, 22).frame(width: 620, height: 56)
                    .background(Capsule().fill(.black.opacity(lib.pickerSaisie ? 0.7 : 0.5))).overlay(Capsule().stroke(.white.opacity(lib.pickerSaisie ? 0.95 : 0.2), lineWidth: lib.pickerSaisie ? 3 : 1))
                    .scaleEffect(lib.pickerSaisie ? 1.02 : 1, anchor: .leading).animation(.easeOut(duration: 0.22), value: lib.pickerSaisie)
                    .padding(.top, 20).contentShape(Capsule()).onTapGesture { lib.pickerSaisie = true }
                    HStack(spacing: 12) { Pilule(k: lib.hints.ok, t: "Utiliser"); Pilule(k: lib.hints.options, t: "Chercher"); Pilule(k: lib.hints.back, t: "Annuler") }.padding(.top, 18)
                }.padding(.horizontal, 96).padding(.top, 70).padding(.bottom, 44)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.white).ignoresSafeArea().transition(.opacity)
            .onChange(of: lib.pickerSaisie) { _, v in saisie = v }            // la manette ou un clic donne (ou reprend) le clavier
            .onChange(of: saisie) { _, v in if lib.pickerSaisie != v { lib.pickerSaisie = v } }
        }
    }
}
extension Notification.Name { static let salonNav = Notification.Name("salonNav"); static let salonNextScreen = Notification.Name("salonNextScreen"); static let salonQuick = Notification.Name("salonQuick"); static let salonShow = Notification.Name("salonShow"); static let salonHide = Notification.Name("salonHide"); static let salonToggleSpace = Notification.Name("salonToggleSpace"); static let salonTakeInput = Notification.Name("salonTakeInput"); static let salonGiveInput = Notification.Name("salonGiveInput") }

struct RootView: View {
    @ObservedObject var lib: Library
    var body: some View {
        GeometryReader { geo in
            // Dessiné pour 1920 de large ; la hauteur suit l'écran (1080 en 16:9, 1200 en 16:10) : aucune bande noire, rien ne dépasse
            let k = max(0.3, geo.size.width / 1920)
            Screen(lib: lib).frame(width: 1920, height: geo.size.height / k).scaleEffect(k).frame(width: geo.size.width, height: geo.size.height).clipped()
        }.background(Color.black).ignoresSafeArea().preferredColorScheme(.dark)
    }
}
struct Screen: View {
    @ObservedObject var lib: Library
    @State private var now = Date()
    @State private var appeared = false
    @State private var barreVolume = false   // la barre de volume en haut de l'écran, visible 2 s après chaque réglage
    @State private var pulse = false
    let clock = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    var body: some View {
        let g = lib.current; let a = g.flatMap { lib.art[$0.id] }
        ZStack {
            // pendant un jeu, l'écran « en cours » couvre tout : le fond (image qui zoome, vidéo en boucle) n'est pas gardé derrière, il coûterait pour rien
            Group { if lib.running != nil { Color.black } else if g == nil { AddBackground() } else { Background(image: a?.background ?? g.map { lib.cover($0) }, video: g?.video, blurred: a?.background == nil) } }.id(lib.running != nil ? "en-jeu" : g?.id ?? "salon-plus")
                .transition(.opacity).animation(.easeInOut(duration: 0.35), value: g?.id)
            let veiled = lib.menu != nil || lib.picker != nil
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    ForEach(Array(lib.categories.enumerated()), id: \.offset) { i, c in
                        // des onglets nus, dans l'écriture de Home : la catégorie en cours est blanche et soulignée, les autres s'effacent
                        let ici = i == lib.categoryIndex
                        Text(c.uppercased()).font(.system(size: 17, weight: .black).width(.expanded)).tracking(1.2).fixedSize()
                            .shadow(color: .black.opacity(0.55), radius: 5)
                            .opacity(ici ? 1 : 0.5)
                            .padding(.vertical, 9).padding(.trailing, 18)
                            .overlay(alignment: .bottomLeading) { Capsule().fill(.white).frame(width: ici ? 26 : 0, height: 3) }
                            .contentShape(Rectangle())
                            .animation(glisse, value: lib.categoryIndex)
                            .onTapGesture { lib.categoryIndex = i; lib.selected = 0; Sounds.shared.play("onglet") }
                    }
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).frame(width: 44, height: 44).background(Circle().fill(.white.opacity(0.10))).onTapGesture { lib.openPlusMenu() }.help("Menu")
                    Spacer()
                    // trois îlots : le volume du Mac (réglable à la souris), l'heure, la batterie de la manette
                    HStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: lib.macMuted || lib.macVolume == 0 ? "speaker.slash.fill" : lib.macVolume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill").font(.system(size: 15, weight: .semibold)).frame(width: 22)
                                .onTapGesture { lib.toggleMacMute() }
                            // la barre : on clique ou on glisse dessus pour régler
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.22)).frame(width: 120, height: 6)
                                Capsule().fill(.white).frame(width: max(6, 120 * CGFloat(lib.macVolume)), height: 6)
                                Circle().fill(.white).frame(width: 14, height: 14).offset(x: max(0, 120 * CGFloat(lib.macVolume) - 7)).shadow(color: .black.opacity(0.4), radius: 3)
                            }
                            .frame(width: 120, height: 26).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                                let avant = Int((lib.macVolume * 20).rounded())
                                lib.macStep(Float(min(1, max(0, g.location.x / 120))) - lib.macVolume, quiet: true, barre: false)
                                if Int((lib.macVolume * 20).rounded()) != avant { Sounds.shared.play("volume") }   // le même clic qu'à la manette, à chaque cran de 5 %
                            })
                            .animation(.linear(duration: 0.06), value: lib.macVolume)
                            Text(lib.macMuted ? "muet" : "\(Int((lib.macVolume * 100).rounded()))").font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()).frame(width: 34, alignment: .trailing)
                        }.padding(.horizontal, 16).frame(height: 44).background(.black.opacity(0.42), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                        if let pct = PadBattery.percent() {
                            HStack(spacing: 8) {
                                Image(systemName: "gamecontroller.fill").font(.system(size: 16))
                                Image(systemName: GCController.controllers().first?.battery?.batteryState == .charging ? "battery.100percent.bolt" : pct < 20 ? "battery.25percent" : pct < 55 ? "battery.50percent" : "battery.100percent").font(.system(size: 15))
                                Text("\(pct) %").font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                            }.padding(.horizontal, 16).frame(height: 44).background(.black.opacity(0.42), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                             .help("Batterie de la manette")
                        }
                        Text(now, format: .dateTime.hour().minute()).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()).shadow(color: .black.opacity(0.5), radius: 6).padding(.leading, 10)
                    }
                }.padding(.horizontal, 84).padding(.top, 44).foregroundStyle(.white)
                Spacer()
                if let g {
                    VStack(alignment: .leading, spacing: 10) {
                        Text((g.viaHome ? (g.appPC?.hasPrefix("steam:") == true ? "Steam" : g.appPC?.hasPrefix("exe:") == true ? "Windows" : "Epic Games") : g.category).uppercased())
                            .font(.system(size: 15, weight: .heavy, design: .rounded)).tracking(2).opacity(0.8)
                        if let l = a?.logo { Image(nsImage: l).resizable().scaledToFit().frame(maxWidth: 560, maxHeight: 180, alignment: .leading).shadow(radius: 12) }
                        else { Text(g.name.uppercased()).font(.system(size: 52, weight: .black).width(.expanded)).tracking(1).lineLimit(1).minimumScaleFactor(0.5).shadow(radius: 12) }
                        HStack(spacing: 16) {
                            HStack(spacing: 10) { if let sym = lib.hints.ok.symbol { Image(systemName: sym.replacingOccurrences(of: ".circle", with: ".circle.fill")).font(.system(size: 22)) } else { Text(lib.hints.ok.text).font(.system(size: 15, weight: .bold)).padding(.horizontal, 6).overlay(Capsule().stroke(.black.opacity(0.6), lineWidth: 1.5)) }; Text(lib.running != nil ? "En cours…" : lib.enFond(g) ? "Reprendre" : "Jouer").font(.system(size: 20, weight: .semibold, design: .rounded)) }
                                .foregroundStyle(.black).padding(.horizontal, 34).padding(.vertical, 14).background(Capsule().fill(.white.opacity(lib.running == nil ? 1 : 0.5)))
                                .shadow(color: .white.opacity(pulse ? 0.45 : 0.1), radius: pulse ? 22 : 8).scaleEffect(pulse ? 1.02 : 1.0)
                                .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true } }
                                .onTapGesture { lib.launch() }
                            Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).frame(width: 54, height: 54).background(Circle().fill(.black.opacity(0.4))).overlay(Circle().stroke(.white.opacity(0.24), lineWidth: 1.5))
                                .onTapGesture { lib.openOptions() }
                        }.padding(.top, 14)
                    }.padding(.horizontal, 84).padding(.bottom, 22).foregroundStyle(.white)
                     .id("info-\(g.id)").transition(.asymmetric(insertion: .offset(x: 28).combined(with: .opacity), removal: .opacity))
                } else {
                    // la case + : ajouter un jeu
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AJOUTER UN JEU").font(.system(size: 52, weight: .black).width(.expanded)).tracking(1).shadow(radius: 12)
                        HStack(spacing: 10) { if let sym = lib.hints.ok.symbol { Image(systemName: sym.replacingOccurrences(of: ".circle", with: ".circle.fill")).font(.system(size: 22)) } else { Text(lib.hints.ok.text).font(.system(size: 15, weight: .bold)).padding(.horizontal, 6).overlay(Capsule().stroke(.black.opacity(0.6), lineWidth: 1.5)) }; Text("Ajouter").font(.system(size: 20, weight: .semibold, design: .rounded)) }
                            .foregroundStyle(.black).padding(.horizontal, 34).padding(.vertical, 14).background(Capsule().fill(.white)).padding(.top, 14)
                            .onTapGesture { lib.openAddMenu() }
                    }.padding(.horizontal, 84).padding(.bottom, 22).foregroundStyle(.white)
                     .id("info-plus").transition(.opacity)
                }
                // les catégories sont des rangées posées l'une sous l'autre : en changer fait monter ou descendre toute la pile, chaque jeu
                // restant dans sa colonne ; la rangée d'après se devine en bas de l'écran
                ZStack(alignment: .topLeading) {
                    ForEach(Array(lib.categories.enumerated()), id: \.offset) { c, _ in
                        // la pile fait le tour : après la dernière catégorie vient la première, qui monte d'en dessous comme les autres
                        let n = lib.categories.count, r = ((c - lib.categoryIndex) % n + n) % n, d = r > n / 2 ? r - n : r
                        if abs(d) <= 1 {
                            RangeeJeux(lib: lib, categorie: c)
                                .offset(y: CGFloat(d) * 236).opacity(d == 0 ? 1 : d == 1 ? 0.45 : 0).blur(radius: d == 0 ? 0 : 14)
                                .allowsHitTesting(d == 0).transition(.opacity).zIndex(d == 0 ? 1 : 0)
                        }
                    }
                }
                .frame(height: 294, alignment: .top).animation(coule, value: lib.categoryIndex)
                .offset(y: appeared ? 0 : 36).opacity(appeared ? 1 : 0).animation(.timingCurve(0.2, 0.75, 0.2, 1, duration: 0.45), value: appeared)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { appeared = true } }
                HStack(spacing: 12) { Pilule(k: lib.hints.ok, t: lib.current == nil ? "Ajouter" : "Jouer"); if lib.current != nil { Pilule(k: lib.hints.options, t: "Options") }; Pilule(k: lib.hints.plus, t: "Menu"); Pilule(k: lib.hints.cat, t: "Catégorie"); Spacer() }
                    .padding(.horizontal, 84).padding(.bottom, 40).foregroundStyle(.white)
            }
            .blur(radius: veiled ? 16 : 0).scaleEffect(veiled ? 0.985 : 1).animation(.easeInOut(duration: 0.35), value: veiled)
            if let m = lib.menu { Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { lib.closeAllMenus() }; MenuView(lib: lib, menu: m).id(m.title + (m.subtitle ?? "")) }
            if lib.picker != nil { PickerView(lib: lib) }
            if lib.bienvenue { BienvenueView(lib: lib).transition(.opacity).zIndex(18) }
            if lib.ouverture { OuvertureView(lib: lib).zIndex(20) }
            if let t = lib.tache {
                TacheView(lib: lib, t: t).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 84).padding(.bottom, 30)   // sur la ligne des aides, à la marge de l'écran
                    .transition(.asymmetric(insertion: .offset(y: 16).combined(with: .opacity), removal: .opacity)).zIndex(15)   // part en fondu ; le rang fixe garde la vue dessinée pendant qu'elle s'efface
            }
            if let r = lib.running {
                // Écran « en cours de jeu » : derrière le jeu (bureau), ou visible quand le jeu est sur l'autre écran / en fenêtre
                NowPlayingView(lib: lib, game: r).transition(.opacity)
            }
                VStack { HStack(spacing: 12) {
                        let v = lib.flashGeneral ? lib.macVolume : lib.volume, muted = lib.flashGeneral ? lib.macMuted : lib.gameMuted
                        Image(systemName: v == 0 ? "speaker.slash.fill" : v < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill").font(.system(size: 18, weight: .semibold))
                        ZStack(alignment: .leading) { Capsule().fill(.white.opacity(0.22)).frame(width: 220, height: 6); Capsule().fill(.white).frame(width: max(6, 220 * CGFloat(v)), height: 6) }
                        Text(muted ? "Muet" : "\(Int((v * 100).rounded())) %").font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()).frame(width: 52, alignment: .trailing)
                        Text(lib.flashGeneral ? "Volume général" : lib.volumeLabel).font(.system(size: 13, weight: .medium, design: .rounded)).opacity(0.6)
                    }.padding(.horizontal, 18).padding(.vertical, 12).background(.black.opacity(0.6), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1)).foregroundStyle(.white).padding(.top, 90); Spacer() }
                .opacity(barreVolume ? 1 : 0).offset(y: barreVolume ? 0 : -16).animation(.easeInOut(duration: 0.5), value: barreVolume).allowsHitTesting(false)
                .zIndex(30)   // par-dessus tous les menus : sans rang, certains la recouvraient
            if let t = lib.toast {
                VStack { Spacer(); Text(t).font(.system(size: 18, weight: .medium, design: .rounded)).padding(.horizontal, 20).padding(.vertical, 12).background(.black.opacity(0.6), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1)).foregroundStyle(.white).padding(.bottom, 130) }
                    .transition(.opacity).onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if lib.toast == t { lib.toast = nil } } }.zIndex(31)
            }
        }
        // chaque réglage la montre (ou la garde) ; 2 s après le dernier, elle repart vers le haut en fondu, comme elle est venue
        .task(id: lib.volumeFlash) {
            guard Date().timeIntervalSince(lib.volumeFlash) < 1 else { return }
            barreVolume = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { barreVolume = false }
        }
        .onReceive(clock) { now = $0 }.animation(.easeInOut(duration: 0.4), value: lib.current?.id).animation(.easeInOut(duration: 0.22), value: lib.menu?.title).animation(.easeInOut(duration: 0.22), value: lib.picker?.game.id)
    }
}

/// Le Salon pendant une partie : le fond du jeu très assombri et flouté, sa jaquette au centre, le nom, la durée, les commandes du HUD
struct NowPlayingView: View {
    @ObservedObject var lib: Library; let game: Game
    @State private var now = Date()
    @State private var breathe = false
    let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        let a = lib.art[game.id]; let elapsed = lib.runningSince.map { Int(now.timeIntervalSince($0)) } ?? 0
        ZStack {
            Color.black.ignoresSafeArea()
            if let bg = a?.background ?? a?.cover { Color.black.overlay { Image(nsImage: bg).resizable().scaledToFill().blur(radius: 40).saturation(0.6) }.opacity(0.22).clipped().ignoresSafeArea() }
            VStack(spacing: 26) {
                Spacer()
                Image(nsImage: lib.cover(game)).resizable().scaledToFill().frame(width: 300, height: 300).clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .shadow(color: .black.opacity(0.7), radius: 40, y: 20).shadow(color: .white.opacity(breathe ? 0.12 : 0.04), radius: 60)
                    .scaleEffect(breathe ? 1.02 : 1.0)
                    .onAppear { breathe = true }   // fixe : une animation sans fin ici tournait derrière le jeu pendant toute la partie
                if let l = a?.logo { Image(nsImage: l).resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 120).shadow(radius: 12) }
                else { Text(game.name.uppercased()).font(.system(size: 42, weight: .black).width(.expanded)).tracking(1) }
                HStack(spacing: 12) {
                    Circle().fill(Color.green).frame(width: 9, height: 9).shadow(color: .green.opacity(0.8), radius: 6)
                    Text(String(format: "%d:%02d:%02d", elapsed / 3600, elapsed % 3600 / 60, elapsed % 60)).font(.system(size: 17, weight: .medium, design: .rounded).monospacedDigit()).opacity(0.75)
                }
                Spacer()
                HStack(spacing: 12) { Pilule(k: lib.hints.plus, t: "Menu rapide") }.opacity(0.7).padding(.bottom, 44)
            }.foregroundStyle(.white)
        }.onReceive(clock) { t in if NSApp.isActive || t.timeIntervalSince(now) >= 60 { now = t } }   // derrière le jeu : une fois par minute suffit
    }
}

// MARK: - HUD en jeu (fenêtre transparente au-dessus du jeu)
struct HUDView: View {
    @ObservedObject var lib: Library
    @State private var now = Date()
    let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        let g = lib.running; let a = g.flatMap { lib.art[$0.id] }
        let elapsed = lib.runningSince.map { Int(now.timeIntervalSince($0)) } ?? 0
        let battery = GCController.controllers().first?.battery
        ZStack(alignment: .top) {
            Color.clear
            // haut droite : heure, batterie manette, voyant capture
            HStack(spacing: 10) {
                if Recorder.shared.active { Circle().fill(.red).frame(width: 7, height: 7) }
                Text(now, format: .dateTime.hour().minute()).font(.system(size: 15, weight: .semibold, design: .rounded))
                if let pct = PadBattery.percent() {
                    Image(systemName: battery?.batteryState == .charging ? "battery.100percent.bolt" : pct < 20 ? "battery.25percent" : pct < 55 ? "battery.50percent" : "battery.100percent").font(.system(size: 13)).opacity(0.85)
                    Text("\(pct) %").font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()).opacity(0.85)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule()).background(Capsule().fill(Color.black.opacity(0.35)))
            .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 10).padding(.trailing, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
            if lib.quick {
                // bas : centre de contrôle — carte du jeu à gauche, cartes d'action au milieu, aides à droite
                VStack { Spacer()
                    // la carte des joueurs existe dès que le jeu est en ligne et ne fait que se montrer : créée au moment de l'ouvrir, elle
                    // apparaissait d'un coup la première fois, sans son animation
                    if let e = lib.enLigne() {
                        JoueursView(titre: e.nom, joueurs: lib.quickJoueurs ? lib.joueursConnectes() : nil, back: lib.hints.back).padding(.bottom, 14)
                            .opacity(lib.quickJoueurs ? 1 : 0).offset(y: lib.quickJoueurs ? 0 : 22).scaleEffect(lib.quickJoueurs ? 1 : 0.96, anchor: .bottom)
                            .frame(height: lib.quickJoueurs ? nil : 0, alignment: .bottom).allowsHitTesting(lib.quickJoueurs)
                    }
                    if lib.quickSlider {
                        // grand curseur de volume (jeu ou général selon la carte) : stick gauche / flèches pour régler, △ muet, ○ pour revenir aux cartes
                        let general = lib.quickIndex == 4, v = general ? lib.macVolume : lib.volume, muted = general ? lib.macMuted : lib.gameMuted
                        HStack(spacing: 18) {
                            VStack(spacing: 4) {
                                Image(systemName: v == 0 ? "speaker.slash.fill" : v < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill").font(.system(size: 26, weight: .medium))
                            }.frame(width: 64)
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.2)).frame(width: 440, height: 10)
                                Capsule().fill(.white).frame(width: max(10, 440 * CGFloat(v)), height: 10)
                                Circle().fill(.white).frame(width: 22, height: 22).shadow(color: .black.opacity(0.5), radius: 6).offset(x: max(0, 440 * CGFloat(v) - 11))
                            }.animation(.linear(duration: 0.08), value: v)
                            Text(muted ? "Muet" : "\(Int((v * 100).rounded())) %").font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit()).frame(width: 84, alignment: .trailing)
                            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 44)
                            Hint(k: lib.hints.tri, t: muted ? "Son" : "Muet").font(.system(size: 13))
                        }
                        .padding(.horizontal, 26).padding(.vertical, 18)
                        .background(.ultraThinMaterial, in: Capsule()).background(Capsule().fill(Color.black.opacity(0.5))).overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 30, y: 12).foregroundStyle(.white).padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    VStack(spacing: 12) {
                        // le nom du choix visé, seul texte du menu ; pour un volume, son niveau
                        if lib.quickItems.indices.contains(lib.quickIndex) {
                            let it = lib.quickItems[lib.quickIndex]; let i = lib.quickIndex
                            let v = i == 4 ? lib.macVolume : lib.volume, muted = i == 4 ? lib.macMuted : lib.gameMuted
                            Text(it.0.hasPrefix("Volume") ? "\(it.0) · \(muted ? "muet" : "\(Int((v * 100).rounded())) %")" : it.0)
                                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit()).padding(.horizontal, 18).padding(.vertical, 8)
                                .background(Capsule().fill(.white)).foregroundStyle(.black).opacity(lib.quickSlider ? 0.5 : 1).id(lib.quickIndex).transition(.opacity)
                        }
                        HStack(spacing: 16) {
                            if let g {
                                Image(nsImage: lib.cover(g)).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                Text(String(format: "%d:%02d", elapsed / 3600, elapsed % 3600 / 60)).font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()).opacity(0.8)
                                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 44).padding(.horizontal, 4)
                            }
                            ForEach(Array(lib.quickItems.enumerated()), id: \.offset) { i, it in
                                let on = i == lib.quickIndex
                                let estVolume = it.0.hasPrefix("Volume"), niveau = i == 4 ? lib.macVolume : lib.volume, muet = i == 4 ? lib.macMuted : lib.gameMuted
                                Image(systemName: estVolume ? (i == 4 ? "laptopcomputer" : "gamecontroller.fill") : it.1).font(.system(size: on ? 29 : 23, weight: .medium)).frame(width: on ? 82 : 62, height: on ? 82 : 62)
                                    .background(Circle().fill(on ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12))))
                                    .overlay(Circle().stroke(.white.opacity(on ? 0 : 0.16), lineWidth: 1))
                                    .overlay { if estVolume { Circle().trim(from: 0, to: muet ? 0 : CGFloat(max(0.02, niveau))).stroke(i == 4 ? Library.bleu[0] : Library.orange[0], style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).padding(-5).animation(.linear(duration: 0.08), value: niveau) } }
                                    .overlay(alignment: .bottomTrailing) { if estVolume { Image(systemName: muet || niveau == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).frame(width: 24, height: 24).background(Circle().fill(i == 4 ? Library.bleu[1] : Library.orange[1])).offset(x: 4, y: 4) } }
                                    .foregroundStyle(on ? .black : .white).opacity(lib.quickSlider && !on ? 0.45 : 1)
                                    .animation(glisse, value: lib.quickIndex)
                            }
                        }
                        .padding(.horizontal, 22).padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule()).background(Capsule().fill(Color.black.opacity(0.45))).overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 40, y: 16)
                        HStack(spacing: 10) { Pilule(k: lib.hints.ok, t: lib.quickIndex >= 3 ? "Ouvrir" : "Valider"); Pilule(k: lib.hints.back, t: "Fermer") }.scaleEffect(0.86)
                    }
                    .foregroundStyle(.white).padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }.onReceive(clock) { t in if lib.quick || t.timeIntervalSince(now) >= 30 { now = t } }   // menu rapide fermé : l'heure seule, toutes les 30 s
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: lib.quick).animation(.spring(response: 0.3, dampingFraction: 0.85), value: lib.quickSlider).animation(.spring(response: 0.3, dampingFraction: 0.85), value: lib.quickJoueurs).preferredColorScheme(.dark)
    }
}

/// Menu rapide, carte Joueurs : qui est connecté au serveur du jeu en ligne (mis à jour chaque seconde avec le HUD)
struct JoueursView: View {
    let titre: String; let joueurs: [String]?; let back: Key
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(joueurs == nil ? Color.orange : Color.green).frame(width: 9, height: 9)
                Text(titre).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1)
                Spacer(minLength: 12)
                Text(joueurs.map { $0.count == 1 ? "1 joueur" : "\($0.count) joueurs" } ?? "Serveur arrêté").font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()).opacity(0.7)
            }
            if let j = joueurs, !j.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(j.prefix(8).enumerated()), id: \.offset) { _, n in
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 20)).opacity(0.85)
                            Text(n).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                        }
                    }
                    if j.count > 8 { Text("et \(j.count - 8) autre\(j.count - 8 > 1 ? "s" : "")").font(.system(size: 13, weight: .medium, design: .rounded)).opacity(0.6) }
                }
            } else {
                Text(joueurs == nil ? "Serveur arrêté" : "Personne").font(.system(size: 14, weight: .medium, design: .rounded)).opacity(0.65)
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 22).frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Color.black.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 12).foregroundStyle(.white)
    }
}

// MARK: - Manette : batterie réelle
/// Le pourcentage que macOS affiche dans le menu Bluetooth (propriété BatteryPercent du pilote HID), GameController en secours
/// (sa valeur reste souvent figée à 100 %). Mis en cache 10 s.
enum PadBattery {
    private static var cache: (Int?, Date) = (nil, .distantPast)
    static func percent() -> Int? {
        if Date().timeIntervalSince(cache.1) < 10 { return cache.0 }
        var found: Int? = nil
        var it: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &it) == KERN_SUCCESS {
            var e = IOIteratorNext(it)
            while e != 0 {
                let usage = (IORegistryEntryCreateCFProperty(e, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int) ?? 0
                if usage == 5 || usage == 4 || usage == 8,   // manette / joystick
                   let p = IORegistryEntrySearchCFProperty(e, kIOServicePlane, "BatteryPercent" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? Int {
                    found = p
                }
                IOObjectRelease(e); if found != nil { break }
                e = IOIteratorNext(it)
            }
            IOObjectRelease(it)
        }
        if found == nil, let b = GCController.controllers().first?.battery, b.batteryState != .unknown { found = Int((b.batteryLevel * 100).rounded()) }
        cache = (found, Date()); return found
    }
}

// MARK: - Manette : saisie exclusive pendant le menu rapide
/// État lisible de la manette (même forme pour GameController et pour la lecture HID directe)
struct PadSnap { var lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0; var dx = 0, dy = 0; var ok = false, back = false, salon = false, tri = false }
/// Ouvre la (les) manette(s) en exclusif via IOKit : tant que c'est pris, ni le jeu (moteur nxnative, MNG, Wine…) ni GameController ne reçoivent plus rien.
/// Sony (DualSense, DualShock 4) : rapports bruts décodés (en Bluetooth, le rapport étendu n'est pas découpé en éléments HID) ; autres : éléments HID.
final class PadSeize {
    static let shared = PadSeize()
    private var devices: [(dev: IOHIDDevice, buf: UnsafeMutablePointer<UInt8>?)] = []
    private var vendor = 0, product = 0
    private var buttons = Set<Int>(), axes: [Int: Float] = [:], hat = -1
    private var sony: PadSnap? = nil
    var active: Bool { !devices.isEmpty }
    func take() -> Bool {
        release()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDOptionsType(0))
        let match: [[String: Any]] = [0x04, 0x05, 0x08].map { [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        let all: [IOHIDDevice] = ((IOHIDManagerCopyDevices(m) as NSSet?)?.allObjects ?? []).compactMap { o in CFGetTypeID(o as CFTypeRef) == IOHIDDeviceGetTypeID() ? (o as! IOHIDDevice) : nil }
        guard !all.isEmpty else { log("Saisie manette : aucune manette HID"); return false }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for d in all {
            let r = IOHIDDeviceOpen(d, IOHIDOptionsType(1) /* kIOHIDOptionsTypeSeizeDevice */)
            guard r == kIOReturnSuccess else { log("Saisie manette : refusée (0x\(String(UInt32(bitPattern: r), radix: 16))) pour \((IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "?")"); continue }
            vendor = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            product = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? 0
            var buf: UnsafeMutablePointer<UInt8>? = nil
            if vendor == 0x054C {
                buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
                IOHIDDeviceRegisterInputReportCallback(d, buf!, 256, { ctx, _, _, _, id, data, len in
                    guard let ctx else { return }; Unmanaged<PadSeize>.fromOpaque(ctx).takeUnretainedValue().sonyReport(id: Int(id), data: data, len: len)
                }, ctx)
            } else {
                IOHIDDeviceRegisterInputValueCallback(d, { ctx, _, _, value in
                    guard let ctx else { return }; Unmanaged<PadSeize>.fromOpaque(ctx).takeUnretainedValue().element(value)
                }, ctx)
            }
            IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            devices.append((d, buf))
        }
        buttons = []; axes = [:]; hat = -1; sony = nil
        if !devices.isEmpty { log("Saisie manette : \(devices.count) appareil(s), fabricant 0x\(String(vendor, radix: 16)) produit 0x\(String(product, radix: 16))") }
        return !devices.isEmpty
    }
    func release() {
        for (d, buf) in devices {
            if let buf { IOHIDDeviceRegisterInputReportCallback(d, buf, 256, nil, nil) } else { IOHIDDeviceRegisterInputValueCallback(d, nil, nil) }
            IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(d, IOHIDOptionsType(1) /* kIOHIDOptionsTypeSeizeDevice */)
            buf?.deallocate()
        }
        devices = []
    }
    private func sonyReport(id: Int, data: UnsafeMutablePointer<UInt8>, len: CFIndex) {
        let ds = (product == 0x0CE6 || product == 0x0DF2)   // DualSense / DualSense Edge ; sinon DualShock 4
        let off: Int
        switch (ds, id) { case (true, 0x31): off = 2; case (true, 0x01): off = 1; case (false, 0x11): off = 3; case (false, 0x01): off = 1; default: return }
        let need = off + (ds ? 10 : 7); guard len >= need else { return }
        func ax(_ i: Int) -> Float { (Float(data[off + i]) - 127.5) / 127.5 }
        let b0 = Int(data[off + (ds ? 7 : 4)]), b1 = Int(data[off + (ds ? 8 : 5)]), b2 = Int(data[off + (ds ? 9 : 6)])
        var s = PadSnap(lx: ax(0), ly: -ax(1), rx: ax(2), ry: -ax(3))
        let h = b0 & 0x0F; if h < 8 { s.dx = [0, 1, 1, 1, 0, -1, -1, -1][h]; s.dy = [1, 1, 0, -1, -1, -1, 0, 1][h] }
        s.ok = b0 & 0x20 != 0; s.back = b0 & 0x40 != 0; s.tri = b0 & 0x80 != 0; s.salon = b2 & 0x02 != 0; _ = b1
        sony = s
    }
    private func element(_ v: IOHIDValue) {
        let el = IOHIDValueGetElement(v); let page = IOHIDElementGetUsagePage(el), usage = Int(IOHIDElementGetUsage(el)); let raw = IOHIDValueGetIntegerValue(v)
        if page == 0x09 { if raw != 0 { buttons.insert(usage) } else { buttons.remove(usage) } }
        else if page == 0x01 {
            let lo = IOHIDElementGetLogicalMin(el), hi = IOHIDElementGetLogicalMax(el)
            if usage == 0x39 { hat = (raw < lo || raw > hi) ? -1 : Int(raw - lo) }
            else if (0x30...0x35).contains(usage), hi > lo { axes[usage] = Float(raw - lo) / Float(hi - lo) * 2 - 1 }
        }
    }
    func snapshot() -> PadSnap {
        if let s = sony { return s }
        var s = PadSnap(lx: axes[0x30] ?? 0, ly: -(axes[0x31] ?? 0), rx: axes[0x32] ?? axes[0x33] ?? 0, ry: -(axes[0x35] ?? axes[0x34] ?? 0))
        if hat >= 0 && hat < 8 { s.dx = [0, 1, 1, 1, 0, -1, -1, -1][hat]; s.dy = [1, 1, 0, -1, -1, -1, 0, 1][hat] }
        switch vendor {
        case 0x057E: s.ok = buttons.contains(2); s.back = buttons.contains(1); s.tri = buttons.contains(4); s.salon = buttons.contains(9)                      // Nintendo : A, B, X, −
        case 0x045E: s.ok = buttons.contains(1); s.back = buttons.contains(2); s.tri = buttons.contains(4) || buttons.contains(5); s.salon = buttons.contains(7) || buttons.contains(11)   // Xbox : A, B, Y, Affichage
        default: s.ok = buttons.contains(1); s.back = buttons.contains(2); s.tri = buttons.contains(4); s.salon = buttons.contains(9)
        }
        return s
    }
}

// MARK: - Application
final class SalonWindow: NSWindow { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true }; override func performClose(_ sender: Any?) { NSApp.terminate(nil) } }
final class HUDPanel: NSPanel { override var canBecomeKey: Bool { true } }   // clé pendant le menu rapide : le Salon reçoit la manette, pas le jeu
final class AppDelegate: NSObject, NSApplicationDelegate {
    let lib = Library(); var window: NSWindow?; var hud: NSPanel?; var gameApp: NSRunningApplication?; var pad: Timer?; var bag = Set<AnyCancellable>(); var holdMenu = 0
    var lastX = 0, lastY = 0, heldX = 0, heldY = 0, prev: [String: Bool] = [:]
    var qLastX = 0, qLastY = 0, qHeldX = 0, qHeldY = 0   // menu rapide en jeu : ses propres compteurs (ceux du Salon sont remis à 0 à chaque tour)
    /// Home ne laisse pas grossir ce qu'il écrit : un journal de plus de 1 Mo ne garde que sa fin, un journal ou un rapport de plus de
    /// 30 jours part, les morceaux d'une capture interrompue aussi.
    static func menage() {
        let fm = FileManager.default, logs = Dossiers.home.appendingPathComponent("log")
        for f in (try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])) ?? [] {
            guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true, ["log", "txt"].contains(f.pathExtension) else { continue }
            if let d = v.contentModificationDate, Date().timeIntervalSince(d) > 30 * 86400 { try? fm.removeItem(at: f); continue }
            if let n = v.fileSize, n > 1_000_000, let h = try? FileHandle(forReadingFrom: f) {
                try? h.seek(toOffset: UInt64(n - 300_000)); let fin = h.readDataToEndOfFile(); try? h.close()
                try? fin.write(to: f, options: .atomic)
            }
        }
        let tmp = salonRoot.appendingPathComponent("captures/tmp")
        for f in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
    }
    func applicationDidFinishLaunching(_ n: Notification) {
        DispatchQueue.global(qos: .utility).async { AppDelegate.menage() }
        // Aperçu pour le développement : HOME_APERCU=<dossier> dessine les trois étapes de l'écran d'accueil en PNG (1920×1080) et quitte,
        // sans rien charger ni installer
        if let dossier = ProcessInfo.processInfo.environment["HOME_APERCU"] {
            func rendre<V: View>(_ v: V, _ nom: String) {
                let r = ImageRenderer(content: ZStack { LinearGradient(colors: [Color(red: 0.10, green: 0.30, blue: 0.55), Color(red: 0.04, green: 0.08, blue: 0.20)], startPoint: .topTrailing, endPoint: .bottomLeading); v }.frame(width: 1920, height: 1080)); r.scale = 1
                if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dossier).appendingPathComponent(nom)) }
            }
            let court = SalonMenu(title: "Super Mario Odyssey", subtitle: "Switch", items: [
                SalonMenuItem(label: "Jouer", icon: "play.fill", action: {}), SalonMenuItem(label: "Réglages du jeu", detail: "60 images par seconde", icon: "slider.horizontal.3", action: {}),
                SalonMenuItem(label: "Mods", detail: "3 installés, 2 activés", icon: "puzzlepiece.extension.fill", action: {}), SalonMenuItem(label: "Mises à jour", icon: "arrow.down.circle.fill", action: {}),
                SalonMenuItem(label: "Apparence", icon: "paintpalette.fill", action: {}), SalonMenuItem(label: "Plus", icon: "ellipsis", action: {})])
            rendre(MenuView(lib: lib, menu: court, apercu: 1), "menu-rangee.png")
            let long = SalonMenu(title: "Bibliothèque Epic Games", subtitle: "32 jeux", items: ["Celeste", "Fall Guys", "Fortnite", "Hades", "Rocket League", "Sifu", "Subnautica", "Control", "Alan Wake", "Death Stranding", "Dishonored", "Prey"].enumerated().map { i, n in
                SalonMenuItem(label: n, detail: n == "Fortnite" ? "Incompatible — anti-triche" : n == "Fall Guys" ? "Vérifié sur Mac" : "Pas encore testé", icon: n == "Fortnite" ? "xmark.shield.fill" : n == "Fall Guys" ? "checkmark.seal.fill" : "arrow.down.circle", destructive: n == "Fortnite", action: {}) })
            rendre(MenuView(lib: lib, menu: long, apercu: 1), "menu-liste.png")
            rendre(MenuView(lib: lib, menu: lib.plusMenu(), apercu: 2), "menu-tuiles.png")
            let sous = SalonMenu(title: "Réglages", subtitle: "Super Mario Odyssey", items: [
                SalonMenuItem(label: "Images par seconde : 60", detail: "Jusqu'à 120 sur un écran qui le permet", icon: "speedometer", section: "Image", action: {}), SalonMenuItem(label: "MetalFX : activé", icon: "sparkles", action: {}),
                SalonMenuItem(label: "Résolution : 1080p", icon: "rectangle.expand.vertical", action: {}), SalonMenuItem(label: "Plein écran : activé", icon: "arrow.up.left.and.arrow.down.right", action: {}),
                SalonMenuItem(label: "Serveur en ligne : Azure", icon: "globe", section: "En ligne", action: {}), SalonMenuItem(label: "Joueurs", detail: "3 connectés", icon: "person.2.fill", info: true, action: {}),
                SalonMenuItem(label: "Volume du jeu : 65 %", icon: "speaker.wave.2.fill", section: "Son", action: {})])
            rendre(MenuView(lib: lib, menu: sous, apercu: 1), "menu-sous.png")
            lib.openModeUtilisation(premier: true); if let m = lib.menu { rendre(MenuView(lib: lib, menu: m, apercu: 0), "mode.png") }; lib.menu = nil
            let comptes = SalonMenu(title: "Comptes", items: [
                SalonMenuItem(label: "Epic Games : Joueur", detail: "Ta bibliothèque", icon: "logo:epic", tint: .purple, action: {}), SalonMenuItem(label: "Steam : non connecté", detail: "Se connecter", icon: "logo:steam", tint: .blue, action: {}),
                SalonMenuItem(label: "Jeu installé", detail: "Son .exe", icon: "folder.fill", section: "Déjà à toi", tint: .orange, action: {}), SalonMenuItem(label: "Installateur", detail: "setup.exe ou .msi", icon: "shippingbox.fill", tint: .orange, action: {})], roue: true)
            rendre(MenuView(lib: lib, menu: comptes, apercu: 1), "comptes.png")
            let ajout = SalonMenu(title: "Ajouter un jeu", items: [SalonMenuItem(label: "Switch", icon: "logo:switch", tint: .red, action: {}), SalonMenuItem(label: "Epic Games", icon: "logo:epic", tint: .purple, action: {}),
                SalonMenuItem(label: "Steam", icon: "logo:steam", tint: .blue, action: {}), SalonMenuItem(label: "App Mac", icon: "apple.logo", tint: .gray, action: {}),
                SalonMenuItem(label: "Jeu Windows", detail: "setup.exe ou .msi", icon: "logo:windows", tint: .blue, action: {}), SalonMenuItem(label: "Jeu Windows préinstallé", detail: "Son .exe", icon: "folder.fill", tint: .orange, action: {})])
            lib.openAdvancedSettings(); if let m = lib.menu { rendre(MenuView(lib: lib, menu: m, apercu: 4), "avance.png") }; lib.menu = nil
            rendre(MenuView(lib: lib, menu: ajout, apercu: 2), "ajouter.png")
            var t1 = Tache(titre: "Mise à jour du moteur nxnative", log: URL(fileURLWithPath: "/tmp/x.log")); t1.fraction = 0.42; t1.etape = "Compilation"
            var t2 = Tache(titre: "Construction du jeu", log: URL(fileURLWithPath: "/tmp/x.log")); t2.fini = true; t2.erreur = "Le jeu de base est introuvable"
            var t3 = Tache(titre: "Mise à jour de Home", log: URL(fileURLWithPath: "/tmp/x.log")); t3.fini = true; t3.etape = "Terminé"
            rendre(ZStack { Color(white: 0.08); VStack(alignment: .trailing, spacing: 40) { TacheView(lib: lib, t: t1); TacheView(lib: lib, t: t2); TacheView(lib: lib, t: t3) } }, "tache.png")
            rendre(BienvenueView(lib: lib, apercu: true), "bienvenue.png")
            // l'écran de démarrage réel (couches Core Animation), dans son état d'arrivée
            let oc = OuvertureCouches(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080)); oc.layout()
            if let l = oc.layer, let ctx = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                l.render(in: ctx)
                if let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dossier).appendingPathComponent("ouverture-couches.png")) }
            }
            let o = ImageRenderer(content: OuvertureApercu(lib: lib, fige: true).frame(width: 1920, height: 1080)); o.scale = 1
            if let img = o.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dossier).appendingPathComponent("ouverture.png")) }
            exit(0)
        }
        Atelier.installerEmbarque()
        lib.load()
        // l'ouverture : le logo et le jingle, sauf si le réglage la coupe ; l'écran du premier lancement attend qu'elle soit passée
        let ouvre = lib.config.ouverture ?? true
        if ouvre { lib.ouverture = true; Sounds.shared.play("lancer") }
        if lib.config.mode == nil { DispatchQueue.main.asyncAfter(deadline: .now() + (ouvre ? 3.2 : 1.2)) { if self.lib.menu == nil, self.lib.running == nil { withAnimation(.easeInOut(duration: 0.5)) { self.lib.bienvenue = true } } } }   // premier lancement : choisir le mode d'utilisation
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem); let sub = NSMenu()
        sub.addItem(withTitle: "Recharger la liste", action: #selector(reload), keyEquivalent: "r")
        sub.addItem(withTitle: "HUD en jeu", action: #selector(toggleHUD), keyEquivalent: "h")
        sub.addItem(withTitle: "Espace plein écran / fenêtre bureau", action: #selector(toggleSpace), keyEquivalent: "f")
        sub.addItem(withTitle: "Écran suivant", action: #selector(nextScreen), keyEquivalent: "e")
        sub.addItem(.separator()); sub.addItem(withTitle: "Quitter Home", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = sub
        // Édition : sans ce menu, ⌘V / ⌘C / ⌘A n'arrivent pas aux champs de texte ni à la page de connexion ; macOS y ajoute aussi
        // « Remplissage automatique → Mots de passe… »
        let edItem = NSMenuItem(); let ed = NSMenu(title: "Édition")
        ed.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        ed.addItem(.separator())
        ed.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        ed.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        ed.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        ed.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edItem.submenu = ed; menu.addItem(edItem)
        NSApp.mainMenu = menu
        let frame = (NSScreen.screens.first ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)   // écran principal (barre des menus), pas celui du Finder
        // Le Salon est un « bureau » : une fenêtre noire sans bordure qui couvre tout l'écran, barre des menus et Dock masqués.
        // Ce n'est pas un Space plein écran macOS : les jeux s'ouvrent donc PAR-DESSUS, sur ce fond noir, et le HUD reste visible.
        let window = SalonWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        window.title = "Home"; window.backgroundColor = .black; window.isOpaque = true; window.hasShadow = false
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.isMovable = false
        // le bouton rouge de macOS en haut à gauche (en plein écran, il apparaît en approchant la souris du haut) : il ferme Home
        for b in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        window.level = .normal; window.collectionBehavior = [.fullScreenPrimary]; window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = false
        window.contentView = NSHostingView(rootView: RootView(lib: lib))
        // HUD transparent au-dessus de tout (y compris des jeux plein écran), ne prend jamais la souris
        let hud = HUDPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.backgroundColor = .clear; hud.isOpaque = false; hud.hasShadow = false; hud.ignoresMouseEvents = true; hud.hidesOnDeactivate = false
        hud.level = .screenSaver; hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hud.contentView = NSHostingView(rootView: HUDView(lib: lib)); hud.orderOut(nil)
        self.window = window; self.hud = hud      // les deux existent avant toute notification d'écran (le masquage de la barre des menus en déclenche une)
        window.setFrame(frame, display: true); window.makeKeyAndOrderFront(nil); NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        // Espace plein écran dédié (par défaut) : Stage Manager et le Dock n'existent pas dans un espace plein écran. Sinon : fenêtre « bureau » couvrant l'écran.
        if lib.config.espacePleinEcran ?? true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } }
        } else { NSApp.presentationOptions = [.hideMenuBar, .hideDock] }
        lib.$running.receive(on: DispatchQueue.main).sink { [weak self] running in
            guard let self, let hud = self.hud else { return }
            // Pendant le jeu, le HUD reste caché : une fenêtre transparente au-dessus du jeu (et le flou de la capsule de l'heure) obligeait macOS
            // à recomposer chaque image (« Composited ») et coûtait du GPU. Il n'apparaît qu'avec le menu rapide.
            if running != nil { let sc = self.lib.gameScreen; hud.setFrame(sc.frame, display: true); hud.orderOut(nil); log("HUD prêt sur \(sc.localizedName) — caché pendant le jeu, visible avec le menu rapide") } else { hud.orderOut(nil) }
        }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: .salonNextScreen, object: nil, queue: .main) { [weak self] _ in self?.nextScreen() }
        NotificationCenter.default.addObserver(forName: .salonQuick, object: nil, queue: .main) { [weak self] _ in self?.lib.toggleQuick() }
        // Pendant un jeu : la fenêtre du Salon passe SOUS le niveau normal — le jeu reste toujours au-dessus, même si on clique sur le fond noir
        NotificationCenter.default.addObserver(forName: .salonHide, object: nil, queue: .main) { [weak self] _ in guard let self, !self.fullSpace else { return }; self.window?.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1) }
        NotificationCenter.default.addObserver(forName: .salonToggleSpace, object: nil, queue: .main) { [weak self] _ in self?.toggleSpace() }
        NotificationCenter.default.addObserver(forName: .salonTakeInput, object: nil, queue: .main) { [weak self] _ in
            guard let self, let hud = self.hud else { return }
            self.gameApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "fr.anas.salon" ? self.gameApp : NSWorkspace.shared.frontmostApplication
            hud.orderFrontRegardless()
            if PadSeize.shared.take() { log("Menu rapide : manette saisie (HID exclusif) — le jeu reste au premier plan") }
            else {   // secours : le Salon devient actif pour que les jeux GameController ne lisent plus la manette ; barre des menus masquée
                if !self.fullSpace { NSApp.presentationOptions = [.hideMenuBar, .hideDock] }
                NSApp.activate(ignoringOtherApps: true); hud.makeKey(); log("Menu rapide : saisie HID impossible, Salon activé à la place (\(self.gameApp?.localizedName ?? "?"))")
            }
        }
        NotificationCenter.default.addObserver(forName: .salonGiveInput, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in if let self, !self.lib.quick { self.hud?.orderOut(nil) } }   // le HUD disparaît après l'animation de fermeture
            if PadSeize.shared.active { PadSeize.shared.release(); log("Menu rapide : manette rendue au jeu (HID libéré)") }
            else if let a = self.gameApp ?? self.lib.watchedApp, !a.isTerminated, NSApp.isActive { a.activate(); log("Menu rapide : manette rendue à \(a.localizedName ?? "?")") }
        }
        NotificationCenter.default.addObserver(forName: .salonShow, object: nil, queue: .main) { [weak self] _ in
            guard let self, let w = self.window else { return }
            w.level = .normal
            if !self.fullSpace, let sc = NSScreen.main { w.setFrame(sc.frame, display: true) }
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); NSApp.unhide(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true); w.orderFrontRegardless(); log("Retour au Salon : 2e tentative d'activation") } }
        }
        GCController.shouldMonitorBackgroundEvents = true   // la manette continue d'arriver au Salon pendant le jeu (menu rapide, retour)
        registerHotKey()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if NSApp.modalWindow != nil || e.window?.firstResponder is NSText { return e }   // saisie de texte : le clavier va au champ
            if e.window?.identifier?.rawValue == "connexion" { return e }   // la fenêtre de connexion (page web d'Epic) garde son clavier
            guard let self else { return e }
            if e.modifierFlags.contains(.command) { return e }
            let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
            switch e.keyCode {
            case 123: self.nav("left"); return nil
            case 124: self.nav("right"); return nil
            case 125: self.nav("down"); return nil
            case 126: self.nav("up"); return nil
            case 36, 76, 49: self.nav("ok"); return nil
            case 48: self.lib.moveCategory(e.modifierFlags.contains(.shift) ? -1 : 1); return nil   // Tab
            case 53: self.nav("back"); return nil
            default:
                if ch == "o" || ch == "y" { self.nav("options"); return nil }
                if ch == "t", self.lib.showOptions { self.nav("tri"); return nil }
                if (ch == "+" || ch == "=" || ch == "n"), !self.lib.showOptions, self.lib.picker == nil { self.nav("plus"); return nil }
                return e
            }
        }
        pad = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.pollPad() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.lib.appTerminee(a) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // une autre app passe devant : si c'est le jeu laissé ouvert derrière Home, sa session reprend (menu rapide, volume)
            guard a.processIdentifier == ProcessInfo.processInfo.processIdentifier else { self.lib.appActivee(a); return }
            // Pendant les 40 premières secondes d'un jeu, macOS peut nous réactiver un instant (écran de démarrage, anti-triche) : on l'ignore,
            // sinon la session était considérée finie et un 2e appui relançait le jeu (« une seule instance d'Easy Anti-Cheat »).
            if self.lib.running == nil { self.lib.load() }
        }
    }
    let demarrage = Date()
    func nav(_ k: String) {
        // pendant la première seconde et demie, rien n'est pris en compte : un bouton tenu ou pressé au moment où Home (re)démarre
        // lançait le premier jeu de la liste sans qu'on le veuille
        if Date().timeIntervalSince(demarrage) < 1.5 { return }   // les appuis parasites du démarrage ne lancent rien, et ne coupent pas l'écran de démarrage
        if lib.ouverture { lib.passerOuverture(); return }   // n'importe quelle touche ou bouton passe l'ouverture
        if lib.bienvenue {   // l'accueil : gauche / droite pour choisir, valider pour commencer ; « Ignorer » est sur Options seulement
            switch k { case "left": lib.bienvenueBouger(-1); case "right": lib.bienvenueBouger(1); case "ok": lib.bienvenueValider(); case "options": lib.bienvenueIgnorer(); default: break }
            return
        }
        if let p = lib.picker {
            _ = p
            if lib.pickerSaisie { if k == "up" || k == "back" { lib.pickerSaisie = false; Sounds.shared.play("deplacer") }; return }
            switch k { case "left": lib.pickSuivant(-1); case "right": lib.pickSuivant(1); case "options", "down": lib.pickerSaisie = true; Sounds.shared.play("deplacer"); case "ok": Sounds.shared.play("valider"); lib.pickCandidate(); case "back", "options": lib.closeMenu(); default: break }
            return
        }
        if lib.menu != nil { if k == "back" || k == "options" { lib.closeMenu() } else { NotificationCenter.default.post(name: .salonNav, object: k) }; return }
        if k == "back", lib.fermerTache() { return }
        switch k {
        case "left": lib.move(-1); case "right": lib.move(1); case "up": lib.moveCategory(-1); case "down": lib.moveCategory(1)
        case "ok": lib.launch(); case "options": lib.openOptions(); case "plus": lib.openPlusMenu()
        case "back": lib.openQuitter()
        default: break
        }
    }
    @objc func reload() { lib.load() }
    @objc func toggleHUD() { lib.toggleQuick() }
    /// ⌥ Espace, même quand le jeu a le clavier : ouvre/ferme le menu rapide (aucune autorisation nécessaire)
    var hotKey: EventHotKeyRef? = nil
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in NotificationCenter.default.post(name: .salonQuick, object: nil); return noErr }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: 0x53414C4E, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
    @objc func nextScreen() {
        let screens = NSScreen.screens; guard screens.count > 1 else { lib.toast = "Un seul écran branché"; return }
        let i = window?.screen.flatMap { screens.firstIndex(of: $0) } ?? 0; let next = screens[(i + 1) % screens.count]
        if fullSpace, let w = window { w.toggleFullScreen(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { w.setFrame(next.frame, display: true); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { w.toggleFullScreen(nil) } } }
        else { window?.setFrame(next.frame, display: true) }
        hud?.setFrame(next.frame, display: true)
        lib.toast = "Écran : \(next.localizedName) (\(Int(next.frame.width))×\(Int(next.frame.height)))"
    }
    var fullSpace: Bool { window?.styleMask.contains(.fullScreen) == true }
    func applicationDidBecomeActive(_ n: Notification) { guard let w = window, !fullSpace else { return }; NSApp.presentationOptions = [.hideMenuBar, .hideDock]; if let sc = w.screen { w.setFrame(sc.frame, display: true) } }
    func applicationDidChangeScreenParameters(_ n: Notification) { if let w = window, !fullSpace, let sc = w.screen { w.setFrame(sc.frame, display: true); hud?.setFrame(sc.frame, display: true) } }
    @objc func toggleSpace() {
        guard let w = window else { return }
        lib.config.espacePleinEcran = !(lib.config.espacePleinEcran ?? true); lib.saveConfig()
        if (lib.config.espacePleinEcran ?? true) != fullSpace { w.toggleFullScreen(nil) }
        if !(lib.config.espacePleinEcran ?? true) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.presentationOptions = [.hideMenuBar, .hideDock]; if let sc = w.screen { w.setFrame(sc.frame, display: true) } } }
        lib.toast = (lib.config.espacePleinEcran ?? true) ? "Espace plein écran dédié" : "Fenêtre bureau (les jeux s'ouvrent par-dessus)"
    }
    var padID: ObjectIdentifier? = nil
    func pollPad() {
        guard let c = GCController.controllers().first, let gp = c.extendedGamepad else { if lib.hints.name != nil { lib.hints = .keyboard; padID = nil }; return }
        let cat = c.productCategory.lowercased()
        let isSwitch = cat.contains("switch") || cat.contains("joy-con") || cat.contains("nintendo")
        let okB = isSwitch ? gp.buttonB : gp.buttonA, backB = isSwitch ? gp.buttonA : gp.buttonB   // Nintendo : A à droite valide, B en bas revient
        // Le bouton « Salon » (menu du Salon, HUD en jeu, maintenu 1 s : retour) : le pavé tactile sur PlayStation, sinon Share/View/− ; rien d'autre n'y est lié
        let salonB: GCControllerButtonInput? = (gp as? GCDualShockGamepad)?.touchpadButton ?? (gp as? GCDualSenseGamepad)?.touchpadButton ?? gp.buttonOptions
        if padID != ObjectIdentifier(c) {
            padID = ObjectIdentifier(c)
            func k(_ b: GCControllerButtonInput?, _ t: String) -> Key { Key(symbol: b?.sfSymbolsName, text: t) }
            lib.hints = PadHints(ok: k(okB, isSwitch ? "A" : "A"), back: k(backB, "B"),
                                 options: k(gp.buttonMenu, cat.contains("dualshock") || cat.contains("dualsense") ? "Options" : isSwitch ? "+" : "Menu"),
                                 plus: k(salonB, (gp is GCDualShockGamepad || gp is GCDualSenseGamepad) ? "Pavé" : isSwitch ? "−" : "View"),
                                 cat: Key(symbol: nil, text: isSwitch ? "L R" : cat.contains("xbox") ? "LB RB" : "L1 R1"),
                                 name: c.vendorName ?? c.productCategory, tri: k(gp.buttonY, isSwitch ? "X" : "Y"))
            log("Manette : \(c.vendorName ?? "?") — \(c.productCategory) — pavé:\(gp is GCDualShockGamepad || gp is GCDualSenseGamepad ? "oui" : "non")")
        }
        // Navigation : un cran par impulsion ; maintenu, répétition après 0,6 s puis toutes les 0,3 s (sondage à 20 Hz). Stick : zone morte large (0,65)
        // Stick moins sensible (user 2026-11-10) : il faut le pousser franchement (0,8) pour un cran, il reste engagé jusqu'à 0,45
        // (pas de crans parasites en relâchant), seul l'axe dominant compte (une diagonale ne bouge plus dans deux sens), et la
        // répétition en le maintenant est plus lente que celle de la croix (après 0,8 s, puis toutes les 0,45 s).
        let sx = gp.leftThumbstick.xAxis.value, sy = gp.leftThumbstick.yAxis.value
        let seuilX: Float = lastX != 0 ? 0.45 : 0.8, seuilY: Float = lastY != 0 ? 0.45 : 0.8
        let stickX: Int = abs(sx) >= abs(sy) && abs(sx) > seuilX ? (sx < 0 ? -1 : 1) : 0
        let stickY: Int = abs(sy) > abs(sx) && abs(sy) > seuilY ? (sy > 0 ? -1 : 1) : 0
        let croixX = gp.dpad.left.isPressed ? -1 : gp.dpad.right.isPressed ? 1 : 0, croixY = gp.dpad.up.isPressed ? -1 : gp.dpad.down.isPressed ? 1 : 0
        let x = croixX != 0 ? croixX : stickX, y = croixY != 0 ? croixY : stickY
        let (debutX, pasX) = croixX != 0 ? (12, 6) : (16, 9), (debutY, pasY) = croixY != 0 ? (12, 6) : (16, 9)
        if x != 0 { heldX += 1; if x != lastX || heldX == 1 || (heldX > debutX && heldX % pasX == 0) { nav(x < 0 ? "left" : "right") } } else { heldX = 0 }
        if y != 0 { heldY += 1; if y != lastY || heldY == 1 || (heldY > debutY && heldY % pasY == 0) { nav(y < 0 ? "up" : "down") } } else { heldY = 0 }
        lastX = x; lastY = y
        if lib.running != nil {
            if lib.quick, Date().timeIntervalSince(lib.lastInput) > 10 { lib.toggleQuick() }   // menu rapide oublié : il se referme et rend la manette
            // Pendant le menu rapide la manette est saisie en exclusif : on lit l'état HID (GameController ne reçoit plus rien, le jeu non plus)
            let seized = lib.quick && PadSeize.shared.active
            let s: PadSnap = seized ? PadSeize.shared.snapshot() : PadSnap(
                lx: gp.leftThumbstick.xAxis.value, ly: gp.leftThumbstick.yAxis.value, rx: gp.rightThumbstick.xAxis.value, ry: gp.rightThumbstick.yAxis.value,
                dx: gp.dpad.left.isPressed ? -1 : gp.dpad.right.isPressed ? 1 : 0, dy: gp.dpad.up.isPressed ? 1 : gp.dpad.down.isPressed ? -1 : 0,
                ok: okB.isPressed, back: backB.isPressed, salon: salonB?.isPressed == true, tri: gp.buttonY.isPressed)
            let homeNow = s.salon   // en jeu : le bouton Salon seulement (pavé tactile), le reste appartient au jeu
            if homeNow, prev["home"] != true { log("Manette en jeu : menu rapide (bouton Salon)"); lib.toggleQuick() }
            prev["home"] = homeNow
            holdMenu = homeNow ? holdMenu + 1 : 0
            if holdMenu == 20 { log("Manette en jeu : bouton Salon maintenu → retour au Salon"); if lib.quick { lib.toggleQuick() }; lib.overlay = false; lib.backToSalon(); NSApp.activate(ignoringOtherApps: true) }
            defer { prev["ok"] = s.ok; prev["back"] = s.back; prev["tri"] = s.tri }
            if lib.quick {
                let now = Date().timeIntervalSince1970
                // stick : comme dans le Salon, il faut le pousser franchement (0,8) pour partir, 0,45 pour continuer, l'axe dominant seulement
                let seuilQX: Float = qLastX != 0 ? 0.45 : 0.8, seuilQY: Float = qLastY != 0 ? 0.45 : 0.8
                let x = s.dx != 0 ? s.dx : (abs(s.lx) >= abs(s.ly) && abs(s.lx) > seuilQX ? (s.lx < 0 ? -1 : 1) : 0)
                let stickQ = s.dx == 0 && x != 0
                if x != 0 { qHeldX += 1 } else { qHeldX = 0 }
                let general = lib.quickIndex == 4   // carte « Volume général » : le stick droit, le curseur et △ agissent sur le général, sinon sur les jeux
                func adjust(_ d: Float, quiet: Bool) { if general { lib.macStep(d, quiet: quiet) } else { lib.volumeStep(d, quiet: quiet) } }
                if s.tri, prev["tri"] != true { if general { lib.toggleMacMute() } else { lib.toggleGameMute() }; lib.lastInput = Date() }
                if lib.quickJoueurs {
                    if (s.back && prev["back"] != true) || (s.ok && prev["ok"] != true) { lib.quickJoueurs = false; Sounds.shared.play("retour"); lib.lastInput = Date() }
                } else if lib.quickSlider {
                    // curseur ouvert : stick gauche / flèches ◀▶ règlent le volume (fin au stick, par pas de 5 % aux flèches), ○ ou ✕ referment le curseur
                    if s.dx != 0, s.dx != qLastX || qHeldX == 1 || (qHeldX > 8 && qHeldX % 3 == 0) { adjust(s.dx < 0 ? -0.05 : 0.05, quiet: false); Sounds.shared.play("volume") }
                    else if s.dx == 0, abs(s.lx) > 0.45 { adjust(s.lx * abs(s.lx) * 0.008, quiet: true); if Int(now * 20) % 6 == 0 { Sounds.shared.play("volume") } }
                    if (s.back && prev["back"] != true) || (s.ok && prev["ok"] != true) { lib.quickSlider = false; Sounds.shared.play("retour"); lib.lastInput = Date() }
                } else {
                    if x != 0, x != qLastX || qHeldX == 1 || (stickQ ? qHeldX > 16 && qHeldX % 9 == 0 : qHeldX > 12 && qHeldX % 6 == 0) {   // gauche/droite : les cartes
                        let n = min(max(lib.quickIndex + x, 0), lib.quickItems.count - 1)
                        if lib.quickIndex != n { lib.quickIndex = n; Sounds.shared.play("deplacer") }
                        lib.lastInput = Date()
                    }
                    let y = s.dy != 0 ? s.dy : (abs(s.ly) > abs(s.lx) && abs(s.ly) > seuilQY ? (s.ly > 0 ? 1 : -1) : 0)
                    if y != 0 { qHeldY += 1 } else { qHeldY = 0 }
                    if y != 0, lib.quickIndex == 3 || general, y != qLastY || qHeldY == 1 || (qHeldY > 8 && qHeldY % 3 == 0) { adjust(y > 0 ? 0.05 : -0.05, quiet: false); Sounds.shared.play("volume") }   // haut/bas sur une carte Volume
                    qLastY = y
                    if s.ok, prev["ok"] != true { lib.quickAct() }
                    if s.back, prev["back"] != true { lib.toggleQuick() }
                }
                qLastX = x
                if abs(s.rx) > 0.5 { adjust(s.rx * abs(s.rx) * 0.006, quiet: true); if Int(now * 20) % 6 == 0 { Sounds.shared.play("volume") } }   // stick droit : volume, partout dans le HUD (comme dans le Salon)
                if s.ok || s.back || abs(s.rx) > 0.5 { lib.lastInput = Date() }
            }
            return   // pendant un jeu, le Salon ne réagit à rien d'autre
        }
        let rxs = gp.rightThumbstick.xAxis.value
        if abs(rxs) > 0.5, lib.picker == nil { lib.macStep(rxs * abs(rxs) * 0.006, quiet: true); if Int(Date().timeIntervalSince1970 * 20) % 6 == 0 { Sounds.shared.play("volume") } }   // stick droit : volume général du Mac
        if gp.buttonY.isPressed, prev["tri"] != true, lib.picker == nil { if lib.showOptions { nav("tri") } else { lib.toggleMacMute() } }   // dans un menu : actualiser
        prev["tri"] = gp.buttonY.isPressed
        let buttons: [(String, Bool, String)] = [("ok", okB.isPressed, "ok"), ("back", backB.isPressed, "back"), ("menu", gp.buttonMenu.isPressed, "options"),
                                                  ("home", salonB?.isPressed == true, "plus"), ("l1", gp.leftShoulder.isPressed, "catL"), ("r1", gp.rightShoulder.isPressed, "catR")]
        for (name, pressed, action) in buttons {
            if pressed && prev[name] != true {
                if action == "catL" { lib.moveCategory(-1) } else if action == "catR" { lib.moveCategory(1) }
                else { nav(action) }   // retour compris : sur la bibliothèque, il ferme la carte d'une tâche finie, sinon propose de quitter Home
            }
            prev[name] = pressed
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
@main struct SalonMain { static let delegate = AppDelegate(); static func main() { let app = NSApplication.shared; app.delegate = delegate; app.run() } }

// MARK: - Atelier : mods, mises à jour et construction des jeux, depuis le Salon
// Les opérations longues (construction d'un jeu, manifeste des mods MacNativeGames, mise à jour du moteur) tournent dans
// une fenêtre Terminal, par des scripts de /Applications/Jeux/moteur : le Salon écrit un petit lanceur .command et l'ouvre.
// Les mods sont rangés dans Salon/mods/<jeu>/<mod>/ ; actifs.json donne ceux qui sont activés (le plus récent en premier).
enum Atelier {
    static let jeux = Dossiers.jeux
    static let home = Dossiers.home   // Home.app à côté ; ici le moteur, MacNativeGames, les constructions, les journaux
    /// TOTK Online : l'adresse du serveur (ip:port) que le Salon donne au jeu à la place du joueur (TOTK_SWKBD_FIRST), lue dans
    /// serveurs/totk-adresse.txt (une ligne, ex. 203.0.113.10:10014 pour un serveur distant) ; sans ce fichier, le serveur local, que le Salon démarre lui-même
    static func totkAdresse() -> String {
        let s = ((try? String(contentsOf: home.appendingPathComponent("serveurs/totk-adresse.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "127.0.0.1:10014" : s
    }
    static func totkLocal() -> Bool { let a = totkAdresse(); return a.hasPrefix("127.0.0.1") || a.hasPrefix("localhost") }
    static let moteur = home.appendingPathComponent("moteur")
    static let constructions = home.appendingPathComponent("constructions")
    static let registreURL = home.appendingPathComponent("registre.json")
    static let modsRoot = salonRoot.appendingPathComponent("mods")
    enum Moteur { case nxnative, mng, pc, mac }
    /// Un jeu construit par le Salon (sources/registre.json, écrit par construire-jeu.command) : ce qu'il faut pour le refaire.
    /// travail : son dossier de construction (les fichiers du jeu déjà extraits) ; base / update / dlc : les fichiers donnés la dernière fois
    struct Inscription: Codable { var moteur: String; var base: String; var update: [String]; var dlc: [String]; var modModule: String?; var travail: String?; var titre: String? }
    struct Mod { let name: String; let url: URL; let romfs: URL?; let exefs: URL?; var actif: Bool }

    static func moteurDe(_ g: Game) -> Moteur {
        if g.viaHome { return .pc }
        if g.titleID != nil { return .nxnative }
        if (Bundle(url: g.url)?.bundleIdentifier ?? "").hasPrefix("org.macnativegames.") { return .mng }
        return .mac
    }
    /// Switch 2 : les title ID commencent par 04
    static func switch2(_ g: Game) -> Bool { (g.storeID ?? "").uppercased().hasPrefix("04") }
    /// Les mods (GameBanana, RomFS, code) : les jeux Switch et Switch 2 construits (nxnative, MacNativeGames), pas les jeux PC ni Mac
    static func modsPossibles(_ g: Game) -> Bool { let m = moteurDe(g); return m == .nxnative || m == .mng }
    /// Les listes GameBanana déjà lues (jeu|page|tri|recherche) : revenir d'une fiche ou basculer un mod ne relit pas le réseau
    static var cacheGB: [String: (recs: [[String: Any]], complet: Bool)] = [:]
    /// Le nom à chercher sur GameBanana : les abréviations des noms d'app développées, MNG / Online / numéros de version retirés
    static func nomRecherche(_ g: Game) -> String {
        if (Bundle(url: g.url)?.bundleIdentifier ?? "").hasPrefix("org.macnativegames.totk") { return "Tears of the Kingdom" }
        if (Bundle(url: g.url)?.bundleIdentifier ?? "").hasPrefix("org.macnativegames.botw") { return "Breath of the Wild" }
        var n = " " + g.name + " "
        for (a, b) in [("TOTK", "Tears of the Kingdom"), ("BOTW", "Breath of the Wild"), ("SMO", "Super Mario Odyssey"), ("MK8", "Mario Kart 8")] {
            n = n.replacingOccurrences(of: #"(?i)\b\#(a)\b"#, with: b, options: .regularExpression) }
        n = n.replacingOccurrences(of: #"(?i)\b(MNG|online|switch 2|nintendo switch|edition|v?\d+(\.\d+)+)\b"#, with: " ", options: .regularExpression)
        return n.replacingOccurrences(of: #"[:™®]"#, with: " ", options: .regularExpression).components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// Le jeu GameBanana dont le nom ressemble le plus (mots en commun, nom identique en premier)
    static func meilleurJeu(_ nom: String, _ recs: [[String: Any]]) -> Int? {
        func mots(_ s: String) -> Set<String> {
            Set(s.lowercased().folding(options: .diacriticInsensitive, locale: nil).components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 && !["the", "of", "la", "le", "les", "de", "du", "and", "et"].contains($0) })
        }
        let a = mots(nom); var best: (id: Int, score: Double)? = nil
        for r in recs {
            guard let id = r["_idRow"] as? Int, let n = r["_sName"] as? String else { continue }
            let b = mots(n); let score = Double(a.intersection(b).count) / Double(max(1, a.union(b).count)) + (b == a ? 1 : 0)
            if score > (best?.score ?? 0) { best = (id, score) }
        }
        return best?.id
    }
    static func slug(_ s: String) -> String {
        let t = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._- ".unicodeScalars.contains($0) ? Character($0) : "-" }
        return String(String(t).trimmingCharacters(in: .whitespaces).prefix(80))
    }
    static func cle(_ g: Game) -> String { g.storeID ?? slug(g.name) }
    static func dossier(_ g: Game) -> URL { modsRoot.appendingPathComponent(cle(g)) }

    // Mods installés : chaque sous-dossier (sauf _telechargements) ; romfs/ et exefs/ cherchés jusqu'à 4 niveaux
    static func trouve(_ nom: String, dans u: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        for case let f as URL in e {
            if e.level > 4 { e.skipDescendants(); continue }
            if f.lastPathComponent.lowercased() == nom, (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return f }
        }
        return nil
    }
    static func actifs(_ g: Game) -> [String] {
        guard let d = try? Data(contentsOf: dossier(g).appendingPathComponent("actifs.json")), let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return a
    }
    static func enregistrer(_ g: Game, actifs: [String]) {
        try? FileManager.default.createDirectory(at: dossier(g), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(actifs) { try? d.write(to: dossier(g).appendingPathComponent("actifs.json")) }
    }
    static func mods(_ g: Game) -> [Mod] {
        let on = actifs(g)
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: dossier(g), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "_telechargements" }
        return dirs.map { Mod(name: $0.lastPathComponent, url: $0, romfs: trouve("romfs", dans: $0), exefs: trouve("exefs", dans: $0), actif: on.contains($0.lastPathComponent)) }
            .sorted { ($0.actif ? 0 : 1, $0.name.lowercased()) < ($1.actif ? 0 : 1, $1.name.lowercased()) }
    }
    /// nxnative : les dossiers romfs des mods activés, lus avant ceux du jeu (DM_ROMFS_OVERLAY), le plus récent d'abord
    /// et, après eux, le romfs/ des mods de code que le moteur applique tout seul (moteur/exefs-mods/<title id>/<mod>/ : SMO Online)
    static func romfsOverlay(cle: String) -> String? {
        let dir = modsRoot.appendingPathComponent(cle)
        var paths: [String] = []
        if let d = try? Data(contentsOf: dir.appendingPathComponent("actifs.json")), let on = try? JSONDecoder().decode([String].self, from: d) {
            paths = on.compactMap { n -> String? in let u = dir.appendingPathComponent(n); return FileManager.default.fileExists(atPath: u.path) ? (trouve("romfs", dans: u) ?? u).path : nil }
        }
        let auto = moteur.appendingPathComponent("exefs-mods/\(cle)")
        for m in ((try? FileManager.default.contentsOfDirectory(at: auto, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).sorted(by: { $0.path < $1.path }) {
            let r = m.appendingPathComponent("romfs"); if FileManager.default.fileExists(atPath: r.path) { paths.append(r.path) }
        }
        paths = paths.filter { !$0.contains(":") }
        return paths.isEmpty ? nil : paths.joined(separator: ":")
    }
    static let outils = moteur.appendingPathComponent("outils")
    /// Home autonome : le moteur que l'app embarque (Contents/Resources/moteur : scripts, outils, version figée des moteurs) est
    /// installé dans <Home>/moteur quand son empreinte n'est pas celle déjà installée — au premier lancement, puis après une mise à jour de l'app
    static func installerEmbarque() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("moteur"), let neuf = try? String(contentsOf: src.appendingPathComponent(".empreinte"), encoding: .utf8) else { return }
        if neuf == (try? String(contentsOf: moteur.appendingPathComponent(".embarque"), encoding: .utf8)) { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [src.appendingPathComponent("outils/installer-embarque.sh").path, src.path]
        p.environment = ProcessInfo.processInfo.environment.merging(Dossiers.env, uniquingKeysWith: { $1 })
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { log("Moteur embarqué : installation impossible"); return }
        let sortie = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit()
        log("Moteur embarqué (\(neuf.prefix(12))) : " + sortie.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " · "))
    }
    /// Les moteurs des jeux Switch sont-ils là ? (nxnative récupéré et patché, MacNativeGames cloné)
    static var nxnativePret: Bool { FileManager.default.fileExists(atPath: moteur.appendingPathComponent("engine/scripts/build_ipa_from_nsp.py").path) }
    static var mngPret: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent("MacNativeGames/build_app.py").path) }
    /// Les jeux que MacNativeGames sait construire : Tears of the Kingdom et Breath of the Wild (title ID)
    static let jeuxMNG = ["0100F2C0115B6000": "Zelda: Tears of the Kingdom", "01007EF00011E000": "Zelda: Breath of the Wild"]
    /// Les title ID qu'un NSP nomme dans sa table de fichiers (tickets, certificats : <title id><génération>.tik), sinon rien
    static func titresNSP(_ u: URL) -> [String] {
        guard let f = try? FileHandle(forReadingFrom: u) else { return [] }
        defer { try? f.close() }
        guard let h = try? f.read(upToCount: 16), h.count == 16, h.prefix(4) == Data("PFS0".utf8) else { return [] }
        func u32(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 | Int(d[d.startIndex + o + 2]) << 16 | Int(d[d.startIndex + o + 3]) << 24 }
        let n = u32(h, 4), taille = u32(h, 8)
        guard n > 0, n < 4096, taille < 1 << 20, let reste = try? f.read(upToCount: n * 24 + taille), reste.count == n * 24 + taille else { return [] }
        let noms = String(decoding: reste.suffix(taille), as: UTF8.self).uppercased()
        var ids: [String] = []
        noms.enumerateSubstrings(in: noms.startIndex..., options: .byWords) { w, _, _, _ in if let w, w.count >= 16, w.hasPrefix("01") || w.hasPrefix("04") { ids.append(String(w.prefix(16))) } }
        return ids
    }
    /// Le moteur recommandé pour une ROM : MacNativeGames pour les jeux qu'il connaît (title ID du NSP, ou nom du fichier), nxnative sinon
    static func moteurRecommande(_ u: URL?) -> (moteur: String, jeu: String?) {
        guard let u else { return ("nxnative", nil) }
        for t in titresNSP(u) { if let j = jeuxMNG[String(t.prefix(13)) + "000"] ?? jeuxMNG[t] { return ("mng", j) } }
        let n = u.lastPathComponent.lowercased()
        if n.contains("totk") || n.contains("tears of the kingdom") || n.contains("0100f2c0115b6000") { return ("mng", jeuxMNG["0100F2C0115B6000"]) }
        if n.contains("botw") || n.contains("breath of the wild") || n.contains("01007ef00011e000") { return ("mng", jeuxMNG["01007EF00011E000"]) }
        return ("nxnative", nil)
    }

    /// Les réglages nxnative d'un jeu (~/Library/Application Support/nxnative/<title id>/env.txt, une ligne CLÉ=valeur)
    static func envURL(_ tid: String) -> URL { appSupport.appendingPathComponent("nxnative/\(tid)/env.txt") }
    static func env(_ tid: String) -> [String: String] {
        var d: [String: String] = [:]
        for l in ((try? String(contentsOf: envURL(tid), encoding: .utf8)) ?? "").components(separatedBy: "\n") {
            guard let i = l.firstIndex(of: "=") else { continue }; d[String(l[..<i])] = String(l[l.index(after: i)...])
        }
        return d
    }
    static func setEnv(_ tid: String, _ key: String, _ value: String?) {
        let f = envURL(tid)
        var lines = ((try? String(contentsOf: f, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix(key + "=") }
        if let value { lines.append("\(key)=\(value)") }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
    }
    /// Le dossier de construction nxnative d'un jeu (le jeu déjà extrait) : celui du registre, sinon <title id>_build ou <title id>_<…>_build
    static func dossierBuild(_ g: Game) -> String? {
        if let t = registre()[g.url.path]?.travail, FileManager.default.fileExists(atPath: t + "/extract") { return t }
        guard let tid = g.titleID?.uppercased() else { return nil }
        let fm = FileManager.default
        for d in ((try? fm.contentsOfDirectory(at: constructions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []) where fm.fileExists(atPath: d.path + "/extract") {
            let t = ((try? String(contentsOf: d.appendingPathComponent(".title-id"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let src = (try? Data(contentsOf: d.appendingPathComponent("source.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if t == tid || ((src?["app"] as? String) ?? "").uppercased() == tid { return d.path }
        }
        return nil
    }

    static func registre() -> [String: Inscription] {
        guard let d = try? Data(contentsOf: registreURL), let r = try? JSONDecoder().decode([String: Inscription].self, from: d) else { return [:] }
        return r
    }
    /// Un jeu MacNativeGames : son dossier de données (Application Support/MacNativeGames/…), son journal, son sous-dossier de construction
    static func dossiersMNG(_ bundle: String) -> (donnees: String, journal: String, court: String)? {
        if bundle.hasPrefix("org.macnativegames.oot") { return ("OcarinaOfTime", "ocarina", "oot") }
        if bundle.hasPrefix("org.macnativegames.totk") { return ("TOTK", "totk", "totk") }
        if bundle.hasPrefix("org.macnativegames.botw") { return ("BotW", "botw", "botw") }
        return nil
    }
    /// Les jeux construits avant le registre ont leur propre script
    static func scriptDedie(_ g: Game) -> String? {
        if (Bundle(url: g.url)?.bundleIdentifier ?? "").hasPrefix("org.macnativegames.totk") { return "totk-mng-online.command" }
        return nil
    }

    /// Lance un script de moteur/outils/ dans le Terminal, avec ses arguments (un lanceur .command écrit dans moteur/.salon)
    @discardableResult
    static func terminal(_ script: String, _ args: [String] = [], env: [String: String] = [:]) -> Bool {
        let s = outils.appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: s.path) else { log("Atelier : \(script) introuvable"); return false }
        let dir = moteur.appendingPathComponent(".salon"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(d) > 86400 { try? FileManager.default.removeItem(at: f) }
        }
        func q(_ x: String) -> String { "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var txt = "#!/bin/bash\n"
        for (k, v) in Dossiers.env.merging(env, uniquingKeysWith: { $1 }) { txt += "export \(k)=\(q(v))\n" }
        txt += "exec /bin/bash " + ([s.path] + args).map(q).joined(separator: " ") + "\n"
        let w = dir.appendingPathComponent("\((script as NSString).deletingPathExtension)-\(Int(Date().timeIntervalSince1970)).command")
        do { try txt.write(to: w, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.path) }
        catch { log("Atelier : lanceur impossible (\(error.localizedDescription))"); return false }
        log("Atelier : \(script) \(args.joined(separator: " "))")
        return NSWorkspace.shared.open(w)
    }

    /// Extraction d'une archive de mod (zip par ditto, 7z / rar / tar par le tar de macOS)
    static func extraire(_ a: URL, vers d: URL) -> Bool {
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let p = Process()
        if a.pathExtension.lowercased() == "zip" { p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", a.path, d.path] }
        else { p.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); p.arguments = ["-xf", a.path, "-C", d.path] }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }

    // GameBanana (API publique v11)
    static let gb = "https://gamebanana.com/apiv11"
    static func json(_ s: String) async -> [String: Any]? {
        guard let u = URL(string: s) else { return nil }
        var r = URLRequest(url: u); r.setValue("Salon/1.0", forHTTPHeaderField: "User-Agent"); r.timeoutInterval = 20
        guard let res = try? await URLSession.shared.data(for: r) else { return nil }
        return (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any]
    }
    /// L'aperçu d'un mod GameBanana (sa première capture, 530 px)
    static func apercu(_ rec: [String: Any]) -> URL? {
        guard let imgs = (rec["_aPreviewMedia"] as? [String: Any])?["_aImages"] as? [[String: Any]], let i = imgs.first, let b = i["_sBaseUrl"] as? String,
              let f = (i["_sFile530"] as? String) ?? (i["_sFile"] as? String) else { return nil }
        return URL(string: b + "/" + f)
    }
    static func couverture(_ mod: URL) -> URL? { let u = mod.appendingPathComponent(".salon-cover.jpg"); return FileManager.default.fileExists(atPath: u.path) ? u : nil }
    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
}

extension Library {
    // MARK: Mods
    /// Le menu Mods, une grille : dossier, fichier, les mods installés, puis directement ceux de GameBanana (le jeu y est trouvé tout seul)
    func openModsMenu(_ g: Game, page: Int = 1, tri: String = "Generic_MostDownloaded", recherche: String? = nil) {
        let cle = config.gamebanana?[g.id].map { "\($0)|\(page)|\(tri)|\(recherche ?? "")" }
        if let cle, let c = Atelier.cacheGB[cle] { afficherMods(g, gb: c, page: page, tri: tri, recherche: recherche); return }
        afficherMods(g, gb: nil, page: page, tri: tri, recherche: recherche)
        Task {
            var id = self.config.gamebanana?[g.id]
            if id == nil {   // le jeu GameBanana : le nom officiel eShop s'il est connu, sinon le nom de l'app nettoyé ; le plus ressemblant
                var noms: [String] = []
                if let t = g.storeID, let off = await EShop.info(titleID: t)?.title, !off.isEmpty { noms.append(off) }
                noms.append(Atelier.nomRecherche(g))
                for n in noms where id == nil {
                    let r = await Atelier.json("\(Atelier.gb)/Util/Search/Results?_sModelName=Game&_sSearchString=\(Atelier.enc(n))&_nPage=1")
                    id = Atelier.meilleurJeu(n, (r?["_aRecords"] as? [[String: Any]]) ?? [])
                }
                if let id { await MainActor.run { var m = self.config.gamebanana ?? [:]; m[g.id] = id; self.config.gamebanana = m; self.saveConfig() } }
            }
            guard let id else { await MainActor.run { self.rafraichirMods(g, gb: ([], true), page: page, tri: tri, recherche: recherche, erreur: "Jeu introuvable sur GameBanana") }; return }
            let url = recherche.map { "\(Atelier.gb)/Util/Search/Results?_sModelName=Mod&_sSearchString=\(Atelier.enc($0))&_idGameRow=\(id)&_nPage=\(page)" }
                ?? "\(Atelier.gb)/Mod/Index?_nPerpage=15&_aFilters%5BGeneric_Game%5D=\(id)&_sSort=\(tri)&_nPage=\(page)"
            let r = await Atelier.json(url)
            let recs = ((r?["_aRecords"] as? [[String: Any]]) ?? []).filter { ($0["_sModelName"] as? String ?? "Mod") == "Mod" }
            let complet = ((r?["_aMetadata"] as? [String: Any])?["_bIsComplete"] as? Bool) ?? true
            await MainActor.run {
                if r != nil { Atelier.cacheGB["\(id)|\(page)|\(tri)|\(recherche ?? "")"] = (recs, complet) }
                self.rafraichirMods(g, gb: (recs, complet), page: page, tri: tri, recherche: recherche, erreur: r == nil ? "GameBanana ne répond pas" : nil)
            }
        }
    }
    /// Remplace le menu Mods affiché (s'il l'est encore) par celui qui a la liste GameBanana
    private func rafraichirMods(_ g: Game, gb: (recs: [[String: Any]], complet: Bool), page: Int, tri: String, recherche: String?, erreur: String?) {
        guard menu?.title == "Mods", (menu?.subtitle ?? "").hasPrefix(g.name) else { return }
        afficherMods(g, gb: gb, page: page, tri: tri, recherche: recherche, erreur: erreur)
    }
    private func afficherMods(_ g: Game, gb: (recs: [[String: Any]], complet: Bool)?, page: Int, tri: String, recherche: String?, erreur: String? = nil) {
        let mods = Atelier.mods(g); let m = Atelier.moteurDe(g)
        let ici: () -> Void = { self.openModsMenu(g, page: page, tri: tri, recherche: recherche) }
        var items: [SalonMenuItem] = [
            SalonMenuItem(label: "Dossier des mods", icon: "folder.fill", action: {
                self.menu = nil; try? FileManager.default.createDirectory(at: Atelier.dossier(g), withIntermediateDirectories: true); NSWorkspace.shared.open(Atelier.dossier(g)) }),
            SalonMenuItem(label: "Depuis un fichier", icon: "doc.badge.plus", action: { self.menu = nil; self.modDepuisFichier(g) }),
        ]
        for md in mods {
            var genre: [String] = []
            if md.romfs != nil { genre.append("RomFS") }
            if md.exefs != nil { genre.append("code") }
            if genre.isEmpty { genre.append("RomFS") }
            items.append(SalonMenuItem(label: md.name, detail: (md.actif ? "✓ Activé" : "Installé — A pour activer") + " · " + genre.joined(separator: ", "),
                                       icon: md.actif ? "checkmark.circle.fill" : "circle", tint: md.actif ? .green : .gray, image: Atelier.couverture(md.url), action: { self.basculerMod(g, md) }))
        }
        if !mods.isEmpty { items.append(SalonMenuItem(label: "Supprimer un mod", icon: "trash", destructive: true, action: { self.openSupprimerMod(g) })) }
        // GameBanana, directement
        items.append(SalonMenuItem(label: "Rechercher sur GameBanana", detail: recherche.map { "« \($0) » — choisir pour une autre recherche" } ?? "Un mot : 60fps, HUD, texture…", icon: "magnifyingglass", action: { self.menu = nil; self.rechercheGameBanana(g) }))
        if recherche != nil {
            items.append(SalonMenuItem(label: "Tous les mods", icon: "square.grid.2x2.fill", action: { self.openModsMenu(g) }))
        } else {
            items.append(SalonMenuItem(label: tri == "Generic_Newest" ? "Les plus téléchargés" : "Les plus récents", detail: "Liste actuelle : \(tri == "Generic_Newest" ? "les plus récents" : "les plus téléchargés")", icon: "arrow.up.arrow.down", action: {
                self.openModsMenu(g, tri: tri == "Generic_Newest" ? "Generic_MostDownloaded" : "Generic_Newest") }))
        }
        if let gb {
            for rec in gb.recs {
                guard let id = rec["_idRow"] as? Int, let n = rec["_sName"] as? String else { continue }
                let likes = rec["_nLikeCount"] as? Int ?? 0; let cat = (rec["_aRootCategory"] as? [String: Any])?["_sName"] as? String
                let obso = rec["_bIsObsolete"] as? Bool ?? false; let ap = Atelier.apercu(rec)
                let deja = mods.contains { $0.name == Atelier.slug(n).replacingOccurrences(of: ":", with: "-") }
                items.append(SalonMenuItem(label: n, detail: ([deja ? "installé" : nil, cat, "♥ \(likes)", obso ? "obsolète" : nil] as [String?]).compactMap { $0 }.joined(separator: " · "), icon: "shippingbox.fill",
                                           image: ap, action: { self.ficheGameBanana(g, modID: id, nom: n, apercu: ap, retour: ici) }))
            }
            if let erreur { items.append(SalonMenuItem(label: erreur, detail: "Choisir pour réessayer", icon: "exclamationmark.triangle.fill", tint: .orange, action: { Atelier.cacheGB = [:]; ici() })) }
            else if gb.recs.isEmpty { items.append(SalonMenuItem(label: "Aucun mod trouvé", icon: "xmark.circle", info: true, action: {})) }
            if !gb.complet { items.append(SalonMenuItem(label: "Page suivante", detail: "Page \(page + 1)", icon: "chevron.right.circle.fill", action: { self.openModsMenu(g, page: page + 1, tri: tri, recherche: recherche) })) }
            if page > 1 { items.append(SalonMenuItem(label: "Page précédente", detail: "Page \(page - 1)", icon: "chevron.left.circle.fill", action: { self.openModsMenu(g, page: page - 1, tri: tri, recherche: recherche) })) }
            if let gid = config.gamebanana?[g.id] {
                items.append(SalonMenuItem(label: "Pas le bon jeu ?", icon: "arrow.uturn.left", tint: .gray, action: { self.openGameBanana(g) }))
            }
        } else {
            items.append(SalonMenuItem(label: "GameBanana…", detail: "Chargement des mods", icon: "globe", info: true, action: {}))
        }
        let titre = recherche.map { "« \($0) »" } ?? (tri == "Generic_Newest" ? "les plus récents" : "les plus téléchargés")
        menu = SalonMenu(title: "Mods", subtitle: g.name + " — \(mods.filter { $0.actif }.count) activé(s) sur \(mods.count) · GameBanana : \(titre)\(page > 1 ? ", page \(page)" : "")", items: items, hero: "puzzlepiece.extension.fill",
                         back: { self.menu = self.optionsMenu(g) }, grid: true)
    }
    func openSupprimerMod(_ g: Game) {
        menu = SalonMenu(title: "Supprimer un mod", subtitle: g.name, items: Atelier.mods(g).map { md in
            SalonMenuItem(label: md.name, detail: md.actif ? "Activé — il sera désactivé" : "Désactivé", icon: "trash", destructive: true, image: Atelier.couverture(md.url), action: {
                var a = Atelier.actifs(g); a.removeAll { $0 == md.name }; Atelier.enregistrer(g, actifs: a)
                NSWorkspace.shared.recycle([md.url]) { _, _ in }
                self.toast = "\(md.name) mis à la corbeille"; if md.actif { self.appliquerMods(g, codeChange: md.exefs != nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openModsMenu(g) } }) }, hero: "trash.fill", back: { self.openModsMenu(g) }, grid: true)
    }
    func basculerMod(_ g: Game, _ md: Atelier.Mod) {
        var a = Atelier.actifs(g)
        if md.actif { a.removeAll { $0 == md.name } } else { a.removeAll { $0 == md.name }; a.insert(md.name, at: 0) }
        Atelier.enregistrer(g, actifs: a)
        Sounds.shared.play(md.actif ? "retour" : "lancer")
        appliquerMods(g, codeChange: md.exefs != nil)
        openModsMenu(g)
    }
    /// Ce que chaque moteur demande pour qu'un changement de mods prenne effet
    func appliquerMods(_ g: Game, codeChange: Bool) {
        switch Atelier.moteurDe(g) {
        case .nxnative:
            toast = codeChange ? "Mod de code : reconstruis le jeu (Options → Mises à jour → Reconstruire)" : "Pris en compte au prochain lancement"
        case .mng:
            let romfs = Atelier.mods(g).filter { $0.actif }.map { $0.url.path }
            if codeChange {   // un mod de code : l'app est refaite depuis son dossier de construction, sans la ROM
                if Atelier.scriptDedie(g) == "totk-mng-online.command" { lancer("totk-mng-online.command", modsCode(g), titre: "Reconstruction de \(g.name)", jeux: [g.id]) }
                else if let reg = Atelier.registre()[g.url.path] { construire(g, reg) }
                toast = nil
            } else {
                if (Bundle(url: g.url)?.bundleIdentifier ?? "").hasPrefix("org.macnativegames.totk") { lancer("mng-mods-appliquer.command", [g.url.path] + romfs, titre: "Mods de \(g.name)", jeux: [g.id]) }
                toast = nil
            }
        case .pc, .mac:
            toast = "Mod PC : place ses fichiers dans le dossier du jeu (Mods → Dossier du jeu)"
        }
    }
    func modDepuisFichier(_ g: Game) {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = false
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"); p.message = "Choisis l'archive ou le dossier du mod pour \(g.name)"
        guard p.runModal() == .OK, let u = p.url else { return }
        installerMod(g, source: u, nom: u.deletingPathExtension().lastPathComponent)
    }
    func installerMod(_ g: Game, source u: URL, nom: String, apercu: URL? = nil) {
        let name = Atelier.slug(nom).replacingOccurrences(of: ":", with: "-")
        let dest = Atelier.dossier(g).appendingPathComponent(name.isEmpty ? "mod" : name)
        toast = "Installation de \(name)…"
        DispatchQueue.global().async {
            var ok = true
            try? FileManager.default.removeItem(at: dest)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                do { try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true); try FileManager.default.copyItem(at: u, to: dest) } catch { ok = false }
            } else { ok = Atelier.extraire(u, vers: dest) }
            if ok, let ap = apercu, let d = try? Data(contentsOf: ap) { try? d.write(to: dest.appendingPathComponent(".salon-cover.jpg")) }   // l'aperçu GameBanana, pour la carte du mod
            DispatchQueue.main.async {
                guard ok else { self.toast = "Archive illisible : \(u.lastPathComponent)"; try? FileManager.default.removeItem(at: dest); return }
                var a = Atelier.actifs(g); a.removeAll { $0 == dest.lastPathComponent }; a.insert(dest.lastPathComponent, at: 0); Atelier.enregistrer(g, actifs: a)
                log("Mod installé pour \(g.name) : \(dest.path)")
                self.appliquerMods(g, codeChange: Atelier.trouve("exefs", dans: dest) != nil)
                if self.menu != nil { self.openModsMenu(g) }
            }
        }
    }

    // MARK: GameBanana
    /// Choisir à la main le jeu GameBanana (quand le nom trouvé tout seul n'est pas le bon)
    func openGameBanana(_ g: Game) {
        toast = "Recherche de \(g.name) sur GameBanana…"
        Task {
            let n = Atelier.nomRecherche(g)
            let r = await Atelier.json("\(Atelier.gb)/Util/Search/Results?_sModelName=Game&_sSearchString=\(Atelier.enc(n))&_nPage=1")
            let recs = (r?["_aRecords"] as? [[String: Any]]) ?? []
            await MainActor.run {
                self.toast = nil
                guard !recs.isEmpty else { self.toast = "\(n) introuvable sur GameBanana (renomme le jeu si besoin)"; return }
                self.menu = SalonMenu(title: "Quel jeu sur GameBanana ?", subtitle: g.name, items: recs.prefix(12).compactMap { rec -> SalonMenuItem? in
                    guard let id = rec["_idRow"] as? Int, let nom = rec["_sName"] as? String else { return nil }
                    return SalonMenuItem(label: nom, detail: id == self.config.gamebanana?[g.id] ? "Choisi actuellement" : "gamebanana.com/games/\(id)", icon: id == self.config.gamebanana?[g.id] ? "checkmark.circle.fill" : "gamecontroller", action: {
                        var m = self.config.gamebanana ?? [:]; m[g.id] = id; self.config.gamebanana = m; self.saveConfig(); self.openModsMenu(g) }) }, hero: "globe", back: { self.openModsMenu(g) })
            }
        }
    }
    func rechercheGameBanana(_ g: Game) {
        let a = NSAlert(); a.messageText = "Rechercher un mod"; a.informativeText = "Sur GameBanana, pour \(g.name)."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); f.placeholderString = "60fps, HUD, texture…"; a.accessoryView = f; a.window.initialFirstResponder = f
        a.addButton(withTitle: "Rechercher"); a.addButton(withTitle: "Annuler")
        guard a.runModal() == .alertFirstButtonReturn else { openModsMenu(g); return }
        let q = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        openModsMenu(g, recherche: q.isEmpty ? nil : q)
    }
    func ficheGameBanana(_ g: Game, modID: Int, nom: String, apercu: URL? = nil, retour: (() -> Void)? = nil) {
        toast = "Fichiers de \(nom)…"
        Task {
            let r = await Atelier.json("\(Atelier.gb)/Mod/\(modID)?_csvProperties=_sName,_aFiles")
            let files = (r?["_aFiles"] as? [[String: Any]]) ?? []
            await MainActor.run {
                self.toast = nil
                var items: [SalonMenuItem] = files.compactMap { f -> SalonMenuItem? in
                    guard let name = f["_sFile"] as? String, let dl = f["_sDownloadUrl"] as? String, let u = URL(string: dl) else { return nil }
                    let size = ByteCountFormatter.string(fromByteCount: Int64(f["_nFilesize"] as? Int ?? 0), countStyle: .file)
                    let desc = (f["_sDescription"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    return SalonMenuItem(label: name, detail: ([size, desc] as [String?]).compactMap { $0 }.joined(separator: " · "), icon: "arrow.down.circle", section: "Installer un fichier", action: {
                        self.menu = nil; self.telechargerMod(g, url: u, fichier: name, nom: nom, apercu: apercu) })
                }
                if items.isEmpty { items.append(SalonMenuItem(label: "Aucun fichier à télécharger", detail: nil, icon: "xmark.circle", action: {})) }
                items.append(SalonMenuItem(label: "Voir la page", icon: "safari", section: " ", action: {
                    self.menu = nil; if let p = URL(string: "https://gamebanana.com/mods/\(modID)") { NSWorkspace.shared.open(p) } }))
                self.menu = SalonMenu(title: nom, subtitle: g.name, items: items, hero: "shippingbox.fill", back: retour ?? { self.openModsMenu(g) }, heroURL: apercu)
            }
        }
    }
    func telechargerMod(_ g: Game, url: URL, fichier: String, nom: String, apercu: URL? = nil) {
        toast = "Téléchargement de \(fichier)…"
        let dl = Atelier.dossier(g).appendingPathComponent("_telechargements"); try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        let dest = dl.appendingPathComponent(fichier)
        Task {
            var r = URLRequest(url: url); r.setValue("Salon/1.0", forHTTPHeaderField: "User-Agent"); r.timeoutInterval = 120
            guard let res = try? await URLSession.shared.download(for: r), ((res.1 as? HTTPURLResponse)?.statusCode ?? 200) < 400 else {
                await MainActor.run { self.toast = "Téléchargement impossible : \(fichier)" }; return }
            try? FileManager.default.removeItem(at: dest); try? FileManager.default.moveItem(at: res.0, to: dest)
            await MainActor.run { log("GameBanana : \(fichier) pour \(g.name)"); self.installerMod(g, source: dest, nom: nom, apercu: apercu) }
        }
    }

    // MARK: Tâches de fond (à la place du Terminal) : barre de progression, journal dans /Applications/Jeux/log/home
    @discardableResult
    func lancer(_ script: String, _ args: [String] = [], env: [String: String] = [:], titre: String, jeux: Set<String> = []) -> Bool {
        if let t = tache, !t.fini { toast = "Déjà en cours : \(t.titre)"; return false }
        let s = Atelier.outils.appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: s.path) else { toast = "\(script) introuvable"; return false }
        let dir = Atelier.home.appendingPathComponent("log/home"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let logURL = dir.appendingPathComponent("\((script as NSString).deletingPathExtension)-\(f.string(from: Date())).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: logURL) else { toast = "Journal impossible : \(logURL.path)"; return false }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [s.path] + args
        var e = ProcessInfo.processInfo.environment; for (k, v) in Dossiers.env { e[k] = v }; e["HOME_MOTEURS"] = moteursVoulus; for (k, v) in env { e[k] = v }; e["HOME_TACHE"] = "1"
        if config.discret ?? false { e["HOME_DISCRET"] = "1" }        // construction silencieuse : cœurs économes, Mac frais
        if config.garderCaches ?? true { e["GARDER_CACHES"] = "1" }  // caches de shaders gardés (par défaut) : reconstructions courtes et froides
        p.environment = e
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let tampon = TamponLignes(); let av = Avancement()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData; guard !d.isEmpty else { return }
            fh.write(d); tampon.data.append(d)
            while let r = tampon.data.firstIndex(of: 0x0a) {
                let ligne = String(decoding: tampon.data[tampon.data.startIndex..<r], as: UTF8.self); tampon.data.removeSubrange(tampon.data.startIndex...r)
                let pr = av.lire(ligne)
                if pr.etape != nil || pr.fraction != nil {
                    DispatchQueue.main.async {
                        guard var t = self?.tache, !t.fini else { return }
                        if let x = pr.etape { t.etape = x }
                        if let x = pr.fraction { let avant = t.fraction ?? 0; t.fraction = x < avant - 0.5 ? x : max(avant, x) }   // n'avance que dans un sens, sauf construction suivante
                        self?.tache = t
                    }
                }
            }
        }
        p.terminationHandler = { [weak self] q in
            pipe.fileHandleForReading.readabilityHandler = nil
            let reste = pipe.fileHandleForReading.readDataToEndOfFile(); fh.write(reste); try? fh.close()
            let code = q.terminationStatus
            DispatchQueue.main.async { self?.finTache(code: code) }
        }
        do { try p.run() } catch { toast = "Impossible de lancer \(script)"; try? fh.close(); return false }
        log("Tâche : \(titre) — \(script) \(args.joined(separator: " ")) (journal \(logURL.path))")
        var nouvelle = Tache(titre: titre, log: logURL, jeux: jeux); nouvelle.attendu = Library.dureeAttendue(script, args)
        tacheProcess = p; withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { tache = nouvelle }
        tacheScript = Library.cleDuree(script, args)
        return true
    }
    /// La progression dans le Dock (icône de Home), retirée à la fin de la tâche
    func majDock() {
        let tile = NSApp.dockTile
        if let t = tache, !t.fini {
            let v = NSHostingView(rootView: DockProgression(fraction: t.fraction)); v.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
            tile.contentView = v
        } else { tile.contentView = nil }
        tile.display()
    }
    private func finTache(code: Int32) {
        guard var t = tache else { return }
        tacheProcess = nil; t.fini = true
        if code == 0 {
            t.fraction = 1; if !t.etape.contains("déjà à jour") { t.etape = "Terminé" }; tache = t; Sounds.shared.play("valider"); load()
            if let c = tacheScript, !t.etape.contains("déjà à jour") { Library.noterDuree(c, Date().timeIntervalSince(t.debut)) }
            if let a = apresTache { apresTache = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { a() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if self.tache?.log == t.log { withAnimation(.easeInOut(duration: 0.6)) { self.tache = nil } } }
        } else {
            let lignes = ((try? String(contentsOf: t.log, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let motif = lignes.last { $0.contains("ÉCHEC") || $0.contains("ERROR") || $0.contains("Error") || $0.contains("introuvable") || $0.contains("[RED]") } ?? lignes.last ?? "Erreur"
            var court = motif.trimmingCharacters(in: .whitespaces)
            if court.hasPrefix("{"), let d = court.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let m = j["msg"] as? String { court = m }
            apresTache = nil
            t.erreur = "Échec : " + String(court.replacingOccurrences(of: "[RED] ", with: "").prefix(70))
            tache = t; Sounds.shared.play("retour")
            log("Tâche échouée (\(code)) : \(t.titre) — \(t.log.path)")
            if running == nil, menu == nil { openTacheMenu() }
        }
    }
    func openTacheMenu() {
        guard let t = tache else { return }
        var items: [SalonMenuItem] = []
        if t.fini {
            items.append(SalonMenuItem(label: "Ouvrir dans le dossier", detail: t.log.lastPathComponent, icon: "folder.fill", action: { self.menu = nil; NSWorkspace.shared.activateFileViewerSelecting([t.log]) }))
            items.append(SalonMenuItem(label: "Fermer", icon: "xmark.circle.fill", tint: .gray, action: { self.menu = nil; withAnimation(.easeInOut(duration: 0.5)) { self.tache = nil } }))
        } else {
            items.append(SalonMenuItem(label: "Continuer", detail: t.etape, icon: "play.fill", action: { self.menu = nil }))
            items.append(SalonMenuItem(label: "Ouvrir le journal dans le dossier", detail: t.log.lastPathComponent, icon: "folder.fill", action: { self.menu = nil; NSWorkspace.shared.activateFileViewerSelecting([t.log]) }))
            items.append(SalonMenuItem(label: "Arrêter", icon: "stop.circle.fill", destructive: true, action: {
                self.menu = nil; if let p = self.tacheProcess { _ = Commande.run("/usr/bin/pkill", ["-TERM", "-P", "\(p.processIdentifier)"]); p.terminate() } }))
        }
        menu = SalonMenu(title: t.titre, subtitle: t.erreur ?? t.etape, items: items, hero: t.erreur != nil ? "exclamationmark.triangle.fill" : "hammer.fill")
    }

    // MARK: Mises à jour et construction
    /// Un assistant pas à pas : les étapes à montrer (base, maj, dlc, recap) et ce qui a été choisi
    struct Assistant {
        var moteur: String; var etapes: [String]
        var base: URL? = nil; var updates: [URL] = []; var dlc: [URL] = []
        var travail: String? = nil; var sortie: URL? = nil; var titre: String? = nil
        var mods: [String] = []; var modModule: String? = nil; var icone: String? = nil
    }
    /// L'icône d'une app nxnative sans icône (construite sans données de contrôle) : la jaquette
    /// de Home, recadrée en carré, en PNG 1024 px — passée à la construction (build_ipa_from_nsp.py --icon)
    func iconePourBuild(_ g: Game) -> String? {
        guard g.titleID != nil, let img = art[g.id]?.cover, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let cote = min(cg.width, cg.height)
        guard let carre = cg.cropping(to: CGRect(x: (cg.width - cote) / 2, y: (cg.height - cote) / 2, width: cote, height: cote)) else { return nil }
        let rep = NSBitmapImageRep(cgImage: carre); rep.size = NSSize(width: 1024, height: 1024)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let u = salonRoot.appendingPathComponent("cache/icone-\(g.titleID ?? "jeu").png")
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? png.write(to: u)) != nil ? u.path : nil
    }
    /// Les dossiers des mods de code activés (leur dossier exefs, passé à la construction)
    func modsCode(_ g: Game) -> [String] { Atelier.modsPossibles(g) ? Atelier.mods(g).filter { $0.actif }.compactMap { $0.exefs?.deletingLastPathComponent().path } : [] }

    func openUpdateMenu(_ g: Game) {
        let dedie = Atelier.scriptDedie(g); let m = Atelier.moteurDe(g)
        // un jeu nxnative construit avant le registre (Mario Odyssey) : son dossier de construction suffit à le refaire
        let reg = Atelier.registre()[g.url.path] ?? (m == .nxnative ? Atelier.dossierBuild(g).map { Atelier.Inscription(moteur: "nxnative", base: "", update: [], dlc: [], modModule: nil, travail: $0, titre: g.titleID) } : nil)
        let retour: () -> Void = { self.menu = self.optionsMenu(g) }
        var items: [SalonMenuItem] = []
        if let reg {
            items.append(SalonMenuItem(label: "Installer une mise à jour", icon: "arrow.down.circle.fill", action: { self.assistantMaj(g, reg) }))
            items.append(SalonMenuItem(label: "Reconstruire", detail: nil, icon: "hammer.fill", action: { self.confirmerReconstruction(g, reg) }))
        } else {
            if let dedie { items.append(SalonMenuItem(label: "Reconstruire", icon: "hammer.fill", action: { self.menu = nil; self.lancer(dedie, dedie == "totk-mng-online.command" ? self.modsCode(g) : [], titre: "Reconstruction de \(g.name)", jeux: [g.id]) })) }
            items.append(SalonMenuItem(label: "Installer une mise à jour", icon: "arrow.down.circle.fill", action: {
                self.assistant(Assistant(moteur: m == .mng ? "mng" : "nxnative", etapes: ["base", "maj", "recap"], sortie: g.url, titre: g.name, mods: self.modsCode(g)), 0, retour: { self.openUpdateMenu(g) }) }))
            // plus de dossier de construction pour ce jeu : le reconstruire redemande le jeu de base (ton dump)
            if dedie == nil { items.append(SalonMenuItem(label: "Reconstruire", detail: "Le dossier de construction n'existe plus : il faut le jeu de base", icon: "hammer.fill", action: {
                var a = Assistant(moteur: m == .mng ? "mng" : "nxnative", etapes: ["base", "recap"], sortie: g.url, titre: g.name, mods: self.modsCode(g)); a.icone = self.iconePourBuild(g)
                self.assistant(a, 0, retour: { self.openUpdateMenu(g) }) })) }
        }
        menu = SalonMenu(title: "Mises à jour", subtitle: g.name, items: items, hero: "arrow.down.circle.fill", back: retour)
    }
    func confirmerReconstruction(_ g: Game, _ reg: Atelier.Inscription) {
        menu = SalonMenu(title: "Reconstruire", subtitle: g.name, items: [
            SalonMenuItem(label: "Reconstruire maintenant", icon: "hammer.fill", tint: .green, action: { self.menu = nil; self.construire(g, reg) }),
        ], hero: "hammer.fill", back: { self.openUpdateMenu(g) })
    }
    func assistantMaj(_ g: Game, _ reg: Atelier.Inscription) {
        let fm = FileManager.default
        let base = fm.fileExists(atPath: reg.base) ? URL(fileURLWithPath: reg.base) : nil
        var a = Assistant(moteur: reg.moteur, etapes: base == nil ? ["base", "maj", "recap"] : ["maj", "recap"], base: base, sortie: g.url, titre: g.name)
        a.dlc = reg.dlc.filter { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        a.modModule = reg.modModule; a.mods = modsCode(g)
        assistant(a, 0, retour: { self.openUpdateMenu(g) })
    }
    func majMoteur() { lancer("mettre-a-jour-et-rebuild.command", env: ["SALON_SANS_VEILLE": "1"], titre: "Mise à jour du moteur nxnative", jeux: Set(games.filter { $0.titleID != nil }.map { $0.id })) }
    /// Les fichiers de ce Mac qui peuvent convenir (par extension, ou par nom exact) : Téléchargements, Bureau, Documents et les disques
    /// branchés, sur trois niveaux de dossiers. Les plus récents d'abord ; ceux dont le nom contient un mot de `priorite` passent devant.
    nonisolated static func fichiersCandidats(ext: [String], noms: [String] = [], priorite: [String] = [], exclus: [URL] = []) -> [URL] {
        let fm = FileManager.default, maison = fm.homeDirectoryForCurrentUser
        var racines = ["Downloads", "Desktop", "Documents"].map { maison.appendingPathComponent($0) }
        racines += (fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRootFileSystemKey], options: [.skipHiddenVolumes]) ?? []).filter { (try? $0.resourceValues(forKeys: [.volumeIsRootFileSystemKey]).volumeIsRootFileSystem) == false && $0.path.hasPrefix("/Volumes/") }
        let e = Set(ext.map { $0.lowercased() }), n = Set(noms.map { $0.lowercased() }), hors = Set(exclus.map { $0.standardizedFileURL.path })
        var trouves: [(URL, Date)] = []; var vus = 0
        for r in racines {
            guard let it = fm.enumerator(at: r, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in it {
                vus += 1; if vus > 30000 { break }   // un dossier énorme ne bloque pas la recherche
                if it.level >= 3 { it.skipDescendants() }
                guard e.contains(u.pathExtension.lowercased()) || n.contains(u.lastPathComponent.lowercased()), !hors.contains(u.standardizedFileURL.path) else { continue }
                trouves.append((u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
            }
        }
        func devant(_ u: URL) -> Bool { let t = u.lastPathComponent.lowercased(); return priorite.contains { t.contains($0) } }
        return trouves.sorted { a, b in devant(a.0) != devant(b.0) ? devant(a.0) : a.1 > b.1 }.prefix(40).map { $0.0 }
    }
    /// Choisir un fichier sans passer par le Finder : Home cherche ce qui convient et le propose ; « Chercher ailleurs… » ouvre le Finder.
    /// S'il ne trouve rien, le Finder s'ouvre tout de suite.
    func proposer(_ titre: String, sousTitre: String? = nil, icone: String = "doc.fill", plusieurs: Bool = false, chercher: @escaping () -> [URL], finder: @escaping () -> [URL]?, back: @escaping () -> Void, puis: @escaping ([URL]) -> Void) {
        menu = SalonMenu(title: titre, subtitle: sousTitre, items: [SalonMenuItem(label: "Recherche…", icon: "magnifyingglass", info: true, action: {})], back: back, roue: true)
        let taille = ByteCountFormatter(); taille.countStyle = .file
        func lieu(_ u: URL) -> String {
            let d = u.deletingLastPathComponent().lastPathComponent
            let ou = ["Downloads": "Téléchargements", "Desktop": "Bureau"][d] ?? d
            let o = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { " · " + taille.string(fromByteCount: Int64($0)) } ?? ""
            return ou + o
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let trouves = chercher()
            DispatchQueue.main.async {
                guard self.menu?.title == titre, self.menu?.items.first?.label == "Recherche…" else { return }   // on est parti entre-temps
                if trouves.isEmpty { if let u = finder(), !u.isEmpty { puis(u) } else { back() }; return }
                func montrer(_ choisis: [URL]) {
                    var items: [SalonMenuItem] = []
                    if plusieurs, !choisis.isEmpty { items.append(SalonMenuItem(label: "Continuer", detail: "\(choisis.count) choisi\(choisis.count > 1 ? "s" : "")", icon: "arrow.right.circle.fill", tint: .green, action: { puis(choisis) })) }
                    items += trouves.map { u in
                        let pris = choisis.contains(u)
                        return SalonMenuItem(label: u.deletingPathExtension().lastPathComponent, detail: lieu(u), icon: pris ? "checkmark.circle.fill" : icone, tint: pris ? .green : nil, action: {
                            if plusieurs { montrer(pris ? choisis.filter { $0 != u } : choisis + [u]) } else { puis([u]) } })
                    }
                    items.append(SalonMenuItem(label: "Chercher ailleurs…", detail: "Avec le Finder", icon: "folder.fill", tint: .gray, action: { if let u = finder(), !u.isEmpty { puis(u) } }))
                    self.menu = SalonMenu(title: titre, subtitle: sousTitre, items: items, back: back, roue: true)
                }
                montrer([])
            }
        }
    }
    private func choisir(_ message: String, plusieurs: Bool, dossiers: Bool) -> [URL]? {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = dossiers; p.allowsMultipleSelection = plusieurs; p.message = message
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return p.runModal() == .OK ? p.urls : nil
    }
    /// Reconstruit un jeu du registre : depuis son dossier de construction s'il existe encore (sans NSP), sinon depuis les fichiers donnés
    func construire(_ g: Game, _ reg: Atelier.Inscription) {
        var a = Assistant(moteur: reg.moteur, etapes: [], sortie: g.url, titre: g.name)
        if let t = reg.travail, FileManager.default.fileExists(atPath: t) { a.travail = t }
        else { a.base = URL(fileURLWithPath: reg.base); a.updates = reg.update.map { URL(fileURLWithPath: $0) }; a.dlc = reg.dlc.map { URL(fileURLWithPath: $0) } }
        a.modModule = reg.modModule; a.mods = modsCode(g); a.icone = iconePourBuild(g)
        lancerConstruction(a)
    }
    func lancerConstruction(_ a: Assistant) {
        var args = ["--moteur", a.moteur]
        if let b = a.base { args += ["--base", b.path] } else if let t = a.travail { args += ["--depuis-build", t] } else { toast = "Aucun jeu de base choisi"; return }
        for u in a.updates { args += ["--update", u.path] }
        for d in a.dlc { args += ["--dlc", d.path] }
        if let mm = a.modModule { args += ["--mod-module", mm] }
        for x in a.mods { args += [a.moteur == "mng" ? "--mod" : "--exefs-mod", x] }
        if let s = a.sortie { args += ["--sortie", s.path] }
        if let i = a.icone { args += ["--icone", i] }
        lancer("construire-jeu.command", args, env: config.cles.map { ["HOME_CLES": $0] } ?? [:], titre: a.sortie == nil ? "Construction du jeu" : "\(a.base == nil ? "Reconstruction" : "Mise à jour") de \(a.titre ?? "du jeu")", jeux: Set(a.sortie.map { [$0.standardizedFileURL.path] } ?? []))
    }
    /// Une étape de l'assistant : une grande illustration, une explication, un ou deux choix
    func assistant(_ a: Assistant, _ i: Int, retour: @escaping () -> Void) {
        guard a.etapes.indices.contains(i) else { return }
        let n = a.etapes.count
        let prec: () -> Void = i == 0 ? retour : { self.assistant(a, i - 1, retour: retour) }
        let suite: (Assistant) -> Void = { b in self.assistant(b, i + 1, retour: retour) }
        let nom = a.titre ?? a.base?.deletingPathExtension().lastPathComponent ?? "Jeu Switch"
        func noms(_ u: [URL]) -> String { u.map { $0.lastPathComponent }.joined(separator: ", ") }
        switch a.etapes[i] {
        case "base":
            var items = [SalonMenuItem(label: a.base?.lastPathComponent ?? "Choisir le jeu…", detail: a.base == nil ? ".nsp, .xci, .nup, ou le dossier d'un jeu extrait" : "Choisir un autre fichier", icon: "folder.fill.badge.plus", action: {
                self.proposer("Quel jeu ?", sousTitre: a.titre, icone: "gamecontroller.fill", chercher: { Library.fichiersCandidats(ext: ["nsp", "xci", "nup"]) },
                              finder: { self.choisir("Le jeu de base\(a.titre.map { " de \($0)" } ?? "") : .nsp, .xci, .nup, ou le dossier du jeu", plusieurs: false, dossiers: true) },
                              back: { self.assistant(a, i, retour: retour) }) { u in
                    var b = a; b.base = u[0]
                    if u[0].pathExtension.lowercased() == "nup" { b.etapes = b.etapes.filter { $0 != "maj" && $0 != "dlc" }; b.updates = []; b.dlc = [] }   // un .nup Switch 2 contient déjà sa mise à jour
                    suite(b) } })]
            if a.base != nil { items.append(SalonMenuItem(label: "Continuer", icon: "arrow.right.circle.fill", tint: .green, action: { suite(a) })) }
            menu = SalonMenu(title: "Le jeu", subtitle: nom, items: items, hero: "gamecontroller.fill",
                             step: i + 1, steps: n, back: prec)
        case "moteur":
            let rec = Atelier.moteurRecommande(a.base)
            let autre = rec.moteur == "mng" ? "nxnative" : "mng"
            func nomMoteur(_ m: String) -> String { m == "mng" ? "MacNativeGames" : "nxnative" }
            menu = SalonMenu(title: "Le moteur", subtitle: rec.jeu ?? a.base?.lastPathComponent ?? nom, items: [
                SalonMenuItem(label: nomMoteur(rec.moteur), detail: "Recommandé", icon: "checkmark.seal.fill", tint: .green, action: { var b = a; b.moteur = rec.moteur; suite(b) }),
                SalonMenuItem(label: "Autre : \(nomMoteur(autre))", icon: "arrow.triangle.swap", tint: .gray, action: { var b = a; b.moteur = autre; suite(b) }),
            ], hero: "cpu", step: i + 1, steps: n, back: prec)
        case "maj":
            var items = [SalonMenuItem(label: a.updates.isEmpty ? "Choisir la mise à jour…" : noms(a.updates), detail: a.updates.isEmpty ? "Un fichier .nsp" : "Choisir d'autres fichiers", icon: "doc.badge.plus", action: {
                self.proposer("Quelle mise à jour ?", sousTitre: nom, icone: "arrow.down.circle.fill", plusieurs: true, chercher: { Library.fichiersCandidats(ext: ["nsp"], priorite: ["upd", "update", "maj", "patch"], exclus: [a.base].compactMap { $0 } + a.dlc) },
                              finder: { self.choisir("Mise à jour de \(nom) (.nsp)", plusieurs: true, dossiers: false) },
                              back: { self.assistant(a, i, retour: retour) }) { u in var b = a; b.updates = u; suite(b) } })]
            if !a.updates.isEmpty { items.append(SalonMenuItem(label: "Continuer", icon: "arrow.right.circle.fill", tint: .green, action: { suite(a) })) }
            else if a.sortie == nil { items.append(SalonMenuItem(label: "Pas de mise à jour", icon: "arrow.right.circle", tint: .gray, action: { suite(a) })) }
            menu = SalonMenu(title: "La mise à jour", subtitle: nom, items: items, hero: "arrow.down.circle.fill",
                             step: i + 1, steps: n, back: prec)
        case "dlc":
            var items = [SalonMenuItem(label: a.dlc.isEmpty ? "Choisir les DLC…" : noms(a.dlc), detail: a.dlc.isEmpty ? "Un ou plusieurs fichiers .nsp" : "Choisir d'autres fichiers", icon: "puzzlepiece.extension.fill", action: {
                self.proposer("Quels DLC ?", sousTitre: nom, icone: "puzzlepiece.extension.fill", plusieurs: true, chercher: { Library.fichiersCandidats(ext: ["nsp"], priorite: ["dlc"], exclus: [a.base].compactMap { $0 } + a.updates) },
                              finder: { self.choisir("DLC de \(nom) (.nsp)", plusieurs: true, dossiers: false) },
                              back: { self.assistant(a, i, retour: retour) }) { u in var b = a; b.dlc = u; suite(b) } })]
            items.append(SalonMenuItem(label: a.dlc.isEmpty ? "Pas de DLC" : "Continuer", icon: "arrow.right.circle\(a.dlc.isEmpty ? "" : ".fill")", tint: a.dlc.isEmpty ? .gray : .green, action: { suite(a) }))
            menu = SalonMenu(title: "Les contenus additionnels", subtitle: nom, items: items, hero: "puzzlepiece.extension.fill", step: i + 1, steps: n, back: prec)
        default:
            var items: [SalonMenuItem] = []
            items.append(SalonMenuItem(label: a.base?.lastPathComponent ?? "Fichiers déjà extraits", detail: "Le jeu", icon: "gamecontroller.fill", info: true, action: {}))
            items.append(SalonMenuItem(label: a.updates.isEmpty ? "Aucune" : noms(a.updates), detail: "Mise à jour", icon: "arrow.down.circle.fill", info: true, action: {}))
            if a.etapes.contains("dlc") || !a.dlc.isEmpty { items.append(SalonMenuItem(label: a.dlc.isEmpty ? "Aucun" : noms(a.dlc), detail: "DLC", icon: "puzzlepiece.extension.fill", info: true, action: {})) }
            if !a.mods.isEmpty { items.append(SalonMenuItem(label: "\(a.mods.count) mod\(a.mods.count > 1 ? "s" : "") de code", detail: "Mods", icon: "puzzlepiece.fill", info: true, action: {})) }
            items.append(SalonMenuItem(label: a.moteur == "mng" ? "MacNativeGames" : "nxnative", detail: "Moteur", icon: "cpu", tint: .purple, info: true, action: {}))
            items.append(SalonMenuItem(label: "Construire", icon: "hammer.fill", section: " ", tint: .green, action: { self.menu = nil; self.lancerConstruction(a) }))
            menu = SalonMenu(title: "Prêt à construire", subtitle: nom, items: items, hero: "hammer.fill",
                             step: i + 1, steps: n, back: prec)
        }
    }
    // MARK: Mode d'utilisation : ce que Home sert à faire sur ce Mac (jeux Nintendo, jeux PC, les deux) et quels moteurs il installe
    var modeNintendo: Bool { config.mode != "pc" }
    var modePC: Bool { config.mode != "nintendo" }
    /// Ce que le script de préparation doit installer pour les jeux Nintendo (HOME_MOTEURS)
    var moteursVoulus: String { modeNintendo ? (config.moteurs ?? "tout") : "aucun" }
    var modeResume: String {
        let m = config.mode == "pc" ? "Jeux PC" : config.mode == "nintendo" ? "Jeux Nintendo" : config.mode == nil ? "Pas encore choisi" : "Jeux Nintendo et jeux PC"
        let e = !modeNintendo || config.mode == nil ? "" : config.moteurs == "mng" ? " · MacNativeGames seul" : config.moteurs == "nxnative" ? " · nxnative seul" : ""
        return m + e
    }
    /// L'assistant du premier lancement, qu'on retrouve dans Menu → Mode d'utilisation : un écran à lui (AccueilView), en trois temps —
    /// 1. à quoi sert Home ici, 2. les moteurs Nintendo (tout, recommandé ; ou un seul, avancé), 3. par où commencer côté PC.
    /// À la fin, Home télécharge ce qui manque pour ce mode.
    // L'accueil du premier lancement : un écran à part (BienvenueView), pas un menu. Trois cartes, un grand bouton ; « Ignorer » existe
    // mais se fait discret, parce que sans ce choix Home ne sait pas quoi installer.
    static let modesAccueil = ["tout", "nintendo", "pc"]
    func bienvenueBouger(_ d: Int) { let n = max(0, min(2, bienvenueIndex + d)); if n != bienvenueIndex { bienvenueIndex = n; Sounds.shared.play("deplacer") } }
    func bienvenueValider() {
        Sounds.shared.play("valider"); withAnimation(.easeInOut(duration: 0.45)) { bienvenue = false }
        appliquerMode(mode: Library.modesAccueil[bienvenueIndex], moteurs: "tout", ensuite: nil)
    }
    func bienvenueIgnorer() { config.mode = "tout"; config.moteurs = "tout"; saveConfig(); Sounds.shared.play("retour"); withAnimation(.easeInOut(duration: 0.45)) { bienvenue = false } }
    func openModeUtilisation(premier: Bool = false) {
        if menu == nil { Sounds.shared.play("ouvrir") }
        let mode = config.mode ?? "tout"
        func choix(_ nom: String, _ precision: String, _ symbole: String, _ teinte: Color, _ cle: String) -> SalonMenuItem {
            SalonMenuItem(label: nom + (!premier && cle == mode ? " : actuel" : ""), detail: precision, icon: symbole, tint: teinte, action: {
                if cle == "pc" { self.appliquerMode(mode: cle, moteurs: "tout", ensuite: nil) } else { self.etapeMoteurs(mode: cle, premier: premier) } })
        }
        var items = [
            choix("Tout", "Jeux Nintendo et jeux PC", "square.grid.2x2.fill", .purple, "tout"),
            choix("Nintendo", "Switch et Switch 2, à partir de tes dumps", "gamecontroller.fill", .orange, "nintendo"),
            choix("PC", "Le moteur Windows, pour Epic Games, Steam et tes jeux Windows", "desktopcomputer", .blue, "pc"),
        ]
        if premier { items.append(SalonMenuItem(label: "Plus tard", icon: "moon.zzz.fill", tint: .gray, action: { self.config.mode = "tout"; self.saveConfig(); self.menu = nil })) }
        menu = SalonMenu(title: premier ? "Bienvenue" : "Composants", items: items, step: 1, steps: 2, back: premier ? { self.config.mode = "tout"; self.saveConfig(); self.menu = nil } : { self.menu = self.plusMenu() }, roue: true)
    }
    private func etapeMoteurs(mode: String, premier: Bool) {
        let suite: (String) -> Void = { m in self.appliquerMode(mode: mode, moteurs: m, ensuite: nil) }
        menu = SalonMenu(title: "Moteurs Nintendo", items: [
            SalonMenuItem(label: "Tout", detail: "Le bon moteur pour chaque jeu", icon: "sparkles", tint: .purple, action: { suite("tout") }),
            SalonMenuItem(label: "MacNativeGames", detail: "Tears of the Kingdom, Breath of the Wild, Ocarina of Time", icon: "leaf.fill", section: "Avancé", tint: .orange, action: { suite("mng") }),
            SalonMenuItem(label: "nxnative", detail: "Les autres jeux — demande Xcode", icon: "cpu.fill", tint: .blue, action: { suite("nxnative") }),
        ], step: 2, steps: 2, back: { self.openModeUtilisation(premier: premier) }, roue: true)
    }
    static let orange = [Color(red: 1.0, green: 0.70, blue: 0.23), Color(red: 1.0, green: 0.42, blue: 0.24)]
    static let bleu = [Color(red: 0.19, green: 0.78, blue: 0.80), Color(red: 0.16, green: 0.38, blue: 1.0)]
    static let violet = [Color(red: 0.58, green: 0.40, blue: 0.98), Color(red: 0.33, green: 0.17, blue: 0.80)]
    /// Enregistre le mode et télécharge ce qui lui manque ; « ensuite » se fait quand tout est installé
    private func appliquerMode(mode: String, moteurs: String, ensuite: (() -> Void)?) {
        config.mode = mode; config.moteurs = moteurs; saveConfig(); menu = nil
        MenuView.dernier["Bienvenue"] = nil; MenuView.dernier["Composants"] = nil
        let nintendoPret = !modeNintendo || ((moteurs == "nxnative" || Atelier.mngPret) && (moteurs == "mng" || Atelier.nxnativePret))
        DispatchQueue.global().async {
            let e = self.modePC ? (PCHome.json(PCHome.run(["etat"])) as? [String: Any] ?? [:]) : [:]
            let pcPret = !self.modePC || (e["voile"] as? String != nil && e["legendary"] as? Bool == true)
            DispatchQueue.main.async {
                if nintendoPret && pcPret { self.toast = "Mode d'utilisation : \(self.modeResume) — tout est déjà installé"; ensuite?(); return }
                self.apresTache = ensuite
                if !self.lancer("preparer-moteurs.command", env: self.modePC ? ["HOME_AUSSI_PC": "1"] : [:], titre: "Installation pour : \(self.modeResume)") { self.apresTache = nil }
            }
        }
    }
    /// Le bouton retour sur la bibliothèque : quitter Home, seulement si on le confirme
    func openQuitter() {
        guard running == nil, menu == nil else { return }
        Sounds.shared.play("ouvrir")
        menu = SalonMenu(title: "Quitter Home ?", items: [
            SalonMenuItem(label: "Rester", icon: "arrow.uturn.backward", action: { self.menu = nil }),
            SalonMenuItem(label: "Quitter Home", icon: "power", destructive: true, action: { self.menu = nil; Sounds.shared.play("retour"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) } }),
        ])
    }
    /// « Préparer ce Mac » : ce qu'il faut pour construire les jeux Switch (outils d'Apple, Homebrew, les deux moteurs), ce qui est déjà
    /// là, et le script qui installe le reste (preparer-moteurs.command). L'état est lu par le même script (--etat), hors du fil principal.
    func openPreparation(bienvenue: Bool = false, back: (() -> Void)? = nil) {
        let titre = bienvenue ? "Bienvenue dans Home" : "Composants Mac"
        menu = SalonMenu(title: titre, items: [SalonMenuItem(label: "Vérification…", icon: "hourglass", info: true, action: {})], back: back ?? { self.menu = self.plusMenu() }, roue: true)
        DispatchQueue.global().async {
            setenv("HOME_MOTEURS", self.moteursVoulus, 1)   // l'état de ce que le mode d'utilisation demande
            let brut = Commande.run("/bin/bash", [Atelier.outils.appendingPathComponent("preparer-moteurs.command").path, "--etat"], timeout: 60)
            var e: [String: String] = [:]
            for l in brut.split(separator: "\n") { let p = l.split(separator: "=", maxSplits: 1).map(String.init); if p.count == 2 { e[p[0]] = p[1] } }
            DispatchQueue.main.async {
                guard self.menu?.title == titre else { return }   // le menu a été quitté entre-temps
                // une roue où tout se parcourt : d'abord l'action, puis chaque outil avec ce à quoi il sert et s'il est là
                let outils: [(String, String, String, String)] = [   // clé, nom, à quoi ça sert, comment il arrive s'il manque
                    ("xcode", "Xcode", "L'outil d'Apple qui fabrique les apps", "À installer depuis l'App Store"),
                    ("metal", "Metal", "Prépare les graphismes des jeux", "Téléchargé par Home"),
                    ("brew", "Homebrew", "Installe les autres outils", "À installer depuis brew.sh"),
                    ("formules", "Outils Homebrew", "Petits programmes dont les moteurs ont besoin", "Installés par Home"),
                    ("dotnet", ".NET", "Sert à lire les fichiers des jeux", "Installé par Home"),
                    ("python", "Python", "Fait tourner les scripts de nxnative", "Installé par Home"),
                    ("nxnative", "nxnative", "Le moteur des jeux Switch", "Téléchargé par Home"),
                    ("mng", "MacNativeGames", "Le moteur des Zelda", "Téléchargé par Home"),
                ].filter { e[$0.0] != "ignore" }   // ce que le mode d'utilisation ne demande pas n'est pas montré
                let manquants = outils.filter { e[$0.0] != "ok" }
                let pret = manquants.isEmpty
                var items = [SalonMenuItem(label: pret ? "Tout est prêt" : "Tout installer", detail: pret ? "Ce Mac peut construire les jeux Switch" : "Il manque : " + manquants.map { $0.1 }.joined(separator: ", ") + " (10 à 20 min)", icon: pret ? "checkmark.seal.fill" : "arrow.down.circle.fill", tint: .green, action: {
                    self.menu = nil; if !pret { self.lancer("preparer-moteurs.command", titre: "Préparation de ce Mac") } })]
                items += outils.map { o in
                    let v = e[o.0] ?? "manque", ok = v == "ok"
                    let quoi = ok ? "Prêt" : v == "outils" ? "Xcode entier nécessaire" : v.hasPrefix("manque:") ? "Manque :" + v.dropFirst(7) : o.3
                    return SalonMenuItem(label: o.1, detail: o.2 + " — " + quoi, icon: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill", tint: ok ? .green : .orange, action: {
                        if o.0 == "brew", !ok { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                        else if o.0 == "xcode", !ok { NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!) } })
                }
                self.menu = SalonMenu(title: titre, items: items, back: back ?? { self.menu = self.plusMenu() }, roue: true)
            }
        }
    }
    /// Un jeu PC que la liste de compatibilité dit impossible sur Mac : la raison, et la source pour vérifier
    func openBloque(_ nom: String, _ b: Compat.Jeu, back: (() -> Void)? = nil) {
        Sounds.shared.play("retour")
        var items = [SalonMenuItem(label: b.raison ?? "L'éditeur du jeu refuse Linux et Mac", detail: "Pourquoi", icon: "hand.raised.fill", tint: .red, info: true, action: {})]
        if let p = b.preuve, let u = URL(string: p) { items.append(SalonMenuItem(label: "Voir la source", detail: u.host, icon: "safari.fill", action: { NSWorkspace.shared.open(u) })) }
        items.append(SalonMenuItem(label: "Fermer", icon: "xmark.circle.fill", tint: .gray, action: { if let back { back() } else { self.menu = nil } }))
        menu = SalonMenu(title: "Incompatible avec le Mac", subtitle: nom, items: items, hero: "xmark.shield.fill", text: "Home ne lance pas ce jeu : il ne démarrerait pas, ou ton compte pourrait être sanctionné. Aucune protection n'est contournée.", back: back)
    }
    /// Comptes (menu de Home) : gérer ses comptes Epic Games et Steam, et rien d'autre — se connecter, en ajouter un, passer de l'un à
    /// l'autre, se déconnecter. Les bibliothèques, elles, s'ouvrent depuis « Ajouter un jeu ».
    func openPC(back: (() -> Void)? = nil) {
        let ici: () -> Void = { self.openPC(back: back) }
        menu = SalonMenu(title: "Comptes", items: [SalonMenuItem(label: "Un instant", icon: "hourglass", info: true, action: {})], back: back, roue: true)
        etatComptes { e, steamActif, steamComptes in
            guard self.menu?.title == "Comptes" else { return }
            let epic = e["compte"] as? String
            self.menu = SalonMenu(title: "Comptes", items: [
                SalonMenuItem(label: "Epic Games : " + (epic ?? "non connecté"), icon: "logo:epic", tint: .purple, action: { self.openCompteEpic(back: ici) }),
                SalonMenuItem(label: "Steam : " + (steamActif ?? "non connecté"), icon: "logo:steam", tint: .blue, action: { self.openCompteSteam(back: ici) }),
            ], back: back, roue: true)
        }
    }
    /// L'état des comptes, lu hors du fil principal : celui d'Epic (pc.command etat), le compte Steam actif et tous les comptes Steam
    private func etatComptes(_ suite: @escaping ([String: Any], String?, [String]) -> Void) {
        DispatchQueue.global().async {
            let e = PCHome.json(PCHome.run(["etat"])) as? [String: Any] ?? [:]
            let st = PCHome.steamPret ? PCHome.json(PCHome.steam(["etat"])) as? [String: Any] : nil
            DispatchQueue.main.async { suite(e, st?["compte"] as? String, st?["comptes"] as? [String] ?? []) }
        }
    }
    /// Un compte Epic de plus (ou le premier) : le moteur Windows d'abord s'il manque, puis la connexion
    private func connecterEpic(moteur: Bool, nouveau: Bool, retour: @escaping () -> Void) {
        if !moteur { apresTache = retour; if !lancer("pc.command", ["preparer"], titre: "Moteur Windows") { apresTache = nil }; return }
        epicNouveau = nouveau; connexionEpic(retour: retour)
    }
    private func connecterSteam(retour: @escaping () -> Void) {
        if !PCHome.steamPret { apresTache = retour; if !lancer("preparer-steam.command", titre: "Préparation de Steam") { apresTache = nil }; return }
        connexionSteam(retour: retour)
    }
    func openCompteEpic(back: @escaping () -> Void) {
        let ici: () -> Void = { self.openCompteEpic(back: back) }
        menu = SalonMenu(title: "Epic Games", items: [SalonMenuItem(label: "Un instant", icon: "hourglass", info: true, action: {})], back: back, roue: true)
        etatComptes { e, _, _ in
            guard self.menu?.title == "Epic Games" else { return }
            let moteur = e["voile"] as? String != nil && e["legendary"] as? Bool == true
            let comptes = (e["comptes"] as? [[String: Any]] ?? []).compactMap { c -> (String, String, Bool)? in guard let i = c["id"] as? String, let n = c["nom"] as? String else { return nil }; return (i, n, c["actif"] as? Bool ?? false) }
            var items: [SalonMenuItem] = comptes.map { c in
                SalonMenuItem(label: c.1 + (c.2 ? " : actif" : ""), detail: c.2 ? nil : "Passer sur ce compte", icon: c.2 ? "checkmark.circle.fill" : "person.crop.circle", tint: c.2 ? .green : .gray, action: {
                    if c.2 { return }; DispatchQueue.global().async { _ = PCHome.run(["compte-choisir", c.0]); DispatchQueue.main.async { ici() } } })
            }
            items.append(SalonMenuItem(label: comptes.isEmpty ? "Se connecter" : "Ajouter un compte", icon: "person.crop.circle.badge.plus", tint: .purple, action: { self.connecterEpic(moteur: moteur, nouveau: !comptes.isEmpty, retour: ici) }))
            if !comptes.isEmpty { items.append(SalonMenuItem(label: "Se déconnecter", detail: comptes.first { $0.2 }?.1, icon: "rectangle.portrait.and.arrow.right", destructive: true, action: { DispatchQueue.global().async { _ = PCHome.run(["deconnexion"]); DispatchQueue.main.async { ici() } } })) }
            self.menu = SalonMenu(title: "Epic Games", items: items, back: back, roue: true)
        }
    }
    func openCompteSteam(back: @escaping () -> Void) {
        let ici: () -> Void = { self.openCompteSteam(back: back) }
        menu = SalonMenu(title: "Steam", items: [SalonMenuItem(label: "Un instant", icon: "hourglass", info: true, action: {})], back: back, roue: true)
        etatComptes { _, actif, comptes in
            guard self.menu?.title == "Steam" else { return }
            var items: [SalonMenuItem] = comptes.map { n in
                SalonMenuItem(label: n + (n == actif ? " : actif" : ""), detail: n == actif ? nil : "Passer sur ce compte", icon: n == actif ? "checkmark.circle.fill" : "person.crop.circle", tint: n == actif ? .green : .gray, action: {
                    if n == actif { return }; _ = PCHome.steam(["compte-choisir", n]); ici() })
            }
            items.append(SalonMenuItem(label: comptes.isEmpty ? "Se connecter" : "Ajouter un compte", icon: "person.crop.circle.badge.plus", tint: .blue, action: { self.connecterSteam(retour: ici) }))
            if actif != nil { items.append(SalonMenuItem(label: "Se déconnecter", detail: actif, icon: "rectangle.portrait.and.arrow.right", destructive: true, action: { _ = PCHome.steam(["deconnexion"]); ici() })) }
            self.menu = SalonMenu(title: "Steam", items: items, back: back, roue: true)
        }
    }
    /// Depuis « Ajouter un jeu » : la bibliothèque d'un service. S'il manque quelque chose (le moteur, un compte), Home le fait d'abord puis y revient.
    func ouvrirBibliotheque(_ service: String, back: @escaping () -> Void) {
        let ici: () -> Void = { self.ouvrirBibliotheque(service, back: back) }
        toast = nil
        etatComptes { e, steamActif, _ in
            if service == "steam" {
                if steamActif == nil { self.connecterSteam(retour: { PCHome.steamPret && (PCHome.json(PCHome.steam(["etat"])) as? [String: Any])?["compte"] as? String != nil ? ici() : back() }) }
                else { self.openBibliothequeSteam(back: back) }
            } else {
                let moteur = e["voile"] as? String != nil && e["legendary"] as? Bool == true
                if !moteur || e["compte"] as? String == nil { self.connecterEpic(moteur: moteur, nouveau: false, retour: { (PCHome.json(PCHome.run(["etat"])) as? [String: Any])?["compte"] as? String != nil || !moteur ? ici() : back() }) }
                else { self.openBibliotheque(back: back) }
            }
        }
    }
    /// Se connecter à Epic : une fenêtre de Home affiche la page de connexion d'Epic ; le code est lu tout seul à la fin
    func connexionEpic(retour: @escaping () -> Void) { connexionEpicFenetre(retour: retour) }
    private func finirEpic(_ code: String, retour: @escaping () -> Void) {
        toast = "Connexion à Epic…"
        DispatchQueue.global().async {
            let s = PCHome.run(["connexion", code] + (self.epicNouveau ? ["--nouveau"] : []), timeout: 60)
            DispatchQueue.main.async { self.epicNouveau = false; self.toast = PCHome.echec(s) ?? "Connecté à Epic Games"; retour() }
        }
    }
    func connexionEpicFenetre(retour: @escaping () -> Void) {
        menu = nil; toast = "Connecte-toi dans la fenêtre d'Epic Games"
        ConnexionEpic.ouvrir { code in
            guard let code else { retour(); return }
            self.finirEpic(code, retour: retour)
        }
    }
    /// Un nom pour la tuile d'un jeu ajouté à la main
    private func demanderNom(_ propose: String, _ message: String) -> String? {
        let a = NSAlert(); a.messageText = "Nom du jeu"; a.informativeText = message
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); f.stringValue = propose; a.accessoryView = f; a.window.initialFirstResponder = f
        a.addButton(withTitle: "Continuer"); a.addButton(withTitle: "Annuler")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let n = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); return n.isEmpty ? nil : n
    }
    private func choisirWindows(_ message: String, _ extensions: [String]) -> URL? {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.message = message
        p.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }; p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return p.runModal() == .OK ? p.url : nil
    }
    /// Un jeu Windows déjà installé (un dossier avec son .exe) : son .exe devient une tuile. 64 bits : moteur Linux de Voile ; 32 bits ou .NET : moteur Rosetta
    func ajouterExe(prefixe: String? = nil, exe: URL? = nil, nom: String? = nil) {
        guard let u = exe ?? choisirWindows("Le programme du jeu (.exe), dans son dossier d'installation", ["exe"]) else { return }
        if let b = Compat.entree(nom: nom ?? u.deletingPathExtension().lastPathComponent), b.etat == "bloque" { openBloque(b.nom, b); return }
        guard let n = nom ?? demanderNom(u.deletingPathExtension().lastPathComponent, "Le nom affiché dans Home, et celui qui sert à trouver sa jaquette.") else { return }
        if let b = Compat.entree(nom: n), b.etat == "bloque" { openBloque(n, b); return }
        menu = nil
        DispatchQueue.global().async {
            let s = PCHome.run(["ajouter-exe", u.path, "--nom", n] + (prefixe.map { ["--prefixe", $0] } ?? []))
            DispatchQueue.main.async {
                if let e = PCHome.echec(s) { self.toast = e; return }
                let m = (PCHome.json(s) as? [String: Any])?["moteur"] as? String
                self.load(); self.toast = "\(n) ajouté\(m == "rosetta" ? " (moteur 32 bits)" : "")"
            }
        }
    }
    /// Installer un jeu depuis son installateur Windows (setup.exe, .msi) : il tourne sur le moteur Rosetta de Voile (32 bits), dans un
    /// Windows neuf réservé à ce jeu ; à la fin, Home demande lequel des programmes installés est le jeu
    func installerDepuisSetup(fichier: URL? = nil) {
        guard let u = fichier else {
            proposer("Quel installateur ?", icone: "shippingbox.fill", chercher: { Library.fichiersCandidats(ext: ["exe", "msi"], priorite: ["setup", "install"]) },
                     finder: { self.choisirWindows("L'installateur du jeu (setup.exe ou .msi)", ["exe", "msi"]).map { [$0] } },
                     back: { self.openAddMenu() }) { self.installerDepuisSetup(fichier: $0[0]) }
            return }
        guard let n = demanderNom(u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: #"(?i)[ _-]*(setup|install(er)?)[ _-]*"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces), "Le nom du jeu que cet installateur installe.") else { return }
        if let b = Compat.entree(nom: n), b.etat == "bloque" { openBloque(n, b); return }
        menu = nil; toast = "Préparation de Windows, puis l'installateur s'ouvre (une minute)…"
        NotificationCenter.default.post(name: .salonHide, object: nil)   // la fenêtre de l'installateur passe devant Home
        DispatchQueue.global().async {
            let s = PCHome.run(["setup", u.path, "--nom", n], timeout: 3 * 3600)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .salonShow, object: nil)
                if let e = PCHome.echec(s) { self.toast = e; return }
                guard let r = PCHome.json(s) as? [String: Any], let pre = r["prefixe"] as? String, let c = r["candidats"] as? [[String: Any]], !c.isEmpty else {
                    self.toast = "L'installateur n'a installé aucun programme (annulé ?)"; return }
                let items: [SalonMenuItem] = c.compactMap { j in
                    guard let e = j["exe"] as? String else { return nil }
                    let court = e.components(separatedBy: "/drive_c/").last.map { "C:/" + $0 } ?? e
                    return SalonMenuItem(label: (e as NSString).lastPathComponent, detail: court, icon: "play.rectangle.fill", action: { self.ajouterExe(prefixe: pre, exe: URL(fileURLWithPath: e), nom: n) })
                }
                self.menu = SalonMenu(title: "Quel est le programme du jeu ?", subtitle: n, items: items, hero: "questionmark.app.fill", text: "L'installation est finie. Choisis le programme qui lance le jeu (souvent le plus gros, en haut).")
            }
        }
    }
    /// Se connecter à Steam : par QR code (rien à taper), ou directement avec le nom du compte et le mot de passe
    func connexionSteam(retour: @escaping () -> Void) {
        menu = SalonMenu(title: "Connexion à Steam", subtitle: "Comment veux-tu te connecter ?", items: [
            SalonMenuItem(label: "QR code", detail: "Avec l'app Steam du téléphone", icon: "qrcode", tint: .blue, action: { self.connexionSteamQR(retour: retour) }),
            SalonMenuItem(label: "Identifiant et mot de passe", detail: "Directement ici", icon: "key.fill", action: { self.connexionSteamIdentifiants(retour: retour) }),
        ], hero: "person.crop.circle.badge.plus", text: "Ton mot de passe part chiffré vers Steam et n'est gardé nulle part. Seule la session est rangée dans le trousseau de macOS.", back: retour)
    }
    func connexionSteamQR(retour: @escaping () -> Void) {
        menu = nil; toast = "Scanne le QR code avec l'app Steam de ton téléphone"
        ConnexionSteam.ouvrir { compte, erreur in
            if let compte { self.toast = "Connecté à Steam : \(compte)" } else if let erreur { self.toast = erreur }
            retour()
        }
    }
    /// Connexion directe : une fenêtre web de Home demande le nom du compte et le mot de passe, puis Steam Guard — validation dans
    /// l'app Steam, ou code à saisir dans la même fenêtre.
    func connexionSteamIdentifiants(retour: @escaping () -> Void) {
        menu = nil
        FormulaireSteam.ouvrir { v in
            guard let v, v.count == 2 else { retour(); return }
            self.connexionSteamAvec(v[0], v[1], retour: retour)
        }
    }
    private func connexionSteamAvec(_ nom: String, _ mdp: String, retour: @escaping () -> Void) {
        toast = "Connexion à Steam…"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [Atelier.outils.appendingPathComponent("steam.command").path, "connexion-identifiants"]
        p.environment = ProcessInfo.processInfo.environment.merging(Dossiers.env, uniquingKeysWith: { $1 })
        let entree = Pipe(), sortie = Pipe(); p.standardInput = entree; p.standardOutput = sortie; p.standardError = FileHandle.nullDevice
        var tampon = Data(); var fini = false
        let conclure: (String) -> Void = { message in if fini { return }; fini = true; self.toast = message; retour() }
        sortie.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; guard !d.isEmpty else { return }
            DispatchQueue.main.async {
                tampon.append(d)
                while let r = tampon.firstIndex(of: 0x0a) {
                    let ligne = String(decoding: tampon[tampon.startIndex..<r], as: UTF8.self); tampon.removeSubrange(tampon.startIndex...r)
                    if ligne.hasPrefix("ÉCHEC : ") { conclure(String(ligne.dropFirst(8))); continue }
                    guard let j = (try? JSONSerialization.jsonObject(with: Data(ligne.utf8))) as? [String: Any] else { continue }
                    switch j["ev"] as? String {
                    case "telephone": self.toast = "Valide la connexion dans l'app Steam de ton téléphone"
                    case "email": self.toast = "Valide la connexion dans l'e-mail que Steam vient d'envoyer"
                    case "code":
                        let texte = (j["par"] as? String) == "email" ? "Steam a envoyé un code par e-mail\((j["vers"] as? String).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? "")." : "Le code affiché par l'app Steam (Steam Guard)."
                        FormulaireSteam.ouvrir(code: texte) { v in entree.fileHandleForWriting.write(Data(((v?.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)) }
                    case "connecte": conclure("Connecté à Steam : \(j["compte"] as? String ?? "")")
                    default: if j["absent"] != nil { conclure("L'outil Steam n'est pas encore préparé") }
                    }
                }
            }
        }
        p.terminationHandler = { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sortie.fileHandleForReading.readabilityHandler = nil; conclure("Connexion à Steam interrompue") } }
        guard (try? p.run()) != nil else { conclure("L'outil Steam ne démarre pas"); return }
        Commande.gardes.removeAll { !$0.isRunning }; Commande.gardes.append(p)
        // le nom et le mot de passe passent par l'entrée de l'outil (jamais par sa ligne de commande), puis sont oubliés ici
        entree.fileHandleForWriting.write(Data((nom + "\n" + mdp + "\n").utf8))
    }
    /// La bibliothèque Steam du compte, avec la compatibilité de chaque jeu : un jeu bloqué montre sa raison, les autres s'installent
    /// (steam.command installer, le circuit d'Obelisk piloté par home-steam)
    func openBibliothequeSteam(back: @escaping () -> Void) {
        menu = SalonMenu(title: "Bibliothèque Steam", subtitle: "Lecture de ta bibliothèque…", items: [SalonMenuItem(label: "Un instant…", icon: "hourglass", info: true, action: {})], hero: "books.vertical.fill", back: back)
        DispatchQueue.global().async {
            let s = PCHome.steam(["bibliotheque"], timeout: 120); let l = PCHome.json(s) as? [[String: Any]]
            DispatchQueue.main.async {
                guard self.menu?.title == "Bibliothèque Steam" else { return }
                guard let l else { self.toast = PCHome.echec(s) ?? "Bibliothèque illisible"; back(); return }
                let ici: () -> Void = { self.openBibliothequeSteam(back: back) }
                let items: [SalonMenuItem] = l.compactMap { j in
                    guard let app = j["app"] as? Int, let nom = j["nom"] as? String, !nom.isEmpty else { return nil }
                    let c = Compat.entree(steam: String(app), nom: nom)
                    if let c, c.etat == "bloque" { return SalonMenuItem(label: nom, detail: "Incompatible — " + (c.raison ?? ""), icon: "xmark.shield.fill", tint: .red, action: { self.openBloque(nom, c, back: ici) }) }
                    if j["windows"] as? Bool == false { return SalonMenuItem(label: nom, detail: "Pas de version Windows", icon: "minus.circle", tint: .gray, info: true, action: {}) }
                    let detail = c?.etat == "verifie" ? "Vérifié sur Mac" : c?.etat == "linux" ? "Fonctionne sous Linux — pas encore confirmé sur Mac" : "Pas encore testé"
                    return SalonMenuItem(label: nom, detail: detail, icon: c?.etat == "verifie" ? "checkmark.seal.fill" : "circle", tint: c?.etat == "verifie" ? .green : c?.etat == "linux" ? .teal : .gray, image: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(app)/library_600x900.jpg"), action: {
                        if PCHome.jeuxSteam().contains(where: { $0.app == "steam:\(app)" }) { self.toast = "\(nom) est déjà installé"; return }
                        self.menu = SalonMenu(title: "Installer", subtitle: nom, items: [
                            SalonMenuItem(label: "Télécharger et installer", detail: detail, icon: "arrow.down.circle.fill", tint: .green, action: { self.menu = nil; self.lancer("steam.command", ["installer", String(app)], titre: "Installation de \(nom)") }),
                        ], hero: "arrow.down.circle.fill", text: "Au premier jeu, Home télécharge aussi le moteur Windows et les composants Steam de Valve.", back: ici) })
                }
                let boutique = SalonMenuItem(label: "Boutique", detail: "Ajoute un jeu à ton compte, puis actualise", icon: "cart.fill", tint: .blue, action: { NSWorkspace.shared.open(URL(string: "https://store.steampowered.com")!) })
                self.menu = SalonMenu(title: "Bibliothèque Steam", subtitle: "\(items.count) jeux", items: [boutique] + items, hero: "books.vertical.fill", back: back, rafraichir: ici)
            }
        }
    }
    /// La bibliothèque Epic du compte : chaque jeu avec sa compatibilité ; un jeu bloqué montre sa raison, les autres s'installent
    func openBibliotheque(back: @escaping () -> Void) {
        menu = SalonMenu(title: "Bibliothèque Epic Games", subtitle: "Lecture de ta bibliothèque…", items: [SalonMenuItem(label: "Un instant…", icon: "hourglass", info: true, action: {})], hero: "books.vertical.fill", back: back)
        DispatchQueue.global().async {
            let s = PCHome.run(["bibliotheque"], timeout: 120); let l = PCHome.json(s) as? [[String: Any]]
            DispatchQueue.main.async {
                guard self.menu?.title == "Bibliothèque Epic Games" else { return }
                guard let l else { self.toast = PCHome.echec(s) ?? "Bibliothèque illisible"; back(); return }
                let ici: () -> Void = { self.openBibliotheque(back: back) }
                let items: [SalonMenuItem] = l.compactMap { j in
                    guard let app = j["app"] as? String, let nom = j["nom"] as? String else { return nil }
                    let etat = j["etat"] as? String ?? "inconnu", installe = j["installe"] as? Bool ?? false
                    if etat == "bloque" {
                        let b = Compat.Jeu(nom: nom, epic: app, espace: nil, steam: nil, etat: etat, raison: j["raison"] as? String, preuve: j["preuve"] as? String)
                        return SalonMenuItem(label: nom, detail: "Incompatible — " + (b.raison ?? ""), icon: "xmark.shield.fill", tint: .red, action: { self.openBloque(nom, b, back: ici) })
                    }
                    let detail = installe ? "Installé" : etat == "verifie" ? "Vérifié sur Mac" : etat == "linux" ? "Fonctionne sous Linux — pas encore confirmé sur Mac" : (j["lanceur"] as? String).map { "Passe par le lanceur \($0) — pas testé" } ?? "Pas encore testé"
                    return SalonMenuItem(label: nom, detail: detail, icon: installe ? "checkmark.circle.fill" : etat == "verifie" ? "checkmark.seal.fill" : "arrow.down.circle", tint: installe || etat == "verifie" ? .green : etat == "linux" ? .teal : .gray, image: (j["image"] as? String).flatMap { URL(string: $0) }, action: {
                        if installe { self.toast = "\(nom) est déjà installé"; return }
                        self.menu = SalonMenu(title: "Installer", subtitle: nom, items: [
                            SalonMenuItem(label: "Télécharger et installer", detail: detail, icon: "arrow.down.circle.fill", tint: .green, action: { self.menu = nil; self.lancer("pc.command", ["installer", app], titre: "Installation de \(nom)") }),
                        ], hero: "arrow.down.circle.fill", back: ici) })
                }
                let boutique = SalonMenuItem(label: "Boutique", detail: "Ajoute un jeu à ton compte, puis actualise", icon: "cart.fill", tint: .purple, action: { NSWorkspace.shared.open(URL(string: "https://store.epicgames.com")!) })
                self.menu = SalonMenu(title: "Bibliothèque Epic Games", subtitle: "\(items.count) jeux", items: [boutique] + items, hero: "books.vertical.fill", back: back, rafraichir: ici)
            }
        }
    }
    func openAddMenu(back: (() -> Void)? = nil) {
        if menu == nil { Sounds.shared.play("ouvrir") }
        let ici: () -> Void = { self.openAddMenu(back: back) }
        menu = SalonMenu(title: "Ajouter un jeu", subtitle: "Que veux-tu ajouter ?", items: [
            SalonMenuItem(label: "Switch", icon: "logo:switch", tint: .red, action: {
                if !Atelier.nxnativePret && !Atelier.mngPret { self.openPreparation(back: ici); return }   // aucun moteur : d'abord préparer ce Mac
                self.assistant(Assistant(moteur: "nxnative", etapes: ["base", "moteur", "maj", "dlc", "recap"]), 0, retour: ici) }),
            SalonMenuItem(label: "Epic Games", icon: "logo:epic", tint: .purple, action: { self.ouvrirBibliotheque("epic", back: ici) }),
            SalonMenuItem(label: "Steam", icon: "logo:steam", tint: .blue, action: { self.ouvrirBibliotheque("steam", back: ici) }),
            SalonMenuItem(label: "App Mac", icon: "apple.logo", tint: .gray, action: { self.addGame(back: ici) }),
            SalonMenuItem(label: "Jeu Windows", detail: "setup.exe ou .msi", icon: "logo:windows", tint: .blue, action: { self.installerDepuisSetup() }),
            SalonMenuItem(label: "Jeu Windows préinstallé", detail: "Son .exe", icon: "folder.fill", tint: .orange, action: { self.ajouterExe() }),
        ].filter { i in (self.modeNintendo || i.label != "Switch") && (self.modePC || !["Epic Games", "Steam", "Jeu Windows", "Jeu Windows préinstallé"].contains(i.label)) },   // seulement ce que le mode d'utilisation comprend
        hero: "plus.app.fill", back: back)
    }
}
