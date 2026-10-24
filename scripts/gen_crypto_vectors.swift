#!/usr/bin/env swift
// Generates docs/specs/crypto-parity-vectors.v2.json — the cross-language crypto
// parity contract for F-049 (the Android Kotlin port must reproduce these).
//
// This MIRRORS Halo/Core/Cloud/CryptoService.swift exactly:
//   key      = PBKDF2-HMAC-SHA256(NFC(passphrase) as UTF-8, salt, iterations) → 32 bytes
//   v1 box   = "v1:" + base64( AES-256-GCM(key, plaintext, aad = "halo.cloud.v1") nonce12||ct||tag16 )
//   v0 box   = base64( AES-256-GCM(key, plaintext, no aad) )   — legacy, read-only
// and PassphrasePolicy (>= 12 characters after NFC, >= 6 distinct).
//
// The authority is HaloTests/CloudFoundationTests.swift `CryptoParityTests`, which
// re-checks this file against the REAL CryptoService — if this script drifts, that
// test fails. Run from the repo root:  swift scripts/gen_crypto_vectors.swift
import Foundation
import CryptoKit
import CommonCrypto

let defaultIterations = 600_000
let legacyIterations = 200_000
let aad = Data("halo.cloud.v1".utf8)

func deriveKey(_ passphrase: String, _ salt: Data, _ iterations: Int) -> Data {
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

func sealV1(_ text: String, key: Data) -> String {
    let box = try! AES.GCM.seal(Data(text.utf8), using: SymmetricKey(data: key), authenticating: aad)
    return "v1:" + box.combined!.base64EncodedString()
}

func sealV0(_ text: String, key: Data) -> String {
    let box = try! AES.GCM.seal(Data(text.utf8), using: SymmetricKey(data: key))
    return box.combined!.base64EncodedString()
}

// Every passphrase below satisfies PassphrasePolicy — vectors model real, creatable keys.
let inputs: [(name: String, pass: String, salt: Data, text: String)] = [
    ("ascii", "correct horse battery staple", Data((0..<16).map { UInt8($0) }), "Hello, Halo"),
    ("bank-sms", "p@ssw0rd!-with-length", Data("halo-salt-1234!!".utf8), "A/C *XX3833 debited by Rs 1250.00 via UPI"),
    ("unicode", "café☕ au lait ☕ crème", Data((0..<16).map { UInt8(0xA0 &+ $0) }), "Unicode: café ☕ 日本語 — clipboard")
]

var kdf: [[String: Any]] = [], dec: [[String: Any]] = [], legacy: [[String: Any]] = [], reject: [[String: Any]] = []

for i in inputs {
    let key = deriveKey(i.pass, i.salt, defaultIterations)
    let common: [String: Any] = ["name": i.name, "passphrase": i.pass,
                                 "saltB64": i.salt.base64EncodedString(), "iterations": defaultIterations]
    kdf.append(common.merging(["derivedKeyB64": key.base64EncodedString()]) { $1 })
    dec.append(common.merging(["plaintext": i.text, "ciphertext": sealV1(i.text, key: key)]) { $1 })

    // v1 body with the prefix removed: must NOT open — the AAD is what stops a downgrade.
    let v1 = sealV1(i.text, key: key)
    reject.append(common.merging(["name": "\(i.name)/prefix-stripped",
                                  "ciphertext": String(v1.dropFirst(3)),
                                  "expect": "decryptionFailed"]) { $1 })
}

// Legacy (pre-v2.5) boxes: 200k iterations, no prefix, no AAD. Must still decrypt.
for i in inputs {
    let key = deriveKey(i.pass, i.salt, legacyIterations)
    legacy.append(["name": i.name, "passphrase": i.pass, "saltB64": i.salt.base64EncodedString(),
                   "iterations": legacyIterations, "plaintext": i.text, "ciphertext": sealV0(i.text, key: key)])
    kdf.append(["name": "\(i.name)/legacy-200k", "passphrase": i.pass, "saltB64": i.salt.base64EncodedString(),
                "iterations": legacyIterations, "derivedKeyB64": key.base64EncodedString()])
}
// A legacy box wearing a v1 prefix: must NOT open (it was never sealed with the AAD).
do {
    let i = inputs[0]
    let key = deriveKey(i.pass, i.salt, defaultIterations)
    reject.append(["name": "ascii/v0-body-with-v1-prefix", "passphrase": i.pass,
                   "saltB64": i.salt.base64EncodedString(), "iterations": defaultIterations,
                   "ciphertext": "v1:" + sealV0(i.text, key: key), "expect": "decryptionFailed"])
}

// PassphrasePolicy. Counting is by user-perceived character AFTER NFC normalisation —
// a UTF-16 `length` (Kotlin's String.length) gets the combining case below wrong.
let policy: [(String, String)] = [
    ("correct horse battery staple", "ok"),
    ("abcdefghijkl", "ok"),                                  // exactly 12, 12 distinct
    ("abcdefghijk", "tooShort:11"),
    ("short", "tooShort:5"),
    ("", "tooShort:0"),
    ("aaaaaaaaaaaaaaaa", "tooRepetitive"),
    ("abcabcabcabc", "tooRepetitive"),                       // 12 long, 3 distinct
    ("abcdeabcdeab", "tooRepetitive"),                       // 5 distinct: just under the floor
    ("abcdefabcdef", "ok"),                                  // 6 distinct: exactly the floor
    ("e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}", "tooShort:6"), // 6 chars after NFC, 12 code points before
    ("café☕café☕café☕", "tooRepetitive"),
]

let root: [String: Any] = [
    "version": 2,
    "algorithm": [
        "kdf": "PBKDF2-HMAC-SHA256", "cipher": "AES-256-GCM",
        "envelope": "\"v1:\" + base64(nonce12 || ciphertext || tag16)",
        "aad": "halo.cloud.v1",
        "legacyEnvelope": "base64(nonce12 || ciphertext || tag16), no AAD — read-only",
        "passwordNormalization": "NFC (precomposed)", "passwordEncoding": "UTF-8",
        "defaultIterations": defaultIterations, "legacyIterations": legacyIterations,
        "minimumIterations": 100_000, "minimumSaltBytes": 16, "keyBytes": 32,
        "passphraseMinimumLength": 12, "passphraseMinimumDistinct": 6
    ],
    "kdfVectors": kdf, "decryptVectors": dec, "legacyDecryptVectors": legacy,
    "rejectVectors": reject,
    "passphraseVectors": policy.map { ["passphrase": $0.0, "verdict": $0.1] }
]

let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("docs/specs/crypto-parity-vectors.v2.json")
try data.write(to: out)
print("Wrote \(out.path) — \(kdf.count) kdf, \(dec.count) decrypt, \(legacy.count) legacy, \(reject.count) reject, \(policy.count) passphrase vectors")
