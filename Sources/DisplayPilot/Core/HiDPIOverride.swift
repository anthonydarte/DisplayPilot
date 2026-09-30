import Foundation

struct HiDPIResolution: Hashable, Identifiable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
}

/// Génère et installe un fichier d'override d'écran dans
/// /Library/Displays/Contents/Resources/Overrides (mécanisme natif de macOS).
/// Pas de daemon root permanent : l'écriture passe par une invite administrateur ponctuelle.
enum HiDPIOverride {
    static let root = "/Library/Displays/Contents/Resources/Overrides"

    static func directory(vendor: UInt32) -> String {
        "\(root)/DisplayVendorID-\(String(vendor, radix: 16))"
    }

    static func path(vendor: UInt32, model: UInt32) -> String {
        "\(directory(vendor: vendor))/DisplayProductID-\(String(model, radix: 16))"
    }

    static func exists(vendor: UInt32, model: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: path(vendor: vendor, model: model))
    }

    /// Largeur logique HiDPI maximale acceptée par les puces Apple (rendu 2× = 7680 px).
    static let maxHiDPIWidth = 3840

    /// Résolutions logiques proposées, au format de l'écran.
    /// `beyondNative` ajoute les définitions supérieures au natif (plus d'espace, rendu 2× puis réduit).
    static func candidates(nativeWidth: Int, nativeHeight: Int, beyondNative: Bool) -> [HiDPIResolution] {
        let widths = [640, 720, 800, 960, 1024, 1152, 1280, 1344, 1440, 1536, 1600, 1680, 1792, 1856, 1920,
                      2048, 2176, 2304, 2400, 2560, 2688, 2880, 3008, 3200, 3360, 3440, 3600, 3840]
        let limit = beyondNative ? maxHiDPIWidth : min(nativeWidth, maxHiDPIWidth)
        let ratio = Double(nativeHeight) / Double(max(nativeWidth, 1))
        let all = Set(widths + [nativeWidth]).filter { $0 <= limit }
        return all.sorted().map { w in
            var h = Int((Double(w) * ratio).rounded())
            if h % 2 == 1 { h += 1 }
            return HiDPIResolution(width: w, height: h)
        }
    }

    static func plistData(name: String, vendor: UInt32, model: UInt32,
                          resolutions: [HiDPIResolution]) throws -> Data {
        func be(_ values: [UInt32]) -> Data {
            var data = Data()
            for v in values { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
            return data
        }
        var scale: [Data] = []
        for r in resolutions.sorted(by: { $0.width > $1.width }) {
            // Mode HiDPI : définition de rendu 2x + drapeaux 0x1 / 0x200000
            scale.append(be([UInt32(r.width * 2), UInt32(r.height * 2), 0x1, 0x0020_0000]))
            // Mode standard équivalent
            scale.append(be([UInt32(r.width), UInt32(r.height)]))
        }
        let dict: [String: Any] = [
            "DisplayProductName": "\(name) (DisplayPilot)",
            "DisplayVendorID": Int(vendor),
            "DisplayProductID": Int(model),
            "scale-resolutions": scale,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    static func install(name: String, vendor: UInt32, model: UInt32,
                        resolutions: [HiDPIResolution]) -> String? {
        do {
            let data = try plistData(name: name, vendor: vendor, model: model, resolutions: resolutions)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("DisplayPilot-override-\(UUID().uuidString).plist")
            try data.write(to: tmp)
            let dst = path(vendor: vendor, model: model)
            let cmd = [
                "mkdir -p '\(directory(vendor: vendor))'",
                "cp '\(tmp.path)' '\(dst)'",
                "chown root:wheel '\(dst)'",
                "chmod 644 '\(dst)'",
                "defaults write /Library/Preferences/com.apple.windowserver.plist DisplayResolutionEnabled -bool true",
                "rm -f '\(tmp.path)'",
            ].joined(separator: " && ")
            return runAsAdmin(cmd)
        } catch {
            return error.localizedDescription
        }
    }

    static func remove(vendor: UInt32, model: UInt32) -> String? {
        runAsAdmin("rm -f '\(path(vendor: vendor, model: model))'")
    }

    /// Retourne nil si OK, sinon le message d'erreur.
    private static func runAsAdmin(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { return err[NSAppleScript.errorMessage] as? String ?? "Erreur inconnue" }
        return nil
    }
}
