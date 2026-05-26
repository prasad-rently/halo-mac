import Foundation
import IOKit

// MARK: - GPUMonitor  (P3-03)
//
// Foreground-active — reads IOAccelerator PerformanceStatistics once per sample.
// Works on both Apple Silicon (AGX) and Intel + discrete GPU Macs.
// Timer owned by the GPU section view; zero cost when view is closed.

actor GPUMonitor {

    // MARK: - Public model

    struct GPUStats: Sendable {
        let name: String
        let utilisation: Double        // 0.0 – 1.0 (renderer busy %)
        let rendererUtil: Double       // renderer-only
        let tilerUtil: Double          // tiler-only (Apple Silicon)
        let memoryUsedMB: Int
        let memoryTotalMB: Int
        var memoryUsage: Double {
            memoryTotalMB > 0 ? Double(memoryUsedMB) / Double(memoryTotalMB) : 0
        }
    }

    // MARK: - Sample

    func sample() -> [GPUStats] {
        var results: [GPUStats] = []

        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef,
                                                     kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = propsRef?.takeRetainedValue() as? [String: Any] else { continue }

            // GPU name from IOKit registry
            var name = "GPU"
            if let n = dict["IOClass"] as? String { name = n }
            if let n = dict["AcceleratorName"] as? String { name = n }

            // PerformanceStatistics sub-dict
            guard let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            // Utilisation keys differ between Apple Silicon and Intel/AMD:
            //   Apple Silicon:  "Renderer Utilization %", "Tiler Utilization %", "Device Utilization %"
            //   Intel/AMD:      "GPU Activity(%)", "In use system memory"
            let deviceUtil   = (perf["Device Utilization %"] as? Int ?? perf["GPU Activity(%)"] as? Int ?? 0)
            let rendererUtil = perf["Renderer Utilization %"] as? Int ?? deviceUtil
            let tilerUtil    = perf["Tiler Utilization %"] as? Int ?? 0

            // Memory (bytes)
            let usedMB  = (perf["In use system memory"] as? Int ?? 0) / 1_048_576
            let totalMB = totalVRAMMB(dict: dict)

            results.append(GPUStats(
                name: name,
                utilisation: Double(deviceUtil) / 100.0,
                rendererUtil: Double(rendererUtil) / 100.0,
                tilerUtil: Double(tilerUtil) / 100.0,
                memoryUsedMB: usedMB,
                memoryTotalMB: totalMB
            ))
        }

        return results
    }

    // MARK: - Helpers

    private func totalVRAMMB(dict: [String: Any]) -> Int {
        // "VRAM,totalMB" is present on discrete GPUs; on Apple Silicon unified memory
        // the "total memory" key is absent — we use ProcessInfo to report total RAM.
        if let mb = dict["VRAM,totalMB"] as? Int { return mb }
        if let bytes = dict["VRAM, total"] as? Int { return bytes / 1_048_576 }
        // Apple Silicon: whole-system unified memory — not exclusively GPU's
        return Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    }
}
