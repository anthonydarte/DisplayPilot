import Foundation
import CoreGraphics
import ObjectiveC

/// Rotation d'écran via MonitorPanel.framework (privé, utilisé par Réglages Système).
/// Toutes les méthodes sont appelées par le runtime Objective-C après vérification
/// `responds(to:)` : si Apple change l'API, la rotation est simplement indisponible.
enum Rotation {
    private static let loaded: Bool =
        dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil

    /// Angle actuel (API publique).
    static func current(_ id: CGDirectDisplayID) -> Int {
        Int(CGDisplayRotation(id).rounded())
    }

    static func canRotate(_ id: CGDirectDisplayID) -> Bool {
        guard let d = mpDisplay(id) else { return false }
        return callBool(d, "canChangeOrientation") ?? true
    }

    @discardableResult
    static func set(_ id: CGDirectDisplayID, degrees: Int) -> Bool {
        guard let d = mpDisplay(id) else { return false }
        let sel = NSSelectorFromString("setOrientation:")
        guard d.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> Void
        unsafeBitCast(d.method(for: sel), to: Fn.self)(d, sel, Int32(((degrees % 360) + 360) % 360))
        return true
    }

    // MARK: Accès MonitorPanel

    private static func mpDisplay(_ id: CGDirectDisplayID) -> NSObject? {
        guard loaded, let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        let mgr = cls.init()                      // instance fraîche : liste d'écrans à jour
        let sel = NSSelectorFromString("displays")
        guard mgr.responds(to: sel),
              let list = mgr.perform(sel)?.takeUnretainedValue() as? [NSObject] else { return nil }
        return list.first { callInt($0, "displayID").map { CGDirectDisplayID($0) } == id }
    }

    private static func callInt(_ obj: NSObject, _ name: String) -> Int32? {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int32
        return unsafeBitCast(obj.method(for: sel), to: Fn.self)(obj, sel)
    }

    private static func callBool(_ obj: NSObject, _ name: String) -> Bool? {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(obj.method(for: sel), to: Fn.self)(obj, sel)
    }
}
