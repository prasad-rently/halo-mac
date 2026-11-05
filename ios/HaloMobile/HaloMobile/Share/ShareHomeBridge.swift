import SwiftUI
import Combine

/// Publishes "N items waiting to send" (Share Extension / pickers) into Home's `HomeBridge`.
/// Only counts and bytes cross this boundary — never file names.
struct ShareHomeBridge: ViewModifier {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var bridge: HomeBridge

    func body(content: Content) -> some View {
        content
            .onAppear { publish() }
            .onReceive(model.objectWillChange.debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)) { _ in publish() }
    }

    private func publish() {
        let next: HomePendingShare? = model.outbox.map {
            HomePendingShare(itemCount: $0.files.count, totalBytes: $0.totalBytes, moreBatches: model.otherStagedBatchCount)
        }
        if bridge.pendingShare != next { bridge.pendingShare = next }
    }
}
