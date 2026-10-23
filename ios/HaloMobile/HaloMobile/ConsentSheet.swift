import SwiftUI
import HaloShareKit

/// MR-RX-2: nothing is written until the person says yes. Shows who, how many, how big, and names.
struct ConsentSheet: View {
    @EnvironmentObject var model: AppModel
    let offer: IncomingOffer

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 40)).foregroundColor(.haloAccent)
            VStack(spacing: 4) {
                Text("\(offer.sender.alias) wants to send you")
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(.haloText)
                    .multilineTextAlignment(.center)
                Text("\(offer.files.count) file\(offer.files.count == 1 ? "" : "s") · \(Bytes.string(offer.totalBytes))")
                    .font(.system(size: 14)).foregroundColor(.haloText2)
                Text("from \(offer.senderAddress)").font(.system(size: 11)).foregroundColor(.haloText3)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("consent.summary")

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(offer.files.prefix(50), id: \.id) { file in
                        HStack {
                            Image(systemName: "doc").foregroundColor(.haloText3)
                            Text(file.fileName).font(.system(size: 13)).foregroundColor(.haloText).lineLimit(1)
                            Spacer()
                            Text(Bytes.string(file.size)).font(.system(size: 11)).foregroundColor(.haloText3)
                        }
                    }
                    if offer.files.count > 50 {
                        Text("and \(offer.files.count - 50) more…").font(.system(size: 12)).foregroundColor(.haloText3)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.haloSurface))

            HStack(spacing: 12) {
                Button(role: .cancel) { model.resolveConsent(.decline) } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("consent.decline")

                Button { model.resolveConsent(.accept) } label: {
                    Text("Accept").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("consent.accept")
            }
            .controlSize(.large)

            Text("Only accept from people you know. Files are saved to Halo's Received folder.")
                .font(.system(size: 11)).foregroundColor(.haloText3).multilineTextAlignment(.center)
        }
        .padding(22)
        .presentationDetents([.medium, .large])
        .background(Color.haloBackground.ignoresSafeArea())
    }
}
