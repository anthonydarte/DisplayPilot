import SwiftUI
import AppKit

@main
struct DisplayPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let manager = DisplayManager.shared

    init() {
        DDCDebug.runIfRequested()   // --ddc-debug : diagnostic en Terminal puis sortie
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(manager)
        } label: {
            Image(systemName: "display.2")
        }
        .menuBarExtraStyle(.window)

        Window("HiDPI", id: "hidpi") {
            HiDPIView().environment(manager)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Réglages DisplayPilot", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isDuplicate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Une seule instance (LaunchAgent géré + élément d'ouverture utilisateur, relance manuelle…)
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me }) {
            isDuplicate = true
            NSApp.terminate(nil)
            return
        }
        MainActor.assumeIsolated {
            DisplayManager.shared.start()
            MediaKeyTap.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isDuplicate else { return }   // ne pas toucher au gamma de l'instance principale
        CGDisplayRestoreColorSyncSettings()   // rend le gamma d'origine aux écrans atténués
    }
}
