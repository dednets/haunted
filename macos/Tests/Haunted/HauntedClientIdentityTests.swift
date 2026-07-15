import Foundation
import Testing
@testable import Ghostty

/// TEST_PLAN §4.1 — `HauntedClientIdentity`, ID-01…ID-13.
///
/// Holding a readable state dir *is* the entire "logged in" state for this
/// fork: there is no password and no token, so which directory `load()` picks
/// and which certificate `certIdentity` believes decides what the sidebar
/// claims the mesh authenticated us as. Every case here runs against a
/// disposable `HauntedTempFileSystem` root (§5.3) — the real `~/.config/haunted`
/// is never read and never written.
struct HauntedClientIdentityTests {
    // MARK: - Fixtures
    //
    // Checked in as literals rather than generated with `openssl` at test time:
    // the ID-11 result turns on whether the *leaf's* DER length is a multiple
    // of three (see `certIdentityFromChainWithUnpaddedLeaf` below), and a cert
    // minted per run flips that coin on every invocation.
    //
    // Both leaves are self-signed EC P-256 with `CN=alice/term`:
    //   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    //     -nodes -keyout /dev/null -out leaf.pem -days 7300 -subj '/CN=alice\/term'

    /// DER length 387 bytes (≡ 0 mod 3) → its base64 carries **no** `=` padding.
    private static let leafUnpaddedPEM = """
        -----BEGIN CERTIFICATE-----
        MIIBfzCCASWgAwIBAgIUEU+L09/PwZ9dFT4ZciaCRgTV7gswCgYIKoZIzj0EAwIw
        FTETMBEGA1UEAwwKYWxpY2UvdGVybTAeFw0yNjA3MDgwOTAxNDZaFw00NjA3MDMw
        OTAxNDZaMBUxEzARBgNVBAMMCmFsaWNlL3Rlcm0wWTATBgcqhkjOPQIBBggqhkjO
        PQMBBwNCAAT8mEof9w+NJXRAtxJguWZaX79q582s/E+c6F0zQpHOrjriQ3Ww3wuJ
        hYV5NltFHQXKHkPoKTtdaujw0VN+hN34o1MwUTAdBgNVHQ4EFgQUaZvvCMKNasFS
        TG+yb78luQtbb5wwHwYDVR0jBBgwFoAUaZvvCMKNasFSTG+yb78luQtbb5wwDwYD
        VR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAxhWOTharrfwD0z4kRg1a
        4E707uLWvFDCx8WLSFQp9lUCIF+avI0tZmYsNEKA2jmdkMr7MY66WLMRT1Qx213v
        5JUT
        -----END CERTIFICATE-----
        """

    /// DER length 386 bytes (≡ 2 mod 3) → its base64 ends in one `=` pad byte.
    private static let leafPaddedPEM = """
        -----BEGIN CERTIFICATE-----
        MIIBfjCCASWgAwIBAgIUb0yWOsboK1EGkyeOlesUJn96DgcwCgYIKoZIzj0EAwIw
        FTETMBEGA1UEAwwKYWxpY2UvdGVybTAeFw0yNjA3MDgwOTAyMTJaFw00NjA3MDMw
        OTAyMTJaMBUxEzARBgNVBAMMCmFsaWNlL3Rlcm0wWTATBgcqhkjOPQIBBggqhkjO
        PQMBBwNCAAReyxlkCoCaiCUolJF9JGxOzfsv4JTQ3Nxezx+ggLnRjjedd6E9oZO1
        XT/5/t5IrivV1yWB6K8gq6cJKLcoVSIpo1MwUTAdBgNVHQ4EFgQUVne7td3N3xYW
        4yeDzGXjwtZw7yswHwYDVR0jBBgwFoAUVne7td3N3xYW4yeDzGXjwtZw7yswDwYD
        VR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiAWpVyOBctGsnbzTe4rcAns
        JJmhGRyhf4CJdXPVxQCjmQIgLpFAmfmZhghHY196mRo/vEB9d6nvw3tKNa3HTQzo
        wKM=
        -----END CERTIFICATE-----
        """

    /// A second, unrelated self-signed cert (`CN=DedNets Test CA`): stands in
    /// for the intermediate a chain-issuing console would append.
    private static let issuerPEM = """
        -----BEGIN CERTIFICATE-----
        MIIBiDCCAS+gAwIBAgIUPMjEQ+j20l0CVRch88K0ATbjIFEwCgYIKoZIzj0EAwIw
        GjEYMBYGA1UEAwwPRGVkTmV0cyBUZXN0IENBMB4XDTI2MDcwODA5MDE0NloXDTQ2
        MDcwMzA5MDE0NlowGjEYMBYGA1UEAwwPRGVkTmV0cyBUZXN0IENBMFkwEwYHKoZI
        zj0CAQYIKoZIzj0DAQcDQgAEKKl46mFC5PKoEUKunH00D5l1mW4Rao8psRo5CZG2
        U41x6eRfFK5nYLY7Y6wg4BwaQH17lXYhtt44tZw59DykCaNTMFEwHQYDVR0OBBYE
        FM4j6hXcyE6A6KBbyBd0iyWRdSwqMB8GA1UdIwQYMBaAFM4j6hXcyE6A6KBbyBd0
        iyWRdSwqMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgCBVs77ox
        IHvZBizRi06FCEWotsvg94A4RlIgFHxmFTQCIFBVSA4n8YlBbEQHCSclORxlsMLz
        72ksaXBC7q08xqeF
        -----END CERTIFICATE-----
        """

    /// Never parsed by anything under test — `hasLogin` only stats it.
    private static let keyPEM = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg
        -----END PRIVATE KEY-----
        """

    private static let validSettings = #"{"console":"console.example.com:9443"}"#

    // MARK: - Helpers

    /// Writes the four files `hasLogin` requires into `dir`, minus `omit`.
    private static func enroll(
        _ dir: URL,
        cert: String = leafUnpaddedPEM,
        settings: String = validSettings,
        omit: [String] = []
    ) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = [
            "cert.pem": cert,
            "key.pem": keyPEM,
            "settings.json": settings,
            "ca.pem": issuerPEM,
        ]
        for (name, body) in files where !omit.contains(name) {
            try Data(body.utf8).write(to: dir.appendingPathComponent(name))
        }
    }

    /// An identity pointed at a bare temp dir. `certIdentity` only reads
    /// `stateDir/cert.pem`, so ID-10…13 need no filesystem seam at all.
    private static func identity(withCertFile contents: String?) throws -> (HauntedClientIdentity, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("haunted-cert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let contents {
            try Data(contents.utf8).write(to: dir.appendingPathComponent("cert.pem"))
        }
        return (HauntedClientIdentity(stateDir: dir, console: nil), dir)
    }

    // MARK: - ID-01…ID-06: which state dir load() picks

    @Test("ID-01: all four files in the default state dir → identity loads")
    func loadsFromCompleteDefaultDir() throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }
        try Self.enroll(HauntedClientIdentity.defaultStateDir(fs))

        let identity = try #require(HauntedClientIdentity.load(fs: fs))
        #expect(identity.stateDir == HauntedClientIdentity.defaultStateDir(fs))
        #expect(identity.console == "console.example.com:9443")
    }

    @Test("ID-02: key.pem missing → load() is nil")
    func missingKeyIsNotEnrolled() throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }
        try Self.enroll(HauntedClientIdentity.defaultStateDir(fs), omit: ["key.pem"])

        // A cert with no key cannot complete an mTLS handshake; reporting
        // "logged in" here would send the user to a console that rejects them.
        #expect(HauntedClientIdentity.load(fs: fs) == nil)
    }

    @Test("ID-03: settings.json missing → load() is nil (all four required)")
    func missingSettingsIsNotEnrolled() throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }
        try Self.enroll(HauntedClientIdentity.defaultStateDir(fs), omit: ["settings.json"])

        #expect(HauntedClientIdentity.load(fs: fs) == nil)
    }

    @Test("ID-04: default dir incomplete, legacy dir complete → legacy used")
    func fallsBackToLegacyDir() throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }
        // The legacy dir is a *child* of the default dir, so a partial default
        // enrollment must not shadow a complete legacy one.
        try Self.enroll(HauntedClientIdentity.defaultStateDir(fs), omit: ["key.pem", "ca.pem"])
        try Self.enroll(HauntedClientIdentity.legacyStateDir(fs))

        let identity = try #require(HauntedClientIdentity.load(fs: fs))
        #expect(identity.stateDir == HauntedClientIdentity.legacyStateDir(fs))
    }

    @Test("ID-05: both dirs complete → default preferred")
    func defaultDirWinsOverLegacy() throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }
        try Self.enroll(HauntedClientIdentity.defaultStateDir(fs))
        try Self.enroll(
            HauntedClientIdentity.legacyStateDir(fs),
            settings: #"{"console":"legacy.example.com:9443"}"#)

        let identity = try #require(HauntedClientIdentity.load(fs: fs))
        #expect(identity.stateDir == HauntedClientIdentity.defaultStateDir(fs))
        #expect(identity.console == "console.example.com:9443")
    }

    @Test("ID-06: malformed settings.json → identity loads, console == nil, no throw")
    func malformedSettingsDoesNotBlockLoad() throws {
        let fs = HauntedTempFileSystem()
        try fs.createRoots()
        defer { fs.remove() }
        try Self.enroll(HauntedClientIdentity.defaultStateDir(fs), settings: "{ not json at all")

        // The credentials are the certificate, not the settings file: a corrupt
        // display hint must not log the user out.
        let identity = try #require(HauntedClientIdentity.load(fs: fs))
        #expect(identity.stateDir == HauntedClientIdentity.defaultStateDir(fs))
        #expect(identity.console == nil)
    }

    // MARK: - ID-07…ID-09: consoleHost

    @Test("ID-07: consoleHost strips the port from a hostname")
    func consoleHostStripsPort() {
        let identity = HauntedClientIdentity(
            stateDir: URL(fileURLWithPath: "/nonexistent"),
            console: "console.example.com:9443")
        #expect(identity.consoleHost == "console.example.com")
    }

    @Test("ID-08: consoleHost of nil console → \"DedNets\"")
    func consoleHostFallsBackWhenUnset() {
        let identity = HauntedClientIdentity(
            stateDir: URL(fileURLWithPath: "/nonexistent"),
            console: nil)
        #expect(identity.consoleHost == "DedNets")
    }

    /// ID-09 — regression test for the fixed BUG-2. `consoleHost` used to be
    /// `console.split(separator: ":").first`, which shredded a bracketed IPv6
    /// literal at its first colon and showed `"["` in the sidebar.
    ///
    /// The reference for correct is `URLComponents`, not `URL`: for
    /// `//[::1]:9443`, `URLComponents.host` is `"[::1]"` (brackets kept) while
    /// `URL.host` is `"::1"` (brackets stripped). What `consoleHost` feeds is a
    /// display string built from a `host:port` pair, so the bracket form is the
    /// one that round-trips. Do not "unify" the two — isAllowedConsoleScheme's
    /// loopback set matches the *stripped* form (SCHEME-05).
    @Test("ID-09: consoleHost preserves a bracketed IPv6 literal (BUG-2 regression)")
    func consoleHostPreservesBracketedIPv6() {
        let identity = HauntedClientIdentity(
            stateDir: URL(fileURLWithPath: "/nonexistent"),
            console: "[::1]:9443")
        #expect(identity.consoleHost == "[::1]")

        // The parse must not disturb the ordinary cases ID-07/08 cover.
        let dir = URL(fileURLWithPath: "/nonexistent")
        #expect(HauntedClientIdentity(stateDir: dir, console: "console.example.com")
            .consoleHost == "console.example.com", "a bare host, no port")
    }

    // MARK: - ID-10…ID-13: certIdentity

    @Test("ID-10: certIdentity reads CN=alice/term from the leaf certificate")
    func certIdentityReadsCommonName() throws {
        let (identity, dir) = try Self.identity(withCertFile: Self.leafUnpaddedPEM)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The CN is the subject the console authenticates. The `/` inside it is
        // part of the name ("username/client-name"), not a path separator.
        #expect(identity.certIdentity == "alice/term")
    }

    /// ID-11a/b — regression tests for the fixed chain bug (TEST_PLAN §4.1).
    ///
    /// `certIdentity` used to strip every `-----` line and join *all* remaining
    /// base64 across *both* certificates before decoding once. What that did
    /// depended entirely on the leaf's DER length, which is why the plan's
    /// blanket "→ nil" prediction was only two-thirds right:
    ///
    /// - **Unpadded leaf** (DER ≡ 0 mod 3, 387 bytes): its base64 carries no `=`
    ///   pad, so the concatenation stayed well-formed base64. It decoded to
    ///   `leafDER || issuerDER`, and `SecCertificateCreateWithData` accepted the
    ///   leading DER while *silently ignoring the trailing bytes*. It returned
    ///   `"alice/term"` — right answer, for the wrong reason, having read a file
    ///   it did not understand.
    /// - **Padded leaf** (386 bytes): the `=` landed mid-string, the join was
    ///   invalid base64, and the sidebar silently dropped the identity line.
    ///
    /// Both now take the same path: parse the first PEM block, ignore the rest.
    /// Keep both fixtures — they are what proves the fix is not itself a
    /// coin flip on the leaf's byte length.
    @Test("ID-11a: chain PEM with an unpadded leaf resolves the leaf's CN")
    func certIdentityFromChainWithUnpaddedLeaf() throws {
        let chain = Self.leafUnpaddedPEM + "\n" + Self.issuerPEM
        let (identity, dir) = try Self.identity(withCertFile: chain)
        defer { try? FileManager.default.removeItem(at: dir) }

        // This fixture really is the no-padding branch: the old joined-base64
        // was decodable, which is precisely why the old code got away with it.
        let joined = chain
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        #expect(Data(base64Encoded: joined) != nil)

        #expect(identity.certIdentity == "alice/term")
    }

    /// ID-11b — the case that used to return nil. The leaf's CN must resolve
    /// even though the joined base64 of the whole chain is undecodable.
    @Test("ID-11b: chain PEM with a padded leaf resolves the leaf's CN")
    func certIdentityFromChainWithPaddedLeaf() throws {
        let chain = Self.leafPaddedPEM + "\n" + Self.issuerPEM
        let (identity, dir) = try Self.identity(withCertFile: chain)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The old code's input: invalid base64. This is what made it return nil.
        let joined = chain
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        #expect(Data(base64Encoded: joined) == nil, "fixture must exercise the padded branch")

        #expect(identity.certIdentity == "alice/term")
    }

    @Test("ID-11c: the padded leaf alone still resolves (isolates the join)")
    func paddedLeafAloneResolves() throws {
        let (identity, dir) = try Self.identity(withCertFile: Self.leafPaddedPEM)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(identity.certIdentity == "alice/term")
    }

    @Test("ID-12: certIdentity with no cert.pem at all → nil")
    func certIdentityWithMissingFile() throws {
        let (identity, dir) = try Self.identity(withCertFile: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(identity.certIdentity == nil)
    }

    @Test("ID-12: certIdentity with an unreadable cert.pem → nil, no throw")
    func certIdentityWithUnreadableFile() throws {
        let (identity, dir) = try Self.identity(withCertFile: Self.leafUnpaddedPEM)
        let cert = dir.appendingPathComponent("cert.pem")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: cert.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: cert.path)
            try? FileManager.default.removeItem(at: dir)
        }

        #expect(identity.certIdentity == nil)
    }

    @Test("ID-13: certIdentity with unparsable cert.pem contents → nil", arguments: [
        // Not base64 → Data(base64Encoded:) is nil.
        "-----BEGIN CERTIFICATE-----\nnot base64 at all !!!\n-----END CERTIFICATE-----",
        // Valid base64, but not a DER certificate → SecCertificateCreateWithData is nil.
        "-----BEGIN CERTIFICATE-----\naGVsbG8gd29ybGQ=\n-----END CERTIFICATE-----",
        // Armour only, no payload → empty base64 decodes to empty Data → nil cert.
        "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----",
        // Entirely empty file.
        "",
    ])
    func certIdentityWithGarbage(contents: String) throws {
        let (identity, dir) = try Self.identity(withCertFile: contents)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(identity.certIdentity == nil)
    }
}
