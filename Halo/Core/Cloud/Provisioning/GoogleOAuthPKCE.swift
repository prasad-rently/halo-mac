import Foundation
import CryptoKit

// MARK: - GoogleOAuthPKCE  (F-044 S2 spike — assisted provisioning)
//
// The verification-independent core of Halo's "assisted provisioning" OAuth flow.
//
// SPIKE FINDING (2026-07): Google's **device / limited-input** OAuth flow only
// supports a fixed scope set (email/openid/profile/Drive/YouTube) — it CANNOT
// request `cloud-platform`/`firebase`, so it's unusable for provisioning. The only
// viable native-desktop flow is the **loopback-IP redirect + PKCE authorization
// code** grant (Google's recommended mechanism; custom URI schemes are deprecated;
// the client secret is optional for installed apps). This type builds exactly that.
//
// It is intentionally standalone and NOT wired into any UI: the live flow is gated
// on Google app-verification for the restricted `cloud-platform` scope (see
// docs/specs/firebase-setup.md §7 "S2"). Everything here is pure request
// construction + PKCE, fully unit-testable without a network or a Google account.

/// A PKCE (RFC 7636) verifier/challenge pair for the authorization-code flow.
struct PKCE: Equatable, Sendable {
    let verifier: String     // 43–128 chars, unreserved set
    let challenge: String    // BASE64URL(SHA256(verifier))
    let method = "S256"

    private enum CodingKeys: String, CodingKey { case verifier, challenge }

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// Fresh pair from 32 random bytes (→ a 43-char base64url verifier).
    static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PKCE(verifier: base64url(Data(bytes)))
    }

    /// S256 challenge = BASE64URL(SHA256(ASCII(verifier))).
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(digest))
    }

    /// URL-safe base64 without padding (RFC 4648 §5).
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Builds the two HTTP artifacts of the loopback + PKCE flow: the browser
/// authorization URL and the code→token exchange request. The caller runs a
/// transient `127.0.0.1` listener for the redirect and opens the URL.
enum GoogleOAuth {

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// The restricted scope that grants Firebase/RTDB/Identity-Toolkit management.
    /// (Its "restricted" status is precisely what triggers Google app-verification.)
    static let cloudPlatformScope = "https://www.googleapis.com/auth/cloud-platform"

    /// Browser URL that starts consent. `redirectURI` is a loopback address with a
    /// transient port, e.g. `http://127.0.0.1:53127/callback`.
    static func authorizationURL(clientID: String,
                                 redirectURI: String,
                                 scopes: [String],
                                 pkce: PKCE,
                                 state: String) -> URL {
        var c = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),   // ask for a refresh token
            .init(name: "prompt", value: "consent")
        ]
        return c.url!
    }

    /// `application/x-www-form-urlencoded` POST that exchanges the returned `code`
    /// for tokens. `clientSecret` is optional (installed-app clients may omit it).
    static func tokenExchangeRequest(clientID: String,
                                     clientSecret: String?,
                                     code: String,
                                     redirectURI: String,
                                     pkce: PKCE) -> URLRequest {
        var params = [
            "client_id": clientID,
            "code": code,
            "code_verifier": pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if let clientSecret { params["client_secret"] = clientSecret }

        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(formEncode(params).utf8)
        return req
    }

    /// Stable, percent-encoded form body (sorted keys for deterministic tests).
    static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.keys.sorted().map { key in
            let v = params[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? params[key]!
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
