import Foundation
import os

// MARK: - AsyncTimeout
//
// A wall-clock ceiling for callback-based work that cannot be cancelled.
//
// ============================================================================
// WHY THIS EXISTS — the idiom it replaces looks right and is not
// ============================================================================
//
// Two features independently wrote this to bound a slow operation:
//
//     await withTaskGroup(of: Value?.self) { group in
//         group.addTask { await theRealWork() }
//         group.addTask {
//             try? await Task.sleep(nanoseconds: timeout)
//             return nil
//         }
//         let first = await group.next() ?? nil
//         group.cancelAll()
//         return first
//     }
//
// It bounds the *value* and not the *time*, for two reasons that compound:
//
//   1. `withTaskGroup` waits for every child task before it returns. Taking
//      `group.next()` and returning from the closure does not abandon the
//      others — the group joins them on the way out.
//
//   2. `group.cancelAll()` only sets a cancellation flag. A child parked in
//      `withCheckedContinuation` around a blocking C call or a framework
//      callback has no cancellation point to observe, so it ignores the flag
//      and runs to completion.
//
// So the sleeper produces `nil` on schedule, and then the group sits on the
// abandoned work anyway. Measured on that exact shape: a 1.5 s "ceiling" over
// 5 s of work returned nil after 5.01 s — the right answer at the wrong time,
// and the time is the half anyone adds a timeout for. Where the work might
// never call back at all, it is worse than useless: the caller blocks forever,
// which is precisely what the timeout was added to prevent.
//
// Both sites had it (F-017 reverse DNS, F-025 PhotoKit thumbnails) and both had
// a plausible-sounding comment claiming the bound it did not deliver. That is
// what makes it worth one documented helper rather than two local fixes.
//
// ============================================================================
// WHAT THIS DOES INSTEAD
// ============================================================================
//
// One continuation, resumed by whichever of the callback or the deadline
// arrives first, behind a one-shot gate.
//
// The gate earns its keep twice over. It stops a late or repeated delivery
// double-resuming the continuation — which is a hard `fatalError`, not a
// recoverable error, and PhotoKit in particular is documented to call a handler
// more than once. And it lets the deadline resume safely when no delivery is
// ever going to come.
//
// **The abandoned work still runs to completion.** Nothing can interrupt a
// thread inside `getnameinfo`, and nothing retracts an in-flight PhotoKit
// request. What this bounds is how long the *caller* waits — which is what
// frees the concurrency slot, keeps a poll loop on cadence, and stops one
// unresponsive item stalling a whole scan. A helper that claimed to stop the
// work would be making the same false promise in a new place.
enum AsyncTimeout {

    /// Runs `start` and returns its first delivered value, or `nil` if
    /// `seconds` elapses first.
    ///
    /// `start` is handed a `deliver` callback and may call it any number of
    /// times, including never:
    ///
    /// * the **first** call wins and resumes the caller;
    /// * every later call is a no-op — safe for a framework that delivers a
    ///   placeholder and then a real result, or that delivers after the
    ///   deadline has already fired;
    /// * **no** call at all still returns `nil` at the deadline.
    ///
    /// `nil` therefore means "no value" without distinguishing "the work said
    /// there is none" from "the work ran out of time". Both call sites already
    /// treat an absent result the same way — an unresolved host, an unhashable
    /// asset — so collapsing them is deliberate. A caller that needs to tell
    /// them apart wants a `Result`-shaped variant, not this.
    ///
    /// Blocking work belongs on a queue of its own inside `start`; this does
    /// not move it off the caller:
    ///
    /// ```swift
    /// await AsyncTimeout.run(seconds: 1.5) { deliver in
    ///     DispatchQueue.global(qos: .utility).async { deliver(blockingLookup()) }
    /// }
    /// ```
    static func run<Value: Sendable>(
        seconds: TimeInterval,
        _ start: @escaping @Sendable (@escaping @Sendable (Value?) -> Void) -> Void
    ) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            @Sendable func deliver(_ value: Value?) {
                let alreadyResumed = resumed.withLock { wasResumed -> Bool in
                    if wasResumed { return true }
                    wasResumed = true
                    return false
                }
                guard !alreadyResumed else { return }
                continuation.resume(returning: value)
            }

            // Armed before `start`, so work that delivers synchronously and work
            // that never delivers are both covered by the same gate.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                deliver(nil)
            }
            start(deliver)
        }
    }

    /// Convenience for synchronous blocking work: runs `work` on a utility
    /// queue and bounds the wait.
    ///
    /// The queue matters. `work` occupies a cooperative-pool thread for its
    /// full duration whether or not anyone is still waiting, so a caller that
    /// runs many of these concurrently should bound that too — see
    /// `NetworkTrafficMonitor.mapConcurrently`.
    static func runBlocking<Value: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () -> Value?
    ) async -> Value? {
        await run(seconds: seconds) { deliver in
            DispatchQueue.global(qos: .utility).async { deliver(work()) }
        }
    }
}
