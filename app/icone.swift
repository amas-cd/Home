// L'icône de Home, dessinée en code (nette à toutes les tailles) : sur un carré sombre arrondi, trois cartes en éventail — orange,
// bleue, violette devant — et une manette blanche sur la carte violette. Usage : swift icone.swift <sortie.png>
// Les mesures viennent de la maquette d'Anas (icône de 412 px, coin haut gauche en 90,90) : P() les ramène au canevas 1024 de macOS
// (le corps de l'icône fait 824 px, centré), l'axe vertical retourné.
import AppKit

let sortie = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let k: CGFloat = 824.0 / 412.0
func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (x - 90) * k + 100, y: 1024 - ((y - 90) * k + 100)) }
func L(_ v: CGFloat) -> CGFloat { v * k }
func C(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a) }
/// Un rectangle de la maquette (coin haut gauche, largeur, hauteur) dans le canevas
func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { let o = P(x, y + h); return NSRect(x: o.x, y: o.y, width: L(w), height: L(h)) }
func ombre(_ flou: CGFloat, _ dy: CGFloat, _ a: CGFloat) -> NSShadow { let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(a); s.shadowBlurRadius = L(flou); s.shadowOffset = NSSize(width: 0, height: -L(dy)); return s }

/// Une carte : centre, taille, rayon, angle (degrés, positif = penchée à droite), dégradé du haut vers le bas
func carte(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, rayon: CGFloat, angle: CGFloat, haut: NSColor, bas: NSColor, bord: NSColor? = nil) {
    NSGraphicsContext.saveGraphicsState()
    let c = P(cx, cy); let t = NSAffineTransform(); t.translateX(by: c.x, yBy: c.y); t.rotate(byDegrees: -angle); t.concat()
    let r = NSRect(x: -L(w) / 2, y: -L(h) / 2, width: L(w), height: L(h)); let p = NSBezierPath(roundedRect: r, xRadius: L(rayon), yRadius: L(rayon))
    NSGraphicsContext.saveGraphicsState(); ombre(14, 8, 0.35).set(); haut.setFill(); p.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: haut, ending: bas)!.draw(in: p, angle: -90)
    if let bord { bord.setStroke(); p.lineWidth = L(1.6); p.stroke() }
    NSGraphicsContext.restoreGraphicsState()
}

let img = NSImage(size: NSSize(width: 1024, height: 1024)); img.lockFocus()
// le corps : carré arrondi sombre, plus clair et bleuté en haut
let corps = NSBezierPath(roundedRect: R(90, 90, 412, 412), xRadius: L(94), yRadius: L(94))
NSGraphicsContext.saveGraphicsState(); ombre(10, 6, 0.30).set(); C(30, 32, 44).setFill(); corps.fill(); NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [C(82, 90, 124), C(52, 57, 80), C(27, 29, 39), C(24, 25, 33)], atLocations: [0, 0.35, 0.8, 1], colorSpace: .sRGB)!.draw(in: corps, angle: -90)
C(255, 255, 255, 0.10).setStroke(); corps.lineWidth = L(1.2); corps.stroke()

// les trois cartes
carte(cx: 222, cy: 296, w: 166, h: 268, rayon: 22, angle: -15, haut: C(255, 178, 58), bas: C(255, 118, 62))
carte(cx: 372, cy: 296, w: 166, h: 268, rayon: 22, angle: 15, haut: C(48, 198, 200), bas: C(40, 104, 255))
carte(cx: 296, cy: 286, w: 196, h: 278, rayon: 30, angle: 0, haut: C(140, 98, 248), bas: C(88, 48, 212), bord: C(190, 170, 255, 0.55))

// la manette : une barre arrondie en haut, deux poignées qui s'écartent, une encoche plate en bas
let m = NSBezierPath()
m.move(to: P(246, 233)); m.line(to: P(346, 233))
m.curve(to: P(364, 250), controlPoint1: P(356, 233), controlPoint2: P(362, 240))
m.line(to: P(379, 332))
m.curve(to: P(362, 356), controlPoint1: P(382, 347), controlPoint2: P(374, 356))
m.curve(to: P(345, 350), controlPoint1: P(355, 356), controlPoint2: P(350, 354))
m.line(to: P(329, 339)); m.curve(to: P(322, 337), controlPoint1: P(327, 338), controlPoint2: P(325, 337))
m.line(to: P(270, 337)); m.curve(to: P(263, 339), controlPoint1: P(267, 337), controlPoint2: P(265, 338))
m.line(to: P(247, 350))
m.curve(to: P(230, 356), controlPoint1: P(242, 354), controlPoint2: P(237, 356))
m.curve(to: P(213, 332), controlPoint1: P(218, 356), controlPoint2: P(210, 347))
m.line(to: P(228, 250))
m.curve(to: P(246, 233), controlPoint1: P(230, 240), controlPoint2: P(236, 233))
m.close()
NSGraphicsContext.saveGraphicsState(); ombre(8, 5, 0.28).set(); NSColor.white.setFill(); m.fill(); NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: C(255, 255, 255), ending: C(226, 226, 244))!.draw(in: m, angle: -90)
// la croix violette et le bouton rouge
C(92, 64, 220).setFill()
NSBezierPath(roundedRect: R(242, 277, 46, 16), xRadius: L(5), yRadius: L(5)).fill()
NSBezierPath(roundedRect: R(257, 262, 16, 46), xRadius: L(5), yRadius: L(5)).fill()
C(255, 92, 110).setFill(); NSBezierPath(ovalIn: R(318, 271, 28, 28)).fill()
img.unlockFocus()

if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: sortie))
}
