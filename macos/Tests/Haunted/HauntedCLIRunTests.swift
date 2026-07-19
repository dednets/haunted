import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.1 — RUN-01…08 and `HauntedCLI.resolve`.
///
/// The RUN-* cases drive `HauntedProcessRunner.run` — the real implementation
/// behind the §5.1 seam — against real, short-lived `/bin/zsh` children. That is
/// deliberate: `run` *is* the subject here, and the properties under test
/// (pipe-buffer deadlock, `nullDevice` stdin, exit-status → `HauntedCLIError`
/// mapping) exist only in the presence of an actual `Process`. Every other
/// Haunted suite injects `FakeProcessRunner` instead.
///
/// Two things every RUN-* case relies on:
///
///  1. **Bounded waits.** RUN-04/05 are regression tests for a deadlock: a pipe
///     buffer is ~64 KiB, so a `run` that waited for termination *before*
///     draining the pipes would hang forever on a 1 MiB child. `run` is built on
///     a non-cancellable `withCheckedThrowingContinuation`, so a task group
///     cannot rescue us — the group would wait for its stuck child. `withDeadline`
///     therefore parks the work on a detached task and polls for a result, so a
///     regression *fails the suite* instead of wedging the whole test run. (The
///     wedged child task leaks for the life of the process. That is the price of
///     observing a hang at all, and it only happens when the test is already red.)
///
///  2. **A quiet login shell.** `run` executes `/bin/zsh -lc`, which sources
///     `/etc/zshenv`, `~/.zshenv`, `/etc/zprofile` and `~/.zprofile`. Anything
///     those print on stdout is indistinguishable from the child's own output —
///     to `run`, and to `HauntedCLI.decodeNodes` in production. The exact
///     byte assertions below are the contract, not a flake: a `~/.zprofile` that
///     echoes also breaks `dedmeshctl haunted -json`.
struct HauntedCLIRunTests {
    // MARK: - RUN-01…03: exit status and stderr mapping

    @Test("RUN-01: child exits 0 → stdout is returned verbatim")
    func runReturnsStdout() async throws {
        let data = try await runShell(#"printf '%s' '{"a":1}'"#, label: "RUN-01")
        #expect(data == Data(#"{"a":1}"#.utf8))
    }

    @Test("RUN-02: nonzero exit with stderr → HauntedCLIError carrying stderr")
    func runMapsStderrToError() async throws {
        let error = try await runShellExpectingFailure(
            "printf 'boom' >&2; exit 3", label: "RUN-02")
        #expect(error.message == "boom")
    }

    /// `run` trims the stderr text, so the CLI's own trailing newline never
    /// reaches the alert the user reads.
    @Test("RUN-02b: stderr is trimmed, not passed through raw")
    func runTrimsStderr() async throws {
        let error = try await runShellExpectingFailure(
            "echo '  boom  ' >&2; exit 1", label: "RUN-02b")
        #expect(error.message == "boom")
    }

    @Test("RUN-03: nonzero exit with empty stderr → \"command failed (3)\"")
    func runFallsBackToExitStatusMessage() async throws {
        let error = try await runShellExpectingFailure("exit 3", label: "RUN-03")
        #expect(error.message == "command failed (3)")
    }

    /// Whitespace-only stderr trims to empty, so it must take the same fallback
    /// as no stderr at all — otherwise the user gets an alert saying `"\n"`.
    @Test("RUN-03b: whitespace-only stderr still falls back to the exit status")
    func runTreatsWhitespaceStderrAsEmpty() async throws {
        let error = try await runShellExpectingFailure(
            "printf '\\n \\n' >&2; exit 9", label: "RUN-03b")
        #expect(error.message == "command failed (9)")
    }

    // MARK: - RUN-04/05: the reason OutputCollector exists

    /// A pipe buffer is ~64 KiB. Before the streaming `readabilityHandler`, a
    /// child writing more than that filled the pipe and blocked in `write(2)`
    /// while the parent blocked waiting for it to exit. 1 MiB is ~16 buffers, so
    /// a regression cannot squeak through. On regression this test does not hang
    /// the run — it exceeds its deadline and fails.
    @Test("RUN-04: 1 MiB on stdout does not deadlock and arrives whole")
    func runDrainsLargeStdout() async throws {
        let data = try await runShell(
            "head -c \(oneMiB) /dev/zero | tr '\\0' x",
            label: "RUN-04",
            seconds: 30)
        #expect(data.count == oneMiB)
        let allFill = data.allSatisfy { $0 == UInt8(ascii: "x") }
        #expect(allFill)
    }

    /// Same deadlock, opposite pipe: stderr is only read inside the termination
    /// handler, so an undrained stderr wedges a child that never gets to exit.
    @Test("RUN-05: 1 MiB on stderr with a nonzero exit does not deadlock")
    func runDrainsLargeStderr() async throws {
        let error = try await runShellExpectingFailure(
            "head -c \(oneMiB) /dev/zero | tr '\\0' x >&2; exit 7",
            label: "RUN-05",
            seconds: 30)
        // Nothing to trim: 1 MiB of 'x'. If the collector dropped bytes this is
        // short; if it deadlocked we never got here.
        #expect(error.message.utf8.count == oneMiB)
    }

    // MARK: - RUN-06: launch failures

    /// `run` always launches `/bin/zsh`, so "executable does not exist" reaches
    /// it as a shell that exits 127 — it must surface as a thrown
    /// `HauntedCLIError`, promptly, not as an empty success.
    @Test("RUN-06: missing binary inside the command throws and does not hang")
    func runThrowsForMissingCommand() async throws {
        let missing = "/nonexistent-\(UUID().uuidString)/haunted"
        let error = try await runShellExpectingFailure(
            "'\(missing)' --version", label: "RUN-06", seconds: 30)
        // zsh explains itself on stderr ("no such file or directory: …"), and
        // that explanation is what the user sees — so it must reach the error,
        // not be flattened into the generic exit-status fallback.
        #expect(!error.message.isEmpty)
        #expect(error.message != "command failed (127)")
    }

    /// The other two seam methods take an executable path directly, so for them
    /// `Process.run()` really does throw. `runToCompletion` must report -1 (never
    /// 0 — callers read `== 0` as "the daemon is up") and `spawnDetached` false.
    @Test("RUN-06b: a missing executable is -1 / false, never a success")
    func launchFailuresAreNotSuccesses() {
        let missing = "/nonexistent-\(UUID().uuidString)/haunted-daemon"
        let runner = HauntedProcessRunner.shared
        #expect(runner.runToCompletion(executable: missing, arguments: ["--daemonize"]) == -1)
        #expect(runner.spawnDetached(executable: missing, arguments: ["--daemonize"]) == false)
    }

    @Test("RUN-06c: runToCompletion reports the child's real exit status")
    func runToCompletionReportsStatus() {
        let runner = HauntedProcessRunner.shared
        #expect(runner.runToCompletion(executable: "/bin/sh", arguments: ["-c", "exit 0"]) == 0)
        #expect(runner.runToCompletion(executable: "/bin/sh", arguments: ["-c", "exit 5"]) == 5)
    }

    // MARK: - RUN-07: concurrency

    /// 32 concurrent `run` calls, each producing ~200 KiB (well past a pipe
    /// buffer, so every one of them is bouncing between a readability handler
    /// and a termination handler on different queues at the same time).
    ///
    /// This is NOT a ThreadSanitizer run — TSan needs a separately instrumented
    /// build of the whole test host, which is out of scope for this suite. What
    /// it does assert is the observable consequence of a race in
    /// `OutputCollector`: a crash, a short read, or bytes from one child landing
    /// in another child's `Data`. Each child emits a distinct fill byte, so
    /// cross-talk is detectable rather than merely improbable. Run the suite
    /// under `-enableThreadSanitizer YES` to get the real thing.
    @Test("RUN-07: 32 concurrent run() calls do not crash or corrupt output")
    func concurrentRunsDoNotCorruptOutput() async throws {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEF")
        #expect(letters.count == 32)

        let results = try await withDeadline("RUN-07", seconds: 180) {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (index, letter) in letters.enumerated() {
                    group.addTask {
                        let data = try await HauntedProcessRunner.shared.run(
                            "head -c \(concurrentPayload) /dev/zero | tr '\\0' '\(letter)'")
                        return (index, data)
                    }
                }
                var collected: [Int: Data] = [:]
                for try await (index, data) in group {
                    collected[index] = data
                }
                return collected
            }
        }

        #expect(results.count == letters.count)
        for (index, letter) in letters.enumerated() {
            let data = try #require(results[index], "child \(index) produced nothing")
            let fill = try #require(letter.asciiValue)
            let uncontaminated = data.allSatisfy { $0 == fill }
            #expect(data.count == concurrentPayload, "child \(index) short read: \(data.count)")
            #expect(uncontaminated, "child \(index) saw another child's bytes")
        }
    }

    // MARK: - RUN-09…11: no run() outlives its deadline

    /// The production freeze this guards (TEST_PLAN §11 BUG-13): `run()` used
    /// to finish its pipe reads and then call `Process.waitUntilExit` on a
    /// dispatch worker, which can miss the child's termination wakeup and
    /// block forever — observed live as a thread parked in
    /// `waitUntilExit → CFRunLoopRun → mach_msg` while the child was long
    /// gone. The sidebar's poll loop awaited that `run()`, so polling froze
    /// silently for the life of the app. The invariant a caller may now rely
    /// on: **no `run()` outlives its deadline** — a wedged child fails the
    /// call with a thrown timeout, never hangs it.
    @Test("RUN-09: a child that never exits fails the call at the deadline, promptly")
    func runFailsWedgedChildAtDeadline() async throws {
        let runner = HauntedProcessRunner(timeout: 1)
        let started = Date()
        var thrown: (any Error)?
        do {
            _ = try await withDeadline("RUN-09", seconds: 30) {
                try await runner.run("sleep 300")
            }
        } catch let error as DeadlineExceeded {
            throw error // a hang and a wrong error are different bugs
        } catch {
            thrown = error
        }
        let error = try #require(thrown as? HauntedCLIError)
        #expect(error.message.contains("timed out"),
                "the caller must learn it was a timeout, got: \(error.message)")
        // 1s deadline + 2s reader grace + slop; anywhere near 300s is the bug.
        #expect(Date().timeIntervalSince(started) < 20)
    }

    /// The deadline must *kill* the wedged child, not merely abandon it — an
    /// abandoned `dedmeshctl` would go on holding mesh connections forever.
    @Test("RUN-10: the deadline SIGKILLs the wedged child")
    func deadlineKillsChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("haunted-run10-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let runner = HauntedProcessRunner(timeout: 1)
        _ = try? await withDeadline("RUN-10", seconds: 30) {
            // exec: the pidfile holds the pid of `sleep` itself.
            try await runner.run("echo $$ > '\(pidFile.path)'; exec sleep 300")
        }

        let contents = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)))
        // SIGKILL delivery is asynchronous; give it a bounded moment.
        let deadline = Date().addingTimeInterval(10)
        var dead = false
        while Date() < deadline {
            // kill(pid, 0) probes liveness without signalling.
            if kill(pid, 0) != 0 && errno == ESRCH { dead = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(dead, "child \(pid) still alive after the deadline")
    }

    /// The deadline is a ceiling, not a floor: a child that finishes on time
    /// is completely unaffected by it.
    @Test("RUN-11: a prompt child is unaffected by the deadline")
    func promptChildUnaffectedByDeadline() async throws {
        let runner = HauntedProcessRunner(timeout: 5)
        let data = try await withDeadline("RUN-11", seconds: 30) {
            try await runner.run("printf ok")
        }
        #expect(data == Data("ok".utf8))
    }

    /// Same hazard, synchronous flavor: `runToCompletion` also used
    /// `waitUntilExit`, and it runs on paths (node supervision) that
    /// must never wedge. A wedged child reports -1 at the deadline.
    @Test("RUN-09b: runToCompletion fails a wedged child at the deadline")
    func runToCompletionFailsWedgedChildAtDeadline() async throws {
        let runner = HauntedProcessRunner(timeout: 1)
        let status = try await withDeadline("RUN-09b", seconds: 30) {
            runner.runToCompletion(
                executable: "/bin/sh", arguments: ["-c", "sleep 300"])
        }
        #expect(status == -1)
    }

    // MARK: - RUN-08: stdin

    /// `standardInput = FileHandle.nullDevice`. A child that reads stdin must see
    /// EOF immediately. If stdin were inherited (or left as an open pipe the
    /// parent never closes), `read` blocks and the app hangs forever behind a
    /// CLI that is merely being polite.
    @Test("RUN-08: a child reading stdin gets EOF rather than blocking")
    func childStdinIsEOF() async throws {
        let readResult = try await runShell(
            "if read line; then printf 'GOT'; else printf 'EOF'; fi",
            label: "RUN-08",
            seconds: 30)
        #expect(readResult == Data("EOF".utf8))

        // `cat` slurps until EOF; it must exit 0 so the `&&` fires.
        let catResult = try await runShell("cat && printf 'done'", label: "RUN-08b", seconds: 30)
        #expect(catResult == Data("done".utf8))
    }

    // MARK: - HauntedCLI.resolve (§4.1, L1)

    /// Most specific first: `~/.local/bin`, then `/opt/homebrew/bin`, then
    /// `/usr/local/bin`, then the bare name for PATH to sort out.
    ///
    /// The home candidate is a real 0755 file under a temp home, probed with a
    /// real `isExecutableFile`. Only the two system candidates are answered from
    /// a set — nothing may write to `/opt/homebrew` — which is also what keeps a
    /// developer who genuinely has `/opt/homebrew/bin/haunted` installed from
    /// changing what these tests observe.
    @Test("resolve: ~/.local/bin wins over both system candidates")
    func resolvePrefersLocalBin() throws {
        try withResolveFS(
            system: ["/opt/homebrew/bin/haunted", "/usr/local/bin/haunted"],
            homeFiles: [".local/bin/haunted": 0o755]
        ) { fs in
            #expect(HauntedCLI.resolve("haunted", fs: fs)
                == "\(fs.homeDirectory.path)/.local/bin/haunted")
        }
    }

    @Test("resolve: /opt/homebrew/bin wins over /usr/local/bin")
    func resolvePrefersHomebrew() throws {
        try withResolveFS(system: ["/opt/homebrew/bin/haunted", "/usr/local/bin/haunted"]) { fs in
            #expect(HauntedCLI.resolve("haunted", fs: fs) == "/opt/homebrew/bin/haunted")
        }
    }

    @Test("resolve: /usr/local/bin is the last absolute candidate")
    func resolveFallsBackToUsrLocal() throws {
        try withResolveFS(system: ["/usr/local/bin/haunted"]) { fs in
            #expect(HauntedCLI.resolve("haunted", fs: fs) == "/usr/local/bin/haunted")
        }
    }

    /// Nothing installed anywhere known: hand back the bare name and let the
    /// login shell's PATH decide. `run` goes through `zsh -lc`, so this is not a
    /// dead end — it is the documented last resort.
    @Test("resolve: bare name when no candidate is executable")
    func resolveFallsBackToBareName() throws {
        try withResolveFS { fs in
            #expect(HauntedCLI.resolve("haunted", fs: fs) == "haunted")
        }
    }

    /// The copy shipped inside Haunted.app (Contents/MacOS) beats every
    /// install on disk: a Sparkle update replaces app and CLIs atomically, so
    /// preferring the bundle is what keeps the two from skewing (LOOP-08). An
    /// installed-but-older `~/.local/bin/haunted` must not shadow it.
    @Test("resolve: the bundled CLI wins over ~/.local/bin")
    func resolvePrefersBundledCopy() throws {
        let bundleDir = URL(fileURLWithPath: "/Applications/Haunted.app/Contents/MacOS")
        try withResolveFS(
            system: ["/Applications/Haunted.app/Contents/MacOS/haunted"],
            homeFiles: [".local/bin/haunted": 0o755]
        ) { fs in
            #expect(HauntedCLI.resolve("haunted", fs: fs, bundledTools: bundleDir)
                == "/Applications/Haunted.app/Contents/MacOS/haunted")
        }
    }

    /// A tool the bundle does not carry (the daemons, deliberately — a
    /// self-updating dedmeshd would break the bundle's signing seal) falls
    /// through to the on-disk candidates unchanged.
    @Test("resolve: a tool absent from the bundle falls through to ~/.local/bin")
    func resolveSkipsBundleForUnbundledTool() throws {
        let bundleDir = URL(fileURLWithPath: "/Applications/Haunted.app/Contents/MacOS")
        try withResolveFS(homeFiles: [".local/bin/dedmeshd": 0o755]) { fs in
            #expect(HauntedCLI.resolve("dedmeshd", fs: fs, bundledTools: bundleDir)
                == "\(fs.homeDirectory.path)/.local/bin/dedmeshd")
        }
    }

    /// "Skips non-executable candidates": a file that *exists* at a
    /// higher-priority candidate but carries no `x` bit must not shadow a real
    /// tool further down. Resolving to it would hand `zsh -lc` an absolute path
    /// that can only fail — and mask the working install one directory over.
    @Test("resolve: a present-but-non-executable file does not shadow a lower candidate")
    func resolveSkipsNonExecutable() throws {
        try withResolveFS(
            system: ["/usr/local/bin/haunted"],
            homeFiles: [".local/bin/haunted": 0o644]
        ) { fs in
            #expect(HauntedCLI.resolve("haunted", fs: fs) == "/usr/local/bin/haunted")
        }
    }

    /// `resolve` is per-tool: with only `haunted` installed, `dedmeshctl` must
    /// still fall back to its bare name rather than borrowing the other tool's
    /// directory.
    @Test("resolve: each tool resolves independently", arguments: [
        ("haunted", "/opt/homebrew/bin/haunted"),
        ("dedmeshctl", "dedmeshctl"),
    ])
    func resolveIsPerTool(tool: String, expected: String) throws {
        try withResolveFS(system: ["/opt/homebrew/bin/haunted"]) { fs in
            #expect(HauntedCLI.resolve(tool, fs: fs) == expected)
        }
    }
}

// MARK: - Fixtures

private let oneMiB = 1_048_576

/// Comfortably past a ~64 KiB pipe buffer, small enough that 32 of them are 6 MB.
private let concurrentPayload = 200_000

/// A filesystem whose home is a temp dir and whose *system* executable probes are
/// answered from a set.
///
/// `HauntedTempFileSystem` answers every `isExecutableFile` from its set, which
/// cannot express "the file is there but has no `x` bit" — the exact distinction
/// `resolveSkipsNonExecutable` is about. Here, paths under the temp home are
/// probed for real (so permissions matter and the syscall is the one production
/// makes), and only `/opt/homebrew` and `/usr/local` — which no test may create —
/// come from the set.
private struct ResolveFileSystem: HauntedFileSystem {
    let homeDirectory: URL
    let applicationSupportDirectory: URL
    let systemExecutables: Set<String>

    func isReadableFile(atPath path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        if path.hasPrefix(homeDirectory.path + "/") {
            return FileManager.default.isExecutableFile(atPath: path)
        }
        return systemExecutables.contains(path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}

/// Builds a fresh temp home, materializes `homeFiles` (path relative to home →
/// POSIX permissions), and tears the whole root down afterwards.
private func withResolveFS(
    system: Set<String> = [],
    homeFiles: [String: Int] = [:],
    _ body: (ResolveFileSystem) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("haunted-resolve-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    for (relative, permissions) in homeFiles {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    try body(ResolveFileSystem(
        homeDirectory: home,
        applicationSupportDirectory: root.appendingPathComponent("appsupport", isDirectory: true),
        systemExecutables: system))
}

// MARK: - Bounded waiting

/// A deadline elapsed before the work finished. Thrown, never ignored: the whole
/// point of RUN-04/05 is that a hang is a *failure*, not a stalled test run.
private struct DeadlineExceeded: Error, CustomStringConvertible {
    let label: String
    let seconds: Double

    var description: String {
        "\(label): no result after \(seconds)s — HauntedProcessRunner.run deadlocked"
    }
}

/// Single-assignment, lock-guarded result slot. Mirrors `OutputCollector`'s
/// `@unchecked Sendable` + `NSLock` shape for the same reason: the value is
/// produced on whatever thread the concurrency pool used and read on ours.
private final class DeadlineBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, any Error>?

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        if stored == nil {
            stored = result
        }
        lock.unlock()
    }

    var result: Result<Value, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Runs `operation` with a wall-clock ceiling.
///
/// A `withThrowingTaskGroup` race would be the idiomatic shape, but it cannot
/// work here: the group awaits its children before unwinding, and
/// `HauntedProcessRunner.run` suspends on a `withCheckedThrowingContinuation`
/// that nothing can cancel — a deadlocked child would take the group, and the
/// whole `xcodebuild test` invocation, with it. Parking the work on a detached
/// task and polling means the deadline is real. The stuck task leaks, which only
/// ever happens on an already-failing run.
private func withDeadline<Value: Sendable>(
    _ label: String,
    seconds: Double = 60,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let box = DeadlineBox<Value>()
    Task.detached {
        do {
            let value = try await operation()
            box.finish(.success(value))
        } catch {
            box.finish(.failure(error))
        }
    }

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let result = box.result {
            return try result.get()
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw DeadlineExceeded(label: label, seconds: seconds)
}

/// `HauntedProcessRunner.run`, under a deadline. Real `/bin/zsh` child, because
/// the child is what these cases are about.
private func runShell(
    _ command: String,
    label: String,
    seconds: Double = 30
) async throws -> Data {
    try await withDeadline(label, seconds: seconds) {
        try await HauntedProcessRunner.shared.run(command)
    }
}

/// `runShell` for the cases that must fail, returning the `HauntedCLIError`.
///
/// A `DeadlineExceeded` is rethrown rather than folded into the `#require`: a
/// deadlock and a wrong error message are different bugs, and only one of them
/// is about `HauntedCLIError`.
private func runShellExpectingFailure(
    _ command: String,
    label: String,
    seconds: Double = 30
) async throws -> HauntedCLIError {
    var thrown: (any Error)?
    do {
        _ = try await runShell(command, label: label, seconds: seconds)
    } catch let error as DeadlineExceeded {
        throw error
    } catch {
        thrown = error
    }
    return try #require(
        thrown as? HauntedCLIError,
        "\(label): expected a HauntedCLIError, got \(String(describing: thrown))")
}
