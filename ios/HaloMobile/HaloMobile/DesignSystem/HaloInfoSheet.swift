import SwiftUI

/// The (i) button that sits next to a header and opens a `HaloInfoSheet`.
struct HaloInfoButton: View {
    var title: String
    let action: () -> Void

    var body: some View {
        Button { HaloHaptics.tap(); action() } label: {
            Image(systemName: "info.circle")
                .font(.system(.footnote).weight(.semibold))
                .foregroundColor(.haloText3)
                .frame(width: HaloLayout.minTarget, height: HaloLayout.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -10).padding(.horizontal, -8)      // keep the 44pt hit area, not 44pt of layout
        .accessibilityLabel("About \(title)")
    }
}

/// One point inside an info sheet: icon, bold lead, supporting text.
struct HaloInfoPoint: Identifiable {
    let id = UUID()
    var icon: String
    var tint: Color
    var title: String
    var text: String
    init(_ icon: String, _ tint: Color = .haloAccent, _ title: String, _ text: String) {
        self.icon = icon; self.tint = tint; self.title = title; self.text = text
    }
}

/// Where the explanations go so primary screens stay glanceable. Honest limits ("Viewer only on
/// iPhone", "not encrypted in transit") belong here — they are moved, never deleted.
struct HaloInfoSheet: View {
    var title: String
    var icon: String = "info.circle.fill"
    var summary: String?
    var points: [HaloInfoPoint]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let summary {
                        Text(summary).font(HaloFont.body).foregroundColor(.haloText2)
                    }
                    ForEach(points) { p in
                        HaloCard {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: p.icon).foregroundColor(p.tint)
                                    .frame(width: 28).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(p.title).font(HaloFont.headline).foregroundColor(.haloText)
                                    Text(p.text).font(HaloFont.body).foregroundColor(.haloText2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(HaloLayout.screenPadding)
            }
            .haloScreen()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// `.haloInfoSheet(isPresented: $show, title: …, points: […])`
    func haloInfoSheet(isPresented: Binding<Bool>, title: String, summary: String? = nil, points: [HaloInfoPoint]) -> some View {
        sheet(isPresented: isPresented) { HaloInfoSheet(title: title, summary: summary, points: points) }
    }
}

#Preview("Info sheet") {
    HaloInfoSheet(title: "Receiving", summary: "Halo listens while it is open.", points: [
        HaloInfoPoint("hand.raised.fill", .haloGreen, "You decide", "Nothing is saved until you accept."),
        HaloInfoPoint("wifi", .haloAmber, "Wi-Fi only", "Transfers are not encrypted in transit."),
    ])
}
