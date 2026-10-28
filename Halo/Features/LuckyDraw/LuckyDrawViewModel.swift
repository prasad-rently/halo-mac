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
    /// v2.6 C-1: where the winner's avatar sat on the wheel when the spin stopped, for the hero
    /// travel into the popup. Set with `winner`, cleared when the popup is dismissed. Display only.
    @Published private(set) var heroOrigin: WheelHeroOrigin?

    /// Set when Reduced Motion is on at the moment Spin is pressed, so the renderer
    /// and the reveal agree on which presentation they are giving.
    @Published private(set) var reducedMotion = false

    @Published var statusMessage: String?

    // MARK: Draw N in a row (FR-10)

    /// 1 means a single draw; 2…10 runs that many spins back to back.
    @Published var drawCount = 1
    /// Non-nil while a run is in progress.
    @Published private(set) var sequence: DrawSequence?
    /// The winner of a spin *inside* a run, highlighted on the wheel during the short
    /// beat before the next spin. Separate from `winner`/`showWinner` because those also
    /// raise the full result card, and a run shows one card at the end, not N.
    @Published private(set) var interimWinner: DrawEntry?
    /// Set when a run ends (completed or stopped): the accumulated winners, in draw order.
    @Published var sequenceSummary: [DrawEntry]?
    /// How many winners the finished run was planned for, so a run ended early with Stop
    /// can say "stopped after 2 of 5" rather than presenting a short list as complete.
    @Published private(set) var sequenceSummaryPlanned: Int?
    @Published private(set) var sequenceNotice: String?

    /// The wheel's centre in the window's coordinate space, reported by the view.
    /// The confetti overlay spans the whole window, so without this the poppers fire
    /// from the window's corners — half of it lands behind the sidebar.
    var wheelCentre: CGPoint?

    private let store = LuckyDrawStore.shared
    private var finishTask: Task<Void, Never>?
    private var sequenceTask: Task<Void, Never>?

    /// How long a run holds each winner on screen before the next spin starts.
    static let sequenceBeat: UInt64 = 1_500_000_000

    var isSequenceActive: Bool { sequence != nil }
    var canSpin: Bool { !isSpinning && !isSequenceActive && (store.selected?.canSpin ?? false) }

    // MARK: - Spin

    func spin(reduceMotion: Bool) {
        guard !isSpinning, !isSequenceActive, let roster = store.selected else { return }
        guard !roster.eligible.isEmpty else { return }

        dismissWinner()
        sequenceSummary = nil
        sequenceNotice = nil
        if drawCount >= DrawSequence.allowedRange.lowerBound {
            guard let run = DrawSequence(requested: drawCount, eligibleCount: roster.eligible.count) else { return }
            sequence = run
            if run.wasReducedToFit {
                sequenceNotice = "Only \(run.total) on the wheel — drawing \(run.total)."
            }
        }
        runSpin(reduceMotion: reduceMotion)
    }

    /// One spin: either the only one, or the next of a run.
    private func runSpin(reduceMotion: Bool) {
        guard let roster = store.selected else { return }
        let pool = sequence?.pool(from: roster.eligible) ?? roster.eligible
        guard !pool.isEmpty else { endSequence(); return }

        reducedMotion = reduceMotion

        guard let plan = DrawEngine.plan(for: pool,
                                         currentAngle: restAngle,
                                         duration: roster.spinDuration.seconds) else { return }
        self.plan = plan
        isSpinning = true

        // D9: the ratchet only exists where the wheel actually turns, so Reduced Motion
        // (which doesn't rotate it) gets the reveal cue and no ticks.
        if roster.soundEnabled, !reduceMotion {
            LuckyDrawSound.shared.startRatchet(plan: plan, segmentCount: pool.count)
        }

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
        LuckyDrawSound.shared.stop()

        guard let won = pool.first(where: { $0.id == plan.winnerID }) else { return }
        store.recordWin(entryID: won.id, label: won.label)

        // Inside a run: log the winner, hold them on the wheel for a beat, and carry on —
        // the one result card comes at the end, listing everyone.
        if var run = sequence {
            run.record(won)
            sequence = run
            interimWinner = won
            statusMessage = "\(run.winners.count) of \(run.total): \(won.label)"
            announce("\(won.label) wins draw \(run.winners.count) of \(run.total).")
            if run.shouldContinue {
                let reduce = reducedMotion
                sequenceTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.sequenceBeat)
                    guard !Task.isCancelled else { return }
                    self?.interimWinner = nil
                    self?.runSpin(reduceMotion: reduce)
                }
            } else {
                endSequence()
            }
            return
        }

        winner = won
        // Captured before the winner is retired off the wheel (a later redraw has one fewer segment).
        heroOrigin = WheelHeroOrigin(index: plan.winnerIndex, count: pool.count, angle: plan.targetAngle)

        withAnimation(reducedMotion ? .easeOut(duration: 0.32)
                                    : .spring(response: 0.42, dampingFraction: 0.68)) {
            showWinner = true
        }
        if !reducedMotion {
            CelebrationManager.shared.trigger(.luckyDrawWinner, focus: wheelCentre)
            celebrate = true
        }
        statusMessage = "\(won.label) wins."
        if store.selected?.soundEnabled == true { LuckyDrawSound.shared.playFanfare() }
        announce("\(won.label) wins.")
    }

    /// VoiceOver gets the result spoken, not just rendered — the reveal is the whole
    /// point of the feature and it is otherwise purely visual.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Draw N in a row

    /// **Stop** on a run. Does not interrupt a spin already turning — once a draw has
    /// started it finishes (FR-18; interrupting would invite "re-roll until I like it").
    /// It prevents the *next* spin, and if the run is between spins, ends it now.
    func stopSequence() {
        guard var run = sequence else { return }
        run.requestStop()
        sequence = run
        if !isSpinning { endSequence() }
    }

    /// Ends a run — finished or stopped — and raises the winners list.
    private func endSequence() {
        sequenceTask?.cancel()
        sequenceTask = nil
        let winners = sequence?.winners ?? []
        let planned = sequence?.total
        sequence = nil
        interimWinner = nil
        guard !winners.isEmpty else { return }

        sequenceSummary = winners
        sequenceSummaryPlanned = planned
        statusMessage = winners.count == 1 ? "\(winners[0].label) wins." : "\(winners.count) winners drawn."
        if !reducedMotion {
            CelebrationManager.shared.trigger(.luckyDrawWinner, focus: wheelCentre)
            celebrate = true
        }
        if store.selected?.soundEnabled == true { LuckyDrawSound.shared.playFanfare() }
        announce("Drawn in order: " + winners.map(\.label).joined(separator: ", ") + ".")
    }

    func dismissSequenceSummary() {
        withAnimation(.easeOut(duration: 0.2)) { sequenceSummary = nil }
        celebrate = false
    }

    func copyWinnersList() {
        guard let winners = sequenceSummary, !winners.isEmpty else { return }
        let text = winners.enumerated().map { "\($0.offset + 1). \($0.element.label)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func dismissWinner() {
        finishTask?.cancel()
        finishTask = nil
        withAnimation(.easeOut(duration: 0.2)) { showWinner = false }
        celebrate = false
        winner = nil
        heroOrigin = nil
    }

    func cancelInFlight() {
        finishTask?.cancel()
        finishTask = nil
        sequenceTask?.cancel()
        sequenceTask = nil
        sequence = nil
        interimWinner = nil
        LuckyDrawSound.shared.stop()
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

    /// v2.6 C-4: the roster as `name,avatar_kind,avatar_value` — emoji/monogram only, never photos.
    func exportRosterCSV() {
        guard let roster = store.selected else { return }
        let csv = RosterImport.rosterCSV(entries: roster.entries)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(roster.name)-roster.csv"
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
