import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.1 — ARG-*, QUOTE-*.
///
/// `target` and session `name` come from remote-controlled JSON and end up as
/// arguments to a CLI whose parser has no `--` end-of-options marker, and as
/// interpolations into a generated `/bin/sh` script. Two boundaries guard that:
/// the decode filters (ARG) and shell quoting (QUOTE).
struct HauntedCLIArgumentTests {
    // MARK: ARG-01…04 — isSafeCLIArgument (targets)

    @Test("ARG: isSafeCLIArgument", arguments: [
        ("", false),                    // ARG-01
        ("-target", false),             // ARG-02 would be read as a flag
        ("--create", false),            // ARG-03
        ("user/box/haunted", true),     // ARG-04
        ("alice/mac-mini/term", true),
        ("a\u{07}b", false),            // BEL: OSC-0 title terminator
        ("a\u{1B}[31m", false),         // ESC: SGR injection
        ("a\u{202E}b", false),          // RTL override: visual row spoofing
        ("a\u{0A}b", false),            // newline
        ("a\u{01}b", false),            // U+0001, the tabKey separator
    ])
    func safeCLIArgument(value: String, safe: Bool) {
        #expect(isSafeCLIArgument(value) == safe, "\(Array(value.unicodeScalars))")
    }

    /// The daemon's `session_name_valid()` (apps/haunted-daemon/src/session.c)
    /// accepts exactly `[A-Za-z0-9_-]{1,63}`. Ours mirrors it, minus a leading
    /// `-` which the daemon permits but the CLI arg parser would misread.
    @Test("ARG: isValidSessionName mirrors the daemon's session_name_valid", arguments: [
        ("", false),
        ("gui-1a2b3c4d", true),
        ("default", true),
        ("work_2", true),
        ("-x", false),                  // daemon allows, we do not: flag-like
        ("x-", true),
        ("gui-\u{07}x", false),         // TITLE-07 / SH-07: BEL in an OSC-0 title
        ("a b", false),                 // space: daemon rejects
        ("a/b", false),                 // slash: daemon rejects
        ("a.b", false),                 // dot: daemon rejects
        ("日本語", false),
        (String(repeating: "a", count: 63), true),
        (String(repeating: "a", count: 64), false),  // HAUNTED_SESSION_NAME_MAX
    ])
    func validSessionName(value: String, valid: Bool) {
        #expect(isValidSessionName(value) == valid, "\(value.debugDescription)")
    }

    // MARK: ARG-05/06 — the filters actually run at the decode boundary

    /// ARG-05: a crafted `target` is dropped; its siblings survive.
    @Test("ARG-05: decodeWorkstations drops flag-like targets")
    func decodeDropsUnsafeTarget() throws {
        let json = """
        [
          {"target":"-rf","daemon":"evil","app":"haunted","online":true},
          {"target":"alice/box/haunted","daemon":"box","app":"haunted","online":true},
          {"target":"","daemon":"empty","app":"haunted","online":false}
        ]
        """.data(using: .utf8)!
        let result = try HauntedCLI.decodeWorkstations(json)
        #expect(result.map(\.target) == ["alice/box/haunted"])
    }

    /// ARG-06 + TITLE-07: a crafted session `name` is dropped, so it can never
    /// reach attach-loop.sh's OSC-0 `printf` nor the sidebar's name fallback.
    @Test("ARG-06: decodeSessions drops invalid session names")
    func decodeDropsUnsafeSessionName() throws {
        let json = """
        [
          {"name":"-create","pid":1,"clients":0,"cols":80,"rows":24,"created":0},
          {"name":"gui-\\u0007x","pid":2,"clients":0,"cols":80,"rows":24,"created":0},
          {"name":"gui-1a2b3c4d","pid":3,"clients":1,"cols":80,"rows":24,"created":0}
        ]
        """.data(using: .utf8)!
        let result = try HauntedCLI.decodeSessions(json)
        #expect(result.map(\.name) == ["gui-1a2b3c4d"])
    }

    // MARK: QUOTE-01…03

    @Test("QUOTE-02: single quotes are escaped")
    func quoteSingleQuote() {
        #expect(HauntedCLI.quote("it's") == "'it'\\''s'")
    }

    @Test("QUOTE-03: the empty string quotes to an empty token, not nothing")
    func quoteEmpty() {
        #expect(HauntedCLI.quote("") == "''")
    }

    /// QUOTE-01. A string-equality assertion would only test our idea of
    /// quoting; the whole point is what a real shell does with the result.
    /// `attachCommand` is interpolated into `zsh -lc`, so use that shell.
    @Test("QUOTE-01: zsh round-trips every quoted string byte-for-byte", arguments: [
        "'", "\"", "`", "$(id)", ";rm -rf /", "\n", "*", "~", "日本語",
        "a b", "$HOME", "\\", "!", "&&echo pwned", "$(echo hi)", "'\"'",
        "", " ", "--create", "-x", "a\u{07}b",
    ])
    func quoteRoundTripsThroughZsh(value: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "printf %s \(HauntedCLI.quote(value))"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(data == Data(value.utf8), "round trip lost \(value.debugDescription)")
    }
}
