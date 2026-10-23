// ──────────────────────────────────────────────────────────────────────────────
// LetheInviteLink.swift — F-052
//
// Invite links are the only way a room key travels, so this file is the only
// place it is serialised.
//
//     lethe://join#roomId=<hex>&roomKey=<base64url>&name=<base64url-encrypted>
//
// The `#` matters: a fragment is never sent to a server by any HTTP client, so
// even pasting the link into a web form does not hand the key to that server.
// Must stay byte-compatible with `app/lib/crypto/invite.dart`.
// ──────────────────────────────────────────────────────────────────────────────

import Foundation

struct LetheInvite: Equatable {
    let roomId: String
    let roomKey: Data
    let roomName: String
}

enum LetheInviteLink {

    static let scheme = "lethe"
    private static let prefix = "lethe://join#"

    // MARK: - Encode

    static func create(roomId: String, roomKey: Data, roomName: String, nonce: Data? = nil) throws -> String {
        let keyB64 = LetheCrypto.base64URLEncode(roomKey)
        let nameBlob = try LetheCrypto.encryptStringURL(roomName, roomKey: roomKey, nonce: nonce)
        return prefix
            + "roomId=\(percentEncode(roomId))"
            + "&roomKey=\(percentEncode(keyB64))"
            + "&name=\(percentEncode(nameBlob))"
    }

    // MARK: - Decode

    /// Returns nil for anything malformed — a bad paste is a normal event, not
    /// an exceptional one, and the caller shows a message either way.
    static func parse(_ url: String) -> LetheInvite? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let fragment = String(trimmed.dropFirst(prefix.count))
        guard !fragment.isEmpty else { return nil }

        var params: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let k = String(pair[pair.startIndex..<eq])
            guard !k.isEmpty else { continue }
            let rawValue = String(pair[pair.index(after: eq)...])
            params[k] = rawValue.removingPercentEncoding ?? rawValue
        }

        guard let roomId = params["roomId"],
              let keyB64 = params["roomKey"],
              let nameBlob = params["name"],
              let roomKey = LetheCrypto.base64URLDecode(keyB64),
              roomKey.count == LetheCrypto.keyLength
        else { return nil }

        // The name blob is encrypted with the very key in the link, so decrypting
        // it is also a free integrity check: if it fails, the link is corrupt or
        // the two halves don't belong together, and joining would be pointless.
        guard let roomName = try? LetheCrypto.decryptStringURL(nameBlob, roomKey: roomKey) else {
            return nil
        }

        // Trust the key, not the stated id: the id is derivable and the key is
        // authoritative. A link claiming a mismatched roomId would otherwise
        // JOIN a room nobody can decrypt.
        let derived = LetheCrypto.deriveRoomId(from: roomKey)
        guard derived == roomId else { return nil }

        return LetheInvite(roomId: roomId, roomKey: roomKey, roomName: roomName)
    }

    // MARK: - Helpers

    /// Matches JS `encodeURIComponent`: escapes everything outside the unreserved
    /// set plus `!*'()`. `CharacterSet.urlQueryAllowed` is far too permissive —
    /// it leaves `&` and `=` unescaped, which would corrupt the fragment.
    private static func percentEncode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}
