import SwiftUI
import AppKit

// MARK: - Onboarding  (4 steps: Welcome → Full Disk → Accessibility → Done)

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var step = 0
    private let totalSteps = 4

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#080c14"), Color(hex: "#0a1020"), Color(hex: "#0d1228")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                Group {
                    switch step {
                    case 0: OnboardingStep0(onNext: { step = 1 })
                    case 1: OnboardingStep1(onNext: { step = 2 })
                    case 2: OnboardingStep2Accessibility(onNext: { step = 3 })
                    default: OnboardingStepDone(onDone: {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        appState.isOnboardingComplete = true
                    })
                    }
                }
                Spacer()

                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Color.haloAccent : Color.haloBorder2)
                            .frame(width: i == step ? 24 : 8, height: 8)
                            .animation(.easeInOut, value: step)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .frame(minWidth: 600, minHeight: 480)
        .preferredColorScheme(.dark)
    }
}

struct OnboardingStep0: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.haloAccent.opacity(0.2), Color.haloAccent2.opacity(0.1)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)
                Circle()
                    .fill(LinearGradient(colors: [.haloAccent, .haloAccent2],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 70, height: 70)
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 8) {
                Text("Welcome to Halo")
                    .font(HaloFont.display(32, weight: .heavy))
                    .foregroundColor(.haloText)
                Text("Your Mac. Elevated.")
                    .font(HaloFont.body(16))
                    .foregroundColor(.haloText2)
            }

            VStack(spacing: 10) {
                OnboardingFeatureRow(icon: "sparkles", text: "One-tap Smart Scan")
                OnboardingFeatureRow(icon: "shield.fill", text: "Malware & privacy protection")
                OnboardingFeatureRow(icon: "doc.on.clipboard.fill", text: "Intelligent clipboard history")
                OnboardingFeatureRow(icon: "menubar.rectangle", text: "Ambient menu bar monitoring")
            }

            HaloPrimaryButton("Get Started", icon: "arrow.right", action: onNext)
        }
        .padding(48)
        .frame(maxWidth: 440)
    }
}

struct OnboardingStep1: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 52))
                .foregroundColor(.haloAccent)

            VStack(spacing: 8) {
                Text("Grant Full Disk Access")
                    .font(HaloFont.display(24, weight: .bold))
                    .foregroundColor(.haloText)
                Text("Halo needs Full Disk Access to scan system files, caches, and logs for cleanup.\nYour data stays on-device — we never upload anything.")
                    .font(HaloFont.body(14))
                    .foregroundColor(.haloText2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            VStack(spacing: 10) {
                Text("System Settings → Privacy & Security → Full Disk Access → Enable Halo")
                    .font(HaloFont.mono(12))
                    .foregroundColor(.haloText2)
                    .padding(12)
                    .background(Color.haloSurface2)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder2, lineWidth: 1))
            }

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .font(HaloFont.body(13, weight: .semibold))
                .foregroundColor(.haloAccent)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.haloAccent.opacity(0.1))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloAccent.opacity(0.3), lineWidth: 1))
                .buttonStyle(.plain)

                HaloPrimaryButton("I've granted access", action: onNext)
            }
        }
        .padding(48)
        .frame(maxWidth: 480)
    }
}

// MARK: - Step 2: Accessibility permission (global clipboard shortcut)

struct OnboardingStep2Accessibility: View {
    let onNext: () -> Void
    @State private var isGranted = AXIsProcessTrusted()
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.haloAccent.opacity(0.15))
                    .frame(width: 90, height: 90)
                    .blur(radius: 16)
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 38))
                    .foregroundColor(.haloAccent)
            }

            VStack(spacing: 8) {
                Text("Enable Global Shortcut")
                    .font(HaloFont.display(24, weight: .bold))
                    .foregroundColor(.haloText)
                Text("Grant Accessibility access so ⌘⇧V opens your clipboard\npicker from any app — Safari, Xcode, Terminal, anywhere.")
                    .font(HaloFont.body(14))
                    .foregroundColor(.haloText2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            // Path hint
            Text("System Settings → Privacy & Security → Accessibility → Enable Halo")
                .font(HaloFont.mono(11))
                .foregroundColor(.haloText2)
                .padding(12)
                .background(Color.haloSurface2)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder2, lineWidth: 1))

            // Live status badge
            HStack(spacing: 6) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundColor(isGranted ? .haloGreen : .haloText3)
                Text(isGranted ? "Accessibility granted" : "Waiting for permission…")
                    .font(HaloFont.body(13))
                    .foregroundColor(isGranted ? .haloGreen : .haloText3)
            }
            .animation(.easeInOut, value: isGranted)

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    // Prompt the system dialog too
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                    AXIsProcessTrustedWithOptions(opts as CFDictionary)
                }
                .font(HaloFont.body(13, weight: .semibold))
                .foregroundColor(.haloAccent)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.haloAccent.opacity(0.1))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloAccent.opacity(0.3), lineWidth: 1))
                .buttonStyle(.plain)

                HaloPrimaryButton(isGranted ? "Continue" : "Skip for now", action: {
                    pollTimer?.invalidate()
                    onNext()
                })
            }
        }
        .padding(48)
        .frame(maxWidth: 480)
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                let trusted = AXIsProcessTrusted()
                if trusted != isGranted { isGranted = trusted }
            }
        }
        .onDisappear { pollTimer?.invalidate() }
    }
}

// MARK: - Step 3: All done

struct OnboardingStepDone: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundColor(.haloGreen)
                .shadow(color: Color.haloGreen.opacity(0.4), radius: 16)

            VStack(spacing: 8) {
                Text("You're all set!")
                    .font(HaloFont.display(24, weight: .bold))
                    .foregroundColor(.haloText)
                Text("Halo is ready to keep your Mac in perfect shape.\nRun your first Smart Scan to see what we find.")
                    .font(HaloFont.body(14))
                    .foregroundColor(.haloText2)
                    .multilineTextAlignment(.center)
            }

            HaloPrimaryButton("Launch Halo", icon: "sparkles", action: onDone)
        }
        .padding(48)
        .frame(maxWidth: 400)
    }
}

struct OnboardingFeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.haloAccent)
                .frame(width: 20)
            Text(text)
                .font(HaloFont.body(14))
                .foregroundColor(.haloText2)
            Spacer()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("enableMenuBar") private var enableMenuBar = true
    @AppStorage("scanFrequency") private var scanFrequency = "weekly"
    @AppStorage("enableAnalytics") private var enableAnalytics = false
    @AppStorage("clipboardHistoryLimit") private var clipboardLimit = 200
    // P3-12: thresholds
    @AppStorage("alertCPUThreshold")    private var alertCPUThreshold: Double = 0.85
    @AppStorage("alertRAMThreshold")    private var alertRAMThreshold: Double = 0.85
    @AppStorage("alertDiskFreeGB")      private var alertDiskFreeGB: Double = 5.0
    @AppStorage("alertBatteryLow")      private var alertBatteryLow: Int = 20
    @AppStorage("alertBatteryCritical") private var alertBatteryCritical: Int = 10
    @AppStorage("temperatureUnit")      private var useFahrenheit = false
    // P3-09: menu bar module visibility
    @AppStorage("menuBarShowCPU")     private var showCPU     = true
    @AppStorage("menuBarShowRAM")     private var showRAM     = true
    @AppStorage("menuBarShowNet")     private var showNet     = true
    @AppStorage("menuBarShowBattery") private var showBattery = true
    @AppStorage("menuBarShowDisk")    private var showDisk    = false
    @AppStorage("menuBarCompact")     private var compactMode = false
    // F-008: display style
    @AppStorage("menuBarDisplayStyle") private var displayStyle = MenuBarDisplayStyle.icon.rawValue

    var body: some View {
        TabView {
            // General
            Form {
                Section("Startup") {
                    Toggle("Launch Halo at login", isOn: $launchAtLogin)
                    Toggle("Enable menu bar agent", isOn: $enableMenuBar)
                }
                Section("Scheduled Scans") {
                    Picker("Frequency", selection: $scanFrequency) {
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly")
                        Text("Off").tag("off")
                    }
                }
                Section("Units") {
                    Toggle("Show temperatures in Fahrenheit (°F)", isOn: $useFahrenheit)
                }
                Section("Privacy") {
                    Toggle("Share anonymous analytics to improve Halo", isOn: $enableAnalytics)
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            // Clipboard
            Form {
                Section("History") {
                    Stepper("Keep \(clipboardLimit) items", value: $clipboardLimit, in: 50...500, step: 50)
                    Button("Clear All History Now", role: .destructive) {}
                }
                Section("Quick Picker Shortcut") {
                    HStack {
                        Text("Open clipboard picker")
                        Spacer()
                        ShortcutRecorderView(
                            keyCode: appState.shortcutKeyCode,
                            modifiers: appState.shortcutModifiers
                        ) { newKeyCode, newModifiers in
                            appState.updateShortcut(keyCode: newKeyCode, modifiers: newModifiers)
                        }
                    }
                    Text("Works from any app when Accessibility is granted.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Privacy") {
                    Text("Clipboard items are stored only on this device and never synced to iCloud.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }

            // Alerts (P3-08/12)
            Form {
                Section("CPU Alerts") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CPU sustained high: \(Int(alertCPUThreshold * 100))%")
                        Slider(value: $alertCPUThreshold, in: 0.50...0.99, step: 0.05)
                            .tint(.haloAccent)
                        Text("Alert fires when CPU stays above this threshold for 10+ seconds.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Section("Memory Alerts") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RAM pressure: \(Int(alertRAMThreshold * 100))%")
                        Slider(value: $alertRAMThreshold, in: 0.50...0.99, step: 0.05)
                            .tint(.haloPurple)
                    }
                }
                Section("Disk Alerts") {
                    Picker("Alert when free space is below", selection: $alertDiskFreeGB) {
                        Text("1 GB").tag(1.0)
                        Text("2 GB").tag(2.0)
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                    }
                }
                Section("Battery Alerts") {
                    Stepper("Low battery warning: \(alertBatteryLow)%",
                            value: $alertBatteryLow, in: 10...40, step: 5)
                    Stepper("Critical battery alert: \(alertBatteryCritical)%",
                            value: $alertBatteryCritical, in: 5...20, step: 5)
                    Text("You'll also get a notification when charging is complete.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .tabItem { Label("Alerts", systemImage: "bell.fill") }

            // Menu Bar (P3-09)
            Form {
                Section("Visible Modules") {
                    Toggle("CPU usage", isOn: $showCPU)
                    Toggle("RAM pressure", isOn: $showRAM)
                    Toggle("Network ↑↓", isOn: $showNet)
                    Toggle("Battery %", isOn: $showBattery)
                    Toggle("Disk I/O", isOn: $showDisk)
                }
                Section("Display") {
                    // F-008: icon style picker
                    Picker("Status Item Style", selection: $displayStyle) {
                        ForEach(MenuBarDisplayStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Compact mode (smaller text)", isOn: $compactMode)
                    Text("When compact mode is on, values are abbreviated (e.g. 42% → 42).")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }

            // About
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundColor(.haloAccent)
                Text("Halo").font(HaloFont.display(24, weight: .heavy))
                Text("Version 1.2.0 (Build 120)").foregroundColor(.secondary)
                Divider()
                Button("Check for Updates") {}
                Button("View Privacy Policy") {}
                Button("Send Feedback") {}
            }
            .padding(40)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Shortcut Recorder

struct ShortcutRecorderView: View {
    let keyCode: Int
    let modifiers: Int
    let onCapture: (Int, Int) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var displayLabel: String {
        isRecording ? "⏺  Press shortcut…" : HotkeyManager.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    var body: some View {
        Button(displayLabel) {
            isRecording ? stopRecording() : startRecording()
        }
        .font(isRecording ? HaloFont.body(12) : HaloFont.mono(13))
        .foregroundColor(isRecording ? .haloAmber : .haloAccent)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isRecording ? Color.haloAmber.opacity(0.1) : Color.haloAccent.opacity(0.08))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isRecording ? Color.haloAmber.opacity(0.5) : Color.haloAccent.opacity(0.3), lineWidth: 1))
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 { // Escape → cancel
                self.stopRecording()
                return nil
            }
            guard !flags.isEmpty else { return event }
            self.onCapture(Int(event.keyCode), Int(flags.rawValue))
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - Commands

struct HaloCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Run Smart Scan") {}
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) {}
    }
}
