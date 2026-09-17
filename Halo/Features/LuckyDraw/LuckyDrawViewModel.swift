import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - LuckyDrawViewModel

/// Owns the spin itself. Roster data lives in `LuckyDrawStore`; this holds only the
/// transient state of one draw in flight.
@MainActor
final class LuckyDrawViewModel: ObservableObject {

    /// The wheel's resting rotation between spins, so the next plan starts where the
    /// wheel actually is rather than snapping back to zero.
    @Published private(set) var restAngle: Double = 0
    @Published private(set) var plan: SpinPlan?
    @Published private(set) var spinStart: Date?
    @Published private(set) var isSpinning = false

    @Published var winner: DrawEntry?
    @Published var showWinner = false
    @Published var celebrate = false

    /// Set when Reduced Motion is on at the moment Spin is pressed, so the renderer
    /// and the reveal agree on which presentation they are giving.
    @Published private(set) var reducedMotion = false

    @Published var statusMessage: String?

    /// The wheel's centre in the window's coordinate space, reported by the view.
    /// The confetti overlay spans the whole window, so without this the poppers fire
    /// from the window's corners — half of it lands behind the sidebar.
    var wheelCentre: CGPoint?

    private let store = LuckyDrawStore.shared
    private var finishTask: Task<Void, Never>?

    var canSpin: Bool { !isSpinning && (store.selected?.canSpin ?? false) }

    // MARK: - Spin

    func spin(reduceMotion: Bool) {
        guard !isSpinning, let roster = store.selected else { return }
        let pool = roster.eligible
        guard !pool.isEmpty else { return }

        dismissWinner()
        reducedMotion = reduceMotion

        guard let plan = DrawEngine.plan(for: pool,
                                         currentAngle: restAngle,
                                         duration: roster.spinDuration.seconds) else { return }
        self.plan = plan
        isSpinning = true

        // Reduced Motion gets a different presentation, not a shortened spin: the
        // wheel does not rotate at all, the winning segment is simply highlighted.
        if reduceMotion {
            restAngle = plan.targetAngle
            spinStart = nil
            finishTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(plan: plan, pool: pool)
            }
            return
        }

        spinStart = Date()
        let wait = plan.totalDuration
        finishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(plan: plan, pool: pool)
        }
    }

    private func finish(plan: SpinPlan, pool: [DrawEntry]) {
        isSpinning = false
        spinStart = nil
        restAngle = plan.targetAngle

        guard let won = pool.first(where: { $0.id == plan.winnerID }) else { return }
        winner = won
        store.recordWin(entryID: won.id, label: won.label)

        withAnimation(reducedMotion ? .easeOut(duration: 0.32)
                                    : .spring(response: 0.42, dampingFraction: 0.68)) {
            showWinner = true
        }
        if !reducedMotion {
            CelebrationManager.shared.trigger(.luckyDrawWinner, focus: wheelCentre)
            celebrate = true
        }
        statusMessage = "\(won.label) wins."
        // VoiceOver gets the result spoken, not just rendered — the reveal is the
        // whole point of the feature and it is otherwise purely visual.
        NSAccessibility.post(element: NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: "\(won.label) wins.",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func dismissWinner() {
        finishTask?.cancel()
        finishTask = nil
        withAnimation(.easeOut(duration: 0.2)) { showWinner = false }
        celebrate = false
        winner = nil
    }

    func cancelInFlight() {
        finishTask?.cancel()
        finishTask = nil
        if isSpinning, let plan {
            restAngle = plan.targetAngle
        }
        isSpinning = false
        spinStart = nil
    }

    // MARK: - Post-draw actions

    /// Returns the most recent winner to the wheel, leaving their row in the log.
    func putBackCurrentWinner() {
        guard let roster = store.selected, let row = roster.history.first else { return }
        store.putBack(row)
        dismissWinner()
    }

    func spinAgain(reduceMotion: Bool) {
        dismissWinner()
        // A beat between dismissing the card and the next wind-up, so the two
        // animations read as separate events rather than one stutter.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            spin(reduceMotion: reduceMotion)
        }
    }

    // MARK: - Export

    func exportHistoryCSV() {
        let csv = store.historyCSV()
        guard !csv.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "halo-lucky-draw.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func copyWinner() {
        guard let winner else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(winner.label, forType: .string)
    }
}
