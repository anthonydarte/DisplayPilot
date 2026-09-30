import SwiftUI
import AppKit

struct MenuView: View {
    @Environment(DisplayManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    private let ui = MenuUIState.shared
    private var presetName: String {
        get { ui.presetName }
        nonmutating set { ui.presetName = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(manager.displays) { d in
                DisplayCard(display: d)
            }

            if !manager.disconnected.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(manager.disconnected) { dd in
                            HStack {
                                Image(systemName: "display")
                                    .foregroundStyle(.secondary)
                                Text(dd.name).foregroundStyle(.secondary)
                                Spacer()
                                Toggle("", isOn: Binding(get: { false }, set: { on in if on { manager.reconnect([dd]) } }))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .labelsHidden()
                                    .help("Reconnecter")
                            }
                        }
                    }
                } label: {
                    Text("Écrans déconnectés").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    manager.disconnectAllButMain()
                } label: {
                    Label("Garder seulement le principal", systemImage: "rectangle.on.rectangle.slash")
                }
                .disabled(manager.displays.count < 2)
                Spacer()
                Button("Tout reconnecter") { manager.reconnectAll() }
                    .disabled(manager.disconnected.isEmpty)
            }
            .controlSize(.small)

            Divider()
            presetsSection
            Divider()

            HStack {
                Button("HiDPI…") { open("hidpi") }
                Button("Réglages…") { open("settings") }
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }
            }
            .controlSize(.small)

            if let err = manager.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { manager.refresh() }
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.caption).foregroundStyle(.secondary)
            ForEach(manager.presets) { p in
                HStack(spacing: 6) {
                    Image(systemName: p.fingerprint == manager.fingerprint ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(p.fingerprint == manager.fingerprint ? Color.accentColor : .secondary)
                        .help(p.fingerprint == manager.fingerprint
                              ? "Correspond aux écrans branchés" : "Autre configuration d'écrans")
                    Button(p.name) { manager.apply(p) }
                        .buttonStyle(.link)
                        .disabled(manager.isApplying)
                    Spacer()
                    Toggle("Auto", isOn: Binding(
                        get: { p.autoApply },
                        set: { manager.setAutoApply(p, $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    Button { manager.deletePreset(p) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Nom (ex. Bureau, Maison)", text: Binding(get: { ui.presetName }, set: { ui.presetName = $0 }))
                    .textFieldStyle(.roundedBorder)
                Button("Enregistrer") {
                    manager.saveCurrentAsPreset(named: presetName.trimmingCharacters(in: .whitespaces))
                    presetName = ""
                }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

/// État d'UI stocké hors de la vue : évite la macro @State, absente des Command Line Tools.
@Observable
final class MenuUIState {
    static let shared = MenuUIState()
    var presetName = ""
}

struct DisplayCard: View {
    @Environment(DisplayManager.self) private var manager
    let display: Display

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                Text(display.name).font(.headline).lineLimit(1)
                if !display.isBuiltin {
                    badge(display.hasDDC ? (Prefs.combined ? "DDC + logiciel" : "DDC") : "Logiciel")
                }
                Spacer()
                // Interrupteur marche/arrêt (déconnexion logicielle), interdit sur l'écran principal
                Toggle("", isOn: Binding(get: { true }, set: { on in if !on { manager.disconnect([display]) } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(display.isMain)
                    .help(display.isMain ? "L'écran principal ne peut pas être déconnecté" : "Déconnecter cet écran")
            }

            controlsRow

            if let b = display.brightness {
                HStack {
                    Image(systemName: "sun.min").frame(width: 18)
                    Slider(value: Binding(get: { b }, set: { manager.setBrightness(display.id, $0) }), in: 0...1)
                    Text("\(Int((b * 100).rounded()))").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }

            if let v = display.volume {
                HStack {
                    Button { manager.toggleMute(display.id) } label: {
                        Image(systemName: display.muted ? "speaker.slash" : "speaker.wave.2")
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    Slider(value: Binding(get: { v }, set: { manager.setVolume(display.id, $0) }), in: 0...1)
                    Text("\(Int((v * 100).rounded()))").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }

            resolutionRow
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Écran principal + rotation.
    private var controlsRow: some View {
        HStack(spacing: 8) {
            if display.isMain {
                Label("Principal", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            } else {
                Button {
                    manager.setMain(display.id)
                } label: {
                    Label("Définir principal", systemImage: "star")
                }
                .controlSize(.small)
            }

            if display.canRotate {
                Menu {
                    ForEach([0, 90, 180, 270], id: \.self) { deg in
                        Button {
                            manager.setRotation(display.id, deg)
                        } label: {
                            Text((deg == display.rotation ? "✓ " : "    ") + (deg == 0 ? "Standard" : "\(deg)°"))
                        }
                    }
                } label: {
                    Label(display.rotation == 0 ? "Rotation" : "\(display.rotation)°", systemImage: "rotate.right")
                }
                .controlSize(.small)
                .fixedSize()
            }
            Spacer()
        }
    }

    private var resolutionRow: some View {
        let hidpi = display.modes.filter(\.isHiDPI)
        let standard = display.modes.filter { !$0.isHiDPI }
        let cur = display.currentMode
        let hasTwin = cur.map { c in
            display.modes.contains { $0.width == c.width && $0.height == c.height && $0.isHiDPI != c.isHiDPI }
        } ?? false
        return HStack {
            Image(systemName: "rectangle.expand.vertical").frame(width: 18)
            Menu {
                if !hidpi.isEmpty {
                    Section("HiDPI (Retina)") {
                        ForEach(hidpi) { m in modeButton(m) }
                    }
                }
                if !standard.isEmpty {
                    Menu("Modes standard") {
                        ForEach(standard) { m in modeButton(m) }
                    }
                }
            } label: {
                Text(cur?.label ?? "—")
            }
            .controlSize(.small)
            Spacer()
            Text("HiDPI").font(.caption).foregroundStyle(hasTwin || cur?.isHiDPI == true ? Color.primary : Color.secondary)
            Toggle("", isOn: Binding(get: { cur?.isHiDPI == true },
                                     set: { _ in manager.toggleHiDPI(display.id) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!hasTwin)
                .help(hasTwin ? "Basculer cette résolution en HiDPI / standard"
                              : "Pas de version HiDPI pour cette résolution — voir « HiDPI… »")
        }
    }

    private func modeButton(_ m: DisplayModeInfo) -> some View {
        Button {
            manager.setMode(display.id, m)
        } label: {
            Text((m.id == display.currentMode?.id ? "✓ " : "    ") + m.label)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}
