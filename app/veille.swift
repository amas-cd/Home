// Home (en arrière-plan) : lancé à l'ouverture de session (LaunchAgent fr.anas.home.veille), invisible. Quand une manette se connecte
// (Bluetooth ou USB : un appareil HID manette / joystick), il ouvre Home s'il n'est pas déjà ouvert. Désactivé par le fichier
// ~/Library/Application Support/Salon/veille-off (Home → Menu → Avancé).
import AppKit
import IOKit.hid

let debut = Date()
var dernier = Date.distantPast

func ouvrirHome() {
    // les manettes déjà branchées au démarrage arrivent dans les premières secondes : pas d'ouverture pour elles
    guard Date().timeIntervalSince(debut) > 4, Date().timeIntervalSince(dernier) > 8 else { return }
    if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Application Support/Salon/veille-off") { return }
    if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "fr.anas.salon" }) { return }
    dernier = Date()
    let c = NSWorkspace.OpenConfiguration(); c.activates = true
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Home.app"), configuration: c) { _, _ in }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let criteres: [[String: Any]] = [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController].map {
    [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey as String: $0] as [String: Any]
}
IOHIDManagerSetDeviceMatchingMultiple(manager, criteres as CFArray)
IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, _ in DispatchQueue.main.async { ouvrirHome() } }, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
