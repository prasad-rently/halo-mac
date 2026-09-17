import SwiftUI

// MARK: - LuckyDrawView

struct LuckyDrawView: View {
    @StateObject private var viewModel = LuckyDrawViewModel()
    @ObservedObject private var store = LuckyDrawStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showFairness = false
    @State private var addFieldIsFocused = false
    @State private var renaming = false
    @State private var rosterName = ""

    private var roster: DrawRoster? { store.selected }
    private var pool: [DrawEntry] { roster?.eligible ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.haloBorder)
            HStack(spacing: 0) {
                stage
                Divider().overlay(Color.haloBorder)
                RosterPanelView(store: store, viewModel: viewModel,
                                addFieldIsFocused: $addFieldIsFocused)
                    .frame(width: 312)
            }
        }
        .background(Color.haloSurface)
        .onDisappear { viewModel.cancelInFlight() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { store.selectedRosterID ?? store.rosters.first?.id ?? UUID() },
                        set: { store.selectedRosterID = $0 }
                    )) {
                        ForEach(store.rosters) { r in
                            Text(r.name).tag(r.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 190)

                    Button {
                        store.addRoster()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.haloText3)
                    .help("New roster")

                    if store.rosters.count > 1 {
                        Button {
                            store.deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.haloText3)
                        .help("Delete this roster")
                    }
                }
                Text("\(pool.count) on the wheel · \(roster?.history.count ?? 0) drawn")
                    .font(.system(size: 11))
                    .foregroundColor(.haloText3)
            }

            Spacer()

            Button {
                showFairness.toggle()
            } label: {
                Label("Fairness", systemImage: "die.face.5")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.haloText2)
            .popover(isPresented: $showFairness, arrowEdge: .bottom) {
                fairnessNote
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.haloSurface)
    }

    private var fairnessNote: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("How the winner is picked")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.haloText)
            Text("""
                 The winner is drawn from the system's cryptographic random generator \
                 **before the wheel starts moving**, and the wheel is then animated to \
                 a pre-computed angle.

                 Every entry on the wheel has identical odds. Nothing about the spin — \
                 its speed, its length, where it appears to slow down — influences the \
                 result, and a spin in progress can't be interrupted.

                 Excluded and already-drawn entries are not in the pool. No result ever \
                 leaves this Mac.
                 """)
                .font(.system(size: 11.5))
                .foregroundColor(.haloText2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
        .background(Color.haloSurface2)
    }

    // MARK: - Stage

    private var stage: some View {
        ZStack {
            VStack(spacing: 18) {
                Spacer(minLength: 8)

                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    SpinnerWheelView(entries: pool,
                                     plan: viewModel.plan,
                                     spinStart: viewModel.spinStart,
                                     restAngle: viewModel.restAngle,
                                     highlightID: viewModel.showWinner ? viewModel.winner?.id : nil,
                                     reducedMotion: viewModel.reducedMotion)
                        .frame(width: side, height: side)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            GeometryReader { wheelGeo in
                                Color.clear.preference(
                                    key: WheelCentreKey.self,
                                    value: CGPoint(x: wheelGeo.frame(in: .global).midX,
                                                   y: wheelGeo.frame(in: .global).midY))
                            }
                        )
                }
                .onPreferenceChange(WheelCentreKey.self) { viewModel.wheelCentre = $0 }
                .frame(maxHeight: 460)

                VStack(spacing: 8) {
                    Button {
                        viewModel.spin(reduceMotion: reduceMotion)
                    } label: {
                        Text(viewModel.isSpinning ? "Drawing…" : "Spin the wheel")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(SpinButtonStyle())
                    .disabled(!viewModel.canSpin)
                    // Nil while the name field has focus, so typing "Anna Maria" adds
                    // one entry rather than spinning the wheel mid-word.
                    .keyboardShortcut(addFieldIsFocused ? nil
                                                        : KeyboardShortcut(.space, modifiers: []))

                    Text(hintText)
                        .font(.system(size: 10.5))
                        .foregroundColor(.haloText3)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 24)

            if viewModel.showWinner, let winner = viewModel.winner {
                DrawResultOverlay(
                    label: winner.label,
                    reducedMotion: viewModel.reducedMotion,
                    canPutBack: roster?.autoRetireWinner ?? true,
                    onSpinAgain: { viewModel.spinAgain(reduceMotion: reduceMotion) },
                    onPutBack: { viewModel.putBackCurrentWinner() },
                    onCopy: { viewModel.copyWinner() },
                    onClose: { viewModel.dismissWinner() }
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(colors: [Color.haloAccent.opacity(0.07), .clear],
                           center: .center, startRadius: 10, endRadius: 360)
        )
    }

    private var hintText: String {
        if pool.isEmpty {
            return store.canReset
                ? "Everyone has been drawn — Reset, or put someone back."
                : "Add a name to get started."
        }
        if roster?.autoRetireWinner == true {
            return "Space to spin · winners are retired, and can be put back"
        }
        return "Space to spin · winners stay on the wheel"
    }
}

// MARK: - WheelCentreKey

/// Carries the wheel's window-space centre up to the view model, so the celebration
/// overlay — which spans the whole window — can aim its poppers at the wheel.
private struct WheelCentreKey: PreferenceKey {
    static var defaultValue: CGPoint?
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        value = nextValue() ?? value
    }
}

// MARK: - SpinButtonStyle

private struct SpinButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(LinearGradient(colors: [Color(hex: "#5b86ff"), Color(hex: "#3a63e6")],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color.haloAccent.opacity(isEnabled ? 0.55 : 0),
                            radius: configuration.isPressed ? 8 : 16, y: 6)
            )
            // The press compression is the wind-up's other half: the button loads at
            // the same moment the wheel recoils.
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .saturation(isEnabled ? 1 : 0.25)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
