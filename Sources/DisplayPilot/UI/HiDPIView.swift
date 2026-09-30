import SwiftUI

@Observable
final class HiDPIUIState {
    static let shared = HiDPIUIState()
    var selectedKey: String?
    var chosen: Set<HiDPIResolution> = []
    var beyondNative = true
    var status: String?
    var working = false
}

struct HiDPIView: View {
    @Environment(DisplayManager.self) private var manager
    private let ui = HiDPIUIState.shared

    private var externals: [Display] { manager.displays.filter { !$0.isBuiltin } }
    private var current: Display? { externals.first { $0.key == ui.selectedKey } ?? externals.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HiDPI (Retina) sur écran externe").font(.title3.bold())
            if let d = current {
                if externals.count > 1 {
                    Picker("Écran", selection: Binding(get: { ui.selectedKey }, set: { ui.selectedKey = $0 })) {
                        ForEach(externals) { Text($0.name).tag(Optional($0.key)) }
                    }
                }
                let native = nativeSize(d)
                let list = candidates(d, native)
                Text("\(d.name) — natif \(native.w)×\(native.h)")
                    .font(.callout).foregroundStyle(.secondary)

                // Action rapide
                GroupBox {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Activer le HiDPI sur toutes les résolutions").font(.headline)
                            Text("Crée une version Retina de chaque résolution proposée par l'écran (tous formats) et de 640 px jusqu'à \(ui.beyondNative ? "\(HiDPIOverride.maxHiDPIWidth) px (au-delà du natif)" : "la définition native").")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Tout activer…") {
                            ui.chosen = Set(list)
                            install(d, Array(list))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(ui.working)
                    }
                    .padding(4)
                }

                Toggle("Inclure les résolutions supérieures au natif (plus d'espace de travail)",
                       isOn: Binding(get: { ui.beyondNative }, set: { ui.beyondNative = $0 }))

                // Sélection fine
                HStack {
                    Text("Ou choisir les résolutions :").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Tout") { ui.chosen = Set(list) }.buttonStyle(.link)
                    Button("Aucune") { ui.chosen = [] }.buttonStyle(.link)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], spacing: 4) {
                        ForEach(list) { r in
                            Toggle(isOn: Binding(
                                get: { ui.chosen.contains(r) },
                                set: { on in if on { ui.chosen.insert(r) } else { ui.chosen.remove(r) } })) {
                                Text("\(r.width)×\(r.height)")
                                    .fontWeight(r.width == native.w ? .semibold : .regular)
                                    .foregroundStyle(r.width > native.w ? Color.orange : Color.primary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 170)

                HStack {
                    Button("Installer la sélection…") { install(d, Array(ui.chosen)) }
                        .disabled(ui.chosen.isEmpty || ui.working)
                    Button("Supprimer l'override…") {
                        run { HiDPIOverride.remove(vendor: d.vendor, model: d.model) }
                    }
                    .disabled(ui.working || !HiDPIOverride.exists(vendor: d.vendor, model: d.model))
                    Spacer()
                    if HiDPIOverride.exists(vendor: d.vendor, model: d.model) {
                        Label("Override installé", systemImage: "checkmark.seal").font(.caption)
                    }
                }
                if let status = ui.status { Text(status).font(.caption) }
                Text("En gras : définition native. En orange : au-delà du natif (rendu 2× puis réduit, texte plus fin mais plus petit). Les nouveaux modes apparaissent après avoir débranché/rebranché l'écran ou redémarré ; bascule ensuite avec l'interrupteur HiDPI du menu.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Aucun écran externe détecté.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { if ui.selectedKey == nil { ui.selectedKey = externals.first?.key } }
        .onChange(of: ui.selectedKey) { ui.chosen = []; ui.status = nil }
    }

    /// Définition native = plus grand mode non HiDPI (les modes HiDPI ont une définition de rendu doublée).
    private func nativeSize(_ d: Display) -> (w: Int, h: Int) {
        let std = d.modes.filter { !$0.isHiDPI }
        let best = (std.isEmpty ? d.modes : std).max { ($0.width * $0.height) < ($1.width * $1.height) }
        return (best?.width ?? 1920, best?.height ?? 1080)
    }

    /// Résolutions au format natif + toutes les résolutions standard proposées par l'écran
    /// (4:3, 16:10, 5:4…), pour que chacune ait sa version HiDPI.
    private func candidates(_ d: Display, _ native: (w: Int, h: Int)) -> [HiDPIResolution] {
        var set = Set(HiDPIOverride.candidates(nativeWidth: native.w, nativeHeight: native.h,
                                               beyondNative: ui.beyondNative))
        for m in d.modes where !m.isHiDPI && m.width <= HiDPIOverride.maxHiDPIWidth {
            set.insert(HiDPIResolution(width: m.width, height: m.height))
        }
        return set.sorted { ($0.width, $0.height) < ($1.width, $1.height) }
    }

    private func install(_ d: Display, _ list: [HiDPIResolution]) {
        run { HiDPIOverride.install(name: d.name, vendor: d.vendor, model: d.model, resolutions: list) }
    }

    private func run(_ action: () -> String?) {
        ui.working = true
        let err = action()
        ui.working = false
        ui.status = err.map { "Échec : \($0)" } ?? "OK — débranche/rebranche l'écran pour voir les nouveaux modes."
    }
}
