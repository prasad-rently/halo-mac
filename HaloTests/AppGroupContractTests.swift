import Testing
import Foundation
@testable import Halo

// MARK: - App Group + entitlement contract
//
// Two silent failures this guards, both found the hard way (see docs/V2_5_PLAN.md, P3/P6):
//
//  1. The widget was blank in v2.4 because the App Group was the iOS-style `group.com.halo.mac`.
//     On macOS 15+ an unprefixed group no provisioning profile authorises silently drops writes
//     between processes. The team-prefixed form shares correctly. `UserDefaults(suiteName:)`
//     returns non-nil either way, so nothing at runtime can notice.
//  2. A *restricted* entitlement (`keychain-access-groups`, anything `com.apple.developer.*`)
//     in `Halo-Debug.entitlements` — the file every DMG is signed with — makes macOS SIGKILL the
//     app at launch, because a development-signed build has no provisioning profile to back it.
//
// `scripts/audit-entitlements.sh --probe` is the behavioural proof for (1); this suite is the
// cheap, always-on guard that runs with every test pass.

@Suite("App Group and entitlement contract")
struct AppGroupContractTests {

    private static let repo = URL(fileURLWithPath: #filePath)     // <repo>/HaloTests/AppGroupContractTests.swift
        .deletingLastPathComponent().deletingLastPathComponent()

    private func entitlements(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent(relative))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private let files = ["Halo/Halo.entitlements", "Halo/Halo-Debug.entitlements",
                         "HaloWidget/HaloWidget.entitlements", "HaloHelper/HaloHelper.entitlements"]

    @Test("The shared suite name carries an Apple team prefix")
    func suiteNameIsTeamPrefixed() {
        let name = HaloWidgetData.suiteName
        let range = name.range(of: #"^[A-Z0-9]{10}\.group\."#, options: .regularExpression)
        #expect(range != nil, "'\(name)' needs a '<TEAMID>.group.' prefix or the widget never sees the app's data")
    }

    @Test("Every target's entitlement declares exactly the group the code reads and writes")
    func entitlementsMatchTheConstant() throws {
        for file in files {
            let groups = try entitlements(file)["com.apple.security.application-groups"] as? [String]
            #expect(groups?.contains(HaloWidgetData.suiteName) == true, "\(file)")
            #expect(groups?.contains("group.com.halo.mac") != true, "\(file) still lists the unprefixed group")
        }
    }

    @Test("The Debug entitlements — what every DMG is signed with — carry no restricted entitlement")
    func debugEntitlementsAreLaunchSafe() throws {
        let e = try entitlements("Halo/Halo-Debug.entitlements")
        #expect(e["keychain-access-groups"] == nil, "restricted: a dev-signed build with it is SIGKILLed at launch")
        let restricted = e.keys.filter { $0.hasPrefix("com.apple.developer.") }
        #expect(restricted.isEmpty, "restricted entitlements need a provisioning profile: \(restricted)")
        #expect(e["com.apple.security.app-sandbox"] as? Bool == false)            // global NSEvent monitors need it off
    }

    @Test("The sandboxed release file does not reintroduce the keychain group either")
    func releaseEntitlementsHaveNoKeychainGroup() throws {
        // Cloud sign-in is REST with in-memory tokens (FirebaseRTDBClient); nothing needs it,
        // and it is the entitlement that forces a provisioning profile.
        #expect(try entitlements("Halo/Halo.entitlements")["keychain-access-groups"] == nil)
    }

    @Test("The widget extension stays sandboxed — WidgetKit requires it")
    func widgetIsSandboxed() throws {
        #expect(try entitlements("HaloWidget/HaloWidget.entitlements")["com.apple.security.app-sandbox"] as? Bool == true)
    }
}
