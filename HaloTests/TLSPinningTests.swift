import Testing
import Foundation
import Security
@testable import Halo

// MARK: - HaloShare TLS pinning  (docs/HALOSHARE_PROTOCOL.md §6, was risk §8.6)
//
// The desktop client used to accept ANY certificate from an https peer. The official LocalSend
// app announces https by default, so every send to one was open to anyone on the LAN who could
// impersonate the peer. These tests drive the real URLSession trust callback with genuine
// SecTrust objects built from a real certificate.

/// A real self-signed certificate (CN=halo-pin-test) and its SHA-256, computed independently by
/// `openssl x509 -fingerprint -sha256` — not by the code under test.
private let certDERBase64 = "MIIC8jCCAdqgAwIBAgIUaqYTuNXqEVSHjuSQw2aFJsSL3ocwDQYJKoZIhvcNAQELBQAwGDEWMBQGA1UEAwwNaGFsby1waW4tdGVzdDAgFw0yNjEwMjUwNTM1MzZaGA8yMTI2MTAwMTA1MzUzNlowGDEWMBQGA1UEAwwNaGFsby1waW4tdGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANjCx1cUOxKTL2BdGGlXWAyVTDOVyoME6PLqhZLIhiyj62LMcWUTFk0w+aCCQ0iRd0XBChPKMyzL30JCrQn0ADpvLtqfg0fSZ2aa9N/4o9gBxC4o/DeKWdYDDG7gHxOIes9Zgq7F+WsiqFxvlAZPE7mmUOtKaW670bI2erEqe0BoazRI85rRFurA8FVmgOSTiRzDz+GvvlEFSIxkhq17BOm8zeSZ7qs4cD2JspcT5Y7TGlY9qCxGsiYNSkyYBTwg4nStwfaMrwyrqP8eSabsfynJ9BL7bnad+MhZQdwk1Yd5JS6xEaLzkROP/JJCwVohqCZo0xxso8GH9FBitbSikLUCAwEAAaMyMDAwHQYDVR0OBBYEFC/y/7hj2X3s49MGMKg/njZpB64LMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAEpriQ83Y8iHjwxfmPCxPPnfHpm5fWeuFpqPz8lKKayec7wE+CjLm3nQFIvjiFyErlixDIs853sLU988RWiPJm/8ZWvReD6kAGx7SALuIFu3VSHcmiBbMO196N+Y94lbLzASI7/XVHd4vcppIpoGhOzD8r8PjYR2dIr7RQGhfvRNuxkTfSZgwu+OLTTDRbd8VCt8q2A0DnZtGHyIMvjAiaB0L7cXFsPz2ajZlfflQCIt6MCmVrf72JTfHIpFEp0D8hMlOBTRREjzkPyBX9aOdf6eA1F1WLhaKyKIlIhSJWMNwtWZa1SQJM0DiWaica3Aiq3TACPY5TQkpax0gXlDTyA="
private let certOpenSSLFingerprint = "0524082f47c51c3f23e79a379180f107fc1138174d61644efd7508a034a24aac"

private func makeCertificate() throws -> SecCertificate {
    let der = try #require(Data(base64Encoded: certDERBase64))
    return try #require(SecCertificateCreateWithData(nil, der as CFData))
}

private final class StubSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

private final class TrustSpace: URLProtectionSpace {
    private let trust: SecTrust
    init(host: String, port: Int, trust: SecTrust) {
        self.trust = trust
        super.init(host: host, port: port, protocol: "https", realm: nil,
                   authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var serverTrust: SecTrust? { trust }
}

private func challenge(host: String, port: Int) throws -> URLAuthenticationChallenge {
    var trust: SecTrust?
    SecTrustCreateWithCertificates(try makeCertificate(), SecPolicyCreateSSL(true, host as CFString), &trust)
    return URLAuthenticationChallenge(protectionSpace: TrustSpace(host: host, port: port, trust: try #require(trust)),
                                      proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
                                      error: nil, sender: StubSender())
}

private func device(host: String, port: Int = 53317, proto: TransportProtocol, fingerprint: String) -> ShareDevice {
    ShareDevice(alias: "Peer", version: "2.1", deviceModel: nil, deviceType: nil, fingerprint: fingerprint,
                port: port, protocol_: proto, download: false, ipAddress: host, lastSeen: Date())
}

private func decide(_ client: LocalShareClient, host: String, port: Int = 53317) throws -> URLSession.AuthChallengeDisposition {
    var result: URLSession.AuthChallengeDisposition?
    client.urlSession(.shared, didReceive: try challenge(host: host, port: port)) { d, _ in result = d }
    return try #require(result)
}

@Suite("HaloShare TLS pinning")
struct TLSPinningTests {

    @Test("The certificate fingerprint is the lower-case hex SHA-256 of the DER — matching openssl")
    func fingerprintMatchesOpenSSL() throws {
        #expect(TLSManager.certificateFingerprint(try makeCertificate()) == certOpenSSLFingerprint)
    }

    @Test("Fingerprint comparison needs both sides, ignores case, and rejects any difference")
    func comparison() {
        let fp = certOpenSSLFingerprint
        #expect(TLSManager.fingerprintMatches(presented: fp, expected: fp))
        #expect(TLSManager.fingerprintMatches(presented: fp, expected: fp.uppercased()))   // some peers announce upper-case hex
        #expect(!TLSManager.fingerprintMatches(presented: fp, expected: String(fp.dropLast()) + "0"))
        #expect(!TLSManager.fingerprintMatches(presented: fp, expected: String(fp.dropLast())))   // length differs
        #expect(!TLSManager.fingerprintMatches(presented: fp, expected: nil))
        #expect(!TLSManager.fingerprintMatches(presented: nil, expected: fp))
        #expect(!TLSManager.fingerprintMatches(presented: "", expected: ""))                // empty never matches empty
        #expect(!TLSManager.fingerprintMatches(presented: nil, expected: nil))
    }

    @Test("An https peer whose certificate matches its announced fingerprint is trusted")
    func matchingPinIsTrusted() throws {
        let client = LocalShareClient()
        client.pin(device(host: "10.0.0.21", proto: .https, fingerprint: certOpenSSLFingerprint))
        #expect(try decide(client, host: "10.0.0.21") == .useCredential)
    }

    @Test("An https peer presenting a DIFFERENT certificate — an impostor on the LAN — is refused")
    func impostorIsRefused() throws {
        let client = LocalShareClient()
        let someoneElses = String(repeating: "ab", count: 32)                          // what the real peer announced
        client.pin(device(host: "10.0.0.22", proto: .https, fingerprint: someoneElses))
        #expect(try decide(client, host: "10.0.0.22") == .cancelAuthenticationChallenge)
    }

    @Test("Fail closed: an https host we hold no pin for is refused, not trusted by default")
    func noPinIsRefused() throws {
        #expect(try decide(LocalShareClient(), host: "10.0.0.23") == .cancelAuthenticationChallenge)
    }

    @Test("A pin is per host and port — one trusted peer does not vouch for another")
    func pinsAreScoped() throws {
        let client = LocalShareClient()
        client.pin(device(host: "10.0.0.24", port: 53317, proto: .https, fingerprint: certOpenSSLFingerprint))
        #expect(try decide(client, host: "10.0.0.24", port: 53317) == .useCredential)
        #expect(try decide(client, host: "10.0.0.24", port: 8443) == .cancelAuthenticationChallenge)
        #expect(try decide(client, host: "10.0.0.99", port: 53317) == .cancelAuthenticationChallenge)
    }

    @Test("A plain-http peer registers no pin, so it can never vouch for an https host")
    func httpDevicesDoNotPin() throws {
        let client = LocalShareClient()
        client.pin(device(host: "10.0.0.25", proto: .http, fingerprint: certOpenSSLFingerprint))
        #expect(try decide(client, host: "10.0.0.25") == .cancelAuthenticationChallenge)
    }

    @Test("A re-announced peer with a new certificate replaces the old pin")
    func repinning() throws {
        let client = LocalShareClient()
        client.pin(device(host: "10.0.0.26", proto: .https, fingerprint: certOpenSSLFingerprint))
        #expect(try decide(client, host: "10.0.0.26") == .useCredential)
        client.pin(device(host: "10.0.0.26", proto: .https, fingerprint: String(repeating: "cd", count: 32)))
        #expect(try decide(client, host: "10.0.0.26") == .cancelAuthenticationChallenge)
    }

    @Test("Non-server-trust challenges are left to default handling")
    func otherMethodsUntouched() {
        let (d, c) = TLSManager.shared.shouldTrustServer(
            challenge: URLAuthenticationChallenge(
                protectionSpace: URLProtectionSpace(host: "h", port: 1, protocol: "https", realm: nil,
                                                    authenticationMethod: NSURLAuthenticationMethodHTTPBasic),
                proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: StubSender()),
            expectedFingerprint: nil)
        #expect(d == .performDefaultHandling && c == nil)
    }
}
