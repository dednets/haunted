import Testing
import Foundation
@testable import Ghostty

/// Workstation display colors (COL-*): the decode boundary that keeps a
/// hostile console out of the UI tint, the exact `dedmeshctl workstation
/// color` argv, and the model's optimistic-update / failure / poll-wins
/// behavior. The color is per-daemon console state — the Terminal that sets
/// it recolors instantly, every other Terminal follows on its next poll.
@MainActor
struct HauntedWorkstationColorTests {
    // MARK: Fakes

    /// A listing whose workstation answers are scripted per poll and whose
    /// color writes are recorded. Local to this suite: the model fakes in
    /// HauntedSidebarModelTests answer statically, and these cases are about
    /// the interleaving of an optimistic write with the polls around it.
    final class ColorListing: HauntedSessionListing, @unchecked Sendable {
        private let lock = NSLock()
        /// Answers for successive `workstations` calls; the last repeats.
        var workstationResults: [[HauntedWorkstation]] = [[]]
        var setColorResult: Result<Void, any Error> = .success(())
        private var _workstationCalls = 0
        private var _colorCalls: [(daemon: String, color: String?)] = []

        var workstationCalls: Int {
            lock.lock(); defer { lock.unlock() }; return _workstationCalls
        }
        var colorCalls: [(daemon: String, color: String?)] {
            lock.lock(); defer { lock.unlock() }; return _colorCalls
        }

        func workstations(identity: HauntedClientIdentity) async throws -> [HauntedWorkstation] {
            lock.lock()
            let index = min(_workstationCalls, workstationResults.count - 1)
            _workstationCalls += 1
            let result = workstationResults[index]
            lock.unlock()
            return result
        }

        func sessions(
            identity: HauntedClientIdentity, target: String
        ) async throws -> [HauntedWorkstationSession] {
            []
        }

        func setWorkstationColor(
            identity: HauntedClientIdentity, daemon: String, color: String?
        ) async throws {
            lock.lock()
            _colorCalls.append((daemon: daemon, color: color))
            let result = setColorResult
            lock.unlock()
            try result.get()
        }
    }

    private static let identity = HauntedClientIdentity(
        stateDir: URL(fileURLWithPath: "/state"), console: "c.example.com:9443")

    private static func workstation(
        _ target: String, color: String? = nil
    ) -> HauntedWorkstation {
        HauntedWorkstation(
            target: target, daemon: String(target.split(separator: "/")[1]),
            app: "haunted", online: true, state: nil, error: nil, color: color)
    }

    private func makeModel(
        _ client: ColorListing, pollInterval: TimeInterval = 3600
    ) -> HauntedSidebarModel {
        HauntedSidebarModel(
            client: client,
            killSession: { _, _, _ in },
            closeWorkstation: { _ in },
            pollInterval: pollInterval,
            refreshDelay: 0.05)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 3,
        _ what: @autoclosure () -> String = "condition"
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(Bool(false), "timed out waiting for \(what())")
    }

    // MARK: COL-01/02 — the decode boundary

    /// The console's stored form is lowercase "#rrggbb"; anything else in the
    /// JSON — uppercase (an old ctl that skipped normalization), garbage, a
    /// truncated value — degrades to nil, never to a raw string in the UI.
    @Test("COL-01: decode normalizes valid colors and drops invalid ones",
          arguments: [
              ("\"#e5484d\"", "#e5484d"),
              ("\"#E5484D\"", "#e5484d"),
              ("\"red\"", nil),
              ("\"#e5484\"", nil),
              ("\"#e5484dd\"", nil),
              ("\"#e5484g\"", nil),
              ("\"e5484d\"", nil),
              ("\"\"", nil),
          ] as [(String, String?)])
    func decodeNormalizesColor(colorJSON: String, expected: String?) throws {
        let json = """
        [{"target":"a/box/haunted","daemon":"box","app":"haunted",
          "online":true,"color":\(colorJSON)}]
        """
        let decoded = try HauntedCLI.decodeWorkstations(Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded.first?.color == expected)
    }

    /// Old `dedmeshctl` / console builds emit no `color` key at all; the row
    /// must decode with the default tint, not fail.
    @Test("COL-02: JSON without a color key decodes with color nil")
    func decodeWithoutColorKey() throws {
        let json = """
        [{"target":"a/box/haunted","daemon":"box","app":"haunted","online":true}]
        """
        let decoded = try HauntedCLI.decodeWorkstations(Data(json.utf8))
        #expect(decoded.first?.color == nil)
        #expect(decoded.first?.target == "a/box/haunted")
    }

    // MARK: COL-03 — normalizedColor is byte-strict

    @Test("COL-03: normalizedColor accepts exactly #rrggbb",
          arguments: [
              ("#e5484d", "#e5484d"),
              ("#E5484D", "#e5484d"),
              ("#AB12ef", "#ab12ef"),
              ("red", nil),
              ("#12345", nil),
              ("#1234567", nil),
              (" #e5484d", nil),
              ("＃e5484d", nil), // fullwidth # — not the ASCII byte
              ("#ｅ5484d", nil), // fullwidth hex lookalike
              ("", nil),
          ] as [(String, String?)])
    func normalizedColorMatrix(input: String, expected: String?) {
        #expect(HauntedWorkstation.normalizedColor(input) == expected)
    }

    // MARK: COL-04 — hexToRGB

    @Test("COL-04: hexToRGB maps normalized colors to 0…1 components")
    func hexToRGBComponents() throws {
        let red = try #require(HauntedWorkstationPalette.hexToRGB("#ff0000"))
        #expect(red.red == 1.0 && red.green == 0.0 && red.blue == 0.0)

        let blue = try #require(HauntedWorkstationPalette.hexToRGB("#0090ff"))
        #expect(blue.red == 0.0)
        #expect(abs(blue.green - Double(0x90) / 255.0) < 0.0001)
        #expect(blue.blue == 1.0)

        // Only the pre-normalized form is renderable; the renderer must not
        // re-trust what the decode boundary should have rejected.
        #expect(HauntedWorkstationPalette.hexToRGB("#FF0000") == nil)
        #expect(HauntedWorkstationPalette.hexToRGB("red") == nil)
    }

    /// Every palette preset must survive its own round trip: stored form →
    /// normalization (identity) → RGB. A preset failing this renders as the
    /// default and the menu checkmark never matches.
    @Test("COL-04b: every palette preset is normalized and renderable")
    func palettePresetsAreCanonical() {
        for preset in HauntedWorkstationPalette.presets {
            #expect(HauntedWorkstation.normalizedColor(preset.hex) == preset.hex)
            #expect(HauntedWorkstationPalette.hexToRGB(preset.hex) != nil)
        }
        #expect(Set(HauntedWorkstationPalette.presets.map(\.hex)).count
            == HauntedWorkstationPalette.presets.count, "duplicate preset values")
    }

    // MARK: COL-05 — the exact argv

    @Test("COL-05: setWorkstationColor shells the exact dedmeshctl command")
    func setColorCommand() async throws {
        var fs = HauntedTempFileSystem()
        let ctl = fs.homeDirectory.path + "/.local/bin/dedmeshctl"
        fs.executables = [ctl]
        let runner = FakeProcessRunner()

        try await HauntedCLI.setWorkstationColor(
            identity: Self.identity, daemon: "box", color: "#e5484d",
            runner: runner, fs: fs)
        try await HauntedCLI.setWorkstationColor(
            identity: Self.identity, daemon: "box", color: nil,
            runner: runner, fs: fs)

        let commands = runner.invocations.compactMap(\.command)
        #expect(commands == [
            "'\(ctl)' workstation color 'box' '#e5484d' -state-dir '/state'",
            "'\(ctl)' workstation color 'box' 'default' -state-dir '/state'",
        ])
    }

    /// `daemon` came out of remote JSON and `color` feeds an argv: a daemon
    /// name that could read as a flag, or a color that is not the normalized
    /// palette form, is refused before any process is spawned.
    @Test("COL-06: hostile daemon names and non-normalized colors never spawn",
          arguments: [
              ("-evil", "#e5484d"),
              ("box", "#E5484D"),
              ("box", "red"),
              ("box", "'; rm -rf ~"),
          ])
    func setColorRejectsHostileArguments(daemon: String, color: String) async {
        let runner = FakeProcessRunner()
        await #expect(throws: HauntedCLIError.self) {
            try await HauntedCLI.setWorkstationColor(
                identity: Self.identity, daemon: daemon, color: color,
                runner: runner, fs: HauntedTempFileSystem())
        }
        #expect(runner.invocations.isEmpty, "nothing may spawn on a refused argument")
    }

    // MARK: COL-07/08/09 — the model

    @Test("COL-07: setColor recolors every row of that daemon at once and persists")
    func setColorIsOptimistic() async throws {
        let client = ColorListing()
        let ws = Self.workstation("a/box/haunted")
        client.workstationResults = [[ws, Self.workstation("a/other/haunted")]]
        let model = makeModel(client)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })

        model.setColor(workstation: ws, color: "#30a46c")
        // The recolor is synchronous — before the CLI call resolves.
        #expect(model.workstations.first { $0.daemon == "box" }?.color == "#30a46c")
        #expect(model.workstations.first { $0.daemon == "other" }?.color == nil,
                "other daemons keep their color")

        try await waitUntil({ !client.colorCalls.isEmpty }, "the console write")
        #expect(client.colorCalls.first?.daemon == "box")
        #expect(client.colorCalls.first?.color == "#30a46c")
    }

    @Test("COL-08: a failed set surfaces the error; the next poll reverts the tint")
    func setColorFailureRevertsOnPoll() async throws {
        let client = ColorListing()
        // Every poll reports the stored truth: no color.
        client.workstationResults = [[Self.workstation("a/box/haunted")]]
        client.setColorResult = .failure(HauntedCLIError(message: "mesh down"))
        let model = makeModel(client, pollInterval: 0.05)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.loaded })

        model.setColor(workstation: Self.workstation("a/box/haunted"), color: "#e5484d")
        #expect(model.workstations.first?.color == "#e5484d", "optimistic even on doom")

        try await waitUntil({ model.errorMessage == "mesh down" }, "the failure lands")
        try await waitUntil({ model.workstations.first?.color == nil },
                            "the poll reverts the optimistic tint")
    }

    @Test("COL-09: a poll carrying another Terminal's color change wins")
    func pollAppliesRemoteColor() async throws {
        let client = ColorListing()
        client.workstationResults = [
            [Self.workstation("a/box/haunted")],
            [Self.workstation("a/box/haunted", color: "#d6409f")],
        ]
        let model = makeModel(client, pollInterval: 0.05)
        defer { model.stop() }

        model.start(identity: Self.identity)
        try await waitUntil({ model.workstations.first?.color == "#d6409f" },
                            "the remote color arrives on the next poll")
    }

    @Test("COL-10: setColor before any identity is set is a no-op")
    func setColorWithoutIdentity() async throws {
        let client = ColorListing()
        let model = makeModel(client)
        model.setColor(workstation: Self.workstation("a/box/haunted"), color: "#e5484d")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(client.colorCalls.isEmpty)
    }
}
