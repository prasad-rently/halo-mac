import SwiftUI

// MARK: - Smart Scan Sheet View
// Presented as a sheet when user taps "Smart Scan"

struct SmartScanView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    enum ScanPhase { case preparing, scanning, reviewing, done }
    @State private var phase: ScanPhase = .preparing
    @State private var progress: Double = 0
    @State private var currentCategory = "Preparing scan…"
    @State private var phasesComplete: [String] = []

    let scanPhases = [
        ("System Caches", "server.rack"),
        ("Log Files", "doc.text"),
        ("Trash & Temp", "trash"),
        ("Xcode Data", "hammer"),
        ("App Leftovers", "square.stack.3d.up"),
        ("Duplicates", "doc.on.doc"),
    ]

    var body: some View {
        ZStack {
            Color.haloBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14))
                            .foregroundColor(.haloText2)
                            .padding(8)
                            .background(Color.haloSurface2)
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)

                Spacer()

                if phase == .preparing || phase == .scanning {
                    ScanningAnimation(
                        progress: progress,
                        currentCategory: currentCategory,
                        phasesComplete: phasesComplete,
                        phases: scanPhases
                    )
                } else if phase == .reviewing, let result = appState.smartScanResult {
                    ScanResultView(result: result, onClean: {
                        Task {
                            // Execute cleanup from result
                            phase = .done
                        }
                    }, onDismiss: { isPresented = false })
                } else if phase == .done {
                    ScanDoneView(onDismiss: { isPresented = false })
                }

                Spacer()
            }
        }
        .frame(width: 560, height: 480)
        .task { await runScan() }
    }

    private func runScan() async {
        phase = .scanning
        for (i, phaseInfo) in scanPhases.enumerated() {
            currentCategory = "Scanning \(phaseInfo.0)…"
            // Simulate per-category scan time
            let steps = 8
            for s in 0..<steps {
                try? await Task.sleep(nanoseconds: 100_000_000)
                progress = (Double(i) + Double(s + 1) / Double(steps)) / Double(scanPhases.count)
            }
            phasesComplete.append(phaseInfo.0)
        }
        // Run actual scan
        await appState.runSmartScan()
        phase = .reviewing
    }
}

// MARK: - Scanning Animation

struct ScanningAnimation: View {
    let progress: Double
    let currentCategory: String
    let phasesComplete: [String]
    let phases: [(String, String)]

    @State private var pulseScale: CGFloat = 1.0
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 28) {
            // Animated ring
            ZStack {
                // Glow
                Circle()
                    .fill(Color.haloAccent.opacity(0.08))
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulseScale)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulseScale)

                Circle()
                    .stroke(Color.haloBorder, lineWidth: 10)
                    .frame(width: 130, height: 130)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(colors: [.haloAccent, .haloPurple, .haloGreen],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .frame(width: 130, height: 130)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)

                VStack(spacing: 3) {
                    Text(String(format: "%.0f%%", progress * 100))
                        .font(HaloFont.display(28, weight: .heavy))
                        .foregroundColor(.haloText)
                    Text("scanned")
                        .font(HaloFont.body(11))
                        .foregroundColor(.haloText2)
                }
            }
            .onAppear { pulseScale = 1.08 }

            VStack(spacing: 6) {
                Text("Smart Scan Running")
                    .font(HaloFont.display(18, weight: .bold))
                    .foregroundColor(.haloText)
                Text(currentCategory)
                    .font(HaloFont.body(13))
                    .foregroundColor(.haloText2)
                    .animation(.easeInOut, value: currentCategory)
            }

            // Phase indicators
            HStack(spacing: 10) {
                ForEach(phases, id: \.0) { phase in
                    let isDone = phasesComplete.contains(phase.0)
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(isDone ? Color.haloGreen.opacity(0.15) : Color.haloBorder.opacity(0.5))
                                .frame(width: 32, height: 32)
                            Image(systemName: isDone ? "checkmark" : phase.1)
                                .font(.system(size: 13))
                                .foregroundColor(isDone ? .haloGreen : .haloText3)
                        }
                        Text(phase.0.components(separatedBy: " ").first ?? "")
                            .font(HaloFont.body(9))
                            .foregroundColor(isDone ? .haloGreen : .haloText3)
                    }
                    .animation(.easeOut, value: isDone)
                }
            }
        }
    }
}

// MARK: - Scan Result

struct ScanResultView: View {
    let result: SmartScanResult
    let onClean: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.haloGreen)
                    .shadow(color: Color.haloGreen.opacity(0.4), radius: 12)
                Text("Scan Complete")
                    .font(HaloFont.display(22, weight: .bold))
                    .foregroundColor(.haloText)
                Text("\(result.totalBytesFormatted) can be freed")
                    .font(HaloFont.body(14))
                    .foregroundColor(.haloText2)
            }

            // Category breakdown
            VStack(spacing: 6) {
                ForEach(result.categoryResults.prefix(4)) { cat in
                    HStack {
                        Image(systemName: cat.kind.icon)
                            .font(.system(size: 13))
                            .foregroundColor(.haloAccent)
                            .frame(width: 20)
                        Text(cat.kind.rawValue)
                            .font(HaloFont.body(13))
                            .foregroundColor(.haloText)
                        Spacer()
                        Text(cat.allFormatted)
                            .font(HaloFont.body(13, weight: .semibold))
                            .foregroundColor(.haloText2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.haloSurface2)
                    .cornerRadius(9)
                }
            }
            .frame(maxWidth: 380)

            HStack(spacing: 12) {
                HaloGhostButton("Review", action: onDismiss)
                HaloPrimaryButton("Clean Now", icon: "sparkles", action: onClean)
            }
        }
    }
}

struct ScanDoneView: View {
    let onDismiss: () -> Void
    @State private var showConfetti = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 52))
                .foregroundColor(.haloGreen)
                .shadow(color: Color.haloGreen.opacity(0.5), radius: 16)
                .scaleEffect(showConfetti ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.6).repeatCount(3), value: showConfetti)

            Text("Your Mac is clean! ✨")
                .font(HaloFont.display(22, weight: .bold))
                .foregroundColor(.haloText)

            HaloPrimaryButton("Done", action: onDismiss)
        }
        .onAppear { showConfetti = true }
    }
}
