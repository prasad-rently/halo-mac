import Foundation

// MARK: - ShellReader
//
// The one place Halo shells out to a command-line tool. Every `Process` call in
// the app should go through here.
//
// ============================================================================
// WHY THIS EXISTS — three hazards, all of which were present in hand-rolled
// call sites before this type landed.
// ============================================================================
//
// 1. PIPE DEADLOCK. The natural-looking sequence
//
//        try process.run()
//        process.waitUntilExit()                      // <-- blocks here
//        let data = pipe.fileHandleForReading.readDataToEndOfFile()
//
//    deadlocks once the child writes more than the pipe buffer holds (64 KB on
//    Darwin). The child blocks in `write(2)` waiting for someone to drain the
//    pipe; the parent is parked in `waitUntilExit()` and will never get to the
//    read. Neither side can progress, and the actor owning the call is wedged
//    permanently — `Task.cancel()` cannot interrupt a thread blocked in
//    `waitUntilExit()`.
//
//    Measured on the dev machine: `lsof -i -n -P` emits ~10 KB across 87 open
//    connections, so ~550 connections would reach the limit. That is a loaded
//    machine (Docker with many containers, a busy browser) rather than a
//    typical one — latent, not routine, but unrecoverable when it happens.
//
//    `readDataToEndOfFile()` before `waitUntilExit()` fixes stdout, but only
//    stdout: an undrained stderr pipe deadlocks identically. This type
//    multiplexes both descriptors with `poll(2)` on the calling thread, so
//    neither can fill.
//
//    Worth recording why it is done inline rather than with a worker per pipe:
//    dispatching two blocking reads onto `DispatchQueue.global()` and waiting on
//    a `DispatchGroup` reads more naturally, but deadlocks once several calls
//    overlap — each parks two pool threads on a blocking read while a third
//    waits on them, so the pool runs out of threads to execute the drain blocks
//    and `leave()` is never reached. Halo can have several of these in flight at
//    once, and a parallel test run reproduced it immediately. Polling inline
//    uses no worker threads, so there is nothing to starve.
//
// 2. UNDRAINED STDERR. `process.standardError = Pipe()` — a pipe nothing ever
//    reads — is the same trap as (1) with the odds hidden, because stderr is
//    usually empty right up until it isn't. Merging stderr into the *stdout*
//    pipe is worse again: it corrupts the output being parsed, and doubles the
//    pressure on one buffer.
//
// 3. NO TIMEOUT. This is the hazard that survives fixing (1) and (2). A child
//    that never exits — `lsof` blocked on an unresponsive NFS mount, `diskutil`
//    on a failing drive, any tool waiting on a lock — blocks the caller
//    forever regardless of pipe ordering, and `waitUntilExit()` has no timeout
//    parameter. Every call here is bounded, and a child that overruns is sent
//    SIGTERM and then SIGKILL.
//
// ============================================================================
// SANDBOX
// ============================================================================
// Under the App Sandbox (`Halo.entitlements`, the release/App Store
// configuration) `posix_spawn` is denied outright, so `process.run()` throws
// and every call here returns `.launchFailed`. That is reported honestly rather
// than as an empty-but-successful result, so callers can distinguish "the tool
// said nothing" from "we were not allowed to ask" and surface an accurate
// state instead of a misleading zero. See `Result.launchFailure`.

/// Runs a command-line tool and returns its output, with both pipes drained
/// concurrently and a hard timeout.
///
/// Synchronous by design: callers are already inside an `actor` or a detached
/// `Task`, so they are off the main thread and an `async` signature here would
/// only add ceremony. Never call this from the main actor.
enum ShellReader {

    // MARK: - Result

    struct Result: Sendable, Equatable {
        /// Decoded stdout. Empty when the tool wrote nothing, or on launch failure.
        let standardOutput: String
        /// Decoded stderr. Captured separately so it can be surfaced in an error
        /// message without corrupting `standardOutput`.
        let standardError: String
        /// The child's exit status, or -1 if it never launched or was killed.
        let exitCode: Int32
        /// True when the child overran `timeout` and had to be terminated.
        /// Its partial output is still returned.
        let didTimeOut: Bool
        /// True when `process.run()` itself threw — the tool is missing, not
        /// executable, or (most commonly in a release build) the sandbox denied
        /// the spawn. Distinct from "ran and produced nothing".
        let launchFailure: String?

        /// A clean, parseable run: launched, exited 0, and wasn't killed.
        var succeeded: Bool {
            launchFailure == nil && !didTimeOut && exitCode == 0
        }

        /// Convenience for the common "give me the output or nothing" case.
        /// Prefer inspecting `succeeded` where the distinction matters.
        var outputIfSucceeded: String? { succeeded ? standardOutput : nil }

        static func launchFailed(_ message: String) -> Result {
            Result(standardOutput: "", standardError: "", exitCode: -1,
                   didTimeOut: false, launchFailure: message)
        }
    }

    // MARK: - Configuration

    /// Default ceiling for a single command. Generous enough for the slowest
    /// tool Halo invokes (`diskutil info` on a spun-down external drive) while
    /// still bounded — the point is that no call hangs indefinitely, not that
    /// the limit is tight.
    static let defaultTimeout: TimeInterval = 15

    /// Grace period between SIGTERM and SIGKILL when a child overruns.
    private static let terminationGrace: TimeInterval = 2

    // MARK: - Run

    /// - Parameters:
    ///   - executablePath: Absolute path to the tool. Passed to
    ///     `URL(fileURLWithPath:)` — no `PATH` lookup and no shell, so callers
    ///     must give a full path (`/usr/sbin/diskutil`, not `diskutil`).
    ///   - arguments: Passed as an argv array, never string-interpolated into a
    ///     shell command line, so no quoting or escaping is required and
    ///     argument injection isn't possible.
    ///   - timeout: Overrun ceiling. Defaults to `defaultTimeout`.
    @discardableResult
    static func run(_ executablePath: String,
                    _ arguments: [String] = [],
                    timeout: TimeInterval = defaultTimeout) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .launchFailed(error.localizedDescription)
        }

        // Drain both pipes by multiplexing them on THIS thread with poll(2).
        //
        // The obvious alternative — dispatch a blocking readDataToEndOfFile()
        // per pipe onto DispatchQueue.global() and wait on a DispatchGroup —
        // deadlocks under concurrency, and it took a parallel test run to
        // surface it: each call parks two pool threads on a blocking read while
        // a third waits for them, so once enough calls overlap the pool has no
        // thread left to run a drain block, `leave()` is never reached, and the
        // wait never returns. Halo can easily have several of these in flight
        // (the SMART timer, SystemControlsManager's poll loop, an AI tool call).
        //
        // Reading both descriptors inline uses no worker threads at all, so
        // there is nothing to starve — and it gives an accurate deadline, since
        // poll's own timeout is the mechanism rather than a separate timer.
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        var outData = Data()
        var errData = Data()
        var outOpen = true
        var errOpen = true
        var didTimeOut = false

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while outOpen || errOpen {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { didTimeOut = true; break }

            // Which descriptors we're waiting on this round, in a known order
            // so revents can be mapped back.
            var watched: [Int32] = []
            if outOpen { watched.append(outFD) }
            if errOpen { watched.append(errFD) }
            var fds = watched.map {
                pollfd(fd: $0, events: Int16(POLLIN), revents: 0)
            }

            // Cap each wait so the deadline is re-checked regularly even while
            // a child sits silent.
            let sliceMS = Int32(min(remaining * 1000, 250).rounded(.up))
            let ready = poll(&fds, nfds_t(fds.count), sliceMS)

            if ready < 0 {
                if errno == EINTR { continue }   // signal — retry
                break                            // unexpected; stop draining
            }
            if ready == 0 { continue }            // nothing yet; re-check deadline

            for (index, pfd) in fds.enumerated() where pfd.revents != 0 {
                let fd = watched[index]
                // Read until EAGAIN so a readable descriptor is fully emptied
                // before poll is called again.
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    buffer.withUnsafeBufferPointer { raw in
                        let slice = UnsafeRawBufferPointer(
                            start: raw.baseAddress, count: count
                        )
                        if fd == outFD { outData.append(contentsOf: slice) }
                        else { errData.append(contentsOf: slice) }
                    }
                } else {
                    // 0 = EOF (write end closed). <0 with anything other than
                    // EINTR/EAGAIN means the descriptor is done either way.
                    if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    if fd == outFD { outOpen = false } else { errOpen = false }
                }
            }
        }

        if didTimeOut {
            process.terminate()                                   // SIGTERM
            // Give it a moment to go quietly, then insist.
            let graceEnd = Date().addingTimeInterval(terminationGrace)
            while process.isRunning && Date() < graceEnd {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        // Safe to block: either both pipes reached EOF (so the child has closed
        // them and is on its way out) or we just killed it. Reaps the child and
        // makes terminationStatus valid.
        process.waitUntilExit()

        return Result(
            standardOutput: String(data: outData, encoding: .utf8) ?? "",
            standardError: String(data: errData, encoding: .utf8) ?? "",
            exitCode: didTimeOut ? -1 : process.terminationStatus,
            didTimeOut: didTimeOut,
            launchFailure: nil
        )
    }

    /// Shorthand for callers that only care about stdout on a clean run and
    /// treat every failure mode identically. Returns `nil` on launch failure,
    /// timeout, or a non-zero exit.
    ///
    /// Use `run(_:_:timeout:)` directly wherever the caller can give the user a
    /// better answer by knowing *which* of those happened — a sandbox-denied
    /// spawn and a tool that legitimately found nothing deserve different UI.
    static func output(_ executablePath: String,
                       _ arguments: [String] = [],
                       timeout: TimeInterval = defaultTimeout) -> String? {
        run(executablePath, arguments, timeout: timeout).outputIfSucceeded
    }
}
