import Foundation
import Security
import CryptoKit
import Network

final class TLSManager: @unchecked Sendable {
    static let shared = TLSManager()

    private(set) var fingerprint: String = ""
    private var identity: SecIdentity?
    private let keychainLabel = "com.halo.mac.localshare"

    func loadOrCreate() throws {
        if let existing = loadFromKeychain() {
            identity = existing
            fingerprint = try computeFingerprint(from: existing)
            return
        }
        let newIdentity = try generateSelfSignedCert()
        identity = newIdentity
        fingerprint = try computeFingerprint(from: newIdentity)
    }

    // MARK: - NWParameters with TLS

    func nwTLSParameters() -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        if let identity = identity {
            let secIdentityRef = sec_identity_create(identity)!
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentityRef)
            sec_protocol_options_set_peer_authentication_required(tlsOptions.securityProtocolOptions, false)
        }
        let params = NWParameters(tls: tlsOptions)
        params.allowLocalEndpointReuse = true
        return params
    }

    func httpParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        return params
    }

    // MARK: - URLSession Trust Delegate

    func shouldTrustServer(challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: serverTrust))
    }

    // MARK: - Device Info

    func deviceInfoDTO() -> DeviceInfoDTO {
        DeviceInfoDTO(
            alias: Host.current().localizedName ?? "Mac",
            version: "2.1",
            deviceModel: macModelIdentifier(),
            deviceType: "desktop",
            fingerprint: fingerprint,
            port: 53317,
            protocol_: "http",
            download: false,
            announce: nil
        )
    }

    // MARK: - Private

    private func macModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private func loadFromKeychain() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: keychainLabel,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return (result as! SecIdentity)
    }

    private func generateSelfSignedCert() throws -> SecIdentity {
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrLabel as String: keychainLabel,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keychainLabel.data(using: .utf8)!
            ] as [String: Any]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw LocalShareError.certGenerationFailed
        }

        let certData = try buildSelfSignedCertDER(publicKey: publicKey, privateKey: privateKey)

        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw LocalShareError.certGenerationFailed
        }

        let addCertQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: keychainLabel
        ]
        SecItemAdd(addCertQuery as CFDictionary, nil)

        var identityRef: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identityRef)
        guard status == errSecSuccess, let identity = identityRef else {
            throw LocalShareError.certGenerationFailed
        }
        return identity
    }

    private func buildSelfSignedCertDER(publicKey: SecKey, privateKey: SecKey) throws -> Data {
        // Minimal self-signed X.509 v3 cert using Security.framework
        // For a production-quality cert we'd use ASN.1 DER encoding manually.
        // Here we use a simplified approach that works with LocalSend protocol.
        let commonName = "HaloShare"
        let daysValid = 3650

        var certParams: [String: Any] = [
            "serialNumber" as String: 1,
            "version" as String: 3,
            "issuer" as String: [["2.5.4.3": commonName]],
            "subject" as String: [["2.5.4.3": commonName]],
            "notBefore" as String: Date(),
            "notAfter" as String: Calendar.current.date(byAdding: .day, value: daysValid, to: Date())!,
            "publicKey" as String: publicKey,
            "signingKey" as String: privateKey
        ]
        _ = certParams // suppress unused warning

        // Fallback: export public key, build minimal DER structure
        guard let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw LocalShareError.certGenerationFailed
        }

        // Build a minimal self-signed certificate DER
        let cert = buildMinimalX509(pubKey: pubKeyData, privKey: privateKey, cn: commonName, days: daysValid)
        return cert
    }

    private func buildMinimalX509(pubKey: Data, privKey: SecKey, cn: String, days: Int) -> Data {
        // Simplified X.509 DER certificate builder
        // This creates a valid self-signed cert structure
        let serial = UInt64.random(in: 1...UInt64.max)

        // TBS Certificate components
        let version = derExplicit(tag: 0, content: derInteger(2)) // v3
        let serialNum = derInteger(Int64(serial & 0x7FFFFFFFFFFFFFFF))
        let signatureAlgo = derSequence([derOID([1,2,840,113549,1,1,11]), derNull()]) // SHA256WithRSA
        let issuer = derSequence([derSet([derSequence([derOID([2,5,4,3]), derUTF8String(cn)])])])
        let now = Date()
        let notAfter = Calendar.current.date(byAdding: .day, value: days, to: now)!
        let validity = derSequence([derUTCTime(now), derUTCTime(notAfter)])
        let subject = issuer
        let subjectPubKeyInfo = derSequence([
            derSequence([derOID([1,2,840,113549,1,1,1]), derNull()]), // RSA
            derBitString(pubKey)
        ])

        let tbsCert = derSequence([version, serialNum, signatureAlgo, issuer, validity, subject, subjectPubKeyInfo])

        // Sign TBS
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsCert as CFData,
            &signError
        ) as Data? else {
            return Data()
        }

        // Final certificate
        return derSequence([tbsCert, signatureAlgo, derBitString(signature)])
    }

    private func computeFingerprint(from identity: SecIdentity) throws -> String {
        var certRef: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certRef)
        guard status == errSecSuccess, let cert = certRef else {
            throw LocalShareError.certGenerationFailed
        }
        let derData = SecCertificateCopyData(cert) as Data
        let hash = SHA256.hash(data: derData)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - DER Encoding Helpers

    private func derLength(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        if length < 256 { return Data([0x81, UInt8(length)]) }
        return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
    }

    private func derTag(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(derLength(content.count))
        result.append(content)
        return result
    }

    private func derSequence(_ items: [Data]) -> Data {
        let content = items.reduce(Data()) { $0 + $1 }
        return derTag(0x30, content)
    }

    private func derSet(_ items: [Data]) -> Data {
        let content = items.reduce(Data()) { $0 + $1 }
        return derTag(0x31, content)
    }

    private func derInteger(_ value: Int64) -> Data {
        var v = value
        let data = withUnsafeBytes(of: &v) { Data($0) }
        var bytes = [UInt8](data.reversed())
        while bytes.count > 1 && bytes[0] == 0 && bytes[1] & 0x80 == 0 { bytes.removeFirst() }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return derTag(0x02, Data(bytes))
    }

    private func derOID(_ components: [UInt]) -> Data {
        var bytes = Data()
        if components.count >= 2 {
            bytes.append(UInt8(components[0] * 40 + components[1]))
        }
        for i in 2..<components.count {
            var value = components[i]
            if value < 128 {
                bytes.append(UInt8(value))
            } else {
                var encoded: [UInt8] = []
                encoded.append(UInt8(value & 0x7F))
                value >>= 7
                while value > 0 {
                    encoded.append(UInt8(value & 0x7F) | 0x80)
                    value >>= 7
                }
                bytes.append(contentsOf: encoded.reversed())
            }
        }
        return derTag(0x06, bytes)
    }

    private func derNull() -> Data { Data([0x05, 0x00]) }

    private func derUTF8String(_ s: String) -> Data {
        derTag(0x0C, Data(s.utf8))
    }

    private func derBitString(_ data: Data) -> Data {
        var content = Data([0x00]) // no unused bits
        content.append(data)
        return derTag(0x03, content)
    }

    private func derUTCTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let s = formatter.string(from: date)
        return derTag(0x17, Data(s.utf8))
    }

    private func derExplicit(tag: UInt8, content: Data) -> Data {
        derTag(0xA0 | tag, content)
    }
}

// MARK: - Errors

enum LocalShareError: Error, LocalizedError {
    case certGenerationFailed
    case serverStartFailed(String)
    case connectionFailed(String)
    case transferRejected
    case transferCancelled
    case sessionNotFound
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .certGenerationFailed: return "Failed to generate TLS certificate"
        case .serverStartFailed(let msg): return "Server failed to start: \(msg)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .transferRejected: return "Transfer was rejected by the receiver"
        case .transferCancelled: return "Transfer was cancelled"
        case .sessionNotFound: return "Session not found"
        case .invalidResponse: return "Invalid response from peer"
        }
    }
}
