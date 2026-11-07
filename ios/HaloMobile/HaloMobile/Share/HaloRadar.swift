import SwiftUI

/// Radar graphic for the Share screen: concentric rings, this phone in the middle, one dot per
/// nearby device, and a pulse while a scan is running. The pulse is static under Reduce Motion.
struct HaloRadar: View {
    var isScanning: Bool
    var peerIDs: [String]
    var size: CGFloat = 148
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach([1.0, 0.68, 0.36], id: \.self) { scale in
                Circle().stroke(Color.haloAccent.opacity(0.10 + 0.08 * (1 - scale)), lineWidth: 1)
                    .frame(width: size * scale, height: size * scale)
            }
            if isScanning {
                Circle().stroke(Color.haloAccent.opacity(reduceMotion ? 0.35 : (pulse ? 0 : 0.6)), lineWidth: 2)
                    .frame(width: size * (reduceMotion ? 0.8 : (pulse ? 1.0 : 0.25)),
                           height: size * (reduceMotion ? 0.8 : (pulse ? 1.0 : 0.25)))
            }
            ForEach(Array(peerIDs.prefix(8).enumerated()), id: \.element) { i, id in
                let angle = Double(abs(id.hashValue % 360)) * .pi / 180 + Double(i) * 0.9
                let r = size * (i % 2 == 0 ? 0.34 : 0.22)
                Circle().fill(Color.haloGreen).frame(width: 10, height: 10)
                    .shadow(color: Color.haloGreen.opacity(0.7), radius: 4)
                    .offset(x: CGFloat(cos(angle)) * r, y: CGFloat(sin(angle)) * r)
            }
            Image(systemName: "iphone")
                .font(.system(.body).weight(.semibold)).foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(LinearGradient(colors: [.haloAccent, .haloAccent2], startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
        .frame(width: size, height: size)
        .onAppear { restartPulse() }
        .onChange(of: isScanning) { _ in restartPulse() }
        .accessibilityHidden(true)
    }

    private func restartPulse() {
        pulse = false
        guard isScanning, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
    }
}

#Preview("Radar") {
    HStack {
        HaloRadar(isScanning: true, peerIDs: ["a", "b", "c"])
        HaloRadar(isScanning: false, peerIDs: [])
    }.padding().haloScreen()
}
