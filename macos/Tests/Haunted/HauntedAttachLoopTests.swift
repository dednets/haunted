import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.1 — SH-01…06 and LOOP-01…05.
///
/// The reconnect loop is a `/bin/sh` script the app generates at launch. It is
/// what stands between "the console restarted" and "the user is staring at an
/// exit banner", and none of it had ever been executed by a test.
///
/// §5.5 proposed extracting the script to a bundle resource so it could be run
/// directly. That is unnecessary and costs a `project.pbxproj` resource-phase
/// edit — the rebase surface §8 exists to avoid. The §5.3 filesystem seam
/// already lets a test generate the *real* script into a temp Application
/// Support root and run it under `/bin/sh`, with a stub `haunted` on the path
/// `HauntedCLI.resolve` embeds. Same two wins, zero project-file change.
///
/// Serialized: `HauntedCLI.attachLoopPath` memoizes written script paths in a
/// plain `static var Set`. Production only ever calls it from the main thread;
/// these are the only concurrent callers, and racing that Set would be our bug,
/// not the code's.
@Suite(.serialized)
struct HauntedAttachLoopTests {
    // MARK: Harness

    private struct Harness {
        let fs: HauntedTempFileSystem
        /// One line per stub-`haunted` invocation, recording its argv.
        let hauntedLog: URL
        /// One line per stub-`sleep`, recording the requested delay.
        let sleepLog: URL
        /// Holds the stub `sleep`; prepended to the script's PATH.
        let stubBin: URL

        func lines(of file: URL) -> [String] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }

        func remove() { fs.remove() }
    }

    /// `hauntedBody` is the stub `haunted`'s shell body; it decides the exit
    /// code, and may consult `hauntedLog` to count its own attempts.
    private func makeHarness(hauntedBody: String) throws -> Harness {
        var fs = HauntedTempFileSystem()
        try fs.createRoots()

        let localBin = fs.homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        let stubBin = fs.root.appendingPathComponent("stub-bin", isDirectory: true)
        for dir in [localBin, stubBin] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // resolve() prefers ~/.local/bin, so the generated script embeds this
        // absolute path — no PATH lookup for `haunted` at all.
        let haunted = localBin.appendingPathComponent("haunted")
        fs.executables = [haunted.path]

        let hauntedLog = fs.root.appendingPathComponent("haunted.log")
        let sleepLog = fs.root.appendingPathComponent("sleep.log")

        try write(
            """
            #!/bin/sh
            echo "$@" >> '\(hauntedLog.path)'
            \(hauntedBody)
            """,
            to: haunted)

        // A stub `sleep` records the backoff schedule and keeps the suite fast.
        // It still sleeps a little, so SH-06's SIGINT has a window to land.
        try write(
            """
            #!/bin/sh
            echo "$1" >> '\(sleepLog.path)'
            exec /bin/sleep 0.08
            """,
            to: stubBin.appendingPathComponent("sleep"))

        return Harness(fs: fs, hauntedLog: hauntedLog, sleepLog: sleepLog, stubBin: stubBin)
    }

    private func write(_ body: String, to url: URL) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Runs the generated script directly. Returns its exit code and stdout.
    @discardableResult
    private func runLoop(
        _ harness: Harness,
        target: String = "alice/box/haunted",
        session: String = "work",
        create: Bool = false,
        extraArguments: [String] = [],
        interruptAfter: TimeInterval? = nil
    ) throws -> (code: Int32, output: String) {
        var arguments = [HauntedCLI.attachLoopPath(fs: harness.fs), target, session]
        if create { arguments.append("--create") }
        arguments.append(contentsOf: extraArguments)
        return try runShell(harness, executable: "/bin/sh", arguments: arguments,
                            interruptAfter: interruptAfter)
    }

    private func runShell(
        _ harness: Harness,
        executable: String,
        arguments: [String],
        interruptAfter: TimeInterval? = nil
    ) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(harness.stubBin.path):/usr/bin:/bin"
        process.environment = environment

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        if let interruptAfter {
            Thread.sleep(forTimeInterval: interruptAfter)
            kill(process.processIdentifier, SIGINT)
        }

        // Read before waiting: the script writes more than a pipe buffer's worth
        // of reconnect banners on the 20-attempt path.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // The script emits an OSC-0 title sequence, so stdout is not plain text;
        // decode leniently rather than failing the test on an escape byte.
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }

    // MARK: SH-01…04 — the exit-code contract

    /// SH-01. Exit 0 means "clean detach, or the session was killed" — stop
    /// looping. Anything else means the transport died: reconnect.
    @Test("SH-01: a clean attach exits 0 after exactly one invocation")
    func cleanExitStopsImmediately() throws {
        let harness = try makeHarness(hauntedBody: "exit 0")
        defer { harness.remove() }

        let result = try runLoop(harness)
        #expect(result.code == 0)
        #expect(harness.lines(of: harness.hauntedLog).count == 1)
        #expect(harness.lines(of: harness.sleepLog).isEmpty, "no backoff on success")
    }

    @Test("SH-02: a permanently failing attach gives up after 20 attempts")
    func exhaustsRetries() throws {
        let harness = try makeHarness(hauntedBody: "exit 1")
        defer { harness.remove() }

        let result = try runLoop(harness)
        #expect(harness.lines(of: harness.hauntedLog).count == 20)
        #expect(result.code == 1)
        #expect(result.output.contains("giving up after 20 attempts"))
    }

    /// SH-03. The point of the whole script: a blip, then the session is still
    /// there, and the user never knew. The stub counts its own attempts.
    @Test("SH-03: transient failures reconnect, then a clean exit stops the loop")
    func reconnectsThenSucceeds() throws {
        let harness = try makeHarness(hauntedBody: """
            attempts=$(wc -l < '\(NSTemporaryDirectory())/unused' 2>/dev/null || echo skip)
            exit 0
            """)
        defer { harness.remove() }

        // Rewrite the stub now that we know the log path: fail 3×, then succeed.
        try write(
            """
            #!/bin/sh
            echo "$@" >> '\(harness.hauntedLog.path)'
            attempts=$(wc -l < '\(harness.hauntedLog.path)' | tr -d ' ')
            [ "$attempts" -le 3 ] && exit 1
            exit 0
            """,
            to: harness.fs.homeDirectory.appendingPathComponent(".local/bin/haunted"))

        let result = try runLoop(harness)
        #expect(result.code == 0)
        #expect(harness.lines(of: harness.hauntedLog).count == 4, "3 failures, then success")
        #expect(harness.lines(of: harness.sleepLog).count == 3)
    }

    /// SH-04. The child's exit code must survive the loop rather than being
    /// flattened to 1 — `wait-after-command` shows it to the user.
    @Test("SH-04: the final exit code is the child's, not 1")
    func propagatesChildExitCode() throws {
        let harness = try makeHarness(hauntedBody: "exit 7")
        defer { harness.remove() }

        let result = try runLoop(harness)
        #expect(result.code == 7)
        #expect(result.output.contains("(exit 7)"))
    }

    // MARK: SH-05 — the backoff schedule

    /// SH-05. Growth by 2, capped at 10. Nineteen sleeps for twenty attempts:
    /// the last failure gives up rather than sleeping again.
    @Test("SH-05: backoff grows by 2 and caps at 10 seconds")
    func backoffSchedule() throws {
        let harness = try makeHarness(hauntedBody: "exit 1")
        defer { harness.remove() }

        _ = try runLoop(harness)
        let delays = harness.lines(of: harness.sleepLog).compactMap { Int($0) }
        #expect(Array(delays.prefix(6)) == [2, 4, 6, 8, 10, 10])
        #expect(delays.count == 19, "20 attempts, no sleep after the last")
        #expect(delays.allSatisfy { $0 <= 10 }, "the cap must hold")
    }

    // MARK: SH-06 — ctrl-c during the backoff

    /// SH-06. The user must be able to stop a doomed reconnect. 130 is the
    /// conventional "terminated by SIGINT" status; the script traps it and exits
    /// deliberately rather than dying mid-sleep.
    @Test("SH-06: SIGINT exits 130 and says the reconnect was cancelled")
    func interruptDuringBackoff() throws {
        let harness = try makeHarness(hauntedBody: "exit 1")
        defer { harness.remove() }

        // Twenty attempts take ~1.7s with the stub sleep; interrupt well inside.
        let result = try runLoop(harness, interruptAfter: 0.3)
        #expect(result.code == 130)
        #expect(result.output.contains("reconnect cancelled"))
        #expect(harness.lines(of: harness.hauntedLog).count < 20, "it stopped early")
    }

    // MARK: LOOP-01…03 — the command a tab actually runs

    @Test("LOOP-01/02: --create is appended only when creating")
    func createFlag() throws {
        let harness = try makeHarness(hauntedBody: "exit 0")
        defer { harness.remove() }

        let creating = HauntedCLI.attachCommand(
            target: "a/b/c", sessionName: "s", create: true, fs: harness.fs)
        let attaching = HauntedCLI.attachCommand(
            target: "a/b/c", sessionName: "s", create: false, fs: harness.fs)
        #expect(creating.hasPrefix("exec "))
        #expect(creating.hasSuffix(" --create"))
        #expect(!attaching.contains("--create"))
    }

    /// The `--create` flag must reach `haunted attach-remote`, since the daemon
    /// does not create a session on a raw attach.
    @Test("LOOP-01: --create reaches attach-remote's argv")
    func createFlagReachesTheCLI() throws {
        let harness = try makeHarness(hauntedBody: "exit 0")
        defer { harness.remove() }

        _ = try runLoop(harness, create: true)
        let argv = harness.lines(of: harness.hauntedLog).first ?? ""
        #expect(argv.contains("--create"))
        #expect(argv.contains("attach-remote"))
        #expect(argv.contains("--target alice/box/haunted"))
    }

    /// LOOP-08. The generated command may only use flags the OLDEST deployed
    /// `haunted` CLI understands. The tab-scoped kill grace is `haunted
    /// attach-remote`'s own gui-* default, NOT an app-emitted flag: when the
    /// app briefly emitted `--kill-grace`, every attach through an older
    /// `~/.local/bin/haunted` died on a usage error and the reconnect loop
    /// spun to exhaustion — a new app must never require a new CLI.
    @Test("LOOP-08: attachCommand emits no flags an old haunted CLI rejects")
    func attachCommandStaysOldCLICompatible() throws {
        let harness = try makeHarness(hauntedBody: "exit 0")
        defer { harness.remove() }

        for (name, create) in [
            ("gui-1a2b3c4d5e6f7a8b", true), ("default", true), ("work", false),
        ] {
            let cmd = HauntedCLI.attachCommand(
                target: "a/b/c", sessionName: name, create: create, fs: harness.fs)
            let flags = cmd.split(separator: " ").filter { $0.hasPrefix("--") }
            #expect(flags.allSatisfy { $0 == "--create" },
                    "unexpected flag(s) \(flags) for \(name); old CLIs reject them")
        }
    }

    /// LOOP-09. Extra flags handed to the loop script must reach attach-remote
    /// on EVERY retry, not just the first attempt — an attach clears the
    /// kill-grace arm daemon-side, so a retry that dropped the flags would
    /// silently change semantics mid-loop.
    @Test("LOOP-09: extra flags reach attach-remote on every retry")
    func killGraceReachesEveryRetry() throws {
        let harness = try makeHarness(hauntedBody: "exit 0")
        defer { harness.remove() }
        // Fail twice, then succeed: three invocations, all of them armed.
        try write(
            """
            #!/bin/sh
            echo "$@" >> '\(harness.hauntedLog.path)'
            attempts=$(wc -l < '\(harness.hauntedLog.path)' | tr -d ' ')
            [ "$attempts" -le 2 ] && exit 1
            exit 0
            """,
            to: harness.fs.homeDirectory.appendingPathComponent(".local/bin/haunted"))

        let result = try runLoop(
            harness, session: "gui-1a2b3c4d5e6f7a8b",
            create: true, extraArguments: ["--kill-grace", "600"])
        #expect(result.code == 0)
        let argvs = harness.lines(of: harness.hauntedLog)
        #expect(argvs.count == 3)
        for argv in argvs {
            #expect(argv.contains("--kill-grace 600"), "argv was: \(argv)")
            #expect(argv.contains("--create"))
            #expect(argv.hasSuffix("gui-1a2b3c4d5e6f7a8b"),
                    "the session stays the last positional")
        }
    }

    /// LOOP-03. `attachCommand` is *typed into a login shell*, so its quoting is
    /// a real boundary. A target holding a single quote must arrive at
    /// `attach-remote` as one intact argument.
    @Test("LOOP-03: a single quote in the target survives the shell round trip")
    func quotingRoundTrip() throws {
        let harness = try makeHarness(hauntedBody: "exit 0")
        defer { harness.remove() }

        let target = "alice/it's box/haunted"
        let command = HauntedCLI.attachCommand(
            target: target, sessionName: "work", create: false, fs: harness.fs)

        // Exactly how the surface runs it: one string, handed to a shell.
        let result = try runShell(harness, executable: "/bin/sh", arguments: ["-c", command])
        #expect(result.code == 0)

        let argv = harness.lines(of: harness.hauntedLog).first ?? ""
        #expect(argv.contains("--target \(target)"), "argv was: \(argv)")
    }

    // MARK: LOOP-04/05 — the generated script itself

    /// The write-once cache is keyed on the script path, so a second call in the
    /// same launch returns the same path and does not rewrite the file.
    @Test("LOOP-04/05: the script is written 0755, once per Application Support root")
    func scriptIsWrittenOnceAndExecutable() throws {
        let harness = try makeHarness(hauntedBody: "exit 0")
        defer { harness.remove() }

        let first = HauntedCLI.attachLoopPath(fs: harness.fs)
        #expect(FileManager.default.isExecutableFile(atPath: first))
        let mode = try FileManager.default.attributesOfItem(atPath: first)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o755)

        // Mutate it. A second call must hand back the same path, unrewritten.
        try "#!/bin/sh\nexit 3\n".write(
            to: URL(fileURLWithPath: first), atomically: true, encoding: .utf8)
        #expect(HauntedCLI.attachLoopPath(fs: harness.fs) == first)
        #expect(try String(contentsOfFile: first, encoding: .utf8) == "#!/bin/sh\nexit 3\n")
    }

    /// A different Application Support root is a different script: claiming it
    /// exists because some other root's copy was written would hand out a path
    /// to a file that was never created.
    @Test("LOOP-04: a second root gets its own script")
    func eachRootGetsItsOwnScript() throws {
        let first = try makeHarness(hauntedBody: "exit 0")
        defer { first.remove() }
        let second = try makeHarness(hauntedBody: "exit 0")
        defer { second.remove() }

        let a = HauntedCLI.attachLoopPath(fs: first.fs)
        let b = HauntedCLI.attachLoopPath(fs: second.fs)
        #expect(a != b)
        #expect(FileManager.default.isExecutableFile(atPath: b))
    }

    /// The script's output lands in a terminal whose charset has not been
    /// negotiated yet, so it must be pure ASCII.
    @Test("The generated script is pure ASCII")
    func scriptIsASCII() throws {
        let harness = try makeHarness(hauntedBody: "exit 0")
        defer { harness.remove() }
        let body = try String(
            contentsOfFile: HauntedCLI.attachLoopPath(fs: harness.fs), encoding: .utf8)
        #expect(body.allSatisfy { $0.isASCII })
    }

    /// The tab title is set from the session name via OSC 0. Session names are
    /// validated at the decode boundary (isValidSessionName), which is what stops
    /// a BEL from terminating that escape sequence early and injecting the
    /// remainder into the *local* terminal — the old SH-07.
    @Test("SH-07: a name that could break the OSC-0 title cannot reach the script")
    func osc0TitleCannotBeInjected() {
        #expect(!isValidSessionName("work\u{07}evil"))
        #expect(!isValidSessionName("work\u{1B}]0;evil"))
        #expect(isValidSessionName("work"))
    }
}
