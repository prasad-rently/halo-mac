import XCTest
@testable import HaloCloudKit

final class PairingFlowTests: XCTestCase {
    static let passphrase = "contract test passphrase 1"
    static let salt = Data((1...16).map(UInt8.init))

    /// A database seeded with one clipboard record sealed under `passphrase` (so KeyCheck has something to open).
    static func seeded(db: InMemoryRTDB, seed: Bool = true) async throws -> (PairingPayload, CryptoService) {
        let payload = PairingPayload(firebaseConfig: FirebaseConfig(apiKey: "test-api-key", projectID: "p", googleAppID: "1:2:ios:3", gcmSenderID: "2",
                                                                    databaseURL: "https://p-default-rtdb.firebaseio.com"),
                                     auth: CloudAuthCredential(email: "me@halo.test", password: "halo-test-password"), salt: salt, iterations: 100_000)
        let crypto = try CryptoService(passphrase: passphrase, salt: salt, iterations: 100_000)
        if seed { await db.seed("clipboard/uid-1/items/x", ClipboardEnvelope(itemId: "x", deviceId: "mac", deviceName: "Mac", kind: "text", contentEnc: try crypto.encrypt("hi"), createdAtMs: 1).node()) }
        return (payload, crypto)
    }

    func setup(_ db: InMemoryRTDB, store: InMemorySecretStore = InMemorySecretStore()) -> (CloudSetup, RTDBStubTransport, InMemorySecretStore) {
        let t = RTDBStubTransport(db: db)
        return (CloudSetup(secrets: store, transport: t, minBackoff: 0.01), t, store)
    }

    func testRightPassphraseOnAPopulatedDatabasePairsVerifiedAndStoresOnlyTheKey() async throws {
        let db = InMemoryRTDB(); let (payload, _) = try await Self.seeded(db: db)
        let (s, _, store) = setup(db)
        let r = try await s.connect(payload: payload, passphrase: Self.passphrase, confirmation: nil)
        XCTAssertEqual(r, .paired(deviceName: "iPhone", verified: true))
        let p = try XCTUnwrap(try s.store.load())
        XCTAssertEqual(p.iterations, 100_000)
        XCTAssertEqual(store.accounts, [CloudProfileStore.account], "exactly one Keychain item")
        XCTAssertFalse(try JSONEncoder().encode(p).contains(Data(Self.passphrase.utf8)), "the passphrase is never stored")
        XCTAssertTrue(s.isPaired())
        XCTAssertNotNil(try s.openSession())
    }

    // SECURITY: a wrong passphrase against real ciphertext is refused and NOTHING is stored.
    func testWrongPassphraseIsRefusedAndStoresNothing() async throws {
        let db = InMemoryRTDB(); let (payload, _) = try await Self.seeded(db: db)
        let (s, _, store) = setup(db)
        do { _ = try await s.connect(payload: payload, passphrase: "totally wrong passphrase", confirmation: nil); XCTFail("must refuse") }
        catch { XCTAssertEqual(error as? PairingFailure, .passphraseMismatch) }
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertFalse(s.isPaired())
    }

    func testEmptyDatabaseAsksForTheSecondEntryAndSaysItCouldNotBeVerified() async throws {
        let db = InMemoryRTDB(); let (payload, _) = try await Self.seeded(db: db, seed: false)
        let (s, _, store) = setup(db)
        let first = try await s.connect(payload: payload, passphrase: Self.passphrase, confirmation: nil)
        XCTAssertEqual(first, .needsConfirmation)
        XCTAssertTrue(store.accounts.isEmpty, "nothing is stored until the passphrase is confirmed")
        XCTAssertTrue(PairingConfirmation.notice.contains("could not be verified"))
    }

    // SECURITY (D-01): a typo made only once cannot get through on an empty database.
    func testMismatchedConfirmationIsRefusedAndStoresNothing() async throws {
        let db = InMemoryRTDB(); let (payload, _) = try await Self.seeded(db: db, seed: false)
        let (s, _, store) = setup(db)
        do { _ = try await s.connect(payload: payload, passphrase: Self.passphrase, confirmation: Self.passphrase + "x"); XCTFail("must refuse") }
        catch { XCTAssertEqual(error as? PairingFailure, .confirmationDoesNotMatch) }
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testMatchingConfirmationPairsUnverified() async throws {
        let db = InMemoryRTDB(); let (payload, _) = try await Self.seeded(db: db, seed: false)
        let (s, _, _) = setup(db)
        let r = try await s.connect(payload: payload, passphrase: Self.passphrase, confirmation: Self.passphrase)
        XCTAssertEqual(r, .paired(deviceName: "iPhone", verified: false))
    }

    func testBadSignInIsReportedWithoutEchoingCredentials() async throws {
        let db = InMemoryRTDB(); var (payload, _) = try await Self.seeded(db: db)
        payload.auth.password = "wrong-password-xyz"
        payload.checksum = PairingPayload.checksum(config: payload.firebaseConfig, auth: payload.auth, saltBase64: payload.saltBase64, schema: payload.schema, iterations: payload.iterations)
        let (s, _, store) = setup(db)
        do { _ = try await s.connect(payload: payload, passphrase: Self.passphrase, confirmation: nil); XCTFail() }
        catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(msg.contains("Wrong email or password"), msg)
            XCTAssertFalse(msg.contains("wrong-password-xyz")); XCTAssertFalse(msg.contains("test-api-key"))
        }
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testSignInSendsCredentialsOnlyToGoogleAndDatabaseCallsCarryAuthQuery() async throws {
        let db = InMemoryRTDB(); let (payload, _) = try await Self.seeded(db: db)
        let (s, t, _) = setup(db)
        _ = try await s.connect(payload: payload, passphrase: Self.passphrase, confirmation: nil)
        for u in t.allURLs {
            if u.path.contains("accounts:signInWithPassword") { XCTAssertEqual(u.host, "identitytoolkit.googleapis.com") }
            else { XCTAssertEqual(u.host, "p-default-rtdb.firebaseio.com") }
        }
        XCTAssertFalse(t.allURLs.filter { $0.host != "identitytoolkit.googleapis.com" }.contains { $0.absoluteString.contains("halo-test-password") }, "the password never rides a database URL")
        XCTAssertTrue(t.allBodies.filter { $0.contains("halo-test-password") }.count == 1, "the password is sent once, in the sign-in body")
    }

    func testUnpairWipesTheKeychainItem() async throws {
        let db = InMemoryRTDB(); let (payload, _) = try await Self.seeded(db: db)
        let (s, _, store) = setup(db)
        _ = try await s.connect(payload: payload, passphrase: Self.passphrase, confirmation: nil)
        XCTAssertFalse(store.accounts.isEmpty)
        try s.unpair()
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertFalse(s.isPaired())
        XCTAssertNil(try s.openSession())
    }

    func testUnreachableDatabaseIsAnErrorNotNoSample() async throws {
        let db = InMemoryRTDB(); let (payload, _) = try await Self.seeded(db: db, seed: false)
        await db.setFailReads(true)
        let (s, _, store) = setup(db)
        do { _ = try await s.connect(payload: payload, passphrase: Self.passphrase, confirmation: Self.passphrase); XCTFail("must not treat a failed read as an empty database") }
        catch { /* any error is correct */ }
        XCTAssertTrue(store.accounts.isEmpty)
    }
}
