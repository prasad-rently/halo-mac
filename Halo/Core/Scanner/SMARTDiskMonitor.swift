import Foundation
import IOKit

// MARK: - SMARTDiskMonitor  (F-020 · S.M.A.R.T. Disk Health Monitor)
//
// Read-only S.M.A.R.T. health reader for internal & external drives. Two
// public, sandbox-safe read paths — no private entitlements, no elevation:
//
//  1. `diskutil info -plist <mount path>` (Process) — the ONLY reliable way
//     found to read NVMe SMART data on this Apple Silicon Mac. Passing a
//     *mounted volume path* (not a raw disk id) works because diskutil
//     itself resolves straight through APFS volume → container → physical
//     store and reports the physical drive's SMART log at the end of that
//     chain — confirmed by hand against `system_profiler SPNVMeDataType`.
//  2. IOKit `IONVMeController` registry lookup — diskutil's -plist output
//     does not include a serial number, so it's recovered separately by
//     matching the controller's "Model Number" against the model diskutil
//     already gave us.
//
// Verified on this machine (Apple Silicon, macOS 26.2, APPLE SSD AP0512Z):
//   diskutil DOES expose a real NVMe SMART/Health-Info log — SMARTStatus,
//   temperature (Kelvin), power-on hours, power cycles, data units read/
//   written (→ real TBW), available spare %, NVMe's own "percentage used"
//   wear indicator, media error count, unsafe shutdown count. All real,
//   all confirmed non-fabricated against a second, independent Apple tool.
//
// Confirmed NOT available (do not fake, ever — show "Not available"):
//   - `IORegistryEntryCreateCFProperties` on IOBlockStorageDriver exposes
//     only aggregate I/O statistics, no SMART data at all, on this machine.
//   - `IONVMeBlockDevice` / `IOAHCIBlockDevice` (the classes DiskHealthMonitor
//     (P3-07) already in this codebase matches against) don't resolve to any
//     service at all on Apple Silicon — that's why P3-07's SMART panel in
//     Cleanup always shows "N/A" here. diskutil reaches the SMART log through
//     a different, non-property-dictionary path (an ioctl), which is why this
//     monitor shells out to it instead of trying harder against raw IOKit.
//   - Serial number is never present in `diskutil info` output; only IOKit
//     has it, and only for drives that publish an IONVMeController (internal
//     Apple Silicon SSDs do; external SATA/USB-UASP bridges were NOT
//     available to test on this machine — treat as unverified for those).
//   - SATA-style "reallocated sector count" / "pending sector count" (ATA
//     SMART attribute IDs 5 and 197) do not exist in the NVMe Health
//     Information Log page at all — this is a real protocol difference, not
//     a missing read. NVMe's nearest equivalents are Available Spare /
//     Available Spare Threshold and Media Errors, both surfaced instead.
//
// Any field diskutil/IOKit didn't report comes back `nil` — callers must
// render that as "Not available on this drive", never a guessed or zeroed
// value.
//
// One gotcha re-verified independently while resuming this feature: querying
// `diskutil info -plist` by *mount path* (what both callers pass — "/" and a
// volume's `.url.path`) returns the SMART log fine, but "MediaName" comes
// back an EMPTY STRING at that level — it's only populated when diskutil is
// queried by the physical whole-disk BSD identifier (e.g. "disk0"). Confirmed
// by hand: `diskutil info -plist /` → MediaName "" vs `diskutil info -plist
// disk0` → MediaName "APPLE SSD AP0512Z", same physical drive. `scan(path:id:)`
// below falls back to a second diskutil query against the resolved whole-disk
// id (already computed for `bsdWholeDiskID`) whenever the first MediaName is
// empty, since the IOKit serial-number match below depends on having a model
// string to match against.
actor SMARTDiskMonitor {

    // MARK: - Public models

    enum SMARTOverallStatus: Equatable, Sendable {
        case verified
        case failing
        case other(String)   // whatever diskutil reported, verbatim, if not one of the above
        case unavailable     // no SMARTStatus key at all (e.g. some external bridges)
    }

    enum DriveHealthLevel: String, Sendable {
        case good
        case warning
        case failing
        case unknown
    }

    struct SMARTDiskInfo: Identifiable, Sendable {
        /// The mount path this scan was run against — stable per `DriveVolume.id`.
        let id: String
        /// Best-effort BSD whole-disk identifier (e.g. "disk0"), for display only.
        let bsdWholeDiskID: String
        let model: String?
        let serialNumber: String?
        let busProtocol: String?
        let isSolidState: Bool?
        let capacityBytes: Int64
        let overallStatus: SMARTOverallStatus

        let temperatureCelsius: Double?
        let powerOnHours: Int?
        let powerCycles: Int?
        let unsafeShutdowns: Int?
        /// Total bytes written over the drive's life (TBW), derived from the
        /// NVMe "Data Units Written" counter. nil if the SMART log wasn't readable.
        let totalBytesWritten: Int64?
        let totalBytesRead: Int64?
        let availableSparePercent: Int?
        let availableSpareThresholdPercent: Int?
        /// NVMe's own wear indicator, 0–100+ (100 = at rated endurance). This is
        /// the drive's own firmware assessment — no manufacturer TBW lookup
        /// table needed, and it's more accurate than one would be.
        let percentageUsed: Int?
        /// Closest NVMe analog to "uncorrectable errors" (there's no separate
        /// uncorrectable-error counter in the NVMe Health Info Log).
        let mediaErrorCount: Int?
        let errorLogEntryCount: Int?
        /// ATA-only concepts (SMART attributes 5 / 197). Always nil for NVMe
        /// drives — see file header. Kept as fields so a future SATA/AHCI read
        /// path can populate them without a model change.
        let reallocatedSectorCount: Int?
        let pendingSectorCount: Int?

        let scannedAt: Date

        var lifespanRemainingPercent: Int? {
            guard let used = percentageUsed else { return nil }
            return max(0, 100 - used)
        }

        var healthLevel: DriveHealthLevel {
            SMARTDiskInfo.classify(status: overallStatus,
                                    percentageUsed: percentageUsed,
                                    mediaErrorCount: mediaErrorCount,
                                    availableSpare: availableSparePercent,
                                    availableSpareThreshold: availableSpareThresholdPercent)
        }

        static func classify(status: SMARTOverallStatus,
                              percentageUsed: Int?,
                              mediaErrorCount: Int?,
                              availableSpare: Int?,
                              availableSpareThreshold: Int?) -> DriveHealthLevel {
            if status == .failing { return .failing }
            if let spare = availableSpare, let threshold = availableSpareThreshold, spare <= threshold {
                // Per the NVMe spec, spare capacity at/below the manufacturer's
                // threshold is itself a critical-warning condition.
                return .failing
            }
            if let used = percentageUsed, used >= 100 { return .failing }
            if let errors = mediaErrorCount, errors > 0 { return .warning }
            if let used = percentageUsed, used >= 90 { return .warning }
            if case .other = status { return .warning }
            if status == .verified { return .good }
            return .unknown
        }
    }

    // MARK: - Scan

    func scan(volume: DriveVolume) async -> SMARTDiskInfo {
        await scan(path: volume.url.path, id: volume.id)
    }

    func scan(path: String, id: String) async -> SMARTDiskInfo {
        let plist = diskutilInfoPlist(forPath: path)

        let busProtocol = Self.nonEmpty(plist?["BusProtocol"] as? String)
        let isSolidState = plist?["SolidState"] as? Bool
        let capacityBytes = (plist?["TotalSize"] as? NSNumber)?.int64Value
            ?? (plist?["Size"] as? NSNumber)?.int64Value ?? 0

        let status = overallStatus(from: plist?["SMARTStatus"] as? String)
        let smartDict = plist?["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any]

        let wholeDiskID = physicalWholeDiskID(fromPlist: plist)

        // Verified on this machine: `diskutil info -plist <mount path>` (e.g.
        // "/") returns an EMPTY "MediaName" — it only gets populated when
        // diskutil is queried by the physical whole-disk BSD identifier
        // (e.g. "disk0"). Both callers of this actor pass mount paths, so
        // without this fallback `model` (and therefore the IOKit serial
        // lookup below, which matches by model) would always come back nil.
        var model = Self.nonEmpty(plist?["MediaName"] as? String)
        if model == nil, wholeDiskID != "unknown" {
            let physicalPlist = diskutilInfoPlist(forPath: wholeDiskID)
            model = Self.nonEmpty(physicalPlist?["MediaName"] as? String)
        }

        let temperatureCelsius: Double? = smartDict
            .flatMap { ($0["TEMPERATURE"] as? NSNumber)?.doubleValue }
            .map { $0 - 273.15 } // NVMe reports Kelvin

        let powerOnHours = smartDict.flatMap { combine64($0, "POWER_ON_HOURS") }.map { Int(clamping: $0) }
        let powerCycles = smartDict.flatMap { combine64($0, "POWER_CYCLES") }.map { Int(clamping: $0) }
        let unsafeShutdowns = smartDict.flatMap { combine64($0, "UNSAFE_SHUTDOWNS") }.map { Int(clamping: $0) }
        let mediaErrors = smartDict.flatMap { combine64($0, "MEDIA_ERRORS") }.map { Int(clamping: $0) }
        let errorLogEntries = smartDict.flatMap { combine64($0, "NUM_ERROR_INFO_LOG_ENTRIES") }.map { Int(clamping: $0) }
        let availableSpare = smartDict.flatMap { ($0["AVAILABLE_SPARE"] as? NSNumber)?.intValue }
        let availableSpareThreshold = smartDict.flatMap { ($0["AVAILABLE_SPARE_THRESHOLD"] as? NSNumber)?.intValue }
        let percentageUsed = smartDict.flatMap { ($0["PERCENTAGE_USED"] as? NSNumber)?.intValue }

        // NVMe "Data Units" are counted in units of 1000 * 512 bytes.
        let bytesWritten = smartDict.flatMap { combine64($0, "DATA_UNITS_WRITTEN") }.map { Int64(clamping: $0) * 512_000 }
        let bytesRead = smartDict.flatMap { combine64($0, "DATA_UNITS_READ") }.map { Int64(clamping: $0) * 512_000 }

        let serial = model.flatMap { serialNumber(matchingModel: $0) }

        return SMARTDiskInfo(
            id: id,
            bsdWholeDiskID: wholeDiskID,
            model: model,
            serialNumber: serial,
            busProtocol: busProtocol,
            isSolidState: isSolidState,
            capacityBytes: capacityBytes,
            overallStatus: status,
            temperatureCelsius: temperatureCelsius,
            powerOnHours: powerOnHours,
            powerCycles: powerCycles,
            unsafeShutdowns: unsafeShutdowns,
            totalBytesWritten: bytesWritten,
            totalBytesRead: bytesRead,
            availableSparePercent: availableSpare,
            availableSpareThresholdPercent: availableSpareThreshold,
            percentageUsed: percentageUsed,
            mediaErrorCount: mediaErrors,
            errorLogEntryCount: errorLogEntries,
            reallocatedSectorCount: nil,   // ATA-only concept — see file header
            pendingSectorCount: nil,       // ATA-only concept — see file header
            scannedAt: Date()
        )
    }

    // MARK: - diskutil

    private func diskutilInfoPlist(forPath path: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    private func overallStatus(from raw: String?) -> SMARTOverallStatus {
        guard let raw else { return .unavailable }
        switch raw.lowercased() {
        case "verified": return .verified
        case "failing":  return .failing
        default:         return .other(raw)
        }
    }

    /// Best-effort mapping from whatever diskutil resolved back to the
    /// physical whole-disk BSD name, for display only (e.g. "disk0"). Falls
    /// back gracefully — this never affects which drive was actually read,
    /// only the label shown for it.
    private func physicalWholeDiskID(fromPlist plist: [String: Any]?) -> String {
        if let stores = plist?["APFSPhysicalStores"] as? [[String: Any]],
           let first = stores.first?["APFSPhysicalStore"] as? String {
            return stripPartitionSuffix(first)
        }
        if let parent = plist?["ParentWholeDisk"] as? String { return parent }
        if let device = plist?["DeviceIdentifier"] as? String { return stripPartitionSuffix(device) }
        return "unknown"
    }

    /// "disk0s2" -> "disk0"
    private func stripPartitionSuffix(_ bsdName: String) -> String {
        guard let range = bsdName.range(of: "s", options: .backwards) else { return bsdName }
        let suffix = bsdName[bsdName.index(after: range.lowerBound)...]
        return suffix.allSatisfy(\.isNumber) ? String(bsdName[..<range.lowerBound]) : bsdName
    }

    /// Combines a diskutil `<BASE>_0`/`<BASE>_1` 32-bit-half pair into one
    /// 64-bit counter (low, high). Returns nil if either half is missing.
    private func combine64(_ dict: [String: Any], _ base: String) -> UInt64? {
        guard let lowNum = dict["\(base)_0"] as? NSNumber,
              let highNum = dict["\(base)_1"] as? NSNumber else { return nil }
        let low = lowNum.uint64Value
        let high = highNum.uint64Value
        return low | (high << 32)
    }

    /// Empty-string → nil normalization used by the `MediaName` empty-string
    /// fallback path (see file header). `static` + non-`private` (rather than
    /// `private`) purely so `HaloTests` can exercise this deterministic logic
    /// directly via `@testable import Halo` without shelling out to `diskutil`
    /// — no behavior change, this is the same stateless check either way.
    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    // MARK: - IOKit serial number lookup

    /// diskutil never reports a serial number. Recovered separately by
    /// matching an `IONVMeController` service's "Model Number" against the
    /// model diskutil already gave us. Only covers drives that publish an
    /// IONVMeController (confirmed present for this Mac's internal SSD) —
    /// external SATA/USB-UASP drives were not available to verify against.
    private func serialNumber(matchingModel model: String) -> String? {
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IONVMeController") as CFDictionary
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        defer {
            if service != 0 { IOObjectRelease(service) }
        }
        while service != 0 {
            var propsRef: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = propsRef?.takeRetainedValue() as? [String: Any],
               let controllerModel = dict["Model Number"] as? String,
               controllerModel.trimmingCharacters(in: .whitespaces) == model.trimmingCharacters(in: .whitespaces) {
                let serial = (dict["Serial Number"] as? String)
                return serial
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return nil
    }
}

// MARK: - Rolling temperature history (F-020)
//
// Sampled once per periodic SMART check (every 5 minutes, from AppState),
// for the internal boot volume only — external drives aren't guaranteed to
// stay connected, so only the always-present internal SSD gets a rolling
// history. Persisted across launches so the 24h window survives app restarts.
@MainActor
final class SMARTTemperatureHistory: ObservableObject {
    static let shared = SMARTTemperatureHistory()

    struct Sample: Codable, Identifiable, Sendable {
        var id: Date { date }
        let date: Date
        let celsius: Double
    }

    @Published private(set) var samples: [Sample] = []

    private let maxSamples = 288   // 24h at a 5-minute cadence
    private let defaultsKey = "haloSMARTTemperatureHistory"

    private init() { load() }

    func record(celsius: Double, at date: Date = Date()) {
        samples.append(Sample(date: date, celsius: celsius))
        let cutoff = date.addingTimeInterval(-24 * 3600)
        samples.removeAll { $0.date < cutoff }
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Sample].self, from: data) else { return }
        samples = decoded
    }
}
