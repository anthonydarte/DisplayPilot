import Foundation
import IOKit
import CoreGraphics

/// Codes VCP (MCCS) utiles.
enum VCP {
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12
    static let inputSource: UInt8 = 0x60
    static let volume: UInt8 = 0x62
    static let mute: UInt8 = 0x8D   // 1 = muet, 2 = son actif
}

/// Service AV d'un écran externe, avec l'identité lue dans l'IORegistry.
struct DDCService {
    let service: OpaquePointer
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
    let name: String?
    // Diagnostic
    let entryID: UInt64
    let location: String?
    let identitySource: String
}

/// DDC/CI pour Apple Silicon via IOAVService (même principe que MonitorControl).
enum DDC {
    /// File série : le bus I2C n'aime pas les accès concurrents.
    static let queue = DispatchQueue(label: "fr.darte.DisplayPilot.ddc", qos: .userInitiated)
    static let writer = DDCWriter()

    private static var serviceCache: [UInt64: OpaquePointer] = [:]
    private static let cacheLock = NSLock()

    // MARK: Découverte

    /// Parcourt l'IORegistry à la recherche des DCPAVServiceProxy externes.
    /// L'identité de l'écran est cherchée, dans l'ordre :
    ///  1. sur le proxy lui-même et ses parents (DisplayAttributes / EDID UUID) ;
    ///  2. sur le dernier framebuffer rencontré (AppleCLCD2, IOMobileFramebufferShim…).
    /// Sur M4/M5, l'identité n'est souvent exposée que via "EDID UUID".
    static func discover() -> [DDCService] {
        guard let create = PrivateAPI.avCreate else { return [] }
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [DDCService] = []
        var lastIdentity: Identity?
        let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { nameBuf.deallocate() }

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, nameBuf) == KERN_SUCCESS else { continue }
            let name = String(cString: nameBuf)

            if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim")
                || name.contains("IOMobileFramebufferAP") || name.hasPrefix("dispext") {
                if let id = identity(of: entry, searchParents: false) { lastIdentity = id }
                continue
            }
            guard name == "DCPAVServiceProxy" else { continue }
            let location = property(entry, "Location") as? String
            if location == "Embedded" { continue }     // écran intégré : pas de DDC

            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &entryID)
            cacheLock.lock()
            var svc = serviceCache[entryID]
            if svc == nil, let created = create(kCFAllocatorDefault, entry) {
                svc = created                      // conservé pour la durée de vie de l'app
                serviceCache[entryID] = created
            }
            cacheLock.unlock()
            guard let svc else { continue }

            let own = identity(of: entry, searchParents: true)
            let id = own ?? lastIdentity
            result.append(DDCService(
                service: svc,
                vendor: id?.vendor ?? 0,
                product: id?.product ?? 0,
                serial: id?.serial ?? 0,
                name: id?.name,
                entryID: entryID,
                location: location,
                identitySource: own != nil ? "proxy:\(own!.source)" : (lastIdentity.map { "framebuffer:\($0.source)" } ?? "aucune")))
            lastIdentity = nil
        }
        return result
    }

    struct Identity {
        var vendor: UInt32
        var product: UInt32
        var serial: UInt32
        var name: String?
        var source: String
    }

    /// Lit l'identité d'un écran depuis les différentes propriétés possibles.
    static func identity(of entry: io_registry_entry_t, searchParents: Bool) -> Identity? {
        func prop(_ key: String) -> Any? {
            if searchParents {
                return IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            return property(entry, key)
        }
        // 1. DisplayAttributes (M1/M2/M3)
        if let attrs = prop("DisplayAttributes") as? [String: Any],
           let p = attrs["ProductAttributes"] as? [String: Any],
           let v = (p["LegacyManufacturerID"] as? NSNumber)?.uint32Value, v != 0 {
            return Identity(vendor: v,
                            product: (p["ProductID"] as? NSNumber)?.uint32Value ?? 0,
                            serial: (p["SerialNumber"] as? NSNumber)?.uint32Value ?? 0,
                            name: p["ProductName"] as? String,
                            source: "DisplayAttributes")
        }
        // 2. EDID UUID, ex. "10AC3D42-0000-0000-0C20-0104A5301B78" → vendor 0x10AC, produit 0x3D42
        var uuid = prop("EDID UUID") as? String
        var hintName: String?
        if uuid == nil, let hints = prop("DisplayHints") as? [String: Any] {
            uuid = hints["EDID UUID"] as? String
            hintName = hints["ProductName"] as? String
        }
        if let uuid, let parsed = parseEDIDUUID(uuid) {
            return Identity(vendor: parsed.vendor, product: parsed.product, serial: 0,
                            name: hintName, source: "EDID UUID")
        }
        return nil
    }

    static func parseEDIDUUID(_ uuid: String) -> (vendor: UInt32, product: UInt32)? {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 8,
              let v = UInt32(hex.prefix(4), radix: 16),
              let p = UInt32(hex.dropFirst(4).prefix(4), radix: 16), v != 0 else { return nil }
        return (v, p)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: Profils d'adressage
    //
    // Direct (HDMI/USB-C) : adresse I2C 0x37, offset 0x51 en écriture comme en lecture (MonitorControl, m1ddc).
    // Via une station / hub DisplayPort (branch device), certains outils utilisent l'adresse 0xB7
    // (0x37 avec le bit 0x80) et lit avec l'offset 0x00. On teste les combinaisons et on
    // mémorise celle qui répond pour chaque service.

    struct Profile: Hashable, CustomStringConvertible {
        let chip: UInt32
        let writeOffset: UInt32
        let readOffset: UInt32
        /// Somme de contrôle de la requête de lecture : 0x6E seul (MonitorControl)
        /// ou 0x6E ^ offset, conforme DDC/CI.
        let strictReadChecksum: Bool
        var readSeed: UInt8 { strictReadChecksum ? 0x6E ^ UInt8(writeOffset) : 0x6E }
        var writeSeed: UInt8 { 0x6E ^ UInt8(writeOffset) }
        var description: String {
            String(format: "chip 0x%02X / write 0x%02X / read 0x%02X / chk %@", chip, writeOffset, readOffset,
                   strictReadChecksum ? "strict" : "MC")
        }
    }

    /// Ordre de test. Les variantes 0xB7 / 0x50 / lecture offset 0 sont celles relevées
    /// pour l'adressage via station / branch device.
    static let profiles: [Profile] = [
        Profile(chip: 0x37, writeOffset: 0x51, readOffset: 0x51, strictReadChecksum: false),  // classique (HDMI OK)
        Profile(chip: 0x37, writeOffset: 0x51, readOffset: 0x00, strictReadChecksum: true),
        Profile(chip: 0xB7, writeOffset: 0x51, readOffset: 0x00, strictReadChecksum: true),
        Profile(chip: 0x37, writeOffset: 0x50, readOffset: 0x00, strictReadChecksum: true),
        Profile(chip: 0xB7, writeOffset: 0x50, readOffset: 0x00, strictReadChecksum: true),
        Profile(chip: 0xB7, writeOffset: 0x51, readOffset: 0x51, strictReadChecksum: false),
    ]

    private static var chosenProfile: [Int: Profile] = [:]     // accès uniquement depuis DDC.queue
    private static var failedAt: [Int: Date] = [:]             // échec récent : pas de nouvel essai avant 60 s
    private static func key(_ s: OpaquePointer) -> Int { Int(bitPattern: s) }

    /// Profil retenu pour un service ; détection automatique au premier appel.
    static func profile(for service: OpaquePointer) -> Profile? {
        if let p = chosenProfile[key(service)] { return p }
        if let t = failedAt[key(service)], Date().timeIntervalSince(t) < 60 { return nil }
        for p in profiles where rawRead(service, vcp: VCP.brightness, profile: p, attempts: 2) != nil {
            chosenProfile[key(service)] = p
            failedAt[key(service)] = nil
            return p
        }
        failedAt[key(service)] = Date()
        return nil
    }

    // MARK: Lecture / écriture (à appeler depuis `DDC.queue`)

    @discardableResult
    static func write(_ service: OpaquePointer, vcp: UInt8, value: UInt16) -> Bool {
        guard let avWrite = PrivateAPI.avWrite else { return false }
        let p = chosenProfile[key(service)] ?? profile(for: service) ?? profiles[0]
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(packet.dropLast(), seed: p.writeSeed)
        var ok = false
        for _ in 0..<2 {                // double envoi : certains écrans ignorent le premier
            usleep(10_000)
            let r = packet.withUnsafeMutableBytes { avWrite(service, p.chip, p.writeOffset, $0.baseAddress!, UInt32($0.count)) }
            ok = ok || r == kIOReturnSuccess
        }
        return ok
    }

    static func read(_ service: OpaquePointer, vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let p = profile(for: service) else { return nil }
        return rawRead(service, vcp: vcp, profile: p, attempts: 4)
    }

    private static func rawRead(_ service: OpaquePointer, vcp: UInt8, profile p: Profile,
                                attempts: Int) -> (current: UInt16, max: UInt16)? {
        guard let avWrite = PrivateAPI.avWrite, let avRead = PrivateAPI.avRead else { return nil }
        var packet: [UInt8] = [0x82, 0x01, vcp, 0]
        packet[3] = checksum(packet.dropLast(), seed: p.readSeed)
        for _ in 0..<attempts {
            var reply = [UInt8](repeating: 0, count: 11)
            usleep(10_000)
            let w = packet.withUnsafeMutableBytes { avWrite(service, p.chip, p.writeOffset, $0.baseAddress!, UInt32($0.count)) }
            guard w == kIOReturnSuccess else { continue }
            usleep(50_000)
            let r = reply.withUnsafeMutableBytes { avRead(service, p.chip, p.readOffset, $0.baseAddress!, UInt32($0.count)) }
            // Réponse attendue : [src, len, 0x02, result, vcp, type, maxH, maxL, curH, curL, chk]
            guard r == kIOReturnSuccess, reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else { continue }
            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let cur = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (cur, max)
        }
        return nil
    }

    /// Variante bavarde pour le diagnostic : teste chaque profil d'adressage.
    static func debugRead(_ service: OpaquePointer, vcp: UInt8,
                          writeSleep: useconds_t = 10_000, readSleep: useconds_t = 50_000) -> String {
        guard let avWrite = PrivateAPI.avWrite, let avRead = PrivateAPI.avRead else { return "API IOAVService absente" }
        var log: [String] = []
        for p in profiles {
            var packet: [UInt8] = [0x82, 0x01, vcp, 0]
            packet[3] = checksum(packet.dropLast(), seed: p.readSeed)
            log.append("  [\(p)]")
            for attempt in 1...2 {
                var reply = [UInt8](repeating: 0, count: 11)
                usleep(writeSleep)
                let w = packet.withUnsafeMutableBytes { avWrite(service, p.chip, p.writeOffset, $0.baseAddress!, UInt32($0.count)) }
                usleep(readSleep)
                let r = reply.withUnsafeMutableBytes { avRead(service, p.chip, p.readOffset, $0.baseAddress!, UInt32($0.count)) }
                let bytes = reply.map { String(format: "%02X", $0) }.joined(separator: " ")
                log.append("    essai \(attempt): write=0x\(String(UInt32(bitPattern: w), radix: 16)) read=0x\(String(UInt32(bitPattern: r), radix: 16)) [\(bytes)]")
                if w == kIOReturnSuccess, r == kIOReturnSuccess, reply[2] == 0x02, reply[4] == vcp {
                    let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
                    let cur = UInt16(reply[8]) << 8 | UInt16(reply[9])
                    log.append("    → OK : valeur \(cur) / max \(max)")
                    return log.joined(separator: "\n")
                }
            }
        }
        return log.joined(separator: "\n")
    }

    private static func checksum<S: Sequence>(_ bytes: S, seed: UInt8 = 0x6E ^ 0x51) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }
}

/// Coalescence des écritures : quand on bouge un slider, seule la dernière valeur
/// part sur le bus, pour ne pas saturer l'écran de commandes DDC.
final class DDCWriter {
    private var pending: [String: UInt16] = [:]
    private let lock = NSLock()

    func set(_ service: OpaquePointer, vcp: UInt8, value: UInt16) {
        let key = "\(Int(bitPattern: service))-\(vcp)"
        lock.lock()
        let mustSchedule = pending[key] == nil
        pending[key] = value
        lock.unlock()
        guard mustSchedule else { return }
        DDC.queue.async {
            self.lock.lock()
            let v = self.pending.removeValue(forKey: key)
            self.lock.unlock()
            if let v { DDC.write(service, vcp: vcp, value: v) }
        }
    }
}
