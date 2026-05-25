import Foundation
import CoreGraphics
import IOKit
import AppKit

// MARK: - DisplayBrightnessManager
//
// Actor that owns all display I/O:
//   • Built-in display  → CoreDisplay private framework, loaded at runtime via dlopen/dlsym
//                         (no compile-time private-framework linking required)
//   • External displays → IODisplayGet/SetFloatParameter via IOKit (public API)
//
// Usage:
//   let manager = DisplayBrightnessManager()
//   let displays = await manager.allDisplays()
//   await manager.setBrightness(0.7, for: display.id)

actor DisplayBrightnessManager {

    // MARK: - CoreDisplay function types (private framework, loaded at runtime)

    private typealias GetFn = @convention(c) (UInt32) -> Double
    private typealias SetFn = @convention(c) (UInt32, Double) -> Void

    private let fnGet: GetFn?
    private let fnSet: SetFn?

    init() {
        let path = "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay"
        let handle = dlopen(path, RTLD_LAZY)
        if let handle {
            let getRaw = dlsym(handle, "CoreDisplay_Display_GetUserBrightness")
            let setRaw = dlsym(handle, "CoreDisplay_Display_SetUserBrightness")
            fnGet = getRaw.map { unsafeBitCast($0, to: GetFn.self) }
            fnSet = setRaw.map { unsafeBitCast($0, to: SetFn.self) }
        } else {
            fnGet = nil
            fnSet = nil
        }
    }

    // MARK: - Display Enumeration

    // allDisplays has been moved to a @MainActor free function (DisplayBrightnessManager+Enumerate.swift)
    // to avoid CG API thread-safety issues inside the actor's background executor.

    // MARK: - Brightness Read

    func readBrightness(_ displayID: CGDirectDisplayID) -> Double {
        if CGDisplayIsBuiltin(displayID) != 0 {
            return fnGet?(displayID) ?? fallbackGetBrightness(displayID)
        }
        return externalGetBrightness(displayID)
    }

    // MARK: - Brightness Write

    /// Clamps to [0.02, 1.0] to prevent accidental blackout.
    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        let v = max(0.02, min(1.0, value))
        if CGDisplayIsBuiltin(displayID) != 0 {
            if let fn = fnSet {
                fn(displayID, v)
            } else {
                fallbackSetBrightness(v, displayID: displayID)
            }
        } else {
            externalSetBrightness(v, displayID: displayID)
        }
    }

    // MARK: - IOKit Fallback (built-in, when CoreDisplay unavailable)

    private func fallbackGetBrightness(_ displayID: CGDirectDisplayID) -> Double {
        let service = ioServiceForDisplay(displayID)
        guard service != 0 else { return 0.5 }
        defer { IOObjectRelease(service) }
        var v: Float = 0.5
        IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey, &v)
        return Double(v)
    }

    private func fallbackSetBrightness(_ value: Double, displayID: CGDirectDisplayID) {
        let service = ioServiceForDisplay(displayID)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey, Float(value))
    }

    // MARK: - IOKit External Brightness

    private func externalGetBrightness(_ displayID: CGDirectDisplayID) -> Double {
        let service = ioServiceForDisplay(displayID)
        guard service != 0 else { return 0.5 }
        defer { IOObjectRelease(service) }
        var v: Float = 0.5
        IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey, &v)
        return Double(v)
    }

    private func externalSetBrightness(_ value: Double, displayID: CGDirectDisplayID) {
        let service = ioServiceForDisplay(displayID)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey, Float(value))
    }

    // MARK: - IOKit Service Lookup

    /// Finds the IOKit service for a display by matching vendor + model IDs.
    private func ioServiceForDisplay(_ displayID: CGDirectDisplayID) -> io_service_t {
        let vendor = CGDisplayVendorNumber(displayID)
        let model  = CGDisplayModelNumber(displayID)

        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iter) }

        var candidate = IOIteratorNext(iter)
        while candidate != 0 {
            if let info = IODisplayCreateInfoDictionary(
                candidate,
                IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] {

                // Keys are defined in <IOKit/graphics/IOGraphicsTypes.h>
                let sVendor = (info["DisplayVendorID"]  as? UInt32) ?? 0
                let sModel  = (info["DisplayProductID"] as? UInt32) ?? 0
                if sVendor == vendor && sModel == model {
                    return candidate   // caller must IOObjectRelease
                }
            }
            IOObjectRelease(candidate)
            candidate = IOIteratorNext(iter)
        }
        return 0
    }

}

// MARK: - IOKit brightness key (matches kIODisplayBrightnessKey from IOGraphicsLib.h)

private let kIODisplayBrightnessKey = "brightness" as CFString
