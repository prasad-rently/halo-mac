import SwiftUI
import HaloShareKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var alias = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("This device") {
                    TextField("Name", text: $alias)
                        .accessibilityIdentifier("settings.alias")
                        .onSubmit { model.setAlias(alias) }
                    Text("Other devices see this name when you send or receive.")
                        .font(.system(size: 11)).foregroundColor(.haloText3)
                }

                Section("HaloShare") {
                    LabeledContent("Status") { Text(statusText).foregroundColor(.haloText2) }
                    LabeledContent("Saved to") { Text("Files › Halo › Received").foregroundColor(.haloText2) }
                    LabeledContent("Local Network") {
                        Text(localNetworkText).foregroundColor(model.localNetwork == .denied ? .haloAmber : .haloText2)
                    }
                    .accessibilityIdentifier("settings.localNetwork")
                    if model.localNetwork == .denied {
                        Button("Open Settings") { model.openSystemSettings() }
                    }
                    LabeledContent("Share from other apps") {
                        Text(model.staging == nil ? "Unavailable" : "On").foregroundColor(model.staging == nil ? .haloAmber : .haloText2)
                    }
                    // Honest limits (F-050 D8) behind an (i): iOS suspends apps; nothing pretends otherwise.
                    HStack {
                        HaloChip(text: ShareStrings.receivingChip, systemImage: "antenna.radiowaves.left.and.right", tint: .haloGreen)
                            .accessibilityIdentifier("settings.receivingCopy")
                        HaloInfoButton(title: ShareStrings.receivingInfoTitle, message: ShareStrings.receivingInfo + "\n\n" + ShareStrings.safetyInfo)
                        Spacer()
                    }
                }

                Section("About HaloShare") {
                    LabeledContent("Protocol") { Text("LocalSend v2 · HTTP").foregroundColor(.haloText2) }
                    LabeledContent("Fingerprint") {
                        Text(String(model.identity.fingerprint.prefix(12)) + "…").font(.system(size: 12, design: .monospaced)).foregroundColor(.haloText3)
                    }
                    Text("Transfers stay on your Wi-Fi and are not encrypted in transit. Only accept files from people you trust.")
                        .font(.system(size: 11)).foregroundColor(.haloText3)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.haloBackground)
            .navigationTitle("Settings")
            .onAppear { alias = model.identity.alias }
            .onDisappear { if alias != model.identity.alias { model.setAlias(alias) } }
        }
    }

    private var localNetworkText: String {
        if !model.localNetworkExplained { return "Not asked yet" }
        switch model.localNetwork {
        case .granted: return "Allowed"
        case .denied: return "Off"
        case .undetermined: return "Checking…"
        }
    }

    private var statusText: String {
        switch model.listenState {
        case .listening(let port): return "Listening on \(port)"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .failed(let why): return why
        }
    }
}
