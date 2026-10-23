import Foundation
import AVFoundation

// MARK: - RatchetSchedule

/// When the ratchet **tick** fires during a spin (D9, spec §8.11).
///
/// The wheel's angle is a pure function of elapsed time (`SpinnerAnimator.frame`), so the
/// moments the pointer crosses a segment boundary can be computed *up front* from the
/// plan, with no audio-clock or display-link coupling: sample the angle densely, and every
/// time `DrawEngine.segmentIndex` changes, that is a crossing.
///
/// The spec's cap is **20 ticks a second**. At cruise speed a 200-entry wheel crosses
/// hundreds of boundaries a second; unthrottled that is a buzz rather than a ratchet, and
/// worse, a burst of thousands of sound starts. Anything past the cap is dropped, which is
/// also what makes the slowing-down audible: the tick rate falls away from the cap as the
/// wheel decelerates, then each remaining crossing becomes a distinct, countable click.
enum RatchetSchedule {

    static let maxTicksPerSecond = 20.0
    static var minimumInterval: Double { 1 / maxTicksPerSecond }

    /// Sampling rate for crossing detection. A boundary crossing is found to within one
    /// sample (≈4 ms), well under the 50 ms tick spacing, so the quantisation is inaudible.
    static let sampleRate = 240.0

    /// Offsets in seconds from the start of the spin at which to play a tick.
    static func tickTimes(for plan: SpinPlan, segmentCount: Int) -> [Double] {
        guard segmentCount > 1 else { return [] }

        var times: [Double] = []
        var lastTick = -Double.infinity
        var lastIndex = DrawEngine.segmentIndex(atAngle: plan.fromAngle, count: segmentCount)

        // The wind-up does not rotate the *model* angle (the recoil is a render offset),
        // so there is nothing to tick before the launch.
        var t = SpinPlan.windupDuration
        let end = plan.totalDuration
        let step = 1 / sampleRate
        while t <= end {
            let frame = SpinnerAnimator.frame(for: plan, elapsed: t)
            let index = DrawEngine.segmentIndex(atAngle: frame.angle, count: segmentCount)
            if index != lastIndex {
                lastIndex = index
                if t - lastTick >= minimumInterval {
                    times.append(t)
                    lastTick = t
                }
            }
            t += step
        }
        return times
    }
}

// MARK: - SoundSynth

/// The two cues, synthesised in code.
///
/// There is deliberately no audio asset in the bundle: the sounds are a few dozen
/// milliseconds of decaying sine, which is smaller as code than as a licensed file, has
/// no provenance question, and is deterministic — so the tests can assert the exact
/// properties that matter (non-silent, never clipping, decays to silence) instead of
/// trusting that a binary blob was exported correctly.
enum SoundSynth {

    static let sampleRate = 44_100

    /// A short, dry click: one fast-decaying sine, ~25 ms. Quiet on purpose — it fires up
    /// to 20 times a second.
    static func tickSamples() -> [Float] {
        sine(partials: [(frequency: 1900, gain: 0.8), (frequency: 3800, gain: 0.2)],
             duration: 0.025, decayTime: 0.0045, amplitude: 0.45)
    }

    /// A soft rising arpeggio (C5–E5–G5–C6) with each note ringing out — one cue at the
    /// reveal, not a jingle.
    static func fanfareSamples() -> [Float] {
        let notes: [(Double, Double)] = [(523.25, 0.00), (659.25, 0.11), (783.99, 0.22), (1046.5, 0.33)]
        let total = 1.05
        var mix = [Float](repeating: 0, count: Int(total * Double(sampleRate)))
        for (frequency, start) in notes {
            let note = sine(partials: [(frequency: frequency, gain: 0.75),
                                       (frequency: frequency * 2, gain: 0.25)],
                            duration: 0.6, decayTime: 0.20, amplitude: 0.32)
            let offset = Int(start * Double(sampleRate))
            for (i, v) in note.enumerated() where offset + i < mix.count {
                mix[offset + i] += v
            }
        }
        return mix
    }

    private static func sine(partials: [(frequency: Double, gain: Double)],
                             duration: Double, decayTime: Double,
                             amplitude: Double) -> [Float] {
        let count = Int(duration * Double(sampleRate))
        let attack = 0.0015   // a hard start clicks; 1.5 ms is enough to remove the pop
        return (0..<count).map { i in
            let t = Double(i) / Double(sampleRate)
            let envelope = min(t / attack, 1) * exp(-t / decayTime)
            var v = 0.0
            for p in partials { v += p.gain * sin(2 * .pi * p.frequency * t) }
            return Float(v * envelope * amplitude)
        }
    }

    /// 16-bit mono PCM in a minimal RIFF/WAVE container.
    static func wav(from samples: [Float]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            var v = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        func u32(_ x: Int) -> Data { var v = UInt32(x).littleEndian; return Data(bytes: &v, count: 4) }
        func u16(_ x: Int) -> Data { var v = UInt16(x).littleEndian; return Data(bytes: &v, count: 2) }

        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.append(u32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.append(u32(16))
        d.append(u16(1)); d.append(u16(1))                       // PCM, mono
        d.append(u32(sampleRate)); d.append(u32(sampleRate * 2)) // rate, byte rate
        d.append(u16(2)); d.append(u16(16))                      // block align, bits
        d.append(contentsOf: Array("data".utf8)); d.append(u32(pcm.count))
        d.append(pcm)
        return d
    }
}

// MARK: - LuckyDrawSound

/// Plays the cues. The first audio Halo has ever produced, so everything about it is
/// opt-in: it does nothing unless the roster's Sound toggle is on, and the toggle
/// defaults to off.
@MainActor
final class LuckyDrawSound {
    static let shared = LuckyDrawSound()

    private var tickPlayers: [AVAudioPlayer] = []
    private var nextTick = 0
    private var fanfarePlayer: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?

    /// A small pool, because a tick lasts 25 ms and two can overlap at the 20/s cap.
    private static let tickPoolSize = 4

    private init() {}

    private func prepareIfNeeded() {
        if tickPlayers.isEmpty {
            let data = SoundSynth.wav(from: SoundSynth.tickSamples())
            tickPlayers = (0..<Self.tickPoolSize).compactMap { _ in
                let p = try? AVAudioPlayer(data: data)
                p?.volume = 0.7
                p?.prepareToPlay()
                return p
            }
        }
        if fanfarePlayer == nil {
            fanfarePlayer = try? AVAudioPlayer(data: SoundSynth.wav(from: SoundSynth.fanfareSamples()))
            fanfarePlayer?.volume = 0.6
            fanfarePlayer?.prepareToPlay()
        }
    }

    /// Starts the ratchet for a spin that has just begun. Cancel with `stop()`.
    func startRatchet(plan: SpinPlan, segmentCount: Int) {
        stop()
        prepareIfNeeded()
        let times = RatchetSchedule.tickTimes(for: plan, segmentCount: segmentCount)
        guard !times.isEmpty else { return }

        let start = Date()
        tickTask = Task { [weak self] in
            for t in times {
                let wait = t - Date().timeIntervalSince(start)
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                guard !Task.isCancelled, let self else { return }
                self.playTick()
            }
        }
    }

    func playFanfare() {
        prepareIfNeeded()
        fanfarePlayer?.currentTime = 0
        fanfarePlayer?.play()
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func playTick() {
        guard !tickPlayers.isEmpty else { return }
        let player = tickPlayers[nextTick % tickPlayers.count]
        nextTick += 1
        player.currentTime = 0
        player.play()
    }
}
