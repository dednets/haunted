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
struct HauntedProcessRunner: HauntedProcessRunning, Sendable {
    static let shared = HauntedProcessRunner()

    /// One reader per pipe, each draining to EOF on its own queue, joined by a
    /// group before the result is assembled.
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
    /// ~64 KiB pipe buffer and deadlock against `waitUntilExit`.
    ///
    /// Known limitation: if the child spawns a grandchild that inherits the pipe
    /// write end, EOF waits for the grandchild too. Every command here is a short
    /// CLI invocation, and `spawnDetached` is the path for anything that outlives
    /// us.
    func run(_ command: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            let collector = OutputCollector()
            let readers = DispatchGroup()
            let queue = DispatchQueue(
                label: "org.thenets.haunted.process-read", attributes: .concurrent)

            readers.enter()
            queue.async {
                collector.appendOut(stdout.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
            readers.enter()
            queue.async {
                collector.appendErr(stderr.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }

            do {
                try process.run()
            } catch {
                // The readers are blocked on pipes nobody will ever write to.
                // Closing the write ends gives them their EOF so they can exit.
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                readers.wait()
                continuation.resume(throwing: error)
                return
            }

            // Both pipes are at EOF, so the child's every byte is in hand before
            // its status is read. `waitUntilExit` cannot block: EOF already
            // implies the write ends are closed.
            readers.notify(queue: queue) {
                process.waitUntilExit()
                let (out, err) = collector.snapshot()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let message = String(data: err, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: HauntedCLIError(
                        message: message.isEmpty
                            ? "command failed (\(process.terminationStatus))"
                            : message))
                }
            }
        }
    }

    @discardableResult
    func runToCompletion(executable: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
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
