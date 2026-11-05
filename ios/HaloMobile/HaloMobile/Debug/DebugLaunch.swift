#if DEBUG
import SwiftUI
import UIKit

/// Debug-only launch arguments so the app can be driven to every screen from `simctl launch` (no tap
/// automation needed), e.g.  `simctl launch <udid> com.halo.mobile -debugTab share -debugPort 53320 -debugPeer 127.0.0.1:53318`.
///   -debugTab home|share|settings   -debugPort N   -debugPeer host:port   -debugScan 1
///   -debugInbox 1   -debugSendTest 1   -debugSheet add|receiving|discovery   -debugDumpAX 1
@MainActor
enum DebugLaunch {
    static func apply(model: AppModel, router: AppRouter) {
        let d = UserDefaults.standard
        if let t = d.string(forKey: "debugTab"), let tab = AppTab(rawValue: t) { router.tab = tab }
        if d.bool(forKey: "debugInbox") { router.showInbox = true; router.tab = .share }
        if d.bool(forKey: "debugScan") { model.scan() }
        if let addr = d.string(forKey: "debugPeer") {
            model.manualAddress = addr
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.addManualPeer() }
        }
        if d.bool(forKey: "debugSendTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.sendTestFile(megabytes: 40) }
        }
        if d.bool(forKey: "debugDumpAX") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { dumpAccessibility() }
        }
    }

    /// Writes the accessibility tree VoiceOver would walk to Documents/ax-dump.txt.
    static func dumpAccessibility() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        var lines: [String] = []
        func walk(_ obj: Any, _ depth: Int) {
            guard let o = obj as? NSObject else { return }
            let pad = String(repeating: "  ", count: depth)
            if o.isAccessibilityElement {
                let traits = o.accessibilityTraits
                lines.append("\(pad)- label=\"\(o.accessibilityLabel ?? "")\" value=\"\(o.accessibilityValue ?? "")\" id=\((o as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? "-") button=\(traits.contains(.button)) frame=\(Int(o.accessibilityFrame.width))x\(Int(o.accessibilityFrame.height))")
            }
            if let els = o.accessibilityElements, !els.isEmpty { els.forEach { walk($0, depth + 1) }; return }
            let n = o.accessibilityElementCount()
            if n != NSNotFound && n > 0 { for i in 0..<n { if let e = o.accessibilityElement(at: i) { walk(e, depth + 1) } }; return }
            if let v = o as? UIView { v.subviews.forEach { walk($0, depth + 1) } }
        }
        walk(window, 0)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ax-dump.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
