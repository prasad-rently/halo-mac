import Foundation
import AppKit

// MARK: - ProcessMonitor  (P3-11)
//
// Lists top processes by CPU or RAM.
// Uses proc_listallpids() + proc_pidinfo() (same APIs as Activity Monitor).

actor ProcessMonitor {

    // MARK: - Singleton
    //
    // One instance, app-wide. Several subsystems sample processes on their own
    // cadences (Performance → Top Processes every 3 s, and the F-021/F-023/F-028
    // features queued behind it). A per-caller instance gives each its own
    // `previousCPUInfo` baseline, which means: the ~600-entry dictionary is
    // duplicated per instance, every instance's first call reports 0 % CPU
    // because it has no baseline to diff against, and two surfaces quote
    // different CPU numbers for the same process because their sampling windows
    // differ. `init` is private so a fourth instance can't reappear by accident.
    static let shared = ProcessMonitor()
    private init() {}

    // MARK: - Public model

    struct ProcessInfo: Identifiable, Sendable {
        let id: Int32              // PID
        let name: String
        let cpuPercent: Double
        let ramMB: Double
        let isUserApp: Bool        // false for daemons/kernel threads
    }

    enum SortKey: Sendable { case cpu, ram }

    // MARK: - Private state

    /// PID → cumulative user+system CPU nanoseconds at the last sample.
    /// Rebuilt (not mutated) on every pass, so dead PIDs drop out — see `resample()`.
    private var previousCPUInfo: [Int32: UInt64] = [:]
    private var previousSampleTime: Date = Date()

    private var cachedProcesses: [ProcessInfo] = []
    private var cachedAt: Date?

    /// Snapshot coalescing window.
    ///
    /// Sharing one instance means two callers can land within milliseconds of
    /// each other. Without this, the second call computes its CPU delta over a
    /// near-zero `elapsed` and every process reads ~0 % — so whichever surface
    /// sampled second would show a flat, wrong CPU column. One second is well
    /// under the fastest real caller (the 3 s Top Processes timer), so that
    /// caller still re-samples on every tick; the window only absorbs
    /// coincidences.
    private static let coalesceWindow: TimeInterval = 1.0

    // MARK: - Public

    func topProcesses(sortBy: SortKey, limit: Int = 10) -> [ProcessInfo] {
        let infos = snapshot()
        let sorted: [ProcessInfo]
        switch sortBy {
        case .cpu: sorted = infos.sorted { $0.cpuPercent > $1.cpuPercent }
        case .ram: sorted = infos.sorted { $0.ramMB > $1.ramMB }
        }
        return Array(sorted.prefix(limit))
    }

    /// Every live process, re-sampled at most once per `coalesceWindow`.
    func snapshot() -> [ProcessInfo] {
        if let at = cachedAt, Date().timeIntervalSince(at) < Self.coalesceWindow {
            return cachedProcesses
        }
        return resample()
    }

    // MARK: - Sampling

    private func resample() -> [ProcessInfo] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }

        var pids = [Int32](repeating: 0, count: Int(count) + 16)
        let actual = proc_listallpids(&pids, Int32(pids.count) * 4)
        guard actual > 0 else { return [] }

        let now     = Date()
        let elapsed = now.timeIntervalSince(previousSampleTime)
        let cores   = Double(Foundation.ProcessInfo.processInfo.activeProcessorCount)

        var infos: [ProcessInfo] = []
        infos.reserveCapacity(Int(actual))

        // Built fresh rather than mutated in place: the previous version only
        // ever added entries, so `previousCPUInfo` kept a row for every PID the
        // app had ever seen and grew without bound as short-lived processes came
        // and went. Rebuilding drops dead PIDs on every pass.
        var nextCPUInfo: [Int32: UInt64] = [:]
        nextCPUInfo.reserveCapacity(Int(actual))

        for pid in pids.prefix(Int(actual)) where pid > 0 {
            // One proc_pidinfo() per PID. The previous version called it twice —
            // once to read the process and again to record the CPU snapshot —
            // which doubled the syscall count of every sample for no benefit.
            var info = proc_taskinfo()
            let size = MemoryLayout<proc_taskinfo>.size
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size)) > 0 else { continue }

            // pti_total_user / pti_total_system are cumulative nanosecond counters.
            let total = info.pti_total_user + info.pti_total_system
            nextCPUInfo[pid] = total

            var cpuPct: Double = 0
            // `total >= previous` is a real guard, not defensive noise: macOS
            // recycles PIDs, so a slot can come back pointing at a younger
            // process with a smaller cumulative counter. `total - previous` is
            // UInt64 subtraction, which traps on underflow — that would crash
            // the app outright. A shared, long-lived instance keeps its baseline
            // for the whole app lifetime, so it sees PID reuse far more often
            // than a short-lived per-view instance ever did.
            if let previous = previousCPUInfo[pid], total >= previous, elapsed > 0 {
                cpuPct = Double(total - previous) / 1e9 / elapsed * 100.0 / cores
            }

            let ramMB = Double(info.pti_resident_size) / 1_048_576

            infos.append(ProcessInfo(
                id: pid,
                name: processName(pid: pid),
                cpuPercent: max(0, min(cpuPct, 100)),
                ramMB: ramMB,
                isUserApp: ramMB > 1   // heuristic: daemons typically < 1 MB
            ))
        }

        previousCPUInfo    = nextCPUInfo
        previousSampleTime = now
        cachedProcesses    = infos
        cachedAt           = now

        return infos
    }

    private func processName(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let raw = String(cString: buffer)
        return raw.isEmpty ? "PID \(pid)" : raw
    }
}

// MARK: - Bridging import for proc_pidinfo

import Darwin.sys.proc_info

private let PROC_PIDTASKINFO: Int32 = 4
