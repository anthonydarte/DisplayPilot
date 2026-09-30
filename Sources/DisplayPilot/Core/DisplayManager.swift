import AppKit
import CoreGraphics
import Observation

@MainActor
@Observable
final class DisplayManager {
    static let shared = DisplayManager()

    private(set) var displays: [Display] = []
    private(set) var disconnected: [DisconnectedDisplay] = [] { didSet { saveDisconnected() } }
    private(set) var presets: [Preset] = [] { didSet { savePresets() } }
    private(set) var isApplying = false
    /// Écran en cours d'activation HiDPI (installation + rechargement).
    private(set) var hidpiBusy: CGDirectDisplayID?
    var lastError: String?

    @ObservationIgnored private var ddc: [CGDirectDisplayID: DDCState] = [:]
    @ObservationIgnored private var reconfigureTask: Task<Void, Never>?
    @ObservationIgnored private var lastAutoFingerprint: String?
    @ObservationIgnored private var started = false

    private struct DDCState {
        var service: OpaquePointer
        var brightness: Double?
        var brightnessMax: UInt16 = 100
        var volume: Double?
        var volumeMax: UInt16 = 100
        var muted = false
        var probed = false
        var failed = false      // l'écran ne répond pas en DDC → atténuation logicielle
    }

    /// Gamma actuellement appliqué aux écrans atténués logiciellement (1 = aucun).
    @ObservationIgnored private var softBrightness: [CGDirectDisplayID: Double] = [:]
    /// Position du slider de luminosité des écrans externes (0…1), en mode combiné ou logiciel.
    @ObservationIgnored private var levels: [CGDirectDisplayID: Double] = [:]
    /// Résolution HiDPI à appliquer dès que macOS l'expose (clé écran → taille).
    @ObservationIgnored private var pendingHiDPI: [String: ResSize] = [:]
    /// Gamma minimal : l'écran n'est jamais complètement noir.
    nonisolated static let gammaFloor = 0.15

    // MARK: Cycle de vie

    func start() {
        guard !started else { return }
        started = true
        Prefs.registerDefaults()
        loadDisconnected()
        loadPresets()
        refresh()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, info in
            guard !flags.contains(.beginConfigurationFlag), let info else { return }
            let me = Unmanaged<DisplayManager>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in me.scheduleReconfigure() }
        }, ctx)

        // Au lancement (ex. ouverture de session sur le dock), applique le preset correspondant.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.autoApplyIfNeeded()
        }
    }

    private func scheduleReconfigure() {
        reconfigureTask?.cancel()
        reconfigureTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.refresh()
            self.autoApplyIfNeeded()
        }
    }

    // MARK: Inventaire

    var fingerprint: String {
        (displays.map(\.key) + disconnected.map(\.key)).sorted().joined(separator: "|")
    }

    func refresh() {
        let ids = Self.onlineIDs()
        let externals = ids.filter { CGDisplayIsBuiltin($0) == 0 }
        let services = DDC.discover()

        // Association écran CoreGraphics ↔ service DDC
        var used = Set<Int>()
        var newDDC: [CGDirectDisplayID: DDCState] = [:]
        for id in externals {
            let v = CGDisplayVendorNumber(id), m = CGDisplayModelNumber(id), s = CGDisplaySerialNumber(id)
            let byteSwapped = ((m & 0xFF) << 8) | ((m >> 8) & 0xFF)
            let idx = services.indices.first { i in
                !used.contains(i) && services[i].vendor == v
                    && (services[i].product == m || services[i].product == byteSwapped)
                    && (services[i].serial == s || services[i].serial == 0 || s == 0)
            }
            guard let i = idx else { continue }
            used.insert(i)
            if var existing = ddc[id] {
                existing.service = services[i].service
                newDDC[id] = existing
            } else {
                newDDC[id] = DDCState(service: services[i].service)
            }
        }
        // Repli : écrans non associés ↔ services sans identité exploitable, dans l'ordre.
        let leftoverDisplays = externals.filter { newDDC[$0] == nil }
        var leftoverServices = services.indices.filter { !used.contains($0) }
        if leftoverDisplays.count == 1 && leftoverServices.count > 1 {
            // Un seul écran à associer : on privilégie les services sans identité (vendor 0).
            leftoverServices.sort { (services[$0].vendor == 0 ? 0 : 1) < (services[$1].vendor == 0 ? 0 : 1) }
        }
        for (id, i) in zip(leftoverDisplays, leftoverServices) {
            used.insert(i)
            if var existing = ddc[id] {
                existing.service = services[i].service
                newDDC[id] = existing
            } else {
                newDDC[id] = DDCState(service: services[i].service)
            }
        }
        ddc = newDDC

        var seenKeys: [String: Int] = [:]
        displays = ids.map { id in
            var key = Self.baseKey(id)
            seenKeys[key, default: 0] += 1
            if let n = seenKeys[key], n > 1 { key += "#\(n)" }   // écrans identiques sans n° de série
            return makeDisplay(id, key: key)
        }
        .sorted { ($0.isMain ? 0 : 1, $0.bounds.minX) < ($1.isMain ? 0 : 1, $1.bounds.minX) }

        // Un écran "déconnecté" qui réapparaît (réactivé ailleurs) sort de la liste.
        let onlineIDs = Set(ids)
        if disconnected.contains(where: { onlineIDs.contains($0.id) }) {
            disconnected.removeAll { onlineIDs.contains($0.id) }
        }

        for (id, st) in ddc where !st.probed { probeDDC(id, st.service) }
        reapplySoftBrightness()
    }

    private func makeDisplay(_ id: CGDirectDisplayID, key: String) -> Display {
        let builtin = CGDisplayIsBuiltin(id) != 0
        let current = CGDisplayCopyDisplayMode(id).map { DisplayModeInfo($0) }
        var brightness: Double?
        var volume: Double?
        var muted = false
        if builtin {
            var b: Float = 0
            if let get = PrivateAPI.getBrightness, get(id, &b) == 0 { brightness = Double(b) }
        } else if let st = ddc[id], !st.failed {
            brightness = levels[id] ?? level(forHardware: st.brightness ?? 0.5)
            volume = st.volume
            muted = st.muted
        } else {
            brightness = levels[id] ?? 1.0
        }
        return Display(
            id: id,
            name: Self.screenName(id),
            key: key,
            isBuiltin: builtin,
            isMain: CGDisplayIsMain(id) != 0,
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            bounds: CGDisplayBounds(id),
            currentMode: current,
            modes: Self.modes(for: id),
            brightness: brightness,
            volume: volume,
            muted: muted,
            hasDDC: ddc[id].map { !$0.failed } ?? false,
            rotation: Rotation.current(id),
            canRotate: Rotation.canRotate(id))
    }

    /// Lecture initiale des valeurs DDC (lente : faite hors du thread principal).
    private func probeDDC(_ id: CGDirectDisplayID, _ service: OpaquePointer) {
        ddc[id]?.probed = true
        DDC.queue.async {
            let b = DDC.read(service, vcp: VCP.brightness)
            let v = DDC.read(service, vcp: VCP.volume)
            let m = DDC.read(service, vcp: VCP.mute)
            Task { @MainActor in
                guard var st = self.ddc[id] else { return }
                if b == nil {
                    // Aucune réponse DDC : bascule sur l'atténuation logicielle.
                    st.failed = true
                    self.ddc[id] = st
                    if let i = self.displays.firstIndex(where: { $0.id == id }) {
                        self.displays[i].hasDDC = false
                        self.displays[i].volume = nil
                        self.displays[i].brightness = self.levels[id] ?? 1.0
                    }
                    return
                }
                if let b {
                    st.brightnessMax = max(b.max, 1)
                    st.brightness = Double(b.current) / Double(st.brightnessMax)
                }
                if let v {
                    st.volumeMax = max(v.max, 1)
                    st.volume = Double(v.current) / Double(st.volumeMax)
                }
                if let m { st.muted = m.current == 1 }
                self.ddc[id] = st
                if let i = self.displays.firstIndex(where: { $0.id == id }) {
                    let lvl = self.levels[id] ?? self.level(forHardware: st.brightness ?? 0.5)
                    self.levels[id] = lvl
                    self.displays[i].brightness = lvl
                    self.displays[i].volume = st.volume
                    self.displays[i].muted = st.muted
                }
            }
        }
    }

    // MARK: Luminosité / volume

    func setBrightness(_ id: CGDirectDisplayID, _ value: Double) {
        let v = min(max(value, 0), 1)
        if CGDisplayIsBuiltin(id) != 0 {
            _ = PrivateAPI.setBrightness?(id, Float(v))
        } else if var st = ddc[id], !st.failed {
            // DDC disponible. En mode combiné, le haut du slider pilote le rétroéclairage
            // et le bas (sous `softRange`) garde le rétroéclairage au minimum en baissant le gamma.
            levels[id] = v
            let k = Prefs.combined ? Prefs.softRange : 0
            let hw = k > 0 ? max(0, (v - k) / (1 - k)) : v
            let gamma = (k > 0 && v < k) ? Self.gammaFloor + (1 - Self.gammaFloor) * (v / k) : 1
            if st.brightness != hw {
                st.brightness = hw
                ddc[id] = st
                DDC.writer.set(st.service, vcp: VCP.brightness, value: UInt16((hw * Double(st.brightnessMax)).rounded()))
            }
            setGamma(id, gamma)
        } else {
            // Pas de DDC (ex. station qui ne relaie pas le DDC) : tout en logiciel.
            levels[id] = v
            setGamma(id, Self.gammaFloor + (1 - Self.gammaFloor) * v)
        }
        if let i = displays.firstIndex(where: { $0.id == id }) { displays[i].brightness = v }
    }

    /// Position de slider correspondant à une valeur de rétroéclairage DDC (gamma neutre).
    private func level(forHardware hw: Double) -> Double {
        Prefs.combined ? Prefs.softRange + hw * (1 - Prefs.softRange) : hw
    }

    /// Applique (ou retire) l'atténuation logicielle d'un écran.
    private func setGamma(_ id: CGDirectDisplayID, _ g: Double) {
        if g >= 0.999 {
            guard softBrightness.removeValue(forKey: id) != nil else { return }
            // Rend le profil ColorSync d'origine, puis réapplique les autres écrans atténués.
            CGDisplayRestoreColorSyncSettings()
            reapplySoftBrightness()
        } else {
            softBrightness[id] = g
            Self.applyGamma(id, g)
        }
    }

    /// Atténuation logicielle : réduit la table gamma (jamais sous le plancher).
    nonisolated static func applyGamma(_ id: CGDirectDisplayID, _ value: Double) {
        let g = Float(max(value, gammaFloor))
        CGSetDisplayTransferByFormula(id, 0, g, 1, 0, g, 1, 0, g, 1)
    }

    /// Recalcule tous les écrans après un changement de réglage (mode combiné, plage).
    func reapplyBrightnessSettings() {
        for d in displays where !d.isBuiltin {
            if let v = d.brightness { setBrightness(d.id, v) }
        }
    }

    /// macOS réinitialise le gamma lors d'une reconfiguration : on le réapplique.
    private func reapplySoftBrightness() {
        let online = Set(Self.onlineIDs())
        for (id, v) in softBrightness where online.contains(id) && v < 0.999 { Self.applyGamma(id, v) }
    }

    func setVolume(_ id: CGDirectDisplayID, _ value: Double) {
        guard var st = ddc[id] else { return }
        let v = min(max(value, 0), 1)
        st.volume = v
        if st.muted && v > 0 {
            st.muted = false
            DDC.writer.set(st.service, vcp: VCP.mute, value: 2)
        }
        ddc[id] = st
        DDC.writer.set(st.service, vcp: VCP.volume, value: UInt16((v * Double(st.volumeMax)).rounded()))
        if let i = displays.firstIndex(where: { $0.id == id }) {
            displays[i].volume = v
            displays[i].muted = st.muted
        }
    }

    func toggleMute(_ id: CGDirectDisplayID) {
        guard var st = ddc[id] else { return }
        st.muted.toggle()
        ddc[id] = st
        DDC.writer.set(st.service, vcp: VCP.mute, value: st.muted ? 1 : 2)
        if let i = displays.firstIndex(where: { $0.id == id }) { displays[i].muted = st.muted }
    }

    // MARK: Résolutions

    static func cgModes(for id: CGDirectDisplayID) -> [CGDisplayMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        return all.filter { $0.isUsableForDesktopGUI() }
    }

    static func modes(for id: CGDirectDisplayID) -> [DisplayModeInfo] {
        var seen = Set<String>()
        return cgModes(for: id)
            .map { DisplayModeInfo($0) }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.width, $0.height, $0.refresh) > ($1.width, $1.height, $1.refresh) }
    }

    private func bestCGMode(_ id: CGDirectDisplayID, _ want: DisplayModeInfo) -> CGDisplayMode? {
        Self.cgModes(for: id)
            .filter { want.sameResolution(as: $0) }
            .min { abs($0.refreshRate - want.refresh) < abs($1.refreshRate - want.refresh) }
    }

    // MARK: Résolution + HiDPI en un clic

    /// Choisit une taille logique en gardant l'état HiDPI actuel si possible.
    func selectResolution(_ id: CGDirectDisplayID, _ size: ResSize) {
        guard let d = displays.first(where: { $0.id == id }) else { return }
        let wantHiDPI = d.currentMode?.isHiDPI ?? false
        let refresh = d.currentMode?.refresh ?? 60
        let candidates = d.modes.filter { $0.width == size.width && $0.height == size.height }
        let pick = (candidates.filter { $0.isHiDPI == wantHiDPI }.isEmpty ? candidates
                    : candidates.filter { $0.isHiDPI == wantHiDPI })
            .min { abs($0.refresh - refresh) < abs($1.refresh - refresh) }
        if let pick { setMode(id, pick) }
    }

    /// Active / désactive le HiDPI sur la résolution courante. Si macOS ne propose pas encore
    /// la version HiDPI, installe l'override (mot de passe administrateur), recharge l'écran
    /// et bascule automatiquement.
    func setHiDPI(_ id: CGDirectDisplayID, _ on: Bool) {
        guard hidpiBusy == nil, let d = displays.first(where: { $0.id == id }), let cur = d.currentMode else { return }
        let size = ResSize(width: cur.width, height: cur.height)
        let twin = d.modes
            .filter { $0.width == size.width && $0.height == size.height && $0.isHiDPI == on }
            .min { abs($0.refresh - cur.refresh) < abs($1.refresh - cur.refresh) }
        if let twin { setMode(id, twin); return }
        guard on, !d.isBuiltin else { return }

        // Override couvrant toutes les résolutions (y compris au-delà du natif) : une seule installation.
        let native = Self.nativeSize(d)
        var set = Set(HiDPIOverride.candidates(nativeWidth: native.width, nativeHeight: native.height, beyondNative: true))
        for m in d.modes where !m.isHiDPI && m.width <= HiDPIOverride.maxHiDPIWidth {
            set.insert(HiDPIResolution(width: m.width, height: m.height))
        }
        set.insert(HiDPIResolution(width: size.width, height: size.height))

        hidpiBusy = id
        lastError = nil
        if let err = HiDPIOverride.install(name: d.name, vendor: d.vendor, model: d.model, resolutions: Array(set)) {
            hidpiBusy = nil
            let lower = err.lowercased()
            if !(lower.contains("cancel") || lower.contains("annul")) { lastError = "HiDPI : \(err)" }
            return
        }
        pendingHiDPI[d.key] = size
        reloadForHiDPI(d)
    }

    /// Fait relire l'override à macOS en coupant/rallumant l'écran (sans le débrancher).
    private func reloadForHiDPI(_ d: Display) {
        let others = displays.filter { $0.id != d.id }
        guard !others.isEmpty else {
            hidpiBusy = nil
            lastError = "HiDPI installé : débranche/rebranche l'écran pour l'activer."
            return
        }
        let wasMain = d.isMain
        Task { @MainActor in
            if wasMain, let other = others.first { setMain(other.id); try? await Task.sleep(for: .seconds(1)) }
            setEnabled([d.id], false)
            try? await Task.sleep(for: .seconds(2))
            setEnabled([d.id], true)
            try? await Task.sleep(for: .seconds(3))
            refresh()
            guard let now = displays.first(where: { $0.key == d.key }) else {
                hidpiBusy = nil
                return
            }
            if wasMain { setMain(now.id); try? await Task.sleep(for: .seconds(1)); refresh() }
            if let size = pendingHiDPI.removeValue(forKey: d.key),
               let cur = displays.first(where: { $0.key == d.key }) {
                if let hi = cur.modes.first(where: { $0.isHiDPI && $0.width == size.width && $0.height == size.height }) {
                    setMode(cur.id, hi)
                } else {
                    lastError = "HiDPI installé : débranche/rebranche l'écran pour que macOS le prenne en compte."
                }
            }
            hidpiBusy = nil
        }
    }

    /// Définition native = plus grand mode standard.
    nonisolated static func nativeSize(_ d: Display) -> ResSize {
        let std = d.modes.filter { !$0.isHiDPI }
        let best = (std.isEmpty ? d.modes : std).max { ($0.width * $0.height) < ($1.width * $1.height) }
        return ResSize(width: best?.width ?? 1920, height: best?.height ?? 1080)
    }

    func setMode(_ id: CGDirectDisplayID, _ mode: DisplayModeInfo) {
        guard let cg = bestCGMode(id, mode) else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        CGConfigureDisplayWithDisplayMode(cfg, id, cg, nil)
        CGCompleteDisplayConfiguration(cfg, .permanently)
    }

    /// Devient l'écran principal = placé en (0,0) ; les autres sont décalés d'autant.
    func setRotation(_ id: CGDirectDisplayID, _ degrees: Int) {
        if !Rotation.set(id, degrees: degrees) {
            lastError = "Rotation indisponible pour cet écran."
        }
    }

    /// Bascule le mode courant entre sa version HiDPI et standard (même taille logique).
    func toggleHiDPI(_ id: CGDirectDisplayID) {
        guard let d = displays.first(where: { $0.id == id }), let cur = d.currentMode else { return }
        let twin = d.modes
            .filter { $0.width == cur.width && $0.height == cur.height && $0.isHiDPI != cur.isHiDPI }
            .min { abs($0.refresh - cur.refresh) < abs($1.refresh - cur.refresh) }
        if let twin { setMode(id, twin) }
    }

    func setMain(_ id: CGDirectDisplayID) {
        guard let target = displays.first(where: { $0.id == id }), !target.isMain else { return }
        let dx = target.bounds.minX, dy = target.bounds.minY
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for d in displays {
            CGConfigureDisplayOrigin(cfg, d.id, Int32(d.bounds.minX - dx), Int32(d.bounds.minY - dy))
        }
        CGCompleteDisplayConfiguration(cfg, .permanently)
    }

    // MARK: Déconnexion logicielle

    /// Désactivation valable pour la session : une déconnexion/redémarrage
    /// réactive tout, ce qui évite de se retrouver bloqué sans écran.
    @discardableResult
    private func setEnabled(_ ids: [CGDirectDisplayID], _ enabled: Bool) -> Bool {
        guard let fn = PrivateAPI.configureDisplayEnabled else {
            lastError = "API de désactivation d'écran indisponible sur cette version de macOS."
            return false
        }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        for id in ids { _ = fn(cfg, id, enabled) }
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
    }

    func disconnect(_ targets: [Display]) {
        let active = displays.count
        let list = targets.filter { !$0.isMain }
        guard !list.isEmpty, list.count < active else { return }
        if setEnabled(list.map(\.id), false) {
            disconnected.append(contentsOf: list.map { DisconnectedDisplay(id: $0.id, key: $0.key, name: $0.name) })
        }
    }

    func disconnectAllButMain() {
        disconnect(displays.filter { !$0.isMain })
    }

    func reconnect(_ items: [DisconnectedDisplay]) {
        guard !items.isEmpty else { return }
        setEnabled(items.map(\.id), true)
        disconnected.removeAll { items.contains($0) }
    }

    func reconnectAll() { reconnect(disconnected) }

    // MARK: Presets

    func saveCurrentAsPreset(named name: String) {
        let active = displays.map {
            PresetDisplay(key: $0.key, name: $0.name, enabled: true, mode: $0.currentMode,
                          originX: Int($0.bounds.minX), originY: Int($0.bounds.minY), brightness: $0.brightness,
                          rotation: $0.rotation)
        }
        let off = disconnected.map {
            PresetDisplay(key: $0.key, name: $0.name, enabled: false, mode: nil, originX: 0, originY: 0, brightness: nil)
        }
        // Un seul preset auto par configuration : on remplace l'éventuel existant.
        presets.removeAll { $0.fingerprint == fingerprint && $0.name == name }
        presets.append(Preset(name: name, fingerprint: fingerprint, displays: active + off))
        lastAutoFingerprint = fingerprint
    }

    func deletePreset(_ p: Preset) { presets.removeAll { $0.id == p.id } }

    func setAutoApply(_ p: Preset, _ on: Bool) {
        guard let i = presets.firstIndex(where: { $0.id == p.id }) else { return }
        presets[i].autoApply = on
    }

    private func autoApplyIfNeeded() {
        guard !isApplying else { return }
        let fp = fingerprint
        guard fp != lastAutoFingerprint else { return }
        lastAutoFingerprint = fp
        if let p = presets.first(where: { $0.autoApply && $0.fingerprint == fp }) { apply(p) }
    }

    func apply(_ p: Preset) {
        guard !isApplying else { return }
        isApplying = true
        Task { @MainActor in
            // 1. Réactiver les écrans attendus
            let toEnable = disconnected.filter { dd in p.displays.contains { $0.key == dd.key && $0.enabled } }
            if !toEnable.isEmpty {
                reconnect(toEnable)
                try? await Task.sleep(for: .seconds(2))
                refresh()
            }

            // 2a. Rotation (avant la disposition, qui dépend des dimensions)
            var rotated = false
            for pd in p.displays where pd.enabled {
                guard let r = pd.rotation, let d = displays.first(where: { $0.key == pd.key }),
                      d.rotation != r else { continue }
                rotated = Rotation.set(d.id, degrees: r) || rotated
            }
            if rotated {
                try? await Task.sleep(for: .seconds(2))
                refresh()
            }

            // 2b. Résolutions + disposition en une seule transaction
            var cfg: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&cfg) == .success {
                for pd in p.displays where pd.enabled {
                    guard let d = displays.first(where: { $0.key == pd.key }) else { continue }
                    if let want = pd.mode, let cg = bestCGMode(d.id, want) {
                        CGConfigureDisplayWithDisplayMode(cfg, d.id, cg, nil)
                    }
                    CGConfigureDisplayOrigin(cfg, d.id, Int32(pd.originX), Int32(pd.originY))
                }
                CGCompleteDisplayConfiguration(cfg, .permanently)
            }
            try? await Task.sleep(for: .seconds(1.5))
            refresh()

            // 3. Désactiver les écrans marqués "off"
            let toDisable = p.displays.filter { !$0.enabled }
                .compactMap { pd in displays.first { $0.key == pd.key } }
            disconnect(toDisable)

            // 4. Luminosité
            for pd in p.displays where pd.enabled {
                if let b = pd.brightness, let d = displays.first(where: { $0.key == pd.key }) {
                    setBrightness(d.id, b)
                }
            }
            lastAutoFingerprint = fingerprint
            isApplying = false
        }
    }

    // MARK: Touches média

    enum MediaKey { case brightnessUp, brightnessDown, volumeUp, volumeDown, mute }

    /// Retourne `true` si l'app prend la touche (l'événement système est alors avalé).
    func handleMediaKey(_ key: MediaKey, isDown: Bool, fine: Bool) -> Bool {
        let step = fine ? 1.0 / 64.0 : Prefs.step
        switch key {
        case .brightnessUp, .brightnessDown:
            let targets: [Display]
            if Prefs.brightnessAll {
                targets = displays.filter { $0.brightness != nil }
            } else {
                guard let d = displayUnderCursor(), !d.isBuiltin, d.brightness != nil else { return false }
                targets = [d]
            }
            guard !targets.isEmpty else { return false }
            if isDown {
                let delta = key == .brightnessUp ? step : -step
                for d in targets { setBrightness(d.id, (d.brightness ?? 0.5) + delta) }
                let hudTarget = displayUnderCursor() ?? targets[0]
                let level = displays.first { $0.id == hudTarget.id }?.brightness
                    ?? displays.first { $0.id == targets[0].id }?.brightness ?? 0
                HUD.shared.show(symbol: "sun.max.fill", value: level, on: hudTarget.id)
            }
            return true

        case .volumeUp, .volumeDown, .mute:
            guard Prefs.volumeKeys, let d = displayUnderCursor(), d.volume != nil else { return false }
            if isDown {
                if key == .mute {
                    toggleMute(d.id)
                } else {
                    setVolume(d.id, (d.volume ?? 0) + (key == .volumeUp ? step : -step))
                }
                let cur = displays.first { $0.id == d.id }
                let muted = cur?.muted ?? false
                HUD.shared.show(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                value: muted ? 0 : (cur?.volume ?? 0), on: d.id)
            }
            return true
        }
    }

    func displayUnderCursor() -> Display? {
        let loc = NSEvent.mouseLocation
        guard let id = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) })?.displayID
        else { return nil }
        return displays.first { $0.id == id }
    }

    // MARK: Utilitaires

    nonisolated static func onlineIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        // Ignore les écrans secondaires d'un groupe de recopie vidéo
        return Array(ids.prefix(Int(count))).filter { CGDisplayMirrorsDisplay($0) == 0 }
    }

    static func baseKey(_ id: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(id) != 0 { return "builtin" }
        return String(format: "%04x-%04x-%08x", CGDisplayVendorNumber(id), CGDisplayModelNumber(id), CGDisplaySerialNumber(id))
    }

    static func screenName(_ id: CGDirectDisplayID) -> String {
        if let s = NSScreen.screens.first(where: { $0.displayID == id }) { return s.localizedName }
        return CGDisplayIsBuiltin(id) != 0 ? "Écran intégré" : "Écran \(id)"
    }

    // MARK: Persistance

    private static var supportDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DisplayPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var presetsURL: URL { supportDir.appendingPathComponent("presets.json") }

    private func loadPresets() {
        guard let data = try? Data(contentsOf: Self.presetsURL),
              let list = try? JSONDecoder().decode([Preset].self, from: data) else { return }
        presets = list
    }

    private func savePresets() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(presets).write(to: Self.presetsURL, options: .atomic)
    }

    private func loadDisconnected() {
        guard let data = UserDefaults.standard.data(forKey: "disconnected"),
              let list = try? JSONDecoder().decode([DisconnectedDisplay].self, from: data) else { return }
        disconnected = list
    }

    private func saveDisconnected() {
        UserDefaults.standard.set(try? JSONEncoder().encode(disconnected), forKey: "disconnected")
    }
}
