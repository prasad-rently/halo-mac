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

/// The sheet page itself. Where the explanations go so primary screens stay glanceable. Honest limits
/// ("Viewer only on iPhone", "not encrypted in transit") belong here — they are moved, never deleted.
struct HaloInfoSheetPage: View {
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
        sheet(isPresented: isPresented) { HaloInfoSheetPage(title: title, summary: summary, points: points) }
    }
}

/// An (i) button that opens a bottom sheet with custom content — `HaloInfoSheet(title: "Cloud") { InfoLine(...) }`.
/// (Same shape as the cloud workstream's shim, so deleting the shim is a no-op for call sites.)
struct HaloInfoSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        HaloInfoButton(title: title) { shown = true }
            .sheet(isPresented: $shown) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) { content }
                            .padding(HaloLayout.screenPadding).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .haloScreen()
                    .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { shown = false } } }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
            }
    }
}

/// One icon + sentence line for use inside `HaloInfoSheet { … }`.
struct InfoLine: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(.haloAccent).frame(width: 22).accessibilityHidden(true)
            Text(text).font(HaloFont.body).foregroundColor(.haloText2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Info sheet") {
    HaloInfoSheetPage(title: "Receiving", summary: "Halo listens while it is open.", points: [
        HaloInfoPoint("hand.raised.fill", .haloGreen, "You decide", "Nothing is saved until you accept."),
        HaloInfoPoint("wifi", .haloAmber, "Wi-Fi only", "Transfers are not encrypted in transit."),
    ])
}
