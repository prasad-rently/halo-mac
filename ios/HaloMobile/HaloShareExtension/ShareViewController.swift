import UIKit
import SwiftUI
import HaloShareStaging

/// The iOS Share Extension (F-050 D7): "Share → HaloShare" from any app.
///
/// It does one thing — copy what was shared into the App Group container and say so. It has
/// **no networking** (this target links `HaloShareStaging` only, not `HaloShareKit`), never
/// lists devices and never sends. The app picks the batch up when it next comes to the
/// foreground, shows a device picker, and sends only after the person taps Send.
final class ShareViewController: UIViewController {

    private let model = ShareExtensionModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 8/255, green: 12/255, blue: 20/255, alpha: 1)

        let root = ShareExtensionView(model: model,
                                      onOpenHalo: { [weak self] in self?.openHalo() },
                                      onDone: { [weak self] in self?.finish() },
                                      onCancel: { [weak self] in self?.cancel() })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)

        stage()
    }

    // MARK: Staging

    private func stage() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { model.phase = .failed("There was nothing to send."); return }
        guard let store = ShareStagingStore.appGroup() else {
            model.phase = .failed(StagingRejection.storageUnavailable.localizedDescription)
            return
        }
        Task { @MainActor in
            let result = await ShareIngest.stage(providers: providers, into: store)
            let problems = result.rejections.compactMap { $0.errorDescription }
            if result.staged > 0 {
                model.phase = .done(staged: result.staged, problems: problems)
            } else {
                model.phase = .failed(problems.first ?? "Nothing could be handed to HaloShare.")
            }
        }
    }

    // MARK: Closing

    private func finish() { extensionContext?.completeRequest(returningItems: nil) }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    /// Extensions have no public "open my app" call. Walking the responder chain to the host's
    /// `UIApplication` is the established workaround; it can be refused (it is on some iOS
    /// versions), so the UI never *depends* on it — the copy always says how to open Halo by hand.
    private func openHalo() {
        guard let url = URL(string: "halomobile://share") else { return }
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:]) { [weak self] _ in self?.finish() }
                return
            }
            responder = r.next
        }
        finish()
    }
}

// MARK: - SwiftUI

final class ShareExtensionModel: ObservableObject {
    enum Phase: Equatable {
        case staging
        case done(staged: Int, problems: [String])
        case failed(String)
    }
    @Published var phase: Phase = .staging
}

/// The compact sheet inside the share sheet, in Halo's dark card style. It cannot list devices
/// (it has no networking), so the one big button hands over to the app, where the device grid
/// and the Send button are.
struct ShareExtensionView: View {
    @ObservedObject var model: ShareExtensionModel
    let onOpenHalo: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    private let accent = Color(red: 0.31, green: 0.49, blue: 1)
    private let surface = Color(red: 13/255, green: 18/255, blue: 32/255)
    private let amber = Color(red: 0.96, green: 0.65, blue: 0.14)

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.arrow.down.circle.fill").font(.system(size: 28)).foregroundColor(accent)
                Text("HaloShare").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundColor(.white.opacity(0.4)) }
                    .frame(minWidth: 44, minHeight: 44).accessibilityLabel("Close")
            }
            switch model.phase {
            case .staging:
                card {
                    HStack(spacing: 10) { ProgressView().tint(.white); Text("Preparing").foregroundColor(.white) }
                }
            case .done(let staged, let problems):
                card {
                    HStack(spacing: 10) {
                        Image(systemName: "tray.full.fill").foregroundColor(accent)
                        Text(staged == 1 ? "1 item" : "\(staged) items").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                            .accessibilityIdentifier("shareext.done")
                        Spacer()
                        chip("Not sent yet", amber)
                    }
                }
                ForEach(problems, id: \.self) { Text($0).font(.system(size: 12)).foregroundColor(amber).frame(maxWidth: .infinity, alignment: .leading) }
                Spacer(minLength: 0)
                Button(action: onOpenHalo) {
                    Label("Choose device", systemImage: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(colors: [accent, Color(red: 0.48, green: 0.37, blue: 0.65)], startPoint: .leading, endPoint: .trailing)))
                }
                .accessibilityIdentifier("shareext.open")
                Button("Done", action: onDone).foregroundColor(.white.opacity(0.6)).frame(minHeight: 44).accessibilityIdentifier("shareext.close")
            case .failed(let why):
                card {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(amber)
                        Text(why).font(.system(size: 13)).foregroundColor(.white)
                    }
                }
                Spacer(minLength: 0)
                Button("Close", action: onCancel).foregroundColor(.white).frame(minHeight: 44).accessibilityIdentifier("shareext.close")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 8/255, green: 12/255, blue: 20/255))
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundColor(tint)
            .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(tint.opacity(0.14)))
    }
}
