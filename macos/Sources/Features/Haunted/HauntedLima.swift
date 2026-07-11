import CryptoKit
import Foundation

/// One Lima VM as `limactl list --json` reports it. Only the two fields the
/// manager needs; everything else in Lima's output is ignored (and Lima's
/// JSON shape drifts across versions — see decodeInstances).
struct HauntedLimaInstance: Identifiable, Equatable {
    let name: String
    /// Lima's own vocabulary: "Running", "Stopped", … Unknown values render
    /// as-is in badges; only "Running" carries meaning here.
    let status: String

    var id: String { name }
    var isRunning: Bool { status == "Running" }
}

/// One exposed directory in the create sheet: an absolute host path plus the
/// user's explicit writable choice. There are NO default mounts — a
/// workstation exports a shell over the mesh, so every exposed directory is
/// an explicit decision (deploy/lima/workstation.yaml has the full argument).
struct HauntedLimaMount: Equatable {
    let path: String
    let writable: Bool
}

/// What the "New workstation…" sheet produces.
struct HauntedLimaVMSpec: Equatable {
    let name: String
    var cpus: Int = 2
    var memoryGiB: Int = 2
    var diskGiB: Int = 20
    var mounts: [HauntedLimaMount] = []
}

private func isWorkstationNameByte(_ byte: UInt8, leading: Bool) -> Bool {
    let alnum = (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
        || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    if leading { return alnum }
    return alnum || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
}

/// Workstation names as the user types them — the Swift port of
/// `names.ValidateWorkstationName` (`^[a-z0-9][a-z0-9_-]{0,31}$`; a leading
/// `-` would read as a CLI flag). Used to drop hostile `limactl list` entries
/// at the decode boundary and as the create sheet's live validator; the
/// console enforces the identical grammar at mint time.
func isValidWorkstationName(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 32 else { return false }
    return bytes.enumerated().allSatisfy {
        isWorkstationNameByte($0.element, leading: $0.offset == 0)
    }
}

/// Console daemon names — the Swift port of `names.ValidateDaemonName`
/// (`^[a-z0-9][a-z0-9_-]{0,64}$`): wide enough for the username-prefixed
/// workstation form. The mint reply's daemon name is remote JSON headed into
/// an argv, so it is re-checked against this before use.
func isValidDaemonName(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 65 else { return false }
    return bytes.enumerated().allSatisfy {
        isWorkstationNameByte($0.element, leading: $0.offset == 0)
    }
}

/// The sidebar-facing name of a console daemon: the caller's own
/// "<username>-" prefix stripped; legacy unprefixed names (and other users'
/// daemons) pass through unchanged. Usernames contain no hyphens, so the
/// prefix is unambiguous.
func workstationDisplayName(daemon: String, username: String?) -> String {
    guard let username, daemon.hasPrefix(username + "-") else { return daemon }
    let stripped = String(daemon.dropFirst(username.count + 1))
    return stripped.isEmpty ? daemon : stripped
}

/// Shells out to `limactl` to manage local workstation VMs. Same posture as
/// HauntedCLI: every argv is built from validated parts, and every command
/// string is exposed as a pure builder so tests compare it verbatim.
enum HauntedLimaCLI {
    /// The two runners and the filesystem travel together. `runner` is the
    /// shared 30s-deadline runner for quick ops (list, the enrolled probe);
    /// `longRunner` covers create/start/delete/enroll — a first `limactl
    /// start` downloads a cloud image and can legitimately run for many
    /// minutes, so it gets a ~30-minute deadline instead of new machinery.
    struct Environment: Sendable {
        let runner: HauntedProcessRunning
        let longRunner: HauntedProcessRunning
        let fs: HauntedFileSystem

        init(
            runner: HauntedProcessRunning = HauntedProcessRunner.shared,
            longRunner: HauntedProcessRunning = HauntedProcessRunner(timeout: 1800),
            fs: HauntedFileSystem = .real
        ) {
            self.runner = runner
            self.longRunner = longRunner
            self.fs = fs
        }
    }

    /// The absolute `limactl` path, or nil — in which case the Terminal shows
    /// zero Lima affordances (no manager rows, no "New workstation…"). Reuses
    /// HauntedCLI.resolve's well-known locations; resolve's bare-name PATH
    /// fallback is deliberately treated as "not installed", because a name
    /// that only might resolve at spawn time cannot gate UI.
    static func detectLimactl(fs: HauntedFileSystem = .real) -> String? {
        let resolved = HauntedCLI.resolve("limactl", fs: fs)
        return resolved == "limactl" ? nil : resolved
    }

    // MARK: Decode boundary

    /// `limactl list --json` emits JSONL (one object per line) on the versions
    /// this was built against, but has emitted a plain array in others — so
    /// accept both, and skip lines that fail to parse rather than failing the
    /// whole list. Names outside the daemon grammar are dropped: they could
    /// never enroll, and they would otherwise flow into argv builders.
    static func decodeInstances(_ data: Data) -> [HauntedLimaInstance] {
        struct Raw: Decodable {
            let name: String
            let status: String?
        }
        var raws: [Raw] = []
        if let array = try? JSONDecoder().decode([Raw].self, from: data) {
            raws = array
        } else {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                if let raw = try? JSONDecoder().decode(Raw.self, from: Data(line)) {
                    raws.append(raw)
                }
            }
        }
        return raws
            .filter { isValidWorkstationName($0.name) }
            .map { HauntedLimaInstance(name: $0.name, status: $0.status ?? "Unknown") }
    }

    // MARK: Pure command builders (the testable argv contract)

    static func listCommand(limactl: String) -> String {
        "\(HauntedCLI.quote(limactl)) list --json"
    }

    static func createCommand(limactl: String, yamlPath: String, name: String) -> String {
        "\(HauntedCLI.quote(limactl)) create --name=\(HauntedCLI.quote(name)) \(HauntedCLI.quote(yamlPath)) --tty=false"
    }

    static func startCommand(limactl: String, name: String) -> String {
        "\(HauntedCLI.quote(limactl)) start \(HauntedCLI.quote(name)) --tty=false"
    }

    static func stopCommand(limactl: String, name: String) -> String {
        "\(HauntedCLI.quote(limactl)) stop \(HauntedCLI.quote(name))"
    }

    static func deleteCommand(limactl: String, name: String) -> String {
        "\(HauntedCLI.quote(limactl)) delete --force \(HauntedCLI.quote(name))"
    }

    /// The "is dedmeshd already set up in this VM" probe: ANY dedmesh config
    /// file means enrolled — one VM hosts exactly one daemon by design, and
    /// the file is named after the daemon name (username-prefixed for new
    /// enrolls, bare on legacy VMs), which only the console knows
    /// authoritatively. A glob sidesteps deriving it locally. $HOME is
    /// escaped so it expands inside the VM, not on the host.
    static func enrolledProbeCommand(limactl: String, vm: String) -> String {
        let inner = "ls \"$HOME/.config/dedmesh/\"*.toml >/dev/null 2>&1"
        return "\(HauntedCLI.quote(limactl)) shell \(HauntedCLI.quote(vm)) -- sh -c \(HauntedCLI.quote(inner))"
    }

    /// A value that is about to be interpolated into a single-quoted region of
    /// the enroll command's inner shell string. isSafeCLIArgument alone is not
    /// enough there: a quote or whitespace would terminate the region.
    static func isSafeSingleQuotedValue(_ value: String) -> Bool {
        guard isSafeCLIArgument(value), !value.contains("'") else { return false }
        return !value.contains(where: \.isWhitespace)
    }

    /// Everything the in-VM enrollment interpolates. `vm` is the local Lima
    /// name (bare); `daemon` is the console-derived username-prefixed name
    /// the host enrolls as (--name).
    struct EnrollSpec {
        let vm: String
        let daemon: String
        let installBase: String
        let control: String
        let token: String
        let fingerprint: String
    }

    /// The in-VM enrollment, mirroring deploy/lima/workstation-setup.sh: pipe
    /// the console's install.sh into sh with the join token, so the VM ends up
    /// with its own dedmeshd + haunted-daemon and `[workstation] managed`.
    /// Every interpolated value is validated against the exact grammar the
    /// other side defines; the fingerprint pins the CA this client already
    /// trusts, so the VM can only enroll against OUR console.
    static func enrollCommand(limactl: String, spec: EnrollSpec) throws -> String {
        guard isValidWorkstationName(spec.vm) else {
            throw HauntedCLIError(message: "invalid workstation name")
        }
        guard isValidDaemonName(spec.daemon) else {
            throw HauntedCLIError(message: "invalid daemon name")
        }
        guard isValidJoinToken(spec.token) else {
            throw HauntedCLIError(message: "malformed join token")
        }
        guard isSafeSingleQuotedValue(spec.installBase),
              isSafeSingleQuotedValue(spec.control) else {
            throw HauntedCLIError(message: "invalid console address")
        }
        guard spec.fingerprint.utf8.count == 64, spec.fingerprint.utf8.allSatisfy({ byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }) else {
            throw HauntedCLIError(message: "invalid CA fingerprint")
        }
        let inner = "curl -fsSL '\(spec.installBase)/install.sh' | sh -s -- "
            + "--console '\(spec.control)' --token '\(spec.token)' --name '\(spec.daemon)' "
            + "--ca-fingerprint 'sha256:\(spec.fingerprint)' --workstation"
        return "\(HauntedCLI.quote(limactl)) shell \(HauntedCLI.quote(spec.vm)) -- sh -c \(HauntedCLI.quote(inner))"
    }

    // MARK: VM definition

    /// The Lima template for a GUI-created workstation VM.
    ///
    /// KEEP IN SYNC with deploy/lima/workstation.yaml (the canonical scripted
    /// template in the parent repo): vz backend, curl + user lingering
    /// provisioning, and the pinned Ubuntu images. There is no cross-repo test
    /// that can enforce this from the submodule — when the deploy template
    /// rotates its image digests, rotate them here too.
    ///
    /// Unlike the deploy template, `mounts` is caller-chosen: the GUI's create
    /// sheet adds explicit directories (each with its own writable toggle),
    /// and the default remains none at all.
    static func vmYAML(spec: HauntedLimaVMSpec) throws -> String {
        var mounts = "mounts: []"
        if !spec.mounts.isEmpty {
            mounts = "mounts:"
            for mount in spec.mounts {
                guard isSafeYAMLPath(mount.path) else {
                    throw HauntedCLIError(message: "unsupported characters in mount path \(mount.path)")
                }
                mounts += "\n- location: \"\(mount.path)\"\n  writable: \(mount.writable)"
            }
        }
        return """
        # Generated by Haunted Terminal (New workstation…); edits are overwritten.
        # Derived from deploy/lima/workstation.yaml — keep the backend,
        # provisioning, and image pins in sync with it.

        vmType: vz
        cpus: \(spec.cpus)
        memory: "\(spec.memoryGiB)GiB"
        disk: "\(spec.diskGiB)GiB"

        # Only the directories the user explicitly exposed in the create sheet.
        # A workstation exports a shell over the mesh; every mount widens what
        # that shell can reach.
        \(mounts)

        provision:
        - mode: system
          script: |
            #!/bin/bash
            set -eux
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends ca-certificates curl
            # Rootful Docker CE, so a workstation shell can build and run
            # containers. NOTE: this VM exports a shell over the mesh, and
            # membership in the docker group (below) is root-equivalent — anyone
            # who reaches this workstation's shell can escalate via the Docker
            # socket. A deliberate trade for a dev workstation.
            if ! command -v docker >/dev/null; then
              curl -fsSL https://get.docker.com | sh
            fi
            usermod -aG docker "{{.User}}"
        - mode: user
          script: |
            #!/bin/bash
            set -eux
            # dedmeshd and haunted-daemon run as `systemd --user` units. Without
            # lingering, that manager dies with the last SSH session and both
            # daemons go with it.
            sudo loginctl enable-linger "$USER"
            mkdir -p "$HOME/.local/bin"

        probes:
        - description: "curl + user lingering + rootful docker ready"
          script: |
            #!/bin/bash
            timeout 180 bash -c 'until command -v curl >/dev/null && \\
              loginctl show-user "$USER" -p Linger --value | grep -q yes && \\
              sudo docker info >/dev/null 2>&1; do sleep 2; done'

        images:
        # Ubuntu 26.04 "Resolute" — arm64 for Apple Silicon (VZ).
        - location: "https://cloud-images.ubuntu.com/releases/resolute/release-20260627/ubuntu-26.04-server-cloudimg-arm64.img"
          arch: "aarch64"
          digest: "sha256:3d8db37fa9a8a0c8676dfc0ee3eb41fd0049d66cb055a792bddc8f4123443ae1"
        # amd64 fallback for Intel Macs or other x86_64 hosts.
        - location: "https://cloud-images.ubuntu.com/releases/resolute/release-20260627/ubuntu-26.04-server-cloudimg-amd64.img"
          arch: "x86_64"
          digest: "sha256:3ee4f67f322abb2d1d1f0fffc957f7411404ad6635dd35b026c8ff05ac6e534c"
        """
    }

    /// Mount paths land inside YAML double quotes: absolute paths only, and
    /// nothing that could escape the scalar or smuggle YAML structure.
    static func isSafeYAMLPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\""), !path.contains("\\") else {
            return false
        }
        return !path.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// sha256 over the DER of the FIRST certificate block in a PEM — exactly
    /// what dedmeshd's --ca-fingerprint verifies. Computed over the LOCAL
    /// ca.pem (the CA this client already pins), never fetched: the enroll pin
    /// then proves the VM is talking to the same console we are.
    static func caFingerprint(pem: String) -> String? {
        var base64 = ""
        var inCertificate = false
        for line in pem.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----BEGIN CERTIFICATE") {
                inCertificate = true
            } else if trimmed.hasPrefix("-----END CERTIFICATE") {
                break // first block only — the leaf CA cert
            } else if inCertificate, !trimmed.isEmpty {
                base64 += trimmed
            }
        }
        guard !base64.isEmpty, let der = Data(base64Encoded: base64) else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Where install.sh is fetched from: the login flow's persisted console
    /// web URL when present, else https:// on the control host — the same
    /// derivation order the docs promise. Trailing slash trimmed so the
    /// builder can append /install.sh.
    static func installBase(
        identity: HauntedClientIdentity, defaults: UserDefaults = .standard
    ) -> String? {
        if let url = defaults.string(forKey: "HauntedConsoleURL"),
           !url.isEmpty {
            return url.hasSuffix("/") ? String(url.dropLast()) : url
        }
        guard let console = identity.console,
              let host = URLComponents(string: "//\(console)")?.host else { return nil }
        return "https://\(host)"
    }

    // MARK: Live operations

    static func list(env: Environment, limactl: String) async throws -> [HauntedLimaInstance] {
        decodeInstances(try await env.runner.run(listCommand(limactl: limactl)))
    }

    /// True when the VM already holds a dedmeshd config (the
    /// workstation-setup.sh idempotence probe): enrolling again would burn a
    /// token and re-run installs for nothing.
    static func isEnrolled(env: Environment, limactl: String, vm: String) async -> Bool {
        guard isValidWorkstationName(vm) else { return false }
        return (try? await env.runner.run(
            enrolledProbeCommand(limactl: limactl, vm: vm))) != nil
    }

    /// Writes the VM definition under Application Support (the attach-loop.sh
    /// precedent: generated artifacts live there, not in the user's dotfiles)
    /// and creates the VM.
    static func create(env: Environment, limactl: String, spec: HauntedLimaVMSpec) async throws {
        guard isValidWorkstationName(spec.name) else {
            throw HauntedCLIError(message: "invalid workstation name")
        }
        let dir = env.fs.applicationSupportDirectory
            .appendingPathComponent("HauntedTerminal/lima", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yaml = dir.appendingPathComponent("\(spec.name).yaml")
        try vmYAML(spec: spec).write(to: yaml, atomically: true, encoding: .utf8)
        _ = try await env.longRunner.run(
            createCommand(limactl: limactl, yamlPath: yaml.path, name: spec.name))
    }

    static func start(env: Environment, limactl: String, name: String) async throws {
        guard isValidWorkstationName(name) else {
            throw HauntedCLIError(message: "invalid workstation name")
        }
        _ = try await env.longRunner.run(startCommand(limactl: limactl, name: name))
    }

    static func stop(env: Environment, limactl: String, name: String) async throws {
        guard isValidWorkstationName(name) else {
            throw HauntedCLIError(message: "invalid workstation name")
        }
        _ = try await env.longRunner.run(stopCommand(limactl: limactl, name: name))
    }

    static func delete(env: Environment, limactl: String, name: String) async throws {
        guard isValidWorkstationName(name) else {
            throw HauntedCLIError(message: "invalid workstation name")
        }
        _ = try await env.longRunner.run(deleteCommand(limactl: limactl, name: name))
    }

    /// Enrolls the VM as a workstation: mint a join token over the mesh (the
    /// client identity is the credential; the console derives and returns the
    /// username-prefixed daemon name), pin the CA we already trust, and run
    /// the console's install.sh inside the VM — the exact flow of
    /// deploy/lima/workstation-setup.sh, minus the admin API.
    static func enroll(
        env: Environment, limactl: String, vm: String,
        identity: HauntedClientIdentity, defaults: UserDefaults = .standard
    ) async throws {
        guard let control = identity.console else {
            throw HauntedCLIError(message: "no console address in the client settings")
        }
        guard let base = installBase(identity: identity, defaults: defaults) else {
            throw HauntedCLIError(message: "cannot derive the console web URL")
        }
        let caFile = identity.stateDir.appendingPathComponent("ca.pem")
        guard let pem = try? String(contentsOf: caFile, encoding: .utf8),
              let fingerprint = caFingerprint(pem: pem) else {
            throw HauntedCLIError(message: "cannot fingerprint the pinned console CA")
        }
        let minted = try await HauntedCLI.mintWorkstationToken(
            identity: identity, workstation: vm, runner: env.runner, fs: env.fs)
        let command = try enrollCommand(limactl: limactl, spec: EnrollSpec(
            vm: vm, daemon: minted.daemon, installBase: base,
            control: control, token: minted.token, fingerprint: fingerprint))
        _ = try await env.longRunner.run(command)
    }
}
