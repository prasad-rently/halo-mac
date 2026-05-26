import Foundation
import IOKit.ps
import SystemConfiguration

// MARK: - System Monitor
// Uses macOS system APIs: host_statistics64, IOKit power sources,
// FileManager for disk, SCNetworkInterface for network

final class SystemMonitor {

    // MARK: - CPU Usage

    // Stored as a value-type copy so the vm_deallocate in cpuUsage() doesn't leave a dangling pointer.
    private var previousCPUTicks: [Int32]?

    func cpuUsage() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let err = host_processor_info(mach_host_self(),
                                      PROCESSOR_CPU_LOAD_INFO,
                                      &numCPUs,
                                      &cpuInfo,
                                      &numCPUInfo)
        guard err == KERN_SUCCESS, let info = cpuInfo else { return 0 }

        let count = Int(numCPUs) * Int(CPU_STATE_MAX)
        // Copy tick data into a Swift array before deallocating the kernel buffer.
        let ticks = Array(UnsafeBufferPointer(start: info, count: count))

        vm_deallocate(mach_task_self_,
                      vm_address_t(bitPattern: info),
                      vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size))

        guard let prev = previousCPUTicks else {
            previousCPUTicks = ticks
            return 0
        }

        var totalUser: Int = 0
        var totalSystem: Int = 0
        var totalIdle: Int = 0
        var totalNice: Int = 0

        for i in 0..<Int(numCPUs) {
            let base = i * Int(CPU_STATE_MAX)
            totalUser   += Int(ticks[base + Int(CPU_STATE_USER)])   - Int(prev[base + Int(CPU_STATE_USER)])
            totalSystem += Int(ticks[base + Int(CPU_STATE_SYSTEM)]) - Int(prev[base + Int(CPU_STATE_SYSTEM)])
            totalIdle   += Int(ticks[base + Int(CPU_STATE_IDLE)])   - Int(prev[base + Int(CPU_STATE_IDLE)])
            totalNice   += Int(ticks[base + Int(CPU_STATE_NICE)])   - Int(prev[base + Int(CPU_STATE_NICE)])
        }

        previousCPUTicks = ticks

        let total = totalUser + totalSystem + totalIdle + totalNice
        guard total > 0 else { return 0 }
        return max(0, min(1, Double(totalUser + totalSystem) / Double(total)))
    }

    // MARK: - RAM Stats

    struct RAMStats {
        let usedGB: Double
        let totalGB: Double
        let wiredGB: Double
        let activeGB: Double
        let inactiveGB: Double
        let compressedGB: Double
        var pressure: Double { totalGB > 0 ? usedGB / totalGB : 0 }
    }

    func ramStats() -> RAMStats {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let pageSize = Double(vm_kernel_page_size)

        let _ = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(),
                                  HOST_VM_INFO64,
                                  reboundPtr,
                                  &count)
            }
        }

        let GB = 1024.0 * 1024.0 * 1024.0
        let wiredGB = Double(vmStats.wire_count) * pageSize / GB
        let activeGB = Double(vmStats.active_count) * pageSize / GB
        let compressedGB = Double(vmStats.compressor_page_count) * pageSize / GB
        let inactiveGB = Double(vmStats.inactive_count) * pageSize / GB
        let usedGB = wiredGB + activeGB + compressedGB
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / GB

        return RAMStats(usedGB: usedGB, totalGB: totalGB,
                        wiredGB: wiredGB, activeGB: activeGB,
                        inactiveGB: inactiveGB, compressedGB: compressedGB)
    }

    // MARK: - Disk Stats

    struct DiskStats {
        let freeGB: Double
        let totalGB: Double
        var usedGB: Double { totalGB - freeGB }
        var usageRatio: Double { totalGB > 0 ? usedGB / totalGB : 0 }
    }

    func diskStats() -> DiskStats {
        let GB = 1024.0 * 1024.0 * 1024.0
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let total = (attrs[.systemSize] as? Double ?? 0) / GB
            let free = (attrs[.systemFreeSize] as? Double ?? 0) / GB
            return DiskStats(freeGB: free, totalGB: total)
        } catch {
            return DiskStats(freeGB: 0, totalGB: 0)
        }
    }

    // MARK: - Battery Stats  (extended in P3-04)

    struct BatteryStats {
        let percent: Int
        let isCharging: Bool
        let timeRemainingMinutes: Int
        let healthPercent: Double
        let cycleCount: Int
        // P3-04 additions
        let designCapacityMAh: Int    // manufacturer spec
        let maxCapacityMAh: Int       // current max (degraded over time)
        let currentCapacityMAh: Int   // instantaneous level
        let amperageMa: Int           // negative = discharging, positive = charging
        let voltageMv: Int            // millivolts
        let temperatureCelsius: Double // SMC TB0T key; 0 if unavailable
        let timeToFullMinutes: Int    // 0 if not charging
        let isOnACPower: Bool
        let isLowPowerMode: Bool

        var timeRemainingString: String {
            guard timeRemainingMinutes > 0 else { return "" }
            let hours = timeRemainingMinutes / 60
            let minutes = timeRemainingMinutes % 60
            if hours > 0 { return "\(hours)h \(minutes)m" }
            return "\(minutes)m"
        }

        var timeToFullString: String {
            guard timeToFullMinutes > 0 else { return "" }
            let h = timeToFullMinutes / 60; let m = timeToFullMinutes % 60
            return h > 0 ? "\(h)h \(m)m" : "\(m)m"
        }

        var healthLabel: String {
            if healthPercent >= 0.80 { return "Good" }
            if healthPercent >= 0.60 { return "Fair" }
            return "Replace Soon"
        }
    }

    func batteryStats() -> BatteryStats {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            let desc = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as! [String: Any]
            let capacity = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let timeToEmpty = desc[kIOPSTimeToEmptyKey] as? Int ?? 0
            let timeToFull  = desc[kIOPSTimeToFullChargeKey] as? Int ?? 0
            let powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? ""
            let isOnAC = powerSource == kIOPSACPowerValue
            let percent = maxCapacity > 0 ? (capacity * 100 / maxCapacity) : 0

            // Extended data from AppleSmartBattery
            var cycleCount = 0
            var designCap = 0, maxCap = 0, curCap = 0
            var amperage = 0, voltage = 0, tempRaw = 0

            let service = IOServiceGetMatchingService(kIOMainPortDefault,
                IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                var propsRef: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = propsRef?.takeRetainedValue() as NSDictionary? {
                    cycleCount  = dict["CycleCount"] as? Int ?? 0
                    designCap   = dict["DesignCapacity"] as? Int ?? 0
                    maxCap      = dict["MaxCapacity"] as? Int ?? 0
                    curCap      = dict["CurrentCapacity"] as? Int ?? 0
                    amperage    = dict["Amperage"] as? Int ?? 0
                    voltage     = dict["Voltage"] as? Int ?? 0
                    tempRaw     = dict["Temperature"] as? Int ?? 0
                }
                IOObjectRelease(service)
            }

            let health = designCap > 0 ? Double(maxCap) / Double(designCap) : 0.91
            let tempC  = tempRaw > 0 ? Double(tempRaw) / 100.0 : 0

            let isLP: Bool
            if #available(macOS 12.0, *) {
                isLP = ProcessInfo.processInfo.isLowPowerModeEnabled
            } else {
                isLP = false
            }

            return BatteryStats(
                percent: percent, isCharging: isCharging,
                timeRemainingMinutes: timeToEmpty, healthPercent: health, cycleCount: cycleCount,
                designCapacityMAh: designCap, maxCapacityMAh: maxCap, currentCapacityMAh: curCap,
                amperageMa: amperage, voltageMv: voltage, temperatureCelsius: tempC,
                timeToFullMinutes: timeToFull, isOnACPower: isOnAC, isLowPowerMode: isLP
            )
        }
        return BatteryStats(percent: 100, isCharging: true,
                            timeRemainingMinutes: 0, healthPercent: 1.0, cycleCount: 0,
                            designCapacityMAh: 0, maxCapacityMAh: 0, currentCapacityMAh: 0,
                            amperageMa: 0, voltageMv: 0, temperatureCelsius: 0,
                            timeToFullMinutes: 0, isOnACPower: true, isLowPowerMode: false)
    }

    // MARK: - Network Stats

    struct NetworkStats {
        let upMBps: Double
        let downMBps: Double
    }

    private var previousNetBytes: (up: UInt64, down: UInt64)?
    private var previousNetTime: Date?

    func networkStats() -> NetworkStats {
        // Use getifaddrs to read network interface bytes
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return NetworkStats(upMBps: 0, downMBps: 0)
        }
        defer { freeifaddrs(ifaddr) }

        var totalUp: UInt64 = 0
        var totalDown: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            if (name.hasPrefix("en") || name.hasPrefix("pdp_ip")),
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let data = current.pointee.ifa_data {
                let ifdata = data.assumingMemoryBound(to: if_data.self)
                totalUp   += UInt64(ifdata.pointee.ifi_obytes)
                totalDown += UInt64(ifdata.pointee.ifi_ibytes)
            }
            ptr = current.pointee.ifa_next
        }

        let now = Date()
        let mbps: (UInt64, UInt64) -> (Double, Double) = { up, down in
            guard let prevUp = self.previousNetBytes?.up,
                  let prevDown = self.previousNetBytes?.down,
                  let prevTime = self.previousNetTime,
                  up >= prevUp, down >= prevDown else { return (0, 0) }
            let elapsed = now.timeIntervalSince(prevTime)
            guard elapsed > 0 else { return (0, 0) }
            let upMBps   = Double(up   - prevUp)   / elapsed / 1_048_576
            let downMBps = Double(down - prevDown) / elapsed / 1_048_576
            return (upMBps, downMBps)
        }
        let (upMBps, downMBps) = mbps(totalUp, totalDown)
        previousNetBytes = (totalUp, totalDown)
        previousNetTime  = now
        return NetworkStats(upMBps: upMBps, downMBps: downMBps)
    }
}
