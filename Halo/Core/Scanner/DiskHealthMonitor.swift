import Foundation
import IOKit

// MARK: - DiskHealthMonitor  (P3-07)
//
// On-demand (SMART check) + foreground (volume usage, lifetime read/write).
// SMART status via IOKit NVMe/AHCI service — returns .unavailable on T2/M-series
// where the SSD controller is behind the Secure Enclave and SMART is not exposed.

actor DiskHealthMonitor {

    // MARK: - Public models

    enum SMARTStatus: Sendable {
        case verified
        case warning(String)
        case failed(String)
        case unavailable
    }

    struct DiskInfo: Identifiable, Sendable {
        let id: UUID
        let bsdName: String          // e.g. "disk0"
        let model: String
        let totalGB: Double
        let lifetimeReadGB: Double
        let lifetimeWrittenGB: Double
        let smartStatus: SMARTStatus
        let powerOnHours: Int?
    }

    struct VolumeInfo: Identifiable, Sendable {
        let id: UUID
        let name: String             // e.g. "Macintosh HD"
        let mountPoint: String
        let totalGB: Double
        let freeGB: Double
        var usedGB: Double { totalGB - freeGB }
        var usageRatio: Double { totalGB > 0 ? usedGB / totalGB : 0 }
        var freeLabel: String { String(format: "%.1f GB free", freeGB) }
    }

    // MARK: - Volume usage (foreground, cheap)

    func volumeUsage() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey]
        guard let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) else { return [] }

        return vols.compactMap { url -> VolumeInfo? in
            guard let res = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let name = res.volumeName ?? url.lastPathComponent
            let total = Double(res.volumeTotalCapacity ?? 0) / 1e9
            let free  = Double(res.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
            guard total > 0.5 else { return nil }   // skip tiny synthetic volumes
            return VolumeInfo(id: UUID(), name: name, mountPoint: url.path,
                              totalGB: total, freeGB: free)
        }
    }

    // MARK: - SMART + lifetime (on-demand)

    func scanAllDisks() async -> [DiskInfo] {
        var results: [DiskInfo] = []

        var iter: io_iterator_t = 0
        // Try NVMe first (Apple Silicon / modern Macs)
        var matching = IOServiceMatching("IONVMeBlockDevice") as CFDictionary
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != KERN_SUCCESS {
            // Fallback: AHCI for older Intel Macs
            matching = IOServiceMatching("IOAHCIBlockDevice") as CFDictionary
            IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        }
        defer { if iter != 0 { IOObjectRelease(iter) } }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }

            if let info = diskInfo(from: service) {
                results.append(info)
            }
        }

        // If IOKit found nothing useful, return a basic entry from FileManager
        if results.isEmpty {
            let vols = volumeUsage()
            if let main = vols.first {
                results.append(DiskInfo(
                    id: UUID(), bsdName: "disk0", model: "Apple SSD",
                    totalGB: main.totalGB, lifetimeReadGB: 0, lifetimeWrittenGB: 0,
                    smartStatus: .unavailable, powerOnHours: nil
                ))
            }
        }

        return results
    }

    // MARK: - IOKit disk info extraction

    private func diskInfo(from service: io_object_t) -> DiskInfo? {
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef,
                                                kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = propsRef?.takeRetainedValue() as? [String: Any] else { return nil }

        // BSD name
        let bsdNameRef = IORegistryEntryCreateCFProperty(service,
                                                          "BSD Name" as CFString,
                                                          kCFAllocatorDefault, 0)
        let bsdName = bsdNameRef?.takeRetainedValue() as? String ?? "disk?"

        let model = dict["Product Name"] as? String ?? dict["Model Number"] as? String ?? "Unknown"

        // Capacity
        let totalBytes = dict["Size"] as? Int64 ?? 0
        let totalGB = Double(totalBytes) / 1e9

        // Lifetime read / write (NVMe SMART attributes)
        let bytesRead    = dict["SMART Lifetime Read MB"] as? Int64 ?? 0
        let bytesWritten = dict["SMART Lifetime Written MB"] as? Int64 ?? 0

        // SMART status
        let status: SMARTStatus
        if let s = dict["SMART Status"] as? String {
            switch s.lowercased() {
            case "verified": status = .verified
            case "failing":  status = .failed("Drive is failing")
            default:         status = .warning(s)
            }
        } else {
            status = .unavailable
        }

        let powerOn = dict["Power On Hours"] as? Int

        return DiskInfo(
            id: UUID(),
            bsdName: bsdName,
            model: model,
            totalGB: totalGB > 0 ? totalGB : 0,
            lifetimeReadGB: Double(bytesRead) / 1024,
            lifetimeWrittenGB: Double(bytesWritten) / 1024,
            smartStatus: status,
            powerOnHours: powerOn
        )
    }
}
