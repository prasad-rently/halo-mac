import Foundation

// MARK: - HaloHelperImpl  (F-002)
//
// Implements the privileged operations. Runs inside the HaloHelper XPC service
// process — NOT inside the sandboxed Halo.app process.
//
// Each operation shells out via Process(). Errors are logged and propagated
// to the caller via the reply block (never throws across XPC boundary).
//
// Privilege model:
//   - DNS flush and mDNSResponder SIGHUP require no special privilege.
//   - `purge` command requires root; we use memory_pressure instead.
//   - mdutil requires no special privilege for the current user's volume.
//   - Font cache clear requires writing to /Library — uses user Library instead.

final class HaloHelperImpl: NSObject, HaloHelperProtocol {

    // MARK: - DNS flush

    func flushDNS(reply: @escaping (Bool) -> Void) {
        let ok1 = shell("/usr/bin/dscacheutil", args: ["-flushcache"])
        let ok2 = shell("/bin/kill", args: ["-HUP", mDNSResponderPID()])
        reply(ok1 && ok2)
    }

    // MARK: - RAM purge

    func purgeRAM(reply: @escaping (Double) -> Void) {
        // memory_pressure -l critical briefly brings memory pressure to
        // "critical" level which triggers the kernel to flush inactive pages.
        // This is the user-accessible equivalent of `sudo purge`.
        let before = availableMemoryMB()
        _ = shell("/usr/bin/memory_pressure", args: ["-l", "critical"])
        // Give the kernel a moment to reclaim pages
        Thread.sleep(forTimeInterval: 0.5)
        let after = availableMemoryMB()
        let freed = max(0, after - before)
        reply(freed)
    }

    // MARK: - Spotlight rebuild

    func rebuildSpotlightIndex(reply: @escaping (Bool) -> Void) {
        // mdutil -E / turns off then re-enables indexing, triggering a full rebuild.
        let ok = shell("/usr/bin/mdutil", args: ["-E", "/"])
        reply(ok)
    }

    // MARK: - Font cache clear

    func clearFontCache(reply: @escaping (Bool) -> Void) {
        // Remove per-user font caches. System-wide font caches in /Library/Caches
        // require root; the user-level caches in ~/Library/Caches cover most issues.
        let userCaches = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Caches/com.apple.ATS")
        let ok = removeDirectory(at: userCaches)
        // Signal fontd to rebuild
        _ = shell("/usr/bin/killall", args: ["-9", "fontd"])
        reply(ok)
    }

    // MARK: - Version

    func helperVersion(reply: @escaping (String) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        reply(version)
    }

    // MARK: - Helpers

    @discardableResult
    private func shell(_ path: String, args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            NSLog("[HaloHelper] shell error: %@ %@: %@", path, args.joined(separator: " "), error.localizedDescription)
            return false
        }
    }

    private func mDNSResponderPID() -> String {
        // Get PID of mDNSResponder for the SIGHUP
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid,comm"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            if line.contains("mDNSResponder") && !line.contains("Helper") {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
                if let pid = parts.first { return pid }
            }
        }
        return "0"
    }

    private func availableMemoryMB() -> Double {
        // Use host_statistics to read vm_statistics
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Double(vm_kernel_page_size)
        let freeMB = Double(stats.free_count) * pageSize / 1_048_576
        let inactiveMB = Double(stats.inactive_count) * pageSize / 1_048_576
        return freeMB + inactiveMB
    }

    private func removeDirectory(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            NSLog("[HaloHelper] removeDirectory error at %@: %@", path, error.localizedDescription)
            return false
        }
    }
}
