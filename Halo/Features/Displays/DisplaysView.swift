import SwiftUI
import CoreGraphics

// MARK: - DisplaysView

struct DisplaysView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = DisplaysViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                DisplaysHeader(count: viewModel.displays.count)

                if viewModel.isLoading {
                    ProgressView("Detecting displays…")
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .foregroundColor(.haloText2)
                } else if viewModel.displays.isEmpty {
                    DisplaysEmptyState()
                } else {
                    // Display cards — 2 columns when space allows, 1 column on narrow layouts
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 16),
                                  GridItem(.flexible(), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach($viewModel.displays) { $display in
                            DisplayCard(display: $display) { newValue in
                                viewModel.setBrightness(newValue, for: display)
                            }
                        }
                    }

                    NightShiftCard(
                        isEnabled: $viewModel.nightShiftEnabled,
                        strength: $viewModel.nightShiftStrength,
                        onToggle: { viewModel.toggleNightShift() },
                        onStrengthChange: { viewModel.setNightShiftStrength($0) }
                    )

                    DisplayInfoTable(displays: viewModel.displays)
                }
            }
            .padding(28)
        }
        .background(Color.haloSurface)
        .task { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            Task { await viewModel.load() }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class DisplaysViewModel: ObservableObject {

    @Published var displays: [ConnectedDisplay] = []
    @Published var nightShiftEnabled: Bool = false
    @Published var nightShiftStrength: Double = 0.5
    @Published var isLoading: Bool = false

    private let manager = DisplayBrightnessManager()
    private var debounceTask: Task<Void, Never>?

    // MARK: Load

    func load() async {
        isLoading = true

        // Enumerate displays entirely on the @MainActor — all CG* APIs are main-thread-safe
        // when called here, avoiding any deadlock risk from running inside the background actor.
        displays = enumerateDisplays()

        // Stop showing the spinner immediately — cards are ready.
        isLoading = false

        // Load Night Shift state in a detached task so a slow CBBlueLightClient XPC
        // connection does not block the main thread or delay the UI.
        Task.detached(priority: .userInitiated) {
            let enabled  = NightShiftHelper.isEnabled()
            let strength = NightShiftHelper.strength()
            await MainActor.run {
                self.nightShiftEnabled = enabled
                self.nightShiftStrength = strength
            }
        }

        // Async pass: read actual brightness for each display via the actor (IOKit / CoreDisplay).
        // We show cards immediately with a 0.5 placeholder and update as each read completes.
        for display in displays {
            let id = display.id
            let actual = await manager.readBrightness(id)
            if let idx = displays.firstIndex(where: { $0.id == id }) {
                displays[idx].brightness = actual
            }
        }
    }

    /// Enumerate active displays on the main thread. Must be called from @MainActor context.
    private func enumerateDisplays() -> [ConnectedDisplay] {
        let screens = NSScreen.screens
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        return ids.compactMap { id -> ConnectedDisplay? in
            guard CGDisplayIsAsleep(id) == 0 else { return nil }
            if CGDisplayIsInMirrorSet(id) != 0, CGDisplayMirrorsDisplay(id) != 0 { return nil }

            let screen = screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
            })
            let name = screen?.localizedName
                ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "External Display")

            let bounds = CGDisplayBounds(id)
            let resolution = CGSize(width: bounds.width, height: bounds.height)

            let mm = CGDisplayScreenSize(id)
            let inches: Double? = mm.width > 0
                ? sqrt(mm.width * mm.width + mm.height * mm.height) / 25.4
                : nil

            var hz: Double = 60
            if let mode = CGDisplayCopyDisplayMode(id) {
                hz = mode.refreshRate > 0 ? mode.refreshRate : 60
            }

            let scale = screen?.backingScaleFactor ?? 1.0
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let isMain    = CGDisplayIsMain(id) != 0

            return ConnectedDisplay(
                id: id,
                name: name,
                resolution: resolution,
                scaleFactor: scale,
                refreshRate: hz,
                isBuiltIn: isBuiltIn,
                isMain: isMain,
                physicalSizeInches: inches,
                brightness: 0.5,           // placeholder — filled in asynchronously
                isDDCCapable: !isBuiltIn
            )
        }
    }

    // MARK: Brightness — debounced 80 ms to avoid IOKit saturation

    func setBrightness(_ value: Double, for display: ConnectedDisplay) {
        // Update local state immediately for smooth slider feedback
        if let idx = displays.firstIndex(where: { $0.id == display.id }) {
            displays[idx].brightness = value
        }
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)  // 80 ms
            guard !Task.isCancelled else { return }
            await manager.setBrightness(value, for: display.id)
        }
    }

    /// Called from menu bar — no debounce needed (called on finger-lift)
    func setBrightnessImmediate(_ value: Double, for displayID: CGDirectDisplayID) {
        if let idx = displays.firstIndex(where: { $0.id == displayID }) {
            displays[idx].brightness = value
        }
        Task { await manager.setBrightness(value, for: displayID) }
    }

    // MARK: Night Shift

    func toggleNightShift() {
        nightShiftEnabled.toggle()
        NightShiftHelper.setEnabled(nightShiftEnabled)
    }

    func setNightShiftStrength(_ value: Double) {
        nightShiftStrength = value
        NightShiftHelper.setStrength(value)
    }
}

// MARK: - Header

private struct DisplaysHeader: View {
    let count: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Displays")
                    .font(HaloFont.display(22, weight: .bold))
                    .foregroundColor(.haloText)
                Text("Brightness · Night Shift · Display Info")
                    .font(HaloFont.body(13))
                    .foregroundColor(.haloText2)
            }
            Spacer()
            if count > 0 {
                HaloBadge(text: "\(count) connected", color: .haloAccent)
            }
        }
    }
}

// MARK: - Empty State

private struct DisplaysEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 44))
                .foregroundColor(.haloText3)
            Text("No Displays Detected")
                .font(HaloFont.display(16, weight: .semibold))
                .foregroundColor(.haloText2)
            Text("Connect a display and Halo will detect it automatically.")
                .font(HaloFont.body(13))
                .foregroundColor(.haloText3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

// MARK: - Display Card

struct DisplayCard: View {
    @Binding var display: ConnectedDisplay
    let onBrightnessChange: (Double) -> Void

    @State private var isHovered = false

    var body: some View {
        HaloCard(accentTop: display.isBuiltIn ? .haloAccent : .haloAccent2) {
            VStack(alignment: .leading, spacing: 16) {

                // ── Header row ──
                HStack(spacing: 12) {
                    // Monitor icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(
                                LinearGradient(
                                    colors: display.isBuiltIn
                                        ? [Color.haloAccent.opacity(0.2), Color.haloAccent2.opacity(0.1)]
                                        : [Color.haloAccent2.opacity(0.2), Color.haloPurple.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing)
                            )
                            .frame(width: 40, height: 40)
                        Image(systemName: display.typeIcon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(display.isBuiltIn ? .haloAccent : .haloAccent2)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        // Display name (truncated to fit card)
                        Text(display.name)
                            .font(HaloFont.display(14, weight: .semibold))
                            .foregroundColor(.haloText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 6) {
                            // Resolution
                            Text(display.resolutionLabel)
                                .font(HaloFont.mono(10))
                                .foregroundColor(.haloText3)

                            Circle()
                                .fill(Color.haloText3)
                                .frame(width: 2, height: 2)

                            // Refresh rate
                            Text(display.refreshLabel)
                                .font(HaloFont.mono(10))
                                .foregroundColor(.haloText3)

                            // Size if known
                            if let size = display.sizeLabel {
                                Circle()
                                    .fill(Color.haloText3)
                                    .frame(width: 2, height: 2)
                                Text(size)
                                    .font(HaloFont.mono(10))
                                    .foregroundColor(.haloText3)
                            }
                        }
                    }

                    Spacer()

                    // Badges
                    VStack(alignment: .trailing, spacing: 4) {
                        if display.isMain {
                            HaloBadge(text: "Main", color: .haloGreen)
                        }
                        HaloBadge(
                            text: display.typeLabel,
                            color: display.isBuiltIn ? .haloAccent : .haloAccent2
                        )
                    }
                }

                Divider().background(Color.haloBorder)

                // ── Brightness slider ──
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "sun.min.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.haloText3)
                        Text("Brightness")
                            .font(HaloFont.body(12, weight: .medium))
                            .foregroundColor(.haloText2)
                        Spacer()
                        Text("\(Int(display.brightness * 100))%")
                            .font(HaloFont.mono(12))
                            .foregroundColor(.haloAccent)
                            .frame(width: 36, alignment: .trailing)
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.haloText3)
                    }

                    if display.isDDCCapable || display.isBuiltIn {
                        Slider(value: Binding(
                            get: { display.brightness },
                            set: { onBrightnessChange($0) }
                        ), in: 0.02...1.0)
                        .tint(display.isBuiltIn ? .haloAccent : .haloAccent2)
                    } else {
                        // External display doesn't support DDC brightness
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.haloAmber)
                            Text("DDC not supported on this display")
                                .font(HaloFont.body(11))
                                .foregroundColor(.haloAmber)
                        }
                    }
                }

                // ── Quick-set buttons ──
                HStack(spacing: 6) {
                    ForEach([25, 50, 75, 100], id: \.self) { pct in
                        Button {
                            onBrightnessChange(Double(pct) / 100.0)
                        } label: {
                            Text("\(pct)%")
                                .font(HaloFont.body(11, weight: .medium))
                                .foregroundColor(
                                    Int(display.brightness * 100) == pct
                                        ? .white
                                        : .haloText2
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    Int(display.brightness * 100) == pct
                                        ? (display.isBuiltIn ? Color.haloAccent : Color.haloAccent2)
                                        : Color.haloSurface
                                )
                                .cornerRadius(7)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(Color.haloBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
        }
    }
}

// MARK: - Night Shift Card

struct NightShiftCard: View {
    @Binding var isEnabled: Bool
    @Binding var strength: Double
    let onToggle: () -> Void
    let onStrengthChange: (Double) -> Void

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 14) {

                // Toggle row
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(
                                LinearGradient(
                                    colors: [Color.haloAmber.opacity(0.2), Color.haloRed.opacity(0.1)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 40, height: 40)
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 17))
                            .foregroundColor(.haloAmber)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Night Shift")
                            .font(HaloFont.display(14, weight: .semibold))
                            .foregroundColor(.haloText)
                        Text("Warm colour temperature reduces eye strain after dark")
                            .font(HaloFont.body(11))
                            .foregroundColor(.haloText2)
                    }

                    Spacer()
                    HaloToggle(isOn: $isEnabled)
                        .onChange(of: isEnabled) { _ in onToggle() }
                }

                if isEnabled {
                    Divider().background(Color.haloBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "thermometer.sun.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.haloText3)
                            Text("Warmth")
                                .font(HaloFont.body(12, weight: .medium))
                                .foregroundColor(.haloText2)
                            Spacer()
                            Text("\(Int(strength * 100))%")
                                .font(HaloFont.mono(12))
                                .foregroundColor(.haloAmber)
                        }

                        Slider(value: Binding(
                            get: { strength },
                            set: { onStrengthChange($0) }
                        ), in: 0...1)
                        .tint(.haloAmber)
                    }
                }
            }
            .padding(18)
        }
    }
}

// MARK: - Display Info Table

private struct DisplayInfoTable: View {
    let displays: [ConnectedDisplay]

    var body: some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.haloAccent)
                    Text("Display Information")
                        .font(HaloFont.display(14, weight: .semibold))
                        .foregroundColor(.haloText)
                }

                Divider().background(Color.haloBorder)

                ForEach(displays) { display in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: display.typeIcon)
                            .font(.system(size: 14))
                            .foregroundColor(display.isBuiltIn ? .haloAccent : .haloAccent2)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.name)
                                .font(HaloFont.body(13, weight: .semibold))
                                .foregroundColor(.haloText)

                            HStack(spacing: 16) {
                                InfoCell(label: "Resolution", value: display.resolutionLabel)
                                InfoCell(label: "Refresh",    value: display.refreshLabel)
                                if let size = display.sizeLabel {
                                    InfoCell(label: "Size", value: size)
                                }
                                InfoCell(label: "Scale",
                                         value: display.scaleFactor == 2 ? "Retina (2×)" : "Standard (1×)")
                            }
                        }

                        Spacer()

                        // Live brightness chip
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(display.brightness * 100))%")
                                .font(HaloFont.display(18, weight: .bold))
                                .foregroundColor(display.isBuiltIn ? .haloAccent : .haloAccent2)
                            Text("Brightness")
                                .font(HaloFont.body(10))
                                .foregroundColor(.haloText3)
                        }
                    }

                    if display.id != displays.last?.id {
                        Divider().background(Color.haloBorder)
                    }
                }
            }
            .padding(18)
        }
    }
}

private struct InfoCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(HaloFont.body(10))
                .foregroundColor(.haloText3)
            Text(value)
                .font(HaloFont.mono(11))
                .foregroundColor(.haloText)
        }
    }
}

// MARK: - Night Shift Helper
// Uses CoreBrightness private framework via dlopen / NSClassFromString.
// Gracefully no-ops if unavailable (App Store sandbox or future macOS).
//
// ARM64 safety note: perform(_:with:) returns Unmanaged<AnyObject>! and Swift
// will try to release whatever is in x0 after the call.  getBlueLightStatus:
// returns BOOL (0 or 1), not a pointer — so Swift crashes trying to release it.
// Fix: get the raw IMP via class_getMethodImplementation and call it through a
// @convention(c) function pointer cast, which has no ARC involvement at all.

enum NightShiftHelper {

    // Oversized buffer — real CBBlueLightStatus is ~12 bytes; 64 bytes is safe.
    // Layout (empirically verified on macOS 13+):
    //   offset  0: Int32  mode
    //   offset  4: Float  strength
    //   offset  8: Bool   enabled   ← the bit we care about
    private static let kStatusSize = 64

    // @convention(c) IMPs for the private methods we call
    private typealias GetStatusIMP   = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetEnabledIMP  = @convention(c) (NSObject, Selector, Bool) -> Void
    private typealias SetStrengthIMP = @convention(c) (NSObject, Selector, Float, Bool) -> Void

    static func isEnabled() -> Bool {
        guard let client = makeClient() else { return false }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard let imp = class_getMethodImplementation(type(of: client) as AnyClass, sel) else { return false }
        let fn = unsafeBitCast(imp, to: GetStatusIMP.self)
        var buf = [UInt8](repeating: 0, count: kStatusSize)
        buf.withUnsafeMutableBufferPointer { _ = fn(client, sel, UnsafeMutableRawPointer($0.baseAddress!)) }
        // enabled is a Bool at byte offset 8 (after Int32 + Float)
        return buf[8] != 0
    }

    static func setEnabled(_ on: Bool) {
        guard let client = makeClient() else { return }
        let sel = NSSelectorFromString("setEnabled:")
        guard let imp = class_getMethodImplementation(type(of: client) as AnyClass, sel) else { return }
        unsafeBitCast(imp, to: SetEnabledIMP.self)(client, sel, on)
    }

    static func strength() -> Double {
        guard let client = makeClient() else { return 0.5 }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard let imp = class_getMethodImplementation(type(of: client) as AnyClass, sel) else { return 0.5 }
        let fn = unsafeBitCast(imp, to: GetStatusIMP.self)
        var buf = [UInt8](repeating: 0, count: kStatusSize)
        buf.withUnsafeMutableBufferPointer { _ = fn(client, sel, UnsafeMutableRawPointer($0.baseAddress!)) }
        // strength is a Float at byte offset 4 (after Int32 mode)
        return buf.withUnsafeBytes { Double($0.load(fromByteOffset: 4, as: Float.self)) }
    }

    static func setStrength(_ value: Double) {
        guard let client = makeClient() else { return }
        let sel = NSSelectorFromString("setStrength:commit:")
        guard let imp = class_getMethodImplementation(type(of: client) as AnyClass, sel) else { return }
        unsafeBitCast(imp, to: SetStrengthIMP.self)(client, sel, Float(value), true)
    }

    private static func makeClient() -> NSObject? {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }
}
