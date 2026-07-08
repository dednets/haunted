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

            // Accumulate output as it streams so a chatty child can never
            // fill the pipe and deadlock against waiting for termination.
            let collector = OutputCollector()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                collector.appendOut(handle.availableData)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                collector.appendErr(handle.availableData)
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(
                    stdout.fileHandleForReading.readDataToEndOfFile())
                collector.appendErr(
                    stderr.fileHandleForReading.readDataToEndOfFile())
                let (out, err) = collector.snapshot()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let message = String(data: err, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: HauntedCLIError(
                        message: message.isEmpty
                            ? "command failed (\(proc.terminationStatus))"
                            : message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
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

/// Thread-safe stdout/stderr accumulator for HauntedProcessRunner.run
/// (readability handlers and the termination handler fire on different queues).
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
