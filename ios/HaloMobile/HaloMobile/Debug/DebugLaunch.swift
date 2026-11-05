#if DEBUG
import SwiftUI
import UIKit

/// Debug-only launch arguments so the app can be driven to every screen from `simctl launch` (no tap
/// automation needed), e.g.  `simctl launch <udid> com.halo.mobile -debugTab share -debugPort 53320 -debugPeer 127.0.0.1:53318`.
///   -debugTab home|share|settings   -debugPort N   -debugPeer host:port   -debugScan 1
///   -debugInbox 1   -debugSendTest 1   -debugSheet add|receiving|discovery
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
        if let t = d.string(forKey: "debugTransfer") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.debugSetTransfer(t) }
        }
        if d.bool(forKey: "debugSendTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.sendTestFile(megabytes: 40) }
        }
    }
}
#endif
