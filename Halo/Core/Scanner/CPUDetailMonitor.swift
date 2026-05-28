import Foundation

// MARK: - CPUDetailMonitor  (P3-01)
//
// Foreground-active: created as @StateObject in the Performance view,
// destroyed automatically when the view disappears.
// Uses host_processor_info() — one Mach syscall per sample, ~0.01% CPU.

actor CPUDetailMonitor {

    // MARK: - Public model

    struct CoreSample: Identifiable, Sendable {
        let id: Int           // core index
        var usage: Double     // 0.0 – 1.0
        let isEfficiency: Bool
    }

    // MARK: - Private state

    private var previousTicks: [Int32]?
    private let pCoreCount: Int   // Performance core count
    private let eCoreCount: Int   // Efficiency core count

    init() {
        // Read P-core and E-core counts once at init — never changes at runtime.
        var p: Int = 0
        var e: Int = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &p, &size, nil, 0)
        sysctlbyname("hw.perflevel1.physicalcpu", &e, &size, nil, 0)
        pCoreCount = max(p, 0)
        eCoreCount = max(e, 0)
    }

    // MARK: - Sample

    /// Returns per-core usage since the last call (diff-based, same as `top`).
    /// First call returns zeros because there's no previous snapshot.
    func sample() -> [CoreSample] {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let err = host_processor_info(mach_host_self(),
                                      PROCESSOR_CPU_LOAD_INFO,
                                      &numCPUs,
                                      &cpuInfo,
                                      &numCPUInfo)
        guard err == KERN_SUCCESS, let info = cpuInfo else {
            return []
        }

        let count = Int(numCPUs) * Int(CPU_STATE_MAX)
        let ticks = Array(UnsafeBufferPointer(start: info, count: count))
        vm_deallocate(mach_task_self_,
                      vm_address_t(bitPattern: info),
                      vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))

        defer { previousTicks = ticks }

        guard let prev = previousTicks else { return [] }

        let totalCores = Int(numCPUs)

        return (0..<totalCores).map { i in
            let base = i * Int(CPU_STATE_MAX)
            let user   = Int(ticks[base + Int(CPU_STATE_USER)])   - Int(prev[base + Int(CPU_STATE_USER)])
            let sys    = Int(ticks[base + Int(CPU_STATE_SYSTEM)]) - Int(prev[base + Int(CPU_STATE_SYSTEM)])
            let idle   = Int(ticks[base + Int(CPU_STATE_IDLE)])   - Int(prev[base + Int(CPU_STATE_IDLE)])
            let nice   = Int(ticks[base + Int(CPU_STATE_NICE)])   - Int(prev[base + Int(CPU_STATE_NICE)])
            let total  = user + sys + idle + nice
            let usage  = total > 0 ? Double(user + sys) / Double(total) : 0

            // Cores 0..<pCoreCount are P-cores on Apple Silicon;
            // the rest are E-cores. On Intel all cores are equal.
            let isP = pCoreCount > 0 ? i < pCoreCount : true

            return CoreSample(id: i, usage: max(0, min(1, usage)), isEfficiency: !isP)
        }
    }
}
