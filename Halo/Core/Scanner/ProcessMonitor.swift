import Foundation
import AppKit

// MARK: - ProcessMonitor  (P3-11)
//
// Foreground-active — lists top processes by CPU or RAM.
// Uses proc_listallpids() + proc_pidinfo() (same APIs as Activity Monitor).
// Timer owned by TopProcessesSection; destroyed when section closes.

actor ProcessMonitor {

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

    private var previousCPUInfo: [Int32: (user: UInt64, sys: UInt64, total: UInt64)] = [:]
    private var previousSampleTime: Date = Date()

    // MARK: - Public

    func topProcesses(sortBy: SortKey, limit: Int = 10) -> [ProcessInfo] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }

        var pids = [Int32](repeating: 0, count: Int(count) + 16)
        let actual = proc_listallpids(&pids, Int32(pids.count) * 4)
        guard actual > 0 else { return [] }

        let now = Date()
        let elapsed = now.timeIntervalSince(previousSampleTime)
        previousSampleTime = now

        var infos: [ProcessInfo] = []

        for pid in pids.prefix(Int(actual)) where pid > 0 {
            guard let info = processInfo(pid: pid, elapsed: elapsed) else { continue }
            infos.append(info)
        }

        // Update CPU snapshot
        for pid in pids.prefix(Int(actual)) where pid > 0 {
            updateCPUSnapshot(pid: pid)
        }

        let sorted: [ProcessInfo]
        switch sortBy {
        case .cpu: sorted = infos.sorted { $0.cpuPercent > $1.cpuPercent }
        case .ram: sorted = infos.sorted { $0.ramMB > $1.ramMB }
        }

        return Array(sorted.prefix(limit))
    }

    // MARK: - Per-process info

    private func processInfo(pid: Int32, elapsed: TimeInterval) -> ProcessInfo? {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        guard ret > 0 else { return nil }

        let ramMB = Double(info.pti_resident_size) / 1_048_576

        // CPU: diff user+system ticks from previous snapshot
        let user  = info.pti_total_user
        let sys   = info.pti_total_system
        let total = user + sys

        var cpuPct: Double = 0
        if let prev = previousCPUInfo[pid], elapsed > 0 {
            let delta = Double(total - prev.total)
            // pti_total_user/system are in nanoseconds
            cpuPct = (delta / 1e9) / elapsed * 100.0 / Double(Foundation.ProcessInfo.processInfo.activeProcessorCount)
        }

        let name = processName(pid: pid)

        return ProcessInfo(
            id: pid,
            name: name,
            cpuPercent: max(0, min(cpuPct, 100)),
            ramMB: ramMB,
            isUserApp: ramMB > 1   // heuristic: daemons typically < 1 MB
        )
    }

    private func updateCPUSnapshot(pid: Int32) {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        guard ret > 0 else { return }
        previousCPUInfo[pid] = (user: info.pti_total_user,
                                sys: info.pti_total_system,
                                total: info.pti_total_user + info.pti_total_system)
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
