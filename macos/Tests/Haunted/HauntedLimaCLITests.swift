import CryptoKit
import Testing
import Foundation
@testable import Ghostty

/// Lima manager plumbing (LIMA-*): the `limactl list` decode boundary, the
/// exact command strings (argv is a security boundary — tokens, names, and
/// console addresses are interpolated into nested shell strings), the
/// generated VM yaml, and the CA fingerprint that pins in-VM enrollment to
/// the console this client already trusts.
struct HauntedLimaCLITests {
    // MARK: Fixtures

    /// Same shape as HauntedCLILoginTests.caPEM: not a real certificate —
    /// caFingerprint only parses the PEM envelope and hashes the DER bytes.
    static let caPEM = """
    -----BEGIN CERTIFICATE-----
    MIIBkTCB+wIJAKZ7Z3xkQ0AA
    MA0GCSqGSIb3DQEBCwUA
    -----END CERTIFICATE-----
    """

    static let identity = HauntedClientIdentity(
        stateDir: URL(fileURLWithPath: "/state"), console: "c.example.com:9443")

    // MARK: LIMA-01 — the decode boundary

    @Test("LIMA-01: decodeInstances accepts both the array and JSONL shapes")
    func decodeShapes() {
        let array = Data(#"[{"name":"ws1","status":"Running"},{"name":"ws2","status":"Stopped"}]"#.utf8)
        #expect(HauntedLimaCLI.decodeInstances(array) == [
            HauntedLimaInstance(name: "ws1", status: "Running"),
            HauntedLimaInstance(name: "ws2", status: "Stopped"),
        ])

        let jsonl = Data("""
        {"name":"ws1","status":"Running"}
        {"name":"ws2","status":"Stopped"}
        """.utf8)
        #expect(HauntedLimaCLI.decodeInstances(jsonl) == [
            HauntedLimaInstance(name: "ws1", status: "Running"),
            HauntedLimaInstance(name: "ws2", status: "Stopped"),
        ])
    }

    @Test("LIMA-01b: hostile names, garbage lines, and a missing status degrade per-entry")
    func decodeTolerance() {
        let jsonl = Data("""
        {"name":"ws1"}
        not json at all
        {"name":"-rf","status":"Running"}
        {"name":"WS2","status":"Running"}
        {"status":"Running"}
        {"name":"ok-2","status":"Running"}
        """.utf8)
        #expect(HauntedLimaCLI.decodeInstances(jsonl) == [
            HauntedLimaInstance(name: "ws1", status: "Unknown"),
            HauntedLimaInstance(name: "ok-2", status: "Running"),
        ])
    }

    // MARK: LIMA-02 — the name grammar (mirror of names.ValidateName)

    @Test("LIMA-02: node-name grammar (a-z, 0-9, - and _; leading alnum)", arguments: [
        ("ws1", true),
        ("a", true),
        ("my-box-2", true),
        ("ws_9", true),
        ("dev_box-2", true),
        ("a_", true),
        ("ws-", true),
        (String(repeating: "a", count: 32), true),
        ("", false),
        ("-ws", false),
        ("_ws", false),
        ("WS1", false),
        ("ws.1", false),
        ("ws 1", false),
        (String(repeating: "a", count: 33), false),
        ("wß1", false),
    ])
    func nameGrammar(name: String, valid: Bool) {
        #expect(isValidNodeName(name) == valid)
    }

    @Test("LIMA-02c: daemon-name grammar takes the prefixed form; display strips it")
    func daemonNamesAndDisplay() {
        #expect(isValidDaemonName("luiz-ws_9"))
        #expect(isValidDaemonName("homelab"))
        #expect(isValidDaemonName(String(repeating: "a", count: 65)))
        #expect(!isValidDaemonName(String(repeating: "a", count: 66)))
        #expect(!isValidDaemonName("-x"))
        #expect(!isValidDaemonName("Luiz-ws"))

        // Own prefix strips; legacy and foreign names pass through.
        #expect(nodeDisplayName(daemon: "luiz-ws_9", username: "luiz") == "ws_9")
        #expect(nodeDisplayName(daemon: "homelab", username: "luiz") == "homelab")
        #expect(nodeDisplayName(daemon: "luiz-ws_9", username: "bob") == "luiz-ws_9")
        #expect(nodeDisplayName(daemon: "luiz-ws_9", username: nil) == "luiz-ws_9")
        // A pathological bare "<username>-" never strips to empty.
        #expect(nodeDisplayName(daemon: "luiz-", username: "luiz") == "luiz-")
    }

    @Test("LIMA-02b: join-token grammar", arguments: [
        ("dn_0123abcdef", true),
        ("dn_", false),
        ("dn_ABC", false),
        ("dn_0g", false),
        ("dx_0123", false),
        ("dn_0123'; rm -rf ~", false),
        ("", false),
    ])
    func tokenGrammar(token: String, valid: Bool) {
        #expect(isValidJoinToken(token) == valid)
    }

    // MARK: LIMA-03 — exact command strings

    @Test("LIMA-03: the lifecycle command builders quote every operand")
    func commandBuilders() {
        let limactl = "/opt/homebrew/bin/limactl"
        #expect(HauntedLimaCLI.listCommand(limactl: limactl)
            == "'/opt/homebrew/bin/limactl' list --json")
        #expect(HauntedLimaCLI.createCommand(limactl: limactl, yamlPath: "/tmp/ws9.yaml", name: "ws9")
            == "'/opt/homebrew/bin/limactl' create --name='ws9' '/tmp/ws9.yaml' --tty=false")
        #expect(HauntedLimaCLI.startCommand(limactl: limactl, name: "ws9")
            == "'/opt/homebrew/bin/limactl' start 'ws9' --tty=false")
        #expect(HauntedLimaCLI.stopCommand(limactl: limactl, name: "ws9")
            == "'/opt/homebrew/bin/limactl' stop 'ws9'")
        #expect(HauntedLimaCLI.deleteCommand(limactl: limactl, name: "ws9")
            == "'/opt/homebrew/bin/limactl' delete --force 'ws9'")
        // $HOME must survive to the VM shell — escaped, not host-expanded. A
        // glob, because the config file is named after the console-derived
        // daemon name (or a legacy bare name) and ANY config means enrolled.
        #expect(HauntedLimaCLI.enrolledProbeCommand(limactl: limactl, vm: "ws9")
            == "'/opt/homebrew/bin/limactl' shell 'ws9' -- sh -c 'ls \"$HOME/.config/dedmesh/\"*.toml >/dev/null 2>&1'")
    }

    @Test("LIMA-04: the enroll command mirrors node-setup.sh exactly")
    func enrollCommand() throws {
        let fingerprint = String(repeating: "ab", count: 32)
        // The VM keeps the bare name; --name is the console-derived
        // username-prefixed daemon name from the mint reply.
        let command = try HauntedLimaCLI.enrollCommand(
            limactl: "/opt/homebrew/bin/limactl",
            spec: HauntedLimaCLI.EnrollSpec(
                vm: "ws9", daemon: "luiz-ws9",
                installBase: "https://console.example.com",
                control: "console.example.com:9443",
                token: "dn_0123abcd", fingerprint: fingerprint))
        #expect(command == "'/opt/homebrew/bin/limactl' shell 'ws9' -- sh -c "
            + "'curl -fsSL '\\''https://console.example.com/install.sh'\\'' | sh -s -- "
            + "--console '\\''console.example.com:9443'\\'' --token '\\''dn_0123abcd'\\'' "
            + "--name '\\''luiz-ws9'\\'' --ca-fingerprint '\\''sha256:\(fingerprint)'\\'' --haunted'")
    }

    /// One bad operand per case; everything else stays valid so the refusal
    /// is attributable.
    struct EnrollOperands: Sendable {
        var vm = "ws9"
        var daemon = "luiz-ws9"
        var base = "https://c.example.com"
        var control = "c.example.com:9443"
        var token = "dn_01"
        var fingerprint = String(repeating: "a", count: 64)
    }

    @Test("LIMA-04b: the enroll builder refuses every non-grammar operand", arguments: [
        EnrollOperands(token: "bad-token"),
        EnrollOperands(vm: "WS9"),
        EnrollOperands(daemon: "Luiz-ws9"),
        EnrollOperands(daemon: "-evil"),
        EnrollOperands(base: "https://c'.example.com"),
        EnrollOperands(control: "c.example.com:9443 --evil"),
        EnrollOperands(fingerprint: "zz"),
    ])
    func enrollCommandRejects(operands: EnrollOperands) {
        #expect(throws: HauntedCLIError.self) {
            _ = try HauntedLimaCLI.enrollCommand(
                limactl: "/x/limactl",
                spec: HauntedLimaCLI.EnrollSpec(
                    vm: operands.vm, daemon: operands.daemon,
                    installBase: operands.base, control: operands.control,
                    token: operands.token, fingerprint: operands.fingerprint))
        }
    }

    // MARK: LIMA-05 — the generated VM definition

    @Test("LIMA-05: vmYAML renders sizing, empty mounts, and the sync warning")
    func vmYAMLDefaults() throws {
        let yaml = try HauntedLimaCLI.vmYAML(spec: HauntedLimaVMSpec(name: "ws9"))
        #expect(yaml.contains("vmType: vz"))
        #expect(yaml.contains("cpus: 2"))
        #expect(yaml.contains("memory: \"2GiB\""))
        #expect(yaml.contains("disk: \"20GiB\""))
        #expect(yaml.contains("mounts: []"), "no default mounts, ever")
        #expect(yaml.contains("deploy/lima/node.yaml"), "the keep-in-sync pointer")
        #expect(yaml.contains("enable-linger"), "daemons must survive the SSH session")
        #expect(yaml.contains("get.docker.com"), "rootful Docker for the node shell")
        #expect(yaml.contains("usermod -aG docker"), "the shell user reaches the Docker socket")
        #expect(yaml.contains("ubuntu-26.04-server-cloudimg-arm64.img"))
    }

    @Test("LIMA-05b: explicit mounts render with their own writable flag")
    func vmYAMLMounts() throws {
        var spec = HauntedLimaVMSpec(name: "ws9")
        spec.cpus = 4
        spec.memoryGiB = 8
        spec.mounts = [
            HauntedLimaMount(path: "/Users/dev/proj", writable: true),
            HauntedLimaMount(path: "/Users/dev/ref", writable: false),
        ]
        let yaml = try HauntedLimaCLI.vmYAML(spec: spec)
        #expect(yaml.contains("cpus: 4"))
        #expect(yaml.contains("memory: \"8GiB\""))
        #expect(yaml.contains("- location: \"/Users/dev/proj\"\n  writable: true"))
        #expect(yaml.contains("- location: \"/Users/dev/ref\"\n  writable: false"))
        #expect(!yaml.contains("mounts: []"))
    }

    @Test("LIMA-05c: a mount path that could escape the YAML scalar throws")
    func vmYAMLRejectsHostilePaths() {
        for path in ["relative/path", "/has\"quote", "/has\\backslash", "/has\nnewline"] {
            var spec = HauntedLimaVMSpec(name: "ws9")
            spec.mounts = [HauntedLimaMount(path: path, writable: false)]
            #expect(throws: HauntedCLIError.self, "\(path) must be refused") {
                _ = try HauntedLimaCLI.vmYAML(spec: spec)
            }
        }
    }

    // MARK: LIMA-06 — the CA pin

    @Test("LIMA-06: caFingerprint hashes the DER of the FIRST PEM block only")
    func caFingerprintFirstBlock() throws {
        let der = try #require(Data(
            base64Encoded: "MIIBkTCB+wIJAKZ7Z3xkQ0AAMA0GCSqGSIb3DQEBCwUA"))
        let expected = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        #expect(HauntedLimaCLI.caFingerprint(pem: Self.caPEM) == expected)

        // A chain (leaf + intermediate) pins the leaf, not the concatenation.
        let chain = Self.caPEM + "\n" + """
        -----BEGIN CERTIFICATE-----
        AAAA
        -----END CERTIFICATE-----
        """
        #expect(HauntedLimaCLI.caFingerprint(pem: chain) == expected)

        #expect(HauntedLimaCLI.caFingerprint(pem: "not a pem") == nil)
        #expect(HauntedLimaCLI.caFingerprint(
            pem: "-----BEGIN CERTIFICATE-----\n!!!\n-----END CERTIFICATE-----") == nil)
    }

    // MARK: LIMA-07 — detection and the install base

    @Test("LIMA-07: detectLimactl is nil unless a well-known location has it")
    func detection() throws {
        var fs = HauntedTempFileSystem()
        #expect(HauntedLimaCLI.detectLimactl(fs: fs) == nil,
                "resolve's bare-name PATH fallback must read as not-installed")
        let path = fs.homeDirectory.path + "/.local/bin/limactl"
        fs.executables = [path]
        #expect(HauntedLimaCLI.detectLimactl(fs: fs) == path)
    }

    @Test("LIMA-08: installBase prefers the login flow's URL, else https on the control host")
    func installBase() throws {
        let suite = "lima-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(HauntedLimaCLI.installBase(identity: Self.identity, defaults: defaults)
            == "https://c.example.com")

        defaults.set("https://web.example.com/", forKey: "HauntedConsoleURL")
        #expect(HauntedLimaCLI.installBase(identity: Self.identity, defaults: defaults)
            == "https://web.example.com", "trailing slash trimmed")

        let bare = HauntedClientIdentity(
            stateDir: URL(fileURLWithPath: "/state"), console: nil)
        let empty = try #require(UserDefaults(suiteName: "lima-tests-2-\(UUID().uuidString)"))
        #expect(HauntedLimaCLI.installBase(identity: bare, defaults: empty) == nil)
    }

    // MARK: LIMA-09 — the dedmeshctl halves (mint + revoke)

    @Test("LIMA-09: mintNodeToken shells the exact command and validates the reply")
    func mintToken() async throws {
        var fs = HauntedTempFileSystem()
        let ctl = fs.homeDirectory.path + "/.local/bin/dedmeshctl"
        fs.executables = [ctl]

        let good = FakeProcessRunner { _ in
            Data(#"{"token":"dn_00ff","daemon":"luiz-ws9"}"#.utf8)
        }
        let minted = try await HauntedCLI.mintNodeToken(
            identity: Self.identity, node: "ws9", runner: good, fs: fs)
        #expect(minted.token == "dn_00ff")
        #expect(minted.daemon == "luiz-ws9")
        #expect(good.invocations.compactMap(\.command)
            == ["'\(ctl)' haunted token 'ws9' -json -state-dir '/state'"])

        // A malformed token or daemon name in the (remote-controlled) reply
        // never escapes into an argv.
        for reply in [
            #"{"token":"dn_x'; rm -rf ~","daemon":"luiz-ws9"}"#,
            #"{"token":"dn_00ff","daemon":"luiz-ws9'; rm -rf ~"}"#,
            #"{"token":"dn_00ff"}"#,
        ] {
            let evil = FakeProcessRunner { _ in Data(reply.utf8) }
            await #expect(throws: HauntedCLIError.self, "\(reply) must be refused") {
                _ = try await HauntedCLI.mintNodeToken(
                    identity: Self.identity, node: "ws9", runner: evil, fs: fs)
            }
        }
    }

    @Test("LIMA-09b: revokeNode shells the exact command; hostile names never spawn")
    func revoke() async throws {
        var fs = HauntedTempFileSystem()
        let ctl = fs.homeDirectory.path + "/.local/bin/dedmeshctl"
        fs.executables = [ctl]

        let runner = FakeProcessRunner()
        try await HauntedCLI.revokeNode(
            identity: Self.identity, daemon: "ws9", runner: runner, fs: fs)
        #expect(runner.invocations.compactMap(\.command)
            == ["'\(ctl)' haunted rm 'ws9' -state-dir '/state'"])

        let refused = FakeProcessRunner()
        await #expect(throws: HauntedCLIError.self) {
            try await HauntedCLI.revokeNode(
                identity: Self.identity, daemon: "-evil", runner: refused, fs: fs)
        }
        #expect(refused.invocations.isEmpty)
    }
}
