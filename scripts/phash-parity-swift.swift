// F-025 pHash cross-language parity — the SWIFT side.
//
// Standalone: `swift scripts/phash-parity-swift.swift --write`   (no app build, no Xcode scheme)
//   --write    read the inputs in docs/specs/phash-parity.v1.json, run the Swift DCT+median code on each, and rewrite
//              the file with the expected hashes / coefficients / safety margins.
//   --verify   same computation, but only COMPARE against what is already in the file (exit 1 on any difference).
//
// Not a reimplementation: `dct2D` and `perceptualHash` below are byte-for-byte the bodies from
// Halo/Core/Scanner/PerceptualDuplicateDetector.swift (only the `nonisolated private static` modifiers differ, because
// a script cannot carry actor-isolation modifiers). Every run first checks that claim against the product file
// and aborts if the two have drifted, so this script cannot silently go stale. Desktop product code is not modified.
import Foundation

enum Core {
    // ---- BEGIN verbatim from PerceptualDuplicateDetector.swift ----
    /// 32×32 grayscale grid → 64-bit pHash (top-left 8×8 DCT coefficients,
    /// thresholded against their median).
    static func perceptualHash(from grid: [[Double]]) -> UInt64 {
        let dct = dct2D(grid)

        var lowFrequency: [Double] = []
        lowFrequency.reserveCapacity(64)
        for y in 0..<8 {
            for x in 0..<8 {
                lowFrequency.append(dct[y][x])
            }
        }

        // Exclude the DC term ([0][0], overall average brightness) when
        // computing the median — it's a huge outlier that would otherwise
        // skew every other bit toward "below median".
        let acCoefficients = Array(lowFrequency.dropFirst())
        let median = acCoefficients.sorted()[acCoefficients.count / 2]

        var hash: UInt64 = 0
        for (i, value) in lowFrequency.enumerated() {
            if value > median {
                hash |= (1 << UInt64(63 - i))
            }
        }
        return hash
    }

    /// Naive separable 2-D DCT-II. O(N^3) but N is fixed at 32, so this is a
    /// few thousand multiply-adds per image — negligible next to image decode.
    static func dct2D(_ input: [[Double]]) -> [[Double]] {
        let n = input.count
        var cosTable = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for x in 0..<n {
            for u in 0..<n {
                cosTable[x][u] = cos(Double.pi / Double(n) * (Double(x) + 0.5) * Double(u))
            }
        }

        // Pass 1: DCT along rows.
        var rowsTransformed = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for y in 0..<n {
            for u in 0..<n {
                var sum = 0.0
                for x in 0..<n { sum += input[y][x] * cosTable[x][u] }
                rowsTransformed[y][u] = sum
            }
        }

        // Pass 2: DCT along columns, with orthonormal scaling factors applied.
        var output = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for u in 0..<n {
            let cu = u == 0 ? 1.0 / 2.0.squareRoot() : 1.0
            for v in 0..<n {
                let cv = v == 0 ? 1.0 / 2.0.squareRoot() : 1.0
                var sum = 0.0
                for y in 0..<n { sum += rowsTransformed[y][u] * cosTable[y][v] }
                output[v][u] = 0.25 * cu * cv * sum
            }
        }
        return output
    }
    // ---- END verbatim ----
}

// MARK: - drift guard

/// Text of the function starting at `func <name>(` through its matching close brace, whitespace-normalised.
func functionBody(_ source: String, name: String) -> String? {
    guard let start = source.range(of: "func \(name)(") else { return nil }
    var depth = 0, seen = false
    var end = start.lowerBound
    for idx in source[start.lowerBound...].indices {
        let c = source[idx]
        if c == "{" { depth += 1; seen = true }
        if c == "}" { depth -= 1 }
        if seen && depth == 0 { end = source.index(after: idx); break }
    }
    return source[start.lowerBound..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let productPath = repoRoot.appendingPathComponent("Halo/Core/Scanner/PerceptualDuplicateDetector.swift")
let fixturePath = repoRoot.appendingPathComponent("docs/specs/phash-parity.v1.json")

do {
    let product = try String(contentsOf: productPath, encoding: .utf8)
    let mine = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
    for fn in ["perceptualHash", "dct2D"] {
        guard let a = functionBody(product, name: fn), let b = functionBody(mine, name: fn), a == b else {
            FileHandle.standardError.write("DRIFT: \(fn) differs from \(productPath.path) — update this script from the product code first.\n".data(using: .utf8)!)
            exit(2)
        }
    }
} catch { print("cannot read sources: \(error)"); exit(2) }

// MARK: - run

let mode = CommandLine.arguments.dropFirst().first ?? "--verify"
guard mode == "--write" || mode == "--verify" else { print("usage: swift phash-parity-swift.swift [--write|--verify]"); exit(64) }

let raw = try Data(contentsOf: fixturePath)
let root = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
let cases = root["cases"] as! [[String: Any]]

func g17(_ d: Double) -> String { String(format: "%.17g", d) }
func jstr(_ s: String) -> String {
    var o = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        default: o += u.value < 0x20 || u.value > 0x7e ? String(format: "\\u%04x", u.value) : String(u)
        }
    }
    return o + "\""
}

var lines: [String] = []
var mismatches = 0
for c in cases {
    let name = c["name"] as! String
    let pixels = (c["pixels"] as! [Any]).map { ($0 as! NSNumber).intValue }
    precondition(pixels.count == 1024, "\(name): need 1024 pixels")
    let grid: [[Double]] = (0..<32).map { y in (0..<32).map { x in Double(pixels[y * 32 + x]) } }
    let hash = Core.perceptualHash(from: grid)
    let dct = Core.dct2D(grid)
    var low: [Double] = []
    for y in 0..<8 { for x in 0..<8 { low.append(dct[y][x]) } }
    let ac = Array(low.dropFirst()).sorted()
    let median = ac[ac.count / 2]
    // Smallest distance of any OTHER coefficient to the median (the median element itself is the reference and is
    // always bit 0). A margin near floating-point noise means that bit could flip with a different libm.
    let medianIndex = low.indices.dropFirst().first { low[$0] == median }!
    let margin = low.indices.filter { $0 != medianIndex }.map { abs(low[$0] - median) }.min()!
    let hex = String(format: "%016llx", hash)

    if mode == "--verify" {
        if (c["hash"] as? String) != hex { print("MISMATCH \(name): file \(String(describing: c["hash"])) swift \(hex)"); mismatches += 1 }
    }
    let note = c["note"] as? String ?? ""
    let degenerate = (c["degenerate"] as? Bool) ?? false
    let px = pixels.map(String.init).joined(separator: ",")
    // Key order = alphabetical, like the Python writer's sort_keys, so --write on an unchanged fixture is a no-op diff.
    lines.append("  {\"coefficients\":[" + low.map(g17).joined(separator: ",") + "],\"degenerate\":\(degenerate),\"hash\":\"\(hex)\",\"margin\":\(g17(margin)),\"median\":\(g17(median)),\"name\":\(jstr(name)),\"note\":\(jstr(note)),\"pixels\":[\(px)]}")
}

if mode == "--verify" {
    print(mismatches == 0 ? "OK — \(cases.count) cases match the Swift implementation" : "\(mismatches) mismatches")
    exit(mismatches == 0 ? 0 : 1)
}

var out = "{\n"
for k in ["version", "description", "generator", "seed"] {
    let v = root[k]!
    out += " \(jstr(k)): " + (v is NSNumber && !(v is String) ? "\(v)" : jstr(v as! String)) + ",\n"
}
out += " \"cases\": [\n" + lines.joined(separator: ",\n") + "\n ]\n}\n"
try out.write(to: fixturePath, atomically: true, encoding: .utf8)
print("wrote \(cases.count) cases with Swift-computed hashes -> \(fixturePath.path)")
