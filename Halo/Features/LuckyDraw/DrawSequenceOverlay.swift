import SwiftUI

// MARK: - DrawSequenceOverlay

/// The end of a **Draw N in a row** run: every winner, in the order they were drawn.
///
/// One card for the whole run rather than N reveals — each spin already got its own
/// moment on the wheel (the winner is held highlighted for a beat), and this is the
/// accumulated result the user actually wants to copy or read out.
struct DrawSequenceOverlay: View {
    let winners: [DrawEntry]
    /// Set when the run was ended with Stop before it reached its planned length.
    let plannedCount: Int?
    let reducedMotion: Bool
    var onCopy: () -> Void
    var onClose: () -> Void

    @State private var appeared = false

    private var headline: String {
        if let plannedCount, winners.count < plannedCount {
            return "STOPPED AFTER \(winners.count) OF \(plannedCount)"
        }
        return "\(winners.count) WINNERS"
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(headline)
                .font(.system(size: 10, weight: .bold))
                .tracking(2.6)
                .foregroundColor(.haloGreen)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(winners.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.haloText3)
                            .frame(width: 18, alignment: .trailing)
                        Text(entry.label)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(.haloText)
                            .lineLimit(1)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reducedMotion ? 0 : 8)
                    .animation(reducedMotion ? nil
                               : .spring(response: 0.45, dampingFraction: 0.75)
                                   .delay(0.08 + Double(index) * 0.05),
                               value: appeared)
                }
            }
            .frame(maxWidth: 300, alignment: .leading)

            HStack(spacing: 7) {
                Button("Copy list", action: onCopy)
                    .buttonStyle(ResultButtonStyle(prominent: true))
                Button("Close", action: onClose)
                    .buttonStyle(ResultButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.haloBackground.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.haloBorder2, lineWidth: 1))
        )
        .scaleEffect(reducedMotion ? 1 : (appeared ? 1 : 0.9))
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reducedMotion ? .easeOut(duration: 0.3)
                                        : .spring(response: 0.42, dampingFraction: 0.72)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Winners in order: " + winners.map(\.label).joined(separator: ", "))
    }
}
