import AppKit
import CoreGraphics

struct DisplayModeInfo: Identifiable, Hashable, Codable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Double

    var id: String { "\(width)x\(height)-\(pixelWidth)x\(pixelHeight)@\(Int(refresh.rounded()))" }
    var isHiDPI: Bool { pixelWidth > width }
    var label: String {
        "\(width)×\(height)" + (refresh > 0 ? " · \(Int(refresh.rounded())) Hz" : "")
    }

    init(_ m: CGDisplayMode) {
        width = m.width; height = m.height
        pixelWidth = m.pixelWidth; pixelHeight = m.pixelHeight
        refresh = m.refreshRate
    }

    func sameResolution(as m: CGDisplayMode) -> Bool {
        m.width == width && m.height == height && m.pixelWidth == pixelWidth && m.pixelHeight == pixelHeight
    }
}

/// Taille logique d'une résolution (indépendamment du HiDPI et de la fréquence).
struct ResSize: Hashable, Identifiable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
    var label: String { "\(width)×\(height)" }
}

struct Display: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var key: String
    var isBuiltin: Bool
    var isMain: Bool
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    var bounds: CGRect
    var currentMode: DisplayModeInfo?
    var modes: [DisplayModeInfo]
    var brightness: Double?
    var volume: Double?
    var muted: Bool
    var hasDDC: Bool
    var rotation: Int = 0
    var canRotate: Bool = false

    /// Tailles logiques disponibles, de la plus grande à la plus petite.
    var sizes: [ResSize] {
        Array(Set(modes.map { ResSize(width: $0.width, height: $0.height) }))
            .sorted { ($0.width, $0.height) > ($1.width, $1.height) }
    }
    func hasHiDPI(_ s: ResSize) -> Bool { modes.contains { $0.isHiDPI && $0.width == s.width && $0.height == s.height } }
    func hasStandard(_ s: ResSize) -> Bool { modes.contains { !$0.isHiDPI && $0.width == s.width && $0.height == s.height } }
}

/// Écran désactivé par l'app (toujours branché physiquement).
struct DisconnectedDisplay: Codable, Hashable, Identifiable {
    let id: CGDirectDisplayID
    let key: String
    let name: String
}

// MARK: Presets

struct PresetDisplay: Codable, Hashable {
    var key: String
    var name: String
    var enabled: Bool
    var mode: DisplayModeInfo?
    var originX: Int
    var originY: Int
    var brightness: Double?
    var rotation: Int? = nil
}

struct Preset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Empreinte de la configuration (identités de tous les écrans branchés).
    var fingerprint: String
    var displays: [PresetDisplay]
    var autoApply: Bool = true
}

// MARK: Réglages

enum Prefs {
    static let brightnessAllKey = "brightnessAllDisplays"
    static let volumeKeysKey = "volumeKeysExternal"
    static let stepKey = "keyStep"
    static let combinedKey = "combinedBrightness"
    static let softRangeKey = "softwareRange"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            brightnessAllKey: false,
            volumeKeysKey: true,
            stepKey: 1.0 / 16.0,
            combinedKey: true,
            softRangeKey: 0.3,
        ])
    }
    static var brightnessAll: Bool { UserDefaults.standard.bool(forKey: brightnessAllKey) }
    static var volumeKeys: Bool { UserDefaults.standard.bool(forKey: volumeKeysKey) }
    static var step: Double { UserDefaults.standard.double(forKey: stepKey) }
    /// Mode combiné : le bas du slider prolonge le DDC par une atténuation logicielle.
    static var combined: Bool { UserDefaults.standard.bool(forKey: combinedKey) }
    /// Part du slider réservée à l'atténuation logicielle en mode combiné (0.1 … 0.5).
    static var softRange: Double { min(max(UserDefaults.standard.double(forKey: softRangeKey), 0.1), 0.5) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
