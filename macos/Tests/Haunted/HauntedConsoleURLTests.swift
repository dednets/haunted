import Testing
import Foundation
@testable import Ghostty

/// TEST_PLAN §4.1 — SCHEME-*, APPR-*.
///
/// The client-login flow trades a redeemable code for an mTLS client
/// certificate, so both the scheme gate and the approval-URL resolver are
/// credential-security boundaries, not cosmetics.
struct HauntedConsoleURLTests {
    // MARK: SCHEME-01…12

    @Test("SCHEME: allowed console schemes", arguments: [
        ("https://console.example.com", true),   // SCHEME-01 happy path
        ("HTTPS://console.example.com", true),   // SCHEME-02 scheme lowercased
        ("http://localhost:8080", true),         // SCHEME-03 local console dev
        ("http://127.0.0.1:8080", true),         // SCHEME-04
        ("http://[::1]:8080", true),             // SCHEME-05 URL.host is "::1", unbracketed
        ("http://console.example.com", false),   // SCHEME-06 plaintext credential interception
        ("http://localhost.evil.com", false),    // SCHEME-07 suffix-match trap
        ("http://127.0.0.1.evil.com", false),    // SCHEME-08
        ("http://LOCALHOST", true),              // SCHEME-09 host lowercased
        ("ftp://localhost", false),              // SCHEME-10
        ("//console.example.com", false),        // SCHEME-11 no scheme
        ("file:///etc/passwd", false),           // SCHEME-12
    ])
    func consoleScheme(input: String, allowed: Bool) throws {
        let url = try #require(URL(string: input), "unparseable fixture: \(input)")
        #expect(url.isAllowedConsoleScheme == allowed, "\(input)")
    }

    /// SCHEME-05 is only meaningful if `URL.host` really does strip the
    /// brackets — the loopback set contains the bare `::1`. Pin the platform
    /// behavior the gate depends on rather than assuming it.
    @Test("SCHEME-05: URL.host strips IPv6 brackets")
    func ipv6HostIsUnbracketed() throws {
        let url = try #require(URL(string: "http://[::1]:8080"))
        #expect(url.host == "::1")
    }

    // MARK: APPR-01…05

    private let base = URL(string: "https://console.example.com")!

    @Test("APPR-01: absolute https URL passes through")
    func approvalAbsolute() throws {
        let start = HauntedClientLoginStart(
            id: "1", url: "https://console.example.com/approve?id=1")
        #expect(start.approvalURL(base: base)?.absoluteString
            == "https://console.example.com/approve?id=1")
    }

    @Test("APPR-02: relative URL resolves against base, query preserved")
    func approvalRelative() throws {
        let start = HauntedClientLoginStart(id: "1", url: "/approve?id=1")
        let resolved = try #require(start.approvalURL(base: base))
        #expect(resolved.absoluteString == "https://console.example.com/approve?id=1")
        #expect(resolved.query == "id=1")
    }

    @Test("APPR-03/04: non-absolute, non-rooted URLs are rejected", arguments: [
        "approve", "",
    ])
    func approvalRejectsUnrooted(url: String) {
        #expect(HauntedClientLoginStart(id: "1", url: url).approvalURL(base: base) == nil)
    }

    /// APPR-05. The console picks this string and we hand it to
    /// `NSWorkspace.shared.open`. A compromised or MITM'd console must not be
    /// able to choose `javascript:`, `file://`, or a registered app scheme.
    @Test("APPR-05: only http(s) console origins may reach NSWorkspace.open", arguments: [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "ftp://console.example.com/approve",
        "x-evil-app://pwn",
        "http://console.example.com/approve",  // plaintext: same gate as SCHEME-06
    ])
    func approvalRejectsDangerousSchemes(url: String) {
        #expect(HauntedClientLoginStart(id: "1", url: url).approvalURL(base: base) == nil,
                "\(url) must not be opened")
    }

    /// A loopback console legitimately serves http, and its own absolute
    /// approval URL must still survive the tightened gate.
    @Test("APPR-05: loopback http console still resolves")
    func approvalAllowsLoopback() throws {
        let localBase = try #require(URL(string: "http://localhost:8080"))
        let start = HauntedClientLoginStart(id: "1", url: "http://localhost:8080/approve?id=1")
        #expect(start.approvalURL(base: localBase) != nil)

        let relative = HauntedClientLoginStart(id: "1", url: "/approve?id=1")
        #expect(relative.approvalURL(base: localBase)?.absoluteString
            == "http://localhost:8080/approve?id=1")
    }
}
