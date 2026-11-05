import SwiftUI
import HaloShareKit

/// MR-RX-2: nothing is written until the person says yes. Shows who, how many, how big, and names.
struct ConsentSheet: View {
    @EnvironmentObject var model: AppModel
    let offer: IncomingOffer

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 40)).foregroundColor(.haloAccent)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("\(offer.sender.alias) wants to send you")
                        .font(HaloFont.title).foregroundColor(.haloText).multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        HaloChip(text: "\(offer.files.count) file\(offer.files.count == 1 ? "" : "s")", icon: "doc.on.doc", tint: .haloAccent)
                        HaloChip(text: Bytes.string(offer.totalBytes), icon: "scalemass", tint: .haloCyan)
                    }
                    Text("from \(offer.senderAddress)").font(HaloFont.mono).foregroundColor(.haloText3)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("consent.summary")

                HaloCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(offer.files.prefix(50).enumerated()), id: \.element.id) { i, file in
                            if i > 0 { HaloRowDivider(inset: 14) }
                            HStack(spacing: 10) {
                                Image(systemName: "doc").foregroundColor(.haloText3).accessibilityHidden(true)
                                Text(file.fileName).font(HaloFont.body).foregroundColor(.haloText).lineLimit(2)
                                Spacer(minLength: 8)
                                Text(Bytes.string(file.size)).font(HaloFont.caption).foregroundColor(.haloText2).fixedSize()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        if offer.files.count > 50 {
                            Text("and \(offer.files.count - 50) \(HaloStrings.Consent.moreFiles)")
                                .font(HaloFont.caption).foregroundColor(.haloText3).padding(10)
                        }
                    }
                }

                HStack(spacing: 12) {
                    HaloSecondaryButton(HaloStrings.Consent.decline, icon: "xmark") { model.resolveConsent(.decline) }
                        .accessibilityIdentifier("consent.decline")
                    HaloPrimaryButton(HaloStrings.Consent.accept, icon: "checkmark") { model.resolveConsent(.accept) }
                        .accessibilityIdentifier("consent.accept")
                }

                Text(HaloStrings.Consent.footer).font(HaloFont.caption).foregroundColor(.haloText3)
            }
            .padding(22)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .haloScreen()
    }
}
