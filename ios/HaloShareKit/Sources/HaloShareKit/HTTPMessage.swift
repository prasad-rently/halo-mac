import Foundation

// MARK: - HTTPRequestHead

/// A parsed HTTP/1.1 request line and headers — **no body**. Pure and byte-oriented, so the
/// framing rules can be tested without a socket (protocol doc §1: never assume the head and
/// the body arrive in separate reads).
public struct HTTPRequestHead: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lower-cased.
    public var headers: [String: String]

    /// 0 when absent or unparseable.
    public var contentLength: Int {
        headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
    }
    public var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") == true }
    public var expectsContinue: Bool { headers["expect"]?.lowercased() == "100-continue" }

    /// `head` is everything before the blank line. Decoding is lossy rather than failing, so
    /// a stray high byte in a header value cannot turn a valid request into a `400`.
    public static func parse(_ head: Data) -> HTTPRequestHead? {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let pieces = String(parts[1]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces[0])
        guard path.hasPrefix("/") else { return nil }

        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let name = kv.first, !name.isEmpty else { continue }
                let value = kv.count > 1 ? String(kv[1]) : ""
                query[String(name).removingPercentEncoding ?? String(name)] = value.removingPercentEncoding ?? value
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        return HTTPRequestHead(method: String(parts[0]).uppercased(), path: path, query: query, headers: headers)
    }
}

// MARK: - HTTPResponse

enum HTTPResponse {
    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default:  return "Unknown"
        }
    }

    static func data(status: Int, json body: String? = nil) -> Data {
        let payload = Data((body ?? "").utf8)
        var head = "HTTP/1.1 \(status) \(reason(status))\r\nConnection: close\r\nContent-Length: \(payload.count)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        return out
    }

    static func data<T: Encodable>(status: Int = 200, encoding value: T) -> Data {
        let json = (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return data(status: status, json: json)
    }

    static func error(_ status: Int, _ message: String) -> Data {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return data(status: status, json: "{\"error\":\"\(escaped)\"}")
    }
}

// MARK: - SafeFileName

/// Turning a sender-supplied file name into a path that is safe to write (protocol doc §7).
///
/// LocalSend senders may include folders (`photos/2026/a.jpg`), so a relative sub-path is
/// kept. Refused: `..`/`.`/empty components, absolute prefixes, NUL. `\` is a separator
/// (Windows senders).
public enum SafeFileName {

    public static func relativePath(_ raw: String) -> String? {
        guard !raw.contains("\0") else { return nil }
        let parts = raw.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// `base/<safe path>`, inside `base`, with ` (1)`, ` (2)` … before the extension if it
    /// already exists — never an overwrite.
    ///
    /// Containment is checked **lexically**, not with `standardizedFileURL`: that call strips a
    /// `/private` prefix only for paths that *exist*, so the (existing) destination directory
    /// and the (not yet written) candidate file normalised differently, the check wrongly
    /// failed, and every file was saved as "file". `relativePath` has already removed `.`,
    /// `..` and empty components, so the result is inside `base` by construction; the prefix
    /// test is the belt to that braces.
    public static func uniqueDestination(for rawName: String, in base: URL,
                                         fileManager: FileManager = .default) -> URL {
        func build(_ relative: String) -> URL {
            var url = base
            for component in relative.split(separator: "/") { url.appendPathComponent(String(component)) }
            return url
        }
        var candidate = build(relativePath(rawName) ?? "file")
        let root = base.path.hasSuffix("/") ? base.path : base.path + "/"
        if !candidate.path.hasPrefix(root) { candidate = build("file") }
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let dir = candidate.deletingLastPathComponent()
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let next = dir.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }
}
