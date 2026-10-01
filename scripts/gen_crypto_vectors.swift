#!/usr/bin/env swift
// Generates docs/specs/crypto-parity-vectors.v1.json — the cross-language crypto
// parity contract for F-049 (Android Kotlin port must reproduce these).
//
// This MIRRORS Halo/Core/Cloud/CryptoService.swift exactly (PBKDF2-HMAC-SHA256,
// 200k iters, NFC/UTF-8 passphrase → 32-byte key; AES-256-GCM combined box
// nonce12||ct||tag16, base64). The authority is HaloTests/CryptoParityTests.verify,
// which re-checks this file against the REAL CryptoService — if this script drifts,
// that test fails. Run:  swift scripts/gen_crypto_vectors.swift
import Foundation
import CryptoKit
import CommonCrypto

let iterations = 200_000

func deriveKey(_ passphrase: String, _ salt: Data) -> Data {
    let pass = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
    var derived = Data(count: 32)
    _ = derived.withUnsafeMutableBytes { d in
        salt.withUnsafeBytes { s in
            pass.withUnsafeBytes { p in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    p.baseAddress?.assumingMemoryBound(to: Int8.self), pass.count,
                    s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    d.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
            }
        }
    }
    return derived
}

func seal(_ text: String, key: Data) -> String {
    let box = try! AES.GCM.seal(Data(text.utf8), using: SymmetricKey(data: key))
    return box.combined!.base64EncodedString()
}

let inputs: [(name: String, pass: String, salt: Data, text: String)] = [
    ("ascii", "correct horse battery staple", Data((0..<16).map { UInt8($0) }), "Hello, Halo"),
    ("bank-sms", "p@ssw0rd!", Data("halo-salt-1234!!".utf8), "A/C *XX3833 debited by Rs 1250.00 via UPI"),
    ("unicode", "café☕", Data((0..<16).map { UInt8(0xA0 &+ $0) }), "Unicode: café ☕ 日本語 — clipboard")
]

var kdf: [[String: Any]] = [], dec: [[String: Any]] = []
for i in inputs {
    let key = deriveKey(i.pass, i.salt)
    kdf.append(["name": i.name, "passphrase": i.pass, "saltB64": i.salt.base64EncodedString(),
                "iterations": iterations, "derivedKeyB64": key.base64EncodedString()])
    dec.append(["name": i.name, "passphrase": i.pass, "saltB64": i.salt.base64EncodedString(),
                "plaintext": i.text, "ciphertextB64": seal(i.text, key: key), "iterations": iterations])
}

let root: [String: Any] = [
    "version": 1,
    "algorithm": ["kdf": "PBKDF2-HMAC-SHA256", "cipher": "AES-256-GCM",
                  "wireFormat": "nonce12 || ciphertext || tag16, base64",
                  "passwordNormalization": "NFC (precomposed)", "passwordEncoding": "UTF-8",
                  "iterations": iterations, "keyBytes": 32, "aad": NSNull()],
    "kdfVectors": kdf, "decryptVectors": dec
]

let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("docs/specs/crypto-parity-vectors.v1.json")
try data.write(to: out)
print("Wrote \(out.path) — \(kdf.count) kdf + \(dec.count) decrypt vectors")
