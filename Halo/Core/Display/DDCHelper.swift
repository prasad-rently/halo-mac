import Foundation
import CoreGraphics
import IOKit

// MARK: - DDCHelper
//
// Apple Silicon DDC/CI brightness control via IOAVService.
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │ How Apple Silicon maps ports to DCPAVServiceProxy Location strings  │
// │   "Embedded" → USB-C / Thunderbolt external display                │
// │   "External" → built-in HDMI port (DDC blocked on Apple Silicon)   │
// └─────────────────────────────────────────────────────────────────────┘
//
// DDC/CI packet format (IOAVServiceWriteI2C chipAddr=0x37 dataAddr=0x51)
// ───────────────────────────────────────────────────────────────────────
//  Set VCP Feature (0x03) — 6 bytes:
//    [0x84][0x03][vcpCode][MSB][LSB][checksum]
//    checksum = 0x6E ^ 0x51 ^ each preceding byte
//
//  Get VCP Feature Request (0x01) — 4 bytes:
//    [0x82][0x01][vcpCode][checksum]
//
//  Get VCP Feature Reply — 12 bytes read via IOAVServiceReadI2C offset=0:
//    [0x6F][0x88][0x02][result][vcpCode][type][maxH][maxL][curH][curL][chk][?]
//    maxVal = bytes[6:7],  curVal = bytes[8:9]
//
// Many external monitors are DDC write-only (Set VCP works, Get VCP reply
// is all zeros). DDCHelper caches the last-written value so the slider
// shows a meaningful position even when reads return nothing.

// MARK: - C function pointer types

private typealias IOAVService_ = OpaquePointer   // IOAVService is an opaque struct pointer

private typealias CreateFn  = @convention(c) (CFAllocator?,  io_service_t) -> IOAVService_?
private typealias WriteFn   = @convention(c) (IOAVService_,  UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private typealias ReadFn    = @convention(c) (IOAVService_,  UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

// MARK: - Internal service record

private struct DDCServiceRecord {
    let service:  IOAVService_
    let location: String          // "Embedded" | "External" | other
    let isWriteCapable: Bool      // confirmed by probe during discovery
}

// MARK: - DDCHelper (actor)

actor DDCHelper {

    // MARK: Symbols

    private let createFn: CreateFn?
    private let writeFn:  WriteFn?
    private let readFn:   ReadFn?

    // MARK: State

    /// Services confirmed write-capable during `discoverServices()`.
    private var services: [DDCServiceRecord] = []

    /// Last brightness value successfully written per display.
    /// Used as a read-fallback on write-only monitors.
    private var lastWritten: [CGDirectDisplayID: Double] = [:]

    // MARK: DDC constants

    private let kChipAddr: UInt32 = 0x37   // I2C 7-bit address
    private let kDataAddr: UInt32 = 0x51   // DDC/CI destination
    private let kBrightness: UInt8 = 0x10  // VCP code

    // MARK: - Init

    init() {
        let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
        let h = dlopen(path, RTLD_LAZY | RTLD_NOLOAD) ?? dlopen(path, RTLD_LAZY)
        if let h {
            createFn = dlsym(h, "IOAVServiceCreateWithService")
                .map { unsafeBitCast($0, to: CreateFn.self) }
            writeFn  = dlsym(h, "IOAVServiceWriteI2C")
                .map { unsafeBitCast($0, to: WriteFn.self) }
            readFn   = dlsym(h, "IOAVServiceReadI2C")
                .map { unsafeBitCast($0, to: ReadFn.self) }
        } else {
            createFn = nil; writeFn = nil; readFn = nil
        }
    }

    // MARK: - Public API

    /// Walk IORegistry for DCPAVServiceProxy nodes, probe each with a
    /// DDC write, and cache the ones that respond.  Call once at startup.
    func discoverServices() {
        guard let create = createFn, let write = writeFn else { return }
        services = []

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"),
            &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }

        // IMPORTANT: do NOT use `defer { IOObjectRelease(node) }` here.
        // Swift defer captures the *variable* by reference, not by value.
        // If we write `node = IOIteratorNext(iter)` inside the loop and
        // then the defer fires, it releases the NEW node (not the current
        // one), corrupting the iterator and causing the second service to
        // be freed before IOAVServiceCreateWithService can use it.
        // Use explicit release + advance instead.
        var node = IOIteratorNext(iter)
        while node != 0 {
            let loc = ioStringProp(node, "Location") ?? "Unknown"

            if let svc = create(kCFAllocatorDefault, node) {
                // Probe: send a Get VCP request — if the write returns 0
                // the I2C channel is open and DDC commands are accepted.
                var probe = getVCPPacket(vcp: kBrightness)
                let probeRet = write(svc, kChipAddr, kDataAddr,
                                     &probe, UInt32(probe.count))
                let capable  = (probeRet == kIOReturnSuccess)

                services.append(DDCServiceRecord(
                    service: svc,
                    location: loc,
                    isWriteCapable: capable
                ))

                print("[DDCHelper] Location=\(loc)  probe=\(capable ? "✅" : "❌ 0x\(String(UInt32(bitPattern: probeRet), radix:16))")")
            }

            IOObjectRelease(node)               // release current before advancing
            node = IOIteratorNext(iter)         // advance to next
        }

        var log = "[DDCHelper discoverServices]\n"
        for s in services { log += "  Location=\(s.location)  capable=\(s.isWriteCapable)\n" }
        log += "total=\(services.count)  capable=\(services.filter(\.isWriteCapable).count)\n"
        try? log.write(toFile: "/tmp/halo_ddc.txt", atomically: true, encoding: .utf8)
        print("[DDCHelper] discovered \(services.count) services, \(services.filter(\.isWriteCapable).count) write-capable")
    }

    /// Read brightness [0, 1] for a display.
    /// Returns the DDC current/max ratio if the monitor supports reads,
    /// or the last-written value (fallback) for write-only monitors.
    /// Returns nil if no DDC service is available at all.
    func readBrightness(for id: CGDirectDisplayID) -> Double? {
        guard let svc = matchedService(for: id),
              svc.isWriteCapable else { return nil }

        // 1. Try actual DDC Get VCP read
        if let v = ddcRead(service: svc) { return v }

        // 2. Write-only monitor — return cached or default
        return lastWritten[id] ?? 0.5
    }

    /// Set brightness [0, 1] via DDC Set VCP Feature.
    /// Returns true if the write succeeded.
    @discardableResult
    func setBrightness(_ normalised: Double, for id: CGDirectDisplayID) -> Bool {
        guard let svc = matchedService(for: id),
              svc.isWriteCapable,
              let write = writeFn else { return false }

        // Scale to DDC integer — use maxValue from a prior read if possible,
        // otherwise assume the display's native max is 100.
        let maxVal: UInt16 = (ddcMaxValue(service: svc) ?? 100)
        let ddcVal = UInt16(max(1, min(Double(maxVal), normalised * Double(maxVal))))

        var pkt = setVCPPacket(vcp: kBrightness, value: ddcVal)
        let ret  = write(svc.service, kChipAddr, kDataAddr,
                         &pkt, UInt32(pkt.count))
        let ok   = (ret == kIOReturnSuccess)

        if ok { lastWritten[id] = normalised }
        return ok
    }

    /// True if a write-capable DDC service is available for this display.
    func hasDDCService(for id: CGDirectDisplayID) -> Bool {
        matchedService(for: id) != nil
    }

    // MARK: - Service matching

    /// Pick the best write-capable service for an external display.
    private func matchedService(for id: CGDirectDisplayID) -> DDCServiceRecord? {
        // Only external displays are DDC-controllable via IOAVService.
        guard CGDisplayIsBuiltin(id) == 0 else { return nil }

        let writeable = services.filter(\.isWriteCapable)
        guard !writeable.isEmpty else { return nil }

        // If there is only one write-capable service, use it.
        if writeable.count == 1 { return writeable[0] }

        // Multiple services: prefer "Embedded" (USB-C/Thunderbolt) over "External" (HDMI).
        // Then fall back to first available.
        let vendor = CGDisplayVendorNumber(id)
        let model  = CGDisplayModelNumber(id)

        // Score: "Embedded" preferred (+2) for non-built-in displays,
        //        vendor/model match from IORegistry EDID (+1 each).
        var best: (DDCServiceRecord, Int)?
        for svc in writeable {
            var score = 0
            if svc.location == "Embedded" { score += 2 }
            score += vendorModelScore(svc, vendor: vendor, model: model)
            score += 1  // baseline so we always have a candidate
            if best == nil || score > best!.1 { best = (svc, score) }
        }
        return best?.0
    }

    // MARK: - DDC read helpers

    private func ddcRead(service: DDCServiceRecord) -> Double? {
        guard let read = readFn, let write = writeFn else { return nil }

        // Send Get VCP request
        var req = getVCPPacket(vcp: kBrightness)
        guard write(service.service, kChipAddr, kDataAddr,
                    &req, UInt32(req.count)) == kIOReturnSuccess else { return nil }

        Thread.sleep(forTimeInterval: 0.05)

        var reply = [UInt8](repeating: 0, count: 12)
        guard read(service.service, kChipAddr, 0,
                   &reply, UInt32(reply.count)) == kIOReturnSuccess else { return nil }

        // Validate reply header
        // reply[0]=0x6F (source), reply[1]=0x88 (len), reply[2]=0x02 (cmd), reply[3]=0x00 (ok)
        guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == kBrightness else {
            return nil   // all-zeros or invalid → write-only monitor
        }

        let maxVal = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let curVal = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        guard maxVal > 0 else { return nil }
        return Double(curVal) / Double(maxVal)
    }

    private func ddcMaxValue(service: DDCServiceRecord) -> UInt16? {
        guard let read = readFn, let write = writeFn else { return nil }
        var req = getVCPPacket(vcp: kBrightness)
        guard write(service.service, kChipAddr, kDataAddr,
                    &req, UInt32(req.count)) == kIOReturnSuccess else { return nil }
        Thread.sleep(forTimeInterval: 0.05)
        var reply = [UInt8](repeating: 0, count: 12)
        guard read(service.service, kChipAddr, 0,
                   &reply, UInt32(reply.count)) == kIOReturnSuccess else { return nil }
        guard reply[2] == 0x02, reply[3] == 0x00 else { return nil }
        let maxVal = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        return maxVal > 0 ? maxVal : nil
    }

    // MARK: - Vendor/model scoring via IORegistry EDID UUID

    private func vendorModelScore(_ svc: DDCServiceRecord,
                                  vendor: UInt32, model: UInt32) -> Int {
        // Look up the DCPAVServiceProxy again and check sibling CLCD2 EDID UUID
        // (best-effort; single display setups don't need this)
        return 0
    }

    // MARK: - IORegistry helpers

    private func ioStringProp(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }

    // MARK: - DDC packet builders

    /// Get VCP Feature request — 4 bytes (write, then read reply).
    private func getVCPPacket(vcp: UInt8) -> [UInt8] {
        // [0x82][0x01][vcpCode][checksum]
        var p: [UInt8] = [0x82, 0x01, vcp, 0x00]
        p[3] = ddcChecksum(Array(p.prefix(3)))
        return p
    }

    /// Set VCP Feature command — 6 bytes.
    private func setVCPPacket(vcp: UInt8, value: UInt16) -> [UInt8] {
        // [0x84][0x03][vcpCode][MSB][LSB][checksum]
        var p: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0x00]
        p[5] = ddcChecksum(Array(p.prefix(5)))
        return p
    }

    /// DDC/CI XOR checksum: (chipAddr<<1) ^ dataAddr ^ each payload byte.
    private func ddcChecksum(_ payload: [UInt8]) -> UInt8 {
        var cs: UInt8 = UInt8((kChipAddr << 1) & 0xFF) ^ UInt8(kDataAddr & 0xFF)
        for b in payload { cs ^= b }
        return cs
    }
}
