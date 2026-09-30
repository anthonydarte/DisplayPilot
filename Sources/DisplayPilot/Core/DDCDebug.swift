import Foundation
import CoreGraphics
import IOKit

/// Mode diagnostic en ligne de commande :
///   DisplayPilot --ddc-debug            → inventaire + test de lecture DDC
///   DisplayPilot --ddc-debug --set 30   → écrit aussi la luminosité 30 sur chaque service
@MainActor
enum DDCDebug {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--ddc-debug") else { return }
        var setValue: UInt16?
        if let i = args.firstIndex(of: "--set"), i + 1 < args.count { setValue = UInt16(args[i + 1]) }
        if args.contains("--scan") { scan() } else { run(setValue: setValue) }
        exit(0)
    }

    static func run(setValue: UInt16?) {
        print("=== DisplayPilot — diagnostic DDC ===")
        print("API : IOAVServiceCreateWithService=\(PrivateAPI.avCreate != nil) ReadI2C=\(PrivateAPI.avRead != nil) WriteI2C=\(PrivateAPI.avWrite != nil)")

        print("\n--- Écrans CoreGraphics ---")
        for id in DisplayManager.onlineIDs() {
            let v = CGDisplayVendorNumber(id), m = CGDisplayModelNumber(id), s = CGDisplaySerialNumber(id)
            print(String(format: "id=%u builtin=%d vendor=0x%04X model=0x%04X serial=0x%08X", id,
                         CGDisplayIsBuiltin(id), v, m, s))
        }

        print("\n--- Nœuds IORegistry pertinents ---")
        dumpRegistry()

        print("\n--- Services DDC retenus ---")
        let services = DDC.discover()
        if services.isEmpty { print("AUCUN") }
        for (n, svc) in services.enumerated() {
            print(String(format: "#%d entry=0x%llX location=%@ vendor=0x%04X product=0x%04X name=%@ source=%@",
                         n, svc.entryID, svc.location ?? "nil", svc.vendor, svc.product,
                         svc.name ?? "?", svc.identitySource))
            print("Lecture luminosité (VCP 0x10) :")
            print(DDC.debugRead(svc.service, vcp: VCP.brightness))
            if let v = setValue {
                let ok = DDC.write(svc.service, vcp: VCP.brightness, value: v)
                print("Écriture luminosité \(v) : \(ok ? "OK (IOReturn succès)" : "ÉCHEC")")
            }
        }
    }

    /// Essaie de créer un IOAVService sur tous les nœuds d'affichage candidats et teste
    /// une lecture DDC avec plusieurs temporisations. Lecture seule : aucun réglage modifié.
    static func scan() {
        print("=== DisplayPilot — balayage DDC (lecture seule) ===")
        guard let create = PrivateAPI.avCreate else { print("API absente"); return }
        let classes = ["DCPAVServiceProxy", "DCPAVDeviceProxy", "DCPDPDeviceProxy", "DCPDPServiceProxy",
                       "AppleDCPDPTXRemotePortUFP", "AppleDCPDPTXRemotePortProxy", "DCPAVVideoInterfaceProxy",
                       "IOAVService", "AppleDCPMCDP29XX"]
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        let nbuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { buf.deallocate(); nbuf.deallocate() }
        var lastDisp = "?"
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            IOObjectGetClass(entry, buf)
            IORegistryEntryGetName(entry, nbuf)
            let cls = String(cString: buf), name = String(cString: nbuf)
            if name.hasPrefix("disp") && !name.contains(":") && !name.contains("-") { lastDisp = name }
            guard classes.contains(where: { cls.contains($0) }) else { continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &entryID)
            let loc = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            print(String(format: "\n[%@] %@ <%@> entry=0x%llX Location=%@", lastDisp, name, cls, entryID, loc ?? "nil"))
            if lastDisp == "disp0" { print("  (écran intégré, ignoré)"); continue }
            guard let svc = create(kCFAllocatorDefault, entry) else { print("  IOAVServiceCreateWithService → nil"); continue }
            for (w, r) in [(10_000, 50_000), (40_000, 100_000)] as [(useconds_t, useconds_t)] {
                print("  timing write \(w / 1000) ms / read \(r / 1000) ms :")
                let out = DDC.debugRead(svc, vcp: VCP.brightness, writeSleep: w, readSleep: r)
                print(out)
                if out.contains("OK") { break }
            }
        }
    }

    /// Liste les nœuds liés aux écrans, avec les propriétés utiles à l'association.
    private static func dumpRegistry() {
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { nameBuf.deallocate() }
        let interesting = ["AppleCLCD2", "IOMobileFramebuffer", "DCPAVServiceProxy", "dispext", "disp0"]
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, nameBuf) == KERN_SUCCESS else { continue }
            let name = String(cString: nameBuf)
            guard interesting.contains(where: { name.contains($0) }) else { continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &entryID)
            let classBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
            defer { classBuf.deallocate() }
            IOObjectGetClass(entry, classBuf)
            var line = String(format: "%@ <%@> entry=0x%llX", name, String(cString: classBuf), entryID)
            if let loc = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String { line += " Location=\(loc)" }
            if let id = DDC.identity(of: entry, searchParents: false) {
                line += String(format: " identité=0x%04X/0x%04X (%@)", id.vendor, id.product, id.source)
            }
            print(line)
        }
    }
}
