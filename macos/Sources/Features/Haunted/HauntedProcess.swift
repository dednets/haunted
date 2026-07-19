import Foundation

/// Every child process this app launches — `haunted`, `dedmeshctl`,
/// `haunted-daemon`, `dedmeshd` — goes through here. The argv these calls build
/// is a security boundary (the CLIs have no `--` end-of-options marker, and
/// their arguments carry console-controlled strings), so it has to be
/// observable without actually forking: a test injects a recorder and reads the
/// exact executable and argument array a real launch would have used.
///
/// Three methods rather than one because the callers genuinely differ: a CLI
/// invocation waits and reads stdout, a daemon guard waits and reads only an
/// exit status, and a fire-and-forget spawn has no status at all — a child that
/// outlives this process cannot report one. Collapsing them would force each
/// call site to lie about one of those.
protocol HauntedProcessRunning: Sendable {
    /// Runs `command` through a login shell (the app is often launched from
    /// Finder with no useful PATH) and yields stdout. A nonzero exit throws
    /// `HauntedCLIError` carrying the child's stderr, because that text is what
    /// the CLIs use to explain themselves.
    func run(_ command: String) async throws -> Data

    /// Launches, waits, and reports the child's exit status. A launch that
    /// never happened (missing executable) reports -1: callers treat "did not
    /// run" and "ran and failed" identically, and neither is 0.
    @discardableResult
    func runToCompletion(executable: String, arguments: [String]) -> Int32

    /// Launches without waiting, for a child meant to outlive this launch.
    /// Reports only whether the fork happened — there is no exit status to
    /// wait for, and Foundation does not kill children on `Process` deinit.
    @discardableResult
    func spawnDetached(executable: String, arguments: [String]) -> Bool
}

/// The real thing: `/bin/zsh -lc` and friends. A stateless struct, so `shared`
/// is a `let` and stays trivially Sendable.
///
/// **Never wait on a child with `Process.waitUntilExit`.** It spins the calling
/// thread's run loop waiting for a wakeup that is delivered on a race-prone
/// path; called from a dispatch worker it can miss the termination and block
/// forever even though the child is long gone. That exact hang shipped: the
/// sidebar's poll loop awaited a `run()` whose notify block sat in
/// `waitUntilExit` (`CFRunLoopRun` → `mach_msg`, child exited and reaped),
/// so the sidebar silently stopped refreshing for the life of the app — titles
/// froze and new ⌘T/⌘D sessions never appeared. `terminationHandler` is armed
/// at launch time on a dispatch source and has no such race; the `timeout`
/// deadline below is the belt-and-braces guarantee that no caller can be
/// wedged by one child no matter what.
struct HauntedProcessRunner: HauntedProcessRunning, Sendable {
    static let shared = HauntedProcessRunner()

    /// Ceiling on any single child's lifetime. Every command here is a short
    /// CLI invocation (list/kill finish in ~1s; enroll dials the console once),
    /// so a child alive this long is wedged, not slow — it is killed and the
    /// call throws rather than hanging its caller. Injectable so tests don't
    /// wait half a minute to observe the deadline.
    let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    /// One reader per pipe, each draining to EOF on its own queue, plus the
    /// termination handler, all joined by one group before the result is
    /// assembled.
    ///
    /// The obvious shape — `readabilityHandler` to drain, then
    /// `readDataToEndOfFile` in `terminationHandler` — silently drops bytes.
    /// Setting `readabilityHandler = nil` cancels the dispatch source but does
    /// **not** wait for a block already running: a handler that has returned from
    /// `availableData` with N bytes and not yet taken the collector's lock
    /// appends *after* the snapshot is taken and the continuation resumed. Those
    /// N bytes vanish. Truncated stdout means an empty sidebar; truncated stderr
    /// means a CLI error the user never sees, replaced by "command failed (1)".
    ///
    /// Both readers start before `run()`, so a chatty child can never fill a
    /// ~64 KiB pipe buffer and deadlock against the termination wait.
    ///
    /// A child that outlives `timeout` is SIGKILLed and the call throws. If a
    /// grandchild inherited the pipe write ends and keeps them open past the
    /// kill, the readers stay blocked; a short grace later the call throws
    /// anyway and the blocked readers are abandoned — a bounded leak on a
    /// pathological child, instead of a caller frozen forever.
    func run(_ command: String) async throws -> Data {
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            let collector = OutputCollector()
            let resumer = RunResumer(continuation)
            let pieces = DispatchGroup()
            let queue = DispatchQueue(
                label: "org.thenets.haunted.process-read", attributes: .concurrent)

            pieces.enter() // stdout EOF
            queue.async {
                collector.appendOut(stdout.fileHandleForReading.readDataToEndOfFile())
                pieces.leave()
            }
            pieces.enter() // stderr EOF
            queue.async {
                collector.appendErr(stderr.fileHandleForReading.readDataToEndOfFile())
                pieces.leave()
            }

            // Armed before run(), so an exit can never slip between launch and
            // observation. This slot replaces waitUntilExit — see the type doc.
            pieces.enter() // termination
            process.terminationHandler = { _ in pieces.leave() }

            do {
                try process.run()
            } catch {
                // The readers are blocked on pipes nobody will ever write to.
                // Closing the write ends gives them their EOF so they can exit.
                // The termination slot will never fire for a child that never
                // launched, so balance it by hand.
                process.terminationHandler = nil
                pieces.leave()
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                pieces.notify(queue: queue) {
                    resumer.resume(.failure(error))
                }
                return
            }

            let pid = process.processIdentifier
            queue.asyncAfter(deadline: .now() + timeout) {
                // markTimedOut is false once resumed, so a finished child is
                // never signalled — no window for the pid to have been reused.
                guard resumer.markTimedOut() else { return }
                kill(pid, SIGKILL)
                queue.asyncAfter(deadline: .now() + 2) {
                    // Readers still blocked (a grandchild holds the pipes):
                    // abandon them and fail the call.
                    resumer.resume(.failure(Self.timeoutError(command, timeout)))
                }
            }

            // All three pieces are in: every byte is in hand and the status is
            // valid (the termination handler has run).
            pieces.notify(queue: queue) {
                if resumer.didTimeOut {
                    resumer.resume(.failure(Self.timeoutError(command, timeout)))
                    return
                }
                let (out, err) = collector.snapshot()
                if process.terminationStatus == 0 {
                    resumer.resume(.success(out))
                } else {
                    let message = String(data: err, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    resumer.resume(.failure(HauntedCLIError(
                        message: message.isEmpty
                            ? "command failed (\(process.terminationStatus))"
                            : message)))
                }
            }
        }
    }

    private static func timeoutError(
        _ command: String, _ timeout: TimeInterval
    ) -> HauntedCLIError {
        HauntedCLIError(
            message: "timed out after \(Int(timeout))s: \(command.prefix(80))")
    }

    @discardableResult
    func runToCompletion(executable: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Same reasoning as run(): waitUntilExit can hang forever, and this
        // method is called synchronously on paths (node supervision)
        // that must never wedge. terminationHandler + a bounded semaphore wait.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return -1 }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            // Let the termination handler observe the kill (bounded), then
            // report "did not run to completion" either way.
            _ = exited.wait(timeout: .now() + 2)
            return -1
        }
        return process.terminationStatus
    }

    @discardableResult
    func spawnDetached(executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}

/// Single-shot continuation guard for HauntedProcessRunner.run: the normal
/// completion path and the timeout watchdog race to resume, and exactly one
/// may win. Also carries the timed-out flag so the completion path (which runs
/// after the SIGKILL lands and the pipes close) reports the timeout instead of
/// a meaningless "command failed (9)".
private final class RunResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var timedOut = false

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    /// Marks the run timed out. False if the run already resumed — in which
    /// case the caller must NOT signal the pid, which may already be reused.
    func markTimedOut() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard continuation != nil else { return false }
        timedOut = true
        return true
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func resume(_ result: Result<Data, any Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Thread-safe stdout/stderr accumulator for HauntedProcessRunner.run: the two
/// pipe readers drain on separate queues, and `snapshot()` runs on a third.
private final class OutputCollector: @unchecked Sendable {
    private var out = Data()
    private var err = Data()
    private let lock = NSLock()

    func appendOut(_ data: Data) {
        lock.lock()
        out.append(data)
        lock.unlock()
    }

    func appendErr(_ data: Data) {
        lock.lock()
        err.append(data)
        lock.unlock()
    }

    func snapshot() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (out, err)
    }
}
