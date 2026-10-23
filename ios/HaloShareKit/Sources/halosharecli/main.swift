import Foundation
import HaloShareKit

// halosharecli — a command-line HaloShare peer.
//
// Exists to drive HaloShareKit against *other* implementations (the desktop app's server, the
// Android app, the official LocalSend app) without a UI, and to be the independent counterpart
// in interop tests.
//
//   halosharecli receive [--dir D] [--port P] [--accept|--decline] [--alias A] [--once]
//                        [--ready-file F] [--timeout S]
//   halosharecli send    --to HOST[:PORT] [--alias A] FILE…
//   halosharecli scan    [--timeout S]
//   halosharecli info    HOST[:PORT]
//
// Exit codes: 0 ok · 1 error · 2 usage · 3 receiver declined · 4 timed out

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func usage() -> Never {
    fail("""
    usage:
      halosharecli receive [--dir D] [--port P] [--accept|--decline] [--alias A] [--once] [--ready-file F] [--timeout S]
      halosharecli send --to HOST[:PORT] [--alias A] FILE…
      halosharecli scan [--timeout S]
      halosharecli info HOST[:PORT]
    """, code: 2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let store = InMemoryIdentityStore()
let alias = option("--alias") ?? "halosharecli"
let identity = DeviceIdentityStore.loadOrCreate(in: store, defaultAlias: alias, deviceModel: "CLI", deviceType: "headless")

@Sendable func formatBytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

switch command {

case "receive":
    let dir = URL(fileURLWithPath: option("--dir") ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let port = UInt16(option("--port") ?? "") ?? HaloShare.defaultPort
    let timeout = Double(option("--timeout") ?? "") ?? 0
    let readyFile = option("--ready-file")
    let decline = flag("--decline")
    _ = flag("--accept")
    let once = flag("--once")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let server = HaloShareServer(configuration: .init(identity: identity, receiveDirectory: dir)) { offer in
        print("offer from \(offer.sender.alias): \(offer.files.count) file(s), \(formatBytes(offer.totalBytes)) → \(decline ? "declining" : "accepting")")
        return decline ? .decline : .accept
    }
    let task = Task {
        do {
            let bound = try await server.start(port: port)
            print("listening on \(bound), saving to \(dir.path)")
            if let readyFile { try? "\(bound)\n".write(toFile: readyFile, atomically: true, encoding: .utf8) }
        } catch { fail("could not listen: \(error)") }
        for await event in server.events {
            switch event {
            case .fileReceived(_, _, let url): print("received \(url.lastPathComponent)")
            case .sessionCompleted:
                print("session complete")
                if once { exit(0) }
            case .sessionCancelled: print("session cancelled")
            case .declined: if once { exit(0) }
            default: break
            }
        }
    }
    if timeout > 0 {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { fail("timed out", code: 4) }
    }
    _ = task
    dispatchMain()

case "send":
    guard let target = option("--to"), let (host, port) = LocalNetwork.parseHostPort(target) else { usage() }
    let paths = args
    guard !paths.isEmpty else { usage() }
    let client = HaloShareClient(identity: identity)
    let files: [OutgoingFile]
    do { files = try paths.map { try OutgoingFile(url: URL(fileURLWithPath: $0)) } }
    catch { fail("cannot read a file: \(error)") }

    let sem = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task {
        defer { sem.signal() }
        guard let peer = await client.probe(host: host, port: port, timeout: 5) else {
            FileHandle.standardError.write(Data("no HaloShare peer at \(host):\(port)\n".utf8)); exitCode = 1; return
        }
        print("sending \(files.count) file(s) to \(peer.alias)")
        do {
            let outcome = try await client.send(files, to: peer) { p in
                if p.sent == p.total { print("  \(p.fileName): \(formatBytes(p.total))") }
            }
            switch outcome {
            case .completed: print("done")
            case .declined: print("declined by receiver"); exitCode = 3
            case .nothingToSend: print("nothing to send")
            }
        } catch { FileHandle.standardError.write(Data("failed: \(error.localizedDescription)\n".utf8)); exitCode = 1 }
    }
    sem.wait()
    exit(exitCode)

case "scan":
    let timeout = Double(option("--timeout") ?? "") ?? 1.5
    let client = HaloShareClient(identity: identity)
    let sem = DispatchSemaphore(value: 0)
    Task {
        let peers = await SubnetScanner(client: client, timeout: timeout).scan { p in print("found \(p.alias) at \(p.host):\(p.port)") }
        print("\(peers.count) peer(s)")
        sem.signal()
    }
    sem.wait()

case "info":
    guard let target = args.first, let (host, port) = LocalNetwork.parseHostPort(target) else { usage() }
    let client = HaloShareClient(identity: identity)
    let sem = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task {
        if let peer = await client.probe(host: host, port: port, timeout: 5) {
            print("\(peer.alias) (\(peer.info.deviceType ?? "?")) fingerprint \(peer.info.fingerprint) \(peer.scheme.rawValue)")
        } else { code = 1; print("no answer") }
        sem.signal()
    }
    sem.wait()
    exit(code)

default:
    usage()
}
