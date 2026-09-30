import AppKit
import SwiftUI
import Observation

@Observable
final class HUDModel {
    var symbol = "sun.max.fill"
    var value = 0.5
}

struct HUDView: View {
    let model: HUDModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24)
            ProgressView(value: min(max(model.value, 0), 1))
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 18)
        .frame(width: 240, height: 54)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Petit OSD affiché sur l'écran concerné quand on utilise les touches.
@MainActor
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private let model = HUDModel()
    private var hideTask: Task<Void, Never>?

    func show(symbol: String, value: Double, on displayID: CGDirectDisplayID) {
        model.symbol = symbol
        model.value = value
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main
        if let f = screen?.frame {
            panel.setFrame(NSRect(x: f.midX - 120, y: f.minY + 120, width: 240, height: 54), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in if panel.alphaValue == 0 { panel.orderOut(nil) } }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 54),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: HUDView(model: model))
        return p
    }
}
