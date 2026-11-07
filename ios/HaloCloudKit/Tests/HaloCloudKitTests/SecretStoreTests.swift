import XCTest
@testable import HaloCloudKit

final class SecretStoreTests: XCTestCase {
    func profile() -> CloudProfile {
        CloudProfile(config: PairingTests.config, auth: PairingTests.auth, saltBase64: "AQIDBAUGBwgJCgsMDQ4PEA==", iterations: 100_000,
                     keyBase64: Data(repeating: 7, count: 32).base64EncodedString(), deviceId: "dev-1", deviceName: "iPhone")
    }

    func testProfileRoundTripAndWipe() throws {
        let s = InMemorySecretStore(); let store = CloudProfileStore(secrets: s)
        XCTAssertNil(try store.load())
        try store.save(profile())
        XCTAssertEqual(try store.load(), profile())
        try store.wipe()
        XCTAssertNil(try store.load())
        XCTAssertTrue(s.accounts.isEmpty)
    }

    // SECURITY: after a REAL pairing flow nothing secret may appear in UserDefaults (any domain we can read).
    func testPairingNeverWritesSecretsToUserDefaults() async throws {
        let db = InMemoryRTDB()
        let (payload, _) = try await PairingFlowTests.seeded(db: db)
        let store = InMemorySecretStore()
        let setup = CloudSetup(secrets: store, transport: RTDBStubTransport(db: db), minBackoff: 0.01)
        let outcome = try await setup.connect(payload: payload, passphrase: PairingFlowTests.passphrase, confirmation: nil)
        XCTAssertEqual(outcome, .paired(deviceName: "iPhone", verified: true))

        let suite = "halo.cloudkit.test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        let dump = UserDefaults.standard.dictionaryRepresentation().description + ud.dictionaryRepresentation().description
        let secrets = ["halo-test-password", "test-api-key", PairingFlowTests.passphrase, try XCTUnwrap(try CloudProfileStore(secrets: store).load()).keyBase64]
        for s in secrets { XCTAssertFalse(dump.contains(s), "secret leaked into UserDefaults: \(s.prefix(6))…") }
    }

    /// The same, but against the REAL Keychain on this machine: the item lands there (and only there), is
    /// readable back, and unpair removes it. Skipped where the Keychain is not usable (e.g. a locked CI box).
    func testRealKeychainStoresAndWipes() throws {
        let kc = KeychainSecretStore(service: "com.halo.cloudkit.tests.\(UUID().uuidString)")
        defer { try? kc.removeAll() }
        do { try kc.set(Data("x".utf8), for: "probe") } catch { throw XCTSkip("Keychain unavailable here: \(error)") }
        let store = CloudProfileStore(secrets: kc)
        try store.save(profile())
        XCTAssertEqual(try store.load(), profile())
        try store.wipe()
        XCTAssertNil(try store.load())
        XCTAssertNil(try kc.get("probe"))
    }
}

extension StubTransport {
    /// Answers only the Identity Toolkit sign-in (uid-1); every database call is a 404 so a test that forgets to
    /// inject its own handler fails loudly.
    static func signInOnly() -> StubTransport {
        StubTransport { req in
            if req.url!.path.hasSuffix("accounts:signInWithPassword") {
                return (Data(#"{"idToken":"id-1","refreshToken":"r","localId":"uid-1","expiresIn":"3600"}"#.utf8), 200)
            }
            return (Data("{}".utf8), 404)
        }
    }
}
