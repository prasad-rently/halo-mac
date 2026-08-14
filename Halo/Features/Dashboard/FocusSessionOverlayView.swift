import SwiftUI
import AppKit

// MARK: - Panel subclass

private final class FocusOverlayPanel: NSPanel {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Panel Controller (F-028)
//
// Same floating-NSPanel pattern as QuickActionPickerController /
// ClipboardQuickPickerController: a non-activating panel at `.floating`
// level, hosting a SwiftUI view via NSHostingController. Unlike those
// pickers, this panel does NOT hide on losing key status — it's meant to sit
// visibly on screen for the whole session, dismissed only via its own
// in-view close button (which just calls `dismissOverlay()`, not
// `endSession()`).
@MainActor
final class FocusSessionOverlayController: NSObject {

    private var panel: NSPanel?

    func show() {
        if let existing = panel {
            existing.orderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: FocusSessionOverlayView())
        let size = NSSize(width: 300, height: 230)
        hosting.view.frame = NSRect(origin: .zero, size: size)

        let p = FocusOverlayPanel(
            contentRect: hosting.view.frame,
            styleMask:   [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.level                       = .floating
        p.titleVisibility             = .hidden
        p.titlebarAppearsTransparent  = true
        p.isMovableByWindowBackground = true
        p.backgroundColor             = NSColor(calibratedRed: 0.031, green: 0.047, blue: 0.078, alpha: 1)
        p.contentViewController       = hosting
        p.hasShadow                   = true

        if let screen = NSScreen.main {
            let origin = NSPoint(
                x: screen.visibleFrame.maxX - size.width - 24,
                y: screen.visibleFrame.maxY - size.height - 24
            )
            p.setFrameOrigin(origin)
        } else {
            p.center()
        }

        p.orderFront(nil)
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - SwiftUI content

struct FocusSessionOverlayView: View {
    @ObservedObject private var manager = FocusSessionManager.shared

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.haloAccent)
                    Text("Focus Session")
                        .font(HaloFont.display(14, weight: .bold))
                        .foregroundColor(.haloText)
                }
                Spacer()
                Button {
                    manager.dismissOverlay()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.haloText3)
                }
                .buttonStyle(.plain)
                .help("Dismiss — the session keeps running in the menu bar")
            }

            Text(manager.remainingFormatted)
                .font(HaloFont.display(44, weight: .heavy))
                .foregroundColor(.haloAccent)
                .monospacedDigit()

            if !manager.hiddenAppNames.isEmpty {
                Text("\(manager.hiddenAppNames.count) app\(manager.hiddenAppNames.count == 1 ? "" : "s") hidden")
                    .font(HaloFont.body(11))
                    .foregroundColor(.haloText2)
            }

            Button {
                manager.endSession()
            } label: {
                Text("End Session")
                    .font(HaloFont.body(13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.haloRed)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 300, height: 230)
        .background(Color(hex: "#080c14"))
    }
}
