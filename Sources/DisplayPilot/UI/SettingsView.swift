import SwiftUI
import ServiceManagement
import ApplicationServices

@Observable
final class SettingsUIState {
    static let shared = SettingsUIState()
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var trusted = AXIsProcessTrusted()
    var loginError: String?
}

struct SettingsView: View {
    @AppStorage(Prefs.brightnessAllKey) private var brightnessAll = false
    @AppStorage(Prefs.volumeKeysKey) private var volumeKeys = true
    @AppStorage(Prefs.stepKey) private var step = 1.0 / 16.0
    @AppStorage(Prefs.combinedKey) private var combined = true
    @AppStorage(Prefs.softRangeKey) private var softRange = 0.3
    private let ui = SettingsUIState.shared
    private var trusted: Bool {
        get { ui.trusted }
        nonmutating set { ui.trusted = newValue }
    }
    private var loginError: String? {
        get { ui.loginError }
        nonmutating set { ui.loginError = newValue }
    }

    /// Présent quand l'app est déployée par le pkg (LaunchAgent système).
    static let managedAgent = FileManager.default.fileExists(
        atPath: "/Library/LaunchAgents/fr.darte.DisplayPilot.agent.plist")

    var body: some View {
        Form {
            Section("Général") {
                Toggle("Lancer à l'ouverture de session", isOn: Binding(
                    get: { Self.managedAgent || ui.launchAtLogin }, set: { ui.launchAtLogin = $0 }))
                    .disabled(Self.managedAgent)
                    .onChange(of: ui.launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if Self.managedAgent {
                    Text("Démarrage géré par l'administrateur (déploiement Intune).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }

            Section("Luminosité des écrans externes") {
                Toggle("Combiner DDC et atténuation logicielle", isOn: $combined)
                    .onChange(of: combined) { DisplayManager.shared.reapplyBrightnessSettings() }
                if combined {
                    LabeledContent("Part logicielle (bas du curseur)") {
                        HStack {
                            Slider(value: $softRange, in: 0.1...0.5, step: 0.05)
                                .frame(width: 160)
                                .onChange(of: softRange) { DisplayManager.shared.reapplyBrightnessSettings() }
                            Text("\(Int(softRange * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Text("Le haut du curseur règle le rétroéclairage (DDC), le bas assombrit l'image au-delà du minimum de l'écran. Sans DDC (station qui ne le relaie pas), tout le curseur est logiciel.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Touches du clavier") {
                Picker("Touches luminosité", selection: $brightnessAll) {
                    Text("Écran sous le curseur").tag(false)
                    Text("Tous les écrans ensemble").tag(true)
                }
                Toggle("Touches volume → écran externe sous le curseur (DDC)", isOn: $volumeKeys)
                Picker("Pas", selection: $step) {
                    Text("Fin (1/32)").tag(1.0 / 32.0)
                    Text("Standard (1/16)").tag(1.0 / 16.0)
                    Text("Large (1/10)").tag(0.1)
                }
                Text("⇧⌥ + touche : pas très fin (1/64).").font(.caption).foregroundStyle(.secondary)
            }

            Section("Autorisations") {
                LabeledContent("Accessibilité") {
                    HStack {
                        Text(trusted ? "Accordée" : "Non accordée")
                            .foregroundStyle(trusted ? .green : .orange)
                        if !trusted {
                            Button("Ouvrir les réglages") {
                                NSWorkspace.shared.open(URL(string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                    }
                }
                Text("Nécessaire pour intercepter les touches luminosité/volume.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { trusted = AXIsProcessTrusted() }
    }
}
