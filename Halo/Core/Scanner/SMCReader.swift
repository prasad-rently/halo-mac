import Foundation
import IOKit

// MARK: - SMCReader  (P3-02)
//
// Reads Apple Silicon / Intel SMC keys for CPU temperature, fan speed, etc.
// via IOKit. Foreground-active — timer is owned by the SensorsSection view.
//
// SMC key reference:
//   TC0P  CPU proximity temp (°C × 64 fixed-point, data type "sp78")
//   TG0P  GPU proximity temp
//   Ts0S  SSD / NVMe temp
//   TB0T  Battery temp
//   F0Ac  Fan 0 actual RPM (rpm, data type "fpe2")

actor SMCReader {

    // MARK: - Public model

    enum SensorUnit: Sendable { case celsius, rpm }

    struct SensorReading: Identifiable, Sendable {
        let id: String      // SMC key
        let label: String
        let value: Double
        let unit: SensorUnit
    }

    // MARK: - Desired sensors

    private static let sensors: [(key: String, label: String, unit: SensorUnit)] = [
        ("TC0P", "CPU Temperature",     .celsius),
        ("TG0P", "GPU Temperature",     .celsius),
        ("Ts0S", "SSD Temperature",     .celsius),
        ("TB0T", "Battery Temperature", .celsius),
        ("F0Ac", "Fan Speed",           .rpm),
    ]

    // MARK: - IOKit connection handle

    private var conn: io_connect_t = 0

    init() {
        openConnection()
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    // MARK: - Public

    /// Reads all known sensor keys. Returns only sensors that responded.
    func readAll() -> [SensorReading] {
        guard conn != 0 else { return [] }
        return SMCReader.sensors.compactMap { sensor in
            guard let value = readKey(sensor.key) else { return nil }
            return SensorReading(id: sensor.key,
                                 label: sensor.label,
                                 value: value,
                                 unit: sensor.unit)
        }
    }

    // MARK: - Connection

    private func openConnection() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        IOServiceOpen(service, mach_task_self_, 0, &conn)
    }

    // MARK: - Read a single SMC key

    private func readKey(_ key: String) -> Double? {
        // SMC userland calls use a struct passed through IOConnectCallStructMethod.
        // Layout matches the well-known SMCParam struct used by smckit / LibreHardwareMonitor.
        var input  = SMCParam()
        var output = SMCParam()
        var inputSize  = MemoryLayout<SMCParam>.size
        var outputSize = MemoryLayout<SMCParam>.size

        input.key = fourCC(key)
        input.dataSize = 4
        input.cmd = 5   // kSMCGetKeyInfo = 9, kSMCReadKey = 5

        let ret = IOConnectCallStructMethod(conn, 2,
                                            &input,  inputSize,
                                            &output, &outputSize)
        guard ret == KERN_SUCCESS else { return nil }

        // Decode based on data type — convert tuple to array first
        let typeBytes: [UInt8] = [output.dataType.0, output.dataType.1,
                                   output.dataType.2, output.dataType.3, output.dataType.4]
        let type = String(bytes: typeBytes, encoding: .macOSRoman) ?? ""
        let bytes = output.bytes

        switch type.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: "\0"))) {
        case "sp78":
            // Fixed-point Q8.8: high byte is integer, low byte is fractional
            let raw = (Int16(bytes.0) << 8) | Int16(bytes.1)
            return Double(raw) / 256.0
        case "fpe2":
            // Fixed-point unsigned Q14.2
            let raw = (UInt16(bytes.0) << 8) | UInt16(bytes.1)
            return Double(raw) / 4.0
        case "ui16":
            let raw = (UInt16(bytes.0) << 8) | UInt16(bytes.1)
            return Double(raw)
        case "ui8":
            return Double(bytes.0)
        default:
            // Try sp78 as fallback for unknown temp types
            let raw = (Int16(bytes.0) << 8) | Int16(bytes.1)
            let v = Double(raw) / 256.0
            return (v > 0 && v < 150) ? v : nil
        }
    }

    // MARK: - Helpers

    private func fourCC(_ s: String) -> UInt32 {
        let chars = Array(s.utf8)
        guard chars.count == 4 else { return 0 }
        return (UInt32(chars[0]) << 24) |
               (UInt32(chars[1]) << 16) |
               (UInt32(chars[2]) <<  8) |
                UInt32(chars[3])
    }
}

// MARK: - SMCParam layout (matches kernel struct SMCParam, 80 bytes)

private struct SMCParam {
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0)
    var pLimitData: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var dataType: (UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0)
    var dataSize: UInt32 = 0
    var cmd: UInt8 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0)
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}
