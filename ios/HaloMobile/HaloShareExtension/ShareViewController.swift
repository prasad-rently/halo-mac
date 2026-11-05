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

struct ShareExtensionView: View {
    @ObservedObject var model: ShareExtensionModel
    let onOpenHalo: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(.system(size: 44)).foregroundColor(Color(red: 0.31, green: 0.49, blue: 1))
            switch model.phase {
            case .staging:
                ProgressView().tint(.white)
                Text("Getting your items ready…").foregroundColor(.white)
            case .done(let staged, let problems):
                Text(staged == 1 ? "1 item is ready in Halo" : "\(staged) items are ready in Halo")
                    .font(.headline).foregroundColor(.white).accessibilityIdentifier("shareext.done")
                Text("Nothing has been sent yet. Open Halo, choose a device and tap Send.")
                    .font(.footnote).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)
                ForEach(problems, id: \.self) { Text("• \($0)").font(.footnote).foregroundColor(.orange) }
                Button("Open Halo", action: onOpenHalo).buttonStyle(.borderedProminent).accessibilityIdentifier("shareext.open")
                Button("Done", action: onDone).accessibilityIdentifier("shareext.close")
            case .failed(let why):
                Text("Couldn't hand this to HaloShare").font(.headline).foregroundColor(.white)
                Text(why).font(.footnote).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)
                Button("Close", action: onCancel).buttonStyle(.borderedProminent).accessibilityIdentifier("shareext.close")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 8/255, green: 12/255, blue: 20/255))
    }
}
