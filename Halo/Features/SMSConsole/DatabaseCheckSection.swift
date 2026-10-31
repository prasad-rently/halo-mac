import SwiftUI

// MARK: - DatabaseCheckSection  (F-057 FR-S1 — Mac UI)
//
// "Check my database" in Cloud settings. The engine is `DatabaseCheckEngine` (DatabaseCheck.swift,
// stub-tested); this is only the button and the report. It signs in with the stored credential and probes
// meta, devices, sms and clipboard. Report text contains no token, password or key (engine guarantee, tested).
// NOT run on screen in the PR that added it — compiled only.

@MainActor
final class DatabaseCheckViewModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var report: DatabaseCheckReport?
    @Published private(set) var notConfigured = false

    func run() {
        guard !running else { return }
        let store = CloudConfigStore.shared
        guard let config = store.firebaseConfig, let auth = store.authCredential else { notConfigured = true; return }
        notConfigured = false
        running = true
        report = nil
        Task {
            let engine = DatabaseCheckEngine(transport: LiveDatabaseProbeTransport(config: config, credential: auth), databaseURL: config.databaseURL)
            let result = await engine.run()
            report = result
            running = false
        }
    }
}

struct DatabaseCheckSection: View {
    @StateObject private var model = DatabaseCheckViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check my database").font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
            Text("Tests that your Firebase database lets Halo read, write and delete under every folder it uses — settings, devices, SMS and clipboard — and that it isn't open to the public. Leaves nothing behind.")
                .font(HaloFont.body(11)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                HaloGhostButton(model.running ? "Checking…" : "Check my database", icon: "stethoscope") { model.run() }
                    .disabled(model.running)
                if model.running { ProgressView().controlSize(.small) }
            }
            if model.notConfigured {
                Text("Connect your Firebase first — there is nothing to check yet.").font(HaloFont.body(10)).foregroundColor(.haloText3)
            }
            if let report = model.report {
                Text(summary(report.overall)).font(HaloFont.body(12, weight: .semibold)).foregroundColor(color(report.overall))
                ForEach(report.items, id: \.kind) { row($0) }
            }
        }
        .padding(14)
        .background(Color.haloSurface2.opacity(0.5)).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.haloBorder, lineWidth: 1))
    }

    private func summary(_ s: DatabaseCheckStatus) -> String {
        switch s { case .pass: return "Everything works."; case .warn: return "Works, with something to fix."; default: return "Something needs fixing." }
    }

    private func color(_ s: DatabaseCheckStatus) -> Color {
        switch s { case .pass: return .haloGreen; case .warn: return .haloAmber; case .fail: return .haloRed; case .skipped: return .haloText3 }
    }

    private func glyph(_ s: DatabaseCheckStatus) -> String {
        switch s { case .pass: return "checkmark.circle.fill"; case .warn: return "exclamationmark.triangle.fill"; case .fail: return "xmark.octagon.fill"; case .skipped: return "minus.circle" }
    }

    private func row(_ item: DatabaseCheckItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: glyph(item.status)).foregroundColor(color(item.status)).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(HaloFont.body(12, weight: .semibold)).foregroundColor(.haloText)
                Text(item.detail).font(HaloFont.body(11)).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
                if let fix = item.fix {
                    Text("Fix: \(fix)").font(HaloFont.body(11)).foregroundColor(.haloAmber).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
