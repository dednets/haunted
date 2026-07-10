import Foundation

/// Sidebar-side state for the Lima workstations manager: which VMs exist,
/// which long operation (if any) is in flight per VM, and the create/enroll/
/// delete pipelines. Shared like HauntedSidebarModel, for the same reason —
/// every window renders the same manager state, and an op started in one tab
/// must survive that tab closing.
///
/// There is no mid-flight cancel in v1: a wedged stage is bounded by the
/// long runner's deadline (~30 min), fails visibly, and Delete recovers by
/// tearing the VM down whatever state it reached.
@MainActor
final class HauntedLimaModel: ObservableObject {
    static let shared = HauntedLimaModel()

    /// The per-VM operation the sidebar renders (spinner + stage label while
    /// in flight, an error badge for `.failed`). One op per VM at a time.
    enum Op: Equatable {
        case creating
        case starting
        case enrolling
        case stopping
        case deleting
        case failed(String)

        var isInFlight: Bool {
            if case .failed = self { return false }
            return true
        }

        var label: String {
            switch self {
            case .creating: return "creating…"
            case .starting: return "starting…"
            case .enrolling: return "enrolling…"
            case .stopping: return "stopping…"
            case .deleting: return "deleting…"
            case .failed(let message): return message
            }
        }
    }

    /// False ⇒ no `limactl` on this host ⇒ zero Lima affordances in the UI.
    @Published private(set) var available = false
    @Published private(set) var instances: [HauntedLimaInstance] = []
    @Published private(set) var ops: [String: Op] = [:]
    /// Non-fatal outcomes (a delete whose console revoke failed): shown in
    /// the sidebar's error line but nothing is blocked.
    @Published var warningMessage: String?

    private let env: HauntedLimaCLI.Environment
    private let defaults: UserDefaults

    init(
        env: HauntedLimaCLI.Environment = .init(),
        defaults: UserDefaults = .standard
    ) {
        self.env = env
        self.defaults = defaults
    }

    private var limactl: String? {
        HauntedLimaCLI.detectLimactl(fs: env.fs)
    }

    /// Called from the sidebar's poll loop (one cadence for everything). A
    /// missing limactl or a failed list keeps the last-known instances — the
    /// same no-flash rule the workstation poll follows.
    func refresh() async {
        guard let limactl else {
            available = false
            instances = []
            return
        }
        available = true
        if let fresh = try? await HauntedLimaCLI.list(env: env, limactl: limactl) {
            instances = fresh.sorted { $0.name < $1.name }
        }
    }

    /// True while `name` may not receive another operation.
    func isBusy(_ name: String) -> Bool {
        ops[name]?.isInFlight == true
    }

    /// The full "New workstation…" pipeline: write yaml → create → start →
    /// enrolled-probe → mint token → install inside the VM. Each stage updates
    /// `ops[name]`; any throw parks the VM at `.failed` (retry by re-running
    /// the stage from the row's menu, or Delete to recover).
    func createAndEnroll(spec: HauntedLimaVMSpec, identity: HauntedClientIdentity) {
        guard let limactl, !isBusy(spec.name) else { return }
        ops[spec.name] = .creating
        Task { [weak self] in
            guard let self else { return }
            do {
                try await HauntedLimaCLI.create(env: self.env, limactl: limactl, spec: spec)
                self.ops[spec.name] = .starting
                try await HauntedLimaCLI.start(env: self.env, limactl: limactl, name: spec.name)
                try await self.enrollIfNeeded(limactl: limactl, name: spec.name, identity: identity)
                self.ops[spec.name] = nil
            } catch {
                self.ops[spec.name] = .failed(error.localizedDescription)
            }
            await self.refresh()
        }
    }

    func start(name: String) {
        run(name: name, stage: .starting) { env, limactl in
            try await HauntedLimaCLI.start(env: env, limactl: limactl, name: name)
        }
    }

    func stop(name: String) {
        run(name: name, stage: .stopping) { env, limactl in
            try await HauntedLimaCLI.stop(env: env, limactl: limactl, name: name)
        }
    }

    /// Explicit enroll for a VM that exists but never finished bootstrap
    /// (the hollow-dot row's menu).
    func enroll(name: String, identity: HauntedClientIdentity) {
        run(name: name, stage: .enrolling) { [weak self] _, limactl in
            guard let self else { return }
            try await self.enrollIfNeeded(limactl: limactl, name: name, identity: identity)
        }
    }

    /// Delete = stop (best effort — the VM may already be stopped) → `limactl
    /// delete --force` → console revoke. A failed revoke is downgraded to a
    /// warning rather than failing the delete: the VM is gone either way, and
    /// the orphaned console row offers manual revoke from its own menu.
    func delete(name: String, identity: HauntedClientIdentity) {
        guard let limactl, !isBusy(name) else { return }
        ops[name] = .deleting
        Task { [weak self] in
            guard let self else { return }
            do {
                try? await HauntedLimaCLI.stop(env: self.env, limactl: limactl, name: name)
                try await HauntedLimaCLI.delete(env: self.env, limactl: limactl, name: name)
                do {
                    try await HauntedCLI.revokeWorkstation(
                        identity: identity, daemon: name,
                        runner: self.env.runner, fs: self.env.fs)
                } catch {
                    self.warningMessage =
                        "\(name): VM deleted, but the console revoke failed "
                        + "(\(error.localizedDescription)) — remove it from the "
                        + "console via the row's menu"
                }
                self.ops[name] = nil
            } catch {
                self.ops[name] = .failed(error.localizedDescription)
            }
            await self.refresh()
        }
    }

    /// Manual console revoke for an orphan row (console knows the daemon, no
    /// local VM backs it).
    func revokeConsole(name: String, identity: HauntedClientIdentity) {
        guard !isBusy(name) else { return }
        ops[name] = .deleting
        Task { [weak self] in
            guard let self else { return }
            do {
                try await HauntedCLI.revokeWorkstation(
                    identity: identity, daemon: name,
                    runner: self.env.runner, fs: self.env.fs)
                self.ops[name] = nil
            } catch {
                self.ops[name] = .failed(error.localizedDescription)
            }
        }
    }

    /// Clears a `.failed` badge (the row's "Dismiss error" action).
    func clearFailure(name: String) {
        if case .failed = ops[name] {
            ops[name] = nil
        }
    }

    private func enrollIfNeeded(
        limactl: String, name: String, identity: HauntedClientIdentity
    ) async throws {
        if await HauntedLimaCLI.isEnrolled(env: env, limactl: limactl, name: name) {
            return // already bootstrapped; a re-enroll would burn a token
        }
        ops[name] = .enrolling
        try await HauntedLimaCLI.enroll(
            env: env, limactl: limactl, name: name,
            identity: identity, defaults: defaults)
    }

    private func run(
        name: String, stage: Op,
        _ body: @escaping @MainActor (HauntedLimaCLI.Environment, String) async throws -> Void
    ) {
        guard let limactl, !isBusy(name) else { return }
        ops[name] = stage
        Task { [weak self] in
            guard let self else { return }
            do {
                try await body(self.env, limactl)
                self.ops[name] = nil
            } catch {
                self.ops[name] = .failed(error.localizedDescription)
            }
            await self.refresh()
        }
    }
}
