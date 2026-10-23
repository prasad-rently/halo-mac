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

                Section("Receiving") {
                    LabeledContent("Status") { Text(statusText).foregroundColor(.haloText2) }
                    LabeledContent("Saved to") { Text("Halo → Received").foregroundColor(.haloText2) }
                    Text("Nothing is saved until you accept. Files never overwrite each other.")
                        .font(.system(size: 11)).foregroundColor(.haloText3)
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

    private var statusText: String {
        switch model.listenState {
        case .listening(let port): return "Listening on \(port)"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .failed(let why): return why
        }
    }
}
