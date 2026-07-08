import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.1 — DEC-*, STAT-*, TITLE-*.
///
/// These structs are a *second* implementation of a protocol the C daemon and
/// the Go control plane already speak. Nothing but these tests keeps them in
/// sync until the golden fixtures of §6.1 land.
struct HauntedModelTests {
    // MARK: DEC-01…06

    @Test("DEC-01: login redeem decodes snake_case")
    func decodeLoginRedeem() throws {
        let json = Data("""
        {"token":"t","username":"alice","client_name":"term",
         "control_port":"9443","ca_pem":"-----BEGIN CERTIFICATE-----"}
        """.utf8)
        let redeemed = try JSONDecoder().decode(HauntedClientLoginRedeem.self, from: json)
        #expect(redeemed.token == "t")
        #expect(redeemed.username == "alice")
        #expect(redeemed.clientName == "term")
        #expect(redeemed.controlPort == "9443")
        #expect(redeemed.caPEM == "-----BEGIN CERTIFICATE-----")
    }

    /// DEC-02. Daemons predating MSG_SESSION_LIST_V2 omit `title` entirely.
    @Test("DEC-02: session without a title decodes, title == nil")
    func decodeSessionWithoutTitle() throws {
        let json = Data("""
        [{"name":"default","pid":42,"clients":1,"cols":80,"rows":24,"created":1700000000}]
        """.utf8)
        let sessions = try HauntedCLI.decodeSessions(json)
        #expect(sessions.count == 1)
        #expect(sessions[0].title == nil)
        #expect(sessions[0].displayTitle == "default")
    }

    /// DEC-03. Forward compatibility: a newer daemon adding a field must not
    /// blank the sidebar on an older Terminal.
    @Test("DEC-03: unknown keys are ignored")
    func decodeSessionForwardCompatible() throws {
        let json = Data("""
        [{"name":"default","pid":42,"clients":1,"cols":80,"rows":24,
          "created":1700000000,"title":"vim","future_field":{"nested":true}}]
        """.utf8)
        let sessions = try HauntedCLI.decodeSessions(json)
        #expect(sessions.count == 1)
        #expect(sessions[0].title == "vim")
    }

    @Test("DEC-04: workstation without error/state decodes")
    func decodeWorkstationSparse() throws {
        let json = Data("""
        [{"target":"alice/box/haunted","daemon":"box","app":"haunted","online":true}]
        """.utf8)
        let workstations = try HauntedCLI.decodeWorkstations(json)
        #expect(workstations.count == 1)
        #expect(workstations[0].state == nil)
        #expect(workstations[0].error == nil)
    }

    @Test("DEC-05: pid at UInt32.max decodes")
    func decodeMaxPID() throws {
        let json = Data("""
        [{"name":"a","pid":4294967295,"clients":0,"cols":80,"rows":24,"created":0}]
        """.utf8)
        let sessions = try HauntedCLI.decodeSessions(json)
        #expect(sessions[0].pid == UInt32.max)
    }

    @Test("DEC-06: malformed JSON throws rather than crashing")
    func decodeMalformed() {
        let json = Data("{not json".utf8)
        #expect(throws: (any Error).self) { try HauntedCLI.decodeSessions(json) }
        #expect(throws: (any Error).self) { try HauntedCLI.decodeWorkstations(json) }
    }

    // MARK: STAT-01…05

    @Test("STAT: workstation status", arguments: [
        (true, String?.none, "online"),      // STAT-01
        (true, "error", "online"),           // STAT-02 online wins
        (false, "active", "offline"),        // STAT-03 the != "active" guard falls through
        (false, "error", "error"),           // STAT-04
        (false, String?.none, "offline"),    // STAT-05
    ])
    func workstationStatus(online: Bool, state: String?, expected: String) {
        let workstation = HauntedWorkstation(
            target: "alice/box/haunted", daemon: "box", app: "haunted",
            online: online, state: state, error: nil)
        #expect(workstation.status == expected)
    }

    // MARK: TITLE-01…07

    /// Titles are attacker-influenced: any program in the remote session sets
    /// them via OSC 0/2. They are sanitized at display.
    @Test("TITLE: displayTitle", arguments: [
        (String?.none, "gui-1a2b3c4d"),          // TITLE-01 nil falls back to name
        ("", "gui-1a2b3c4d"),                    // TITLE-02 empty falls back
        ("vim ~/notes.md", "vim ~/notes.md"),    // TITLE-03 unchanged
        ("a\u{07}b", "ab"),                      // TITLE-04 BEL stripped
        ("a\u{202E}b", "ab"),                    // TITLE-05 RTL override stripped
        ("\u{07}\u{07}", "gui-1a2b3c4d"),        // TITLE-06 all stripped -> name
        ("a\u{1B}[31mred", "a[31mred"),          // ESC stripped, literal text kept
    ])
    func displayTitle(title: String?, expected: String) {
        let session = HauntedWorkstationSession(
            name: "gui-1a2b3c4d", pid: 1, clients: 0, cols: 80, rows: 24,
            created: 0, title: title)
        #expect(session.displayTitle == expected)
    }

    /// TITLE-07. `name` is the sidebar's fallback *and* what attach-loop.sh
    /// interpolates into an OSC-0 title sequence, so it is never sanitized at
    /// display — it is rejected at the decode boundary instead. Constructing
    /// one directly still yields the raw name, which is exactly why the decode
    /// filter (ARG-06) is the load-bearing guard.
    @Test("TITLE-07: an unsanitized name cannot survive decode")
    func unsanitizedNameRejectedAtDecode() throws {
        let hostile = "gui-\u{07}x"

        // Displayed raw if it ever got this far...
        let session = HauntedWorkstationSession(
            name: hostile, pid: 1, clients: 0, cols: 80, rows: 24,
            created: 0, title: nil)
        #expect(session.displayTitle == hostile)

        // ...so it must never get this far.
        #expect(!isValidSessionName(hostile))
        let json = Data("""
        [{"name":"gui-\\u0007x","pid":1,"clients":0,"cols":80,"rows":24,"created":0}]
        """.utf8)
        #expect(try HauntedCLI.decodeSessions(json).isEmpty)
    }
}
