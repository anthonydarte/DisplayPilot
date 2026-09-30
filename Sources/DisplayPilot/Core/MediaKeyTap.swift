import AppKit
import ApplicationServices

/// Intercepte les touches luminosité / volume (événements NX_SYSDEFINED)
/// pour piloter les écrans externes en DDC. Nécessite l'autorisation Accessibilité.
@MainActor
final class MediaKeyTap {
    static let shared = MediaKeyTap()

    private var tap: CFMachPort?
    private var retryTimer: Timer?

    // Codes NX_KEYTYPE_*
    private enum Code: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// La demande système n'est affichée qu'une seule fois (premier lancement).
    /// Ensuite, l'état est visible et corrigeable dans Réglages › Autorisations.
    func start(prompt: Bool? = nil) {
        guard tap == nil else { return }
        let alreadyAsked = UserDefaults.standard.bool(forKey: "axPromptShown")
        let showPrompt = prompt ?? !alreadyAsked
        if showPrompt { UserDefaults.standard.set(true, forKey: "axPromptShown") }
        let opts = ["AXTrustedCheckOptionPrompt": showPrompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            // On réessaie en silence jusqu'à ce que l'autorisation soit accordée.
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task { @MainActor in
                    if AXIsProcessTrusted() {
                        MediaKeyTap.shared.retryTimer?.invalidate()
                        MediaKeyTap.shared.retryTimer = nil
                        MediaKeyTap.shared.start(prompt: false)
                    }
                }
            }
            return
        }

        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                // Le tap est branché sur la run loop principale : on est déjà sur le MainActor.
                let swallow = MainActor.assumeIsolated { me.shouldSwallow(type: type, event: event) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: ctx)
        else { return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// `true` = l'app gère la touche et l'événement est avalé.
    private func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        let pass = false
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type.rawValue == 14,
              let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == 8 else { return pass }

        let data1 = ns.data1
        guard let code = Code(rawValue: (data1 & 0xFFFF_0000) >> 16) else { return pass }
        let isDown = ((data1 & 0xFF00) >> 8) == 0x0A
        let fine = ns.modifierFlags.contains([.shift, .option])

        let key: DisplayManager.MediaKey
        switch code {
        case .brightnessUp: key = .brightnessUp
        case .brightnessDown: key = .brightnessDown
        case .soundUp: key = .volumeUp
        case .soundDown: key = .volumeDown
        case .mute: key = .mute
        }
        return DisplayManager.shared.handleMediaKey(key, isDown: isDown, fine: fine)
    }
}
