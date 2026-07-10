# Haunted macOS Terminal — Test Plan

Test plan for the **Haunted feature delta** carried on top of upstream Ghostty in
the `thenets/ghostty` fork (`apps/haunted-terminal`, branch `haunted`). When this
plan was written the delta had **zero automated coverage**: `macos/Tests/` and
`macos/GhosttyUITests/` were inherited upstream suites, and `grep -ril haunt` over
both returned nothing. `make haunted-test` runs six ctest targets, all C.

Status: **Phases 1, 2 and 3 landed** (§7). `macos/Tests/Haunted/` holds ~120 test
functions across 14 suites, run green by `make haunted-test-macos`. Phases 4–5 are
still plan only. Findings marked ⚠️ are defect *candidates* spotted while reading
the code to write this plan; each is phrased as a test that should fail today.
Confirm before "fixing".

Confirmed and fixed in **Phase 1**:

- **APPR-05** — `approvalURL` returned `javascript:` / `file://` / any-scheme URLs
  straight to `NSWorkspace.shared.open`. Now both the absolute and the
  base-resolved branch must pass `isAllowedConsoleScheme`.
- **TITLE-07 / SH-07** — session `name` was never validated. Now rejected at the
  decode boundary by `isValidSessionName`, mirroring the daemon's
  `session_name_valid()` (`[A-Za-z0-9_-]{1,63}`), plus a leading-`-` ban.

Confirmed and fixed in **Phase 2** (each has a regression test named for its ID):

- **SUP-08 (was BUG-3)** — `pgrep -f` takes a POSIX **ERE**, not a literal. A
  config path holding `+` never matched the daemon actually running it, so a
  **second `dedmeshd` spawned** and the two fought the Console for one identity;
  the same wildcards could also falsely match a *different* daemon's path, so one
  that should start never did. Both directions were reproduced against the real
  `/usr/bin/pgrep`. The path is now ERE-escaped and passed after `--`.
  The most severe defect found in Phase 2.
- **LOG-04 (was BUG-4)** — `createDirectory(attributes:)` applies its mode only to
  directories it *creates*. A pre-existing `0755` `~/.config/haunted` stayed
  world-readable while `haunted enroll` wrote `key.pem` — the client's mTLS
  **private key** — into it. Now chmod'd `0700` unconditionally.
- **ID-11 (was BUG-5)** — `certIdentity` joined the base64 of *every* PEM block, so
  a certificate chain decoded to garbage (or, when the leaf's DER length happened
  to be ≡ 0 mod 3, to the leaf with a whole second cert stapled to its tail, which
  Security.framework silently ignored). Now parses the first block only. This
  answers §10 Q3's if-then: yes, chains were already broken.
- **ID-09 (was BUG-2)** — `consoleHost` of `"[::1]:9443"` returned `"["`.
- **NAME-01 (BUG-6)** — `generateSessionName` had **32 bits** of entropy, and the
  Phase 1 test drew 10 000 names asserting no collision: by the birthday bound that
  test failed ~1.16% of runs (≈1 in 86) forever, with a perfect RNG. Generator
  widened to 64 bits, and the test now states the bound it depends on.

Confirmed, **not yet fixed** — see §11: `BUG-1` (four ways to open a plain local
terminal), `BUG-7` (`login()` has no rollback), and `BUG-8` (a *plausible*,
unreproduced short read in the process runner — pre-existing).

Corrections to this plan, found by writing the tests:

- **SCHEME-05** — `URL.host` does yield `::1` unbracketed, so `http://[::1]:8080`
  is allowed. The plan's guess was right; there is now a test pinning it.
- **INV-06** — the fork overrides `applicationShouldHandleReopen`, not
  `applicationOpenUntitledFile`.
- **ID-11** — the plan predicted "→ nil" for chain PEMs. Only true for ~2/3 of
  leaf certificates; for the rest it returned the right CN for the wrong reason.
- **§2 / §8** — the separate-target advice was wrong for this project; see §8.

> **Harness trap.** `-only-testing:Suite/testName` silently runs **zero**
> swift-testing tests and exits 0. Only suite-level selectors work; that is why
> `HAUNTED_MACOS_SUITES` in the root `Makefile` lists suites, not functions. Any
> new suite must be added there or it never runs.

> **Paths.** This file lives in the `thenets/ghostty` submodule, mounted in the
> DedNets monorepo at `apps/haunted-terminal/`. Paths starting `macos/` are
> relative to the submodule root; `tests/haunted/`, `apps/`, `docs/` refer to the
> outer repo. The two repos both matter to this plan (§6 spans them).

---

## 1. Scope

The delta versus `origin/main` (`git diff --stat origin/main...HEAD`):

| File | Lines | Nature |
|---|---:|---|
| `macos/Sources/Features/Haunted/HauntedClient.swift` | 499 | New. CLI shell-out, Console login API, decode boundary, attach-loop script |
| `macos/Sources/Features/Haunted/HauntedManager.swift` | 635 | New. Session↔tab routing, sidebar layout, container view |
| `macos/Sources/Features/Haunted/HauntedSidebarView.swift` | 370 | New. Sidebar model + SwiftUI views |
| `macos/Sources/Features/Haunted/HauntedLogin.swift` | 254 | New. Startup gate, login window, menu item |
| `macos/Sources/Features/Haunted/HauntedWorkstationSupervisor.swift` | 87 | New. Local `dedmeshd` / `haunted-daemon` supervision |
| `macos/Sources/Features/Haunted/HauntedProcess.swift` | 137 | New (Phase 2, §5.1). Process-runner seam |
| `macos/Sources/Features/Haunted/HauntedFileSystem.swift` | 53 | New (Phase 2, §5.3). Filesystem-root seam |
| `macos/Sources/Features/Haunted/HauntedSessionRouter.swift` | 37 | New (Phase 3, §5.4). Where a new window lands |
| `macos/Sources/App/macOS/AppDelegate.swift` | +22/−19 | Modified. "Never a plain local terminal" |
| `macos/Sources/Features/Terminal/TerminalRestorable.swift` | +5/−9 | Modified. Restoration disabled |
| `macos/Sources/Features/Terminal/BaseTerminalController.swift` | +3 | Modified. Split inheritance hooks |
| `macos/Sources/Ghostty/Ghostty.App.swift` | +6 | Modified. **Child-exited → sidebar refresh (§4.7).** Inside an upstream-owned file; guarded by EXIT-01 |
| `macos/Ghostty.xcodeproj/project.pbxproj` | +2/−2 | Modified. Bundle ID / display name |

**In scope:** all nine files, plus the JSON and exit-code contracts the Swift
code consumes from `haunted` / `dedmeshctl`.

**Out of scope:** upstream Ghostty behavior (its own suites cover it);
libghostty-vt; the C daemon internals (`tests/haunted/` covers those);
DedMesh transport (Go tests).

---

## 2. Where these tests live

Three homes, because the code under test spans two languages and a submodule:

1. **`apps/haunted-terminal/macos/Tests/Haunted/`** — the Haunted unit tests,
   inside upstream's existing `GhosttyTests` target. **Landed.** `Tests/` is a
   `PBXFileSystemSynchronizedRootGroup`, so files added under it need no
   `project.pbxproj` edit at all — strictly less rebase surface than a separate
   target would cost (see §8).
2. **`apps/haunted-terminal/macos/GhosttyUITests/`** — the L3 invariants, when
   Phase 5 arrives. Same reasoning: it is already a synchronized root group.
3. **`tests/haunted/fixtures/`** — golden JSON contract files, written by a C
   test and read by the Swift tests (see §6.1). This is the only piece that
   lives in the DedNets monorepo proper.

Make target, kept out of the default `make test` and out of `make haunted-test`
(which is ctest/C only):

```make
haunted-test-macos:   ## Swift/macOS tests for the Haunted fork delta
	xcodebuild test \
	  -project apps/haunted-terminal/macos/Ghostty.xcodeproj \
	  -scheme Ghostty \
	  -destination 'platform=macOS,arch=arm64' \
	  -only-testing:GhosttyTests/Haunted…   # one flag per Haunted suite
```

The `-only-testing` filter, not a custom `.xctestplan`, is what keeps the run
fast and independent of upstream's own suites.

### Tier placement

The three-tier model in `CLAUDE.md` does not fit here: Swift is macOS-only, so
the Lima VM (Tier 1) cannot run any of it. Effective placement:

- **Tier 0 (macOS host)** — L0/L1/L2 below. This is nearly everything.
- **Tier 0 + built C binaries** — L2 needs `make haunted-build` to have run, so
  the tests can spawn a real `haunted-daemon`.
- **Manual** — L4. The mesh round trip (real console, real workstation) is not
  worth automating yet; keep it a checklist.

---

## 3. Test layers

| Layer | What it can touch | Speed | Where |
|---|---|---|---|
| **L0** Pure unit | No process, no network, no filesystem, no `NSApp` | <1ms | `HauntedTests/` |
| **L1** Seam unit | Injected fakes: process runner, `URLProtocol`, temp `HOME`, scratch `UserDefaults` | ~ms | `HauntedTests/` |
| **L2** Local integration | Spawns the real `haunted-daemon` + real `haunted` CLI over a temp `AF_UNIX` socket. No mesh. | ~s | `HauntedTests/` |
| **L3** UI | Launches the app bundle, drives menus/windows | ~10s | `HauntedUITests/` |
| **L4** Manual | Real console, real workstation, real network | — | checklist |

L0 is where most of the security-relevant logic lives, and it needs no
refactoring to reach. **Start there.** L1 needs the seams in §5.

---

## 4. Test matrix

### 4.1 `HauntedClient.swift` — decode & argument boundary

The highest-value target in the delta: it is the trust boundary between
remote-controlled JSON and a hand-rolled CLI arg parser with no `--`
end-of-options marker.

#### `URL.isAllowedConsoleScheme` — L0, table-driven

| ID | Input | Expect | Why |
|---|---|---|---|
| SCHEME-01 | `https://console.example.com` | allow | happy path |
| SCHEME-02 | `HTTPS://console.example.com` | allow | scheme lowercased |
| SCHEME-03 | `http://localhost:8080` | allow | local console dev |
| SCHEME-04 | `http://127.0.0.1:8080` | allow | — |
| SCHEME-05 | `http://[::1]:8080` | allow | ✅ `URL.host` does yield `::1` unbracketed on macOS; pinned by a test |
| SCHEME-06 | `http://console.example.com` | **deny** | plaintext credential interception |
| SCHEME-07 | `http://localhost.evil.com` | **deny** | suffix-match trap; host is not in the set |
| SCHEME-08 | `http://127.0.0.1.evil.com` | **deny** | same |
| SCHEME-09 | `http://LOCALHOST` | allow | host lowercased |
| SCHEME-10 | `ftp://localhost` | **deny** | — |
| SCHEME-11 | `//console.example.com` (no scheme) | **deny** | — |
| SCHEME-12 | `file:///etc/passwd` | **deny** | — |

#### `isSafeCLIArgument` + decode filtering — L0

| ID | Case | Expect |
|---|---|---|
| ARG-01 | `""` | unsafe |
| ARG-02 | `"-target"` | unsafe (would be read as a flag) |
| ARG-03 | `"--create"` | unsafe |
| ARG-04 | `"user/box/haunted"` | safe |
| ARG-05 | `workstations` JSON with a `-`-prefixed `target` | that element is **dropped**, others survive |
| ARG-06 | `sessions` JSON with a `-`-prefixed `name` | dropped |
| ARG-07 | Session name `"gui-\u{07}x"` | ✅ **fixed** — `isValidSessionName` rejects it at decode, so it never reaches `attach-loop.sh`'s OSC-0 `printf`. See TITLE-07. |

`kill`'s parser (`apps/haunted-terminal/src/cli/main.c:1380`) treats
`argv[i][0] != '-'` as the positional — ARG-02/03 confirm the Swift-side filter
is what keeps a crafted session name from being read as a flag.

#### `HauntedCLI.quote` — L0 property test

| ID | Case | Expect |
|---|---|---|
| QUOTE-01 | For each of `'`, `"`, `` ` ``, `$(id)`, `;rm -rf /`, `\n`, `*`, `~`, `日本語` | `/bin/zsh -lc "printf %s \(quote(s))"` echoes `s` byte-for-byte |
| QUOTE-02 | `"it's"` | → `'it'\''s'` |
| QUOTE-03 | Empty string | → `''` (not the empty token) |

Run QUOTE-01 as a real `zsh` round trip, not a string-equality assertion — the
whole point is what the shell does with it.

#### Model decoding — L0

| ID | Case | Expect |
|---|---|---|
| DEC-01 | `HauntedClientLoginRedeem` from snake_case JSON | `client_name`→`clientName`, `control_port`→`controlPort`, `ca_pem`→`caPEM` |
| DEC-02 | Session JSON **without** `title` (pre-`MSG_SESSION_LIST_V2` daemon) | decodes, `title == nil` |
| DEC-03 | Session JSON with unknown extra keys | decodes (forward compat) |
| DEC-04 | Workstation JSON with `error` and `state` absent | decodes |
| DEC-05 | `pid` at `UInt32.max` | decodes |
| DEC-06 | Malformed JSON | throws, does not crash |

#### `HauntedWorkstation.status` / `statusColor` — L0

| ID | `online` | `state` | Expect `status` |
|---|---|---|---|
| STAT-01 | true | `nil` | `online` |
| STAT-02 | true | `"error"` | `online` (online wins) |
| STAT-03 | false | `"active"` | `offline` (the `!= "active"` guard falls through) |
| STAT-04 | false | `"error"` | `error` |
| STAT-05 | false | `nil` | `offline` |

#### `HauntedWorkstationSession.displayTitle` — L0

Titles are attacker-influenced: any program in the remote session sets them via
OSC 0/2.

| ID | `title` | Expect |
|---|---|---|
| TITLE-01 | `nil` | falls back to `name` |
| TITLE-02 | `""` | falls back to `name` |
| TITLE-03 | `"vim ~/notes.md"` | unchanged |
| TITLE-04 | `"a\u{07}b"` (BEL, `.control`) | `"ab"` |
| TITLE-05 | `"a\u{202E}b"` (RTL override, `.format`) | `"ab"` — no visual row spoofing |
| TITLE-06 | `"\u{07}\u{07}"` (all stripped) | falls back to `name` |
| TITLE-07 | Session **`name`** = `"gui-\u{07}x"`, `title` = `nil` | ✅ **fixed** — rejected at the decode boundary (`isValidSessionName`), not at display, so `displayTitle`'s `name` fallback is safe by construction. Confirmed failing before the fix. |

Note: `.surrogate` in the filter is unreachable — a Swift `String` cannot hold a
lone surrogate scalar. Harmless, but do not write a test that pretends to cover it.

#### `HauntedClientIdentity` — L1 (needs temp `HOME`, §5.3)

| ID | Case | Expect |
|---|---|---|
| ID-01 | All four of `cert.pem`, `key.pem`, `settings.json`, `ca.pem` in `~/.config/haunted` | identity loads |
| ID-02 | `key.pem` missing | `load()` → `nil` |
| ID-03 | `settings.json` missing, others present | `nil` (all four required) |
| ID-04 | Default dir incomplete, legacy `~/.config/haunted/client` complete | legacy used |
| ID-05 | Both complete | default preferred |
| ID-06 | `settings.json` is malformed | identity loads, `console == nil` (no throw) |
| ID-07 | `consoleHost` of `"console.example.com:9443"` | `"console.example.com"` |
| ID-08 | `consoleHost` of `nil` | `"DedMesh"` |
| ID-09 | `consoleHost` of `"[::1]:9443"` | ✅ **fixed** — was `"["` (split on `":"` took the first component). Now `URLComponents`-parsed → `"[::1]"`. Note `URLComponents.host` keeps brackets, `URL.host` strips them (SCHEME-05); do not unify. |
| ID-10 | `certIdentity` from a fixture cert with `CN=alice/term` | `"alice/term"` |
| ID-11 | `certIdentity` from a **chain** PEM (leaf + intermediate) | ✅ **fixed** — parses the first PEM block only. The plan's "→ nil" was right for ~1/3 of leaves (padded DER → invalid base64) but for the rest the joined blob decoded and Security.framework *silently ignored the stapled second cert*, returning the right CN for the wrong reason. Both fixtures (ID-11a padded, ID-11b unpadded) are pinned. |
| ID-12 | `certIdentity`, unreadable file | `nil` |
| ID-13 | `certIdentity`, garbage base64 | `nil` |

#### `approvalURL(base:)` — L0

| ID | `url` from console | Expect |
|---|---|---|
| APPR-01 | `https://console.example.com/approve?id=1` | passthrough |
| APPR-02 | `/approve?id=1` | resolved against base, **query preserved** |
| APPR-03 | `approve` (no leading `/`) | `nil` |
| APPR-04 | `""` | `nil` |
| APPR-05 | `javascript:alert(1)` | ✅ **fixed** — `isAllowedConsoleScheme` is now required on both the absolute and the base-resolved branch, so `javascript:`, `file:///…` and custom app schemes return `nil` instead of reaching `NSWorkspace.shared.open`. Confirmed failing before the fix. |

#### `attachCommand` / `attachLoopPath` — L1

| ID | Case | Expect |
|---|---|---|
| LOOP-01 | `create: true` | command ends with ` --create` |
| LOOP-02 | `create: false` | no `--create` |
| LOOP-03 | Target/session containing `'` | quoted; `zsh -lc` round trip yields the original argv |
| LOOP-04 | First call | script written, mode `0755` |
| LOOP-05 | Second call in the same launch | not rewritten (`wroteAttachLoop`), same path returned |
| LOOP-06 | Application Support dir unwritable | returns a path, logs, does not throw |

#### `attach-loop.sh` behavior — L1, driven by `/bin/sh` with a stub `haunted`

Extract the script to a bundle resource first (§5.5) so it can be run directly.

| ID | Stub `haunted attach-remote` behavior | Expect |
|---|---|---|
| SH-01 | exit 0 immediately | loop exits 0, exactly 1 invocation |
| SH-02 | always exit 1 | 20 invocations, exit 1 |
| SH-03 | exit 1 three times then 0 | 4 invocations, exit 0 |
| SH-04 | always exit 7 | final exit code is 7, not 1 |
| SH-05 | delay schedule with a stub `sleep` recording its argument | `2,4,6,8,10,10,10,…` — growth by 2, capped at 10 |
| SH-06 | `SIGINT` during backoff | exit 130, `reconnect cancelled` on stdout |
| SH-07 | Session name `x\u{07}y` | ⚠️ OSC-0 title terminates early, remainder injected into the local terminal. Blocked by TITLE-07's fix. |

`attach-remote`'s exit-code contract (0 = clean detach or session killed;
nonzero = transport failure) is what SH-01/04 depend on. Pin it C-side too — see
§6.2.

#### `HauntedCLI.run` — L1

| ID | Case | Expect |
|---|---|---|
| RUN-01 | Child exits 0, stdout `{"a":1}` | returns that `Data` |
| RUN-02 | Child exits 3, stderr `boom` | `HauntedCLIError(message: "boom")` |
| RUN-03 | Child exits 3, stderr empty | `"command failed (3)"` |
| RUN-04 | Child writes 1 MiB to stdout then exits 0 | no deadlock, all bytes returned. **This is the reason `OutputCollector` exists** — a pipe buffer is ~64 KiB. |
| RUN-05 | Child writes 1 MiB to stderr and exits nonzero | no deadlock |
| RUN-06 | Executable does not exist | throws, no hang |
| RUN-07 | 32 concurrent `run` calls under **ThreadSanitizer** | no data race in `OutputCollector` |
| RUN-08 | Child reads stdin | gets EOF (`nullDevice`), does not block |
| RUN-09 | Child never exits (`sleep 300`, 1s deadline) | the call **throws a timeout promptly** — no `run()` outlives its deadline. Regression test for BUG-13 (§11): the `waitUntilExit` freeze that silently killed the sidebar poll loop. |
| RUN-09b | Same, synchronous `runToCompletion` | returns `-1` at the deadline |
| RUN-10 | Child wedged past the deadline | the child is **SIGKILLed**, not merely abandoned |
| RUN-11 | Prompt child under a generous deadline | unaffected — the deadline is a ceiling, not a floor |

`HauntedCLI.resolve` — L1: prefers `~/.local/bin`, then `/opt/homebrew/bin`,
then `/usr/local/bin`, then bare name; skips non-executable candidates.

---

### 4.2 `HauntedWorkstationSupervisor.swift` — L1 (needs the process seam)

| ID | Case | Expect |
|---|---|---|
| SUP-01 | No `~/.config/dedmesh` | `ensureRunning() == false`, nothing spawned |
| SUP-02 | Dir exists, no `.toml` | `false`, nothing spawned |
| SUP-03 | Dir has `a.conf` only | `.toml` filter excludes it |
| SUP-04 | One `.toml`, `dedmeshd` not running | spawns `haunted-daemon --daemonize` **before** `dedmeshd`. Assert spawn *order* — the comment explains the 30s socket-probe window that ordering protects. |
| SUP-05 | Two `.toml`, one already running | exactly one `dedmeshd` spawned |
| SUP-06 | `haunted-daemon` already up (exits 1 via its pidfile guard) | `ensureRunning()` still returns `true` iff a `dedmeshd` was spawned |
| SUP-07 | Nothing to start | `false` — caller skips the online-wait |
| SUP-08 | Config path `~/.config/dedmesh/a+b.toml` | ✅ **fixed** — `pgrep -f` takes an **ERE**, so `+` was a quantifier and `.` matched any char. Confirmed against the real `/usr/bin/pgrep` in *both* directions: a running daemon was missed (→ a second spawned, the two fighting the console for one identity), **and** the pattern falsely matched a daemon at `ab.toml` (→ one that should start, didn't). Path is now ERE-escaped and passed after `--`. |
| SUP-09 | `pgrep` binary missing | returns `false`, no crash |

---

### 4.3 `HauntedManager.swift`

Pure logic first — extract `HauntedSessionRouter` (§5.4) so these are L0:

Startup **never creates** a session — a session only appears from an explicit
click. `route` takes the last target's session list and resumes (with
`create: false`) only when the remembered session is still there; everything
else lands on the `.empty` "Nothing here" state (sidebar shown, no shell).

| ID | `lastAttached` | Workstations / sessions | Expect |
|---|---|---|---|
| OPEN-01 | `(box, work)`, `box` online, `work` listed | resume `box`/`work` (`create: false`) |
| OPEN-02 | `(box, gui-…)`, `box` online, session **gone** | `.empty` — never re-create the remembered session |
| OPEN-03 | `(box, work)`, `box` **offline**, `other` online | `.empty` — no auto-attach to another workstation |
| OPEN-04 | `nil`, a workstation online | `.empty` — no auto-open on a fresh launch |
| OPEN-05 | `nil`, none online | `.empty` |
| OPEN-06 | `(box, work)`, `box` offline but `work` in a stale list | `.empty` — offline beats the stale list |

| ID | Case | Expect |
|---|---|---|
| TAB-01 | `focusOrOpen(sessionName: nil)` | generated `gui-xxxxxxxx` name, `create: true` |
| TAB-02 | `focusOrOpen(sessionName: "work")` | `create: false` — the daemon does not create on raw attach |
| TAB-03 | Session already open in a live window | focuses it, opens **no** new tab |
| TAB-04 | Session in `sessionTabs` but its window is gone | opens a new tab (weak value → `nil`) |
| TAB-05 | `tabKey("a/b", "c")` vs `tabKey("a", "b/c")` | distinct — the `\u{1}` separator is doing real work |
| KILL-01 | `sessionTabClosePlan(siblingTabCount:)` | last tab → `.emptyState`; with siblings → `.closeTab`. Killing the *last* session must NOT close the window — `window.close()` frees the attached `SurfaceView` while libghostty is still delivering a scrollbar action into it (use-after-free, `SIGABRT` in `Ghostty.App.scrollbar`). The last tab drops to the "Nothing here" empty state instead. |
| KILL-02 | CLI kill throws | logged, `hauntedSessionsDidChange` still posted |
| NAME-01 | `generateSessionName()` × 10 000 | all match `^gui-[0-9a-f]{16}$`, no collisions. ⚠️ The uniqueness half is a *statistical* claim: P(collision) ≈ 1 − exp(−n(n−1)/2N). At the original 8 hex digits (N = 2³²) that is **1.16% per run** — the Phase 1 test was flaky by construction, ~1 failure in 86 runs. Widened to 16 digits (2.7e-12) in Phase 2; a companion test asserts the entropy width the assertion depends on. Do not narrow the generator without deleting the uniqueness assertion. |
| CFG-01 | `buildConfiguration` | `waitAfterCommand == true`, `initialInput` ends with `\n` |
| LAST-01 | `HauntedLastTarget` set, `HauntedLastSession` unset | `lastAttached == nil` |

Split inheritance (L1, `@MainActor`):

| ID | Case | Expect |
|---|---|---|
| SPL-01 | Split from a Haunted surface | child gets a fresh session on the parent's target, `create: true` |
| SPL-02 | Split from a non-Haunted surface | `base` config returned unchanged, `pendingSplitSessionName` stays `nil` |
| SPL-03 | `splitConfiguration` then `surfaceCreated` | pending name consumed exactly once; a second `surfaceCreated` sees `nil` |
| SPL-04 | `splitConfiguration` where surface creation then fails | ⚠️ `pendingSplitSessionName` leaks into the next split, which adopts the wrong name. **Expected to fail.** |
| SPL-05 | Swift 6 strict concurrency | ⚠️ `splitConfiguration` is non-isolated but mutates `pendingSplitSessionName`; `surfaceCreated` is `@MainActor`. Compile the target with `-strict-concurrency=complete` and assert it builds. |

Session landing (`HauntedManager.sessionLanded`, L1 with an injected listing) —
the ⌘T/⌘D → sidebar hand-off: a fresh tab/split's session exists daemon-side
only once its `haunted attach --create` runs, and the sidebar is told the
moment it does instead of waiting out the next poll:

| ID | Case | Expect |
|---|---|---|
| LAND-01 | Session listed with `clients > 0` on the first poll | `true`, exactly one listing call |
| LAND-02 | Listed with `clients == 0`, attaches on the third poll | keeps polling, `true` after three calls |
| LAND-03 | Session never appears | `false` at the deadline — bounded, never forever |
| LAND-04 | Listing throws once, then lists the session | the failure is retried, `true` |

Overlay (L1):

| ID | Case | Expect |
|---|---|---|
| OVL-01 | Session reports `clients > 0` | overlay hidden within one poll (~700ms) |
| OVL-02 | Session never attaches | overlay hidden after the 15s deadline — the reconnect banner must become visible |
| OVL-03 | `showConnectingOverlay` twice | previous overlay removed, not stacked |
| OVL-04 | Overlay frame | covers the terminal area only; the sidebar stays interactive |

`HauntedSidebarLayout` (L1, scratch `UserDefaults`):

| ID | Case | Expect |
|---|---|---|
| LAY-01 | Saved width `50` (below `minWidth`) | falls back to `220` |
| LAY-02 | Saved width `9999` | clamped to `480` |
| LAY-03 | `propose(300)` while expanded | width `300` |
| LAY-04 | `propose(600)` | clamped to `480` |
| LAY-05 | `propose(40)` while collapsed (`< minWidth/2`) | no-op, stays collapsed |
| LAY-06 | `propose(120)` while collapsed (`> minWidth/2 == 80`) | expands, width `160` |
| LAY-07 | `setCollapsed(true)` then `setCollapsed(false)` inside `animationDuration` | final state expanded, `contentVisible == true`; the deferred closure's `if !self.contentVisible` guard must not strand it |
| LAY-08 | Persisted across instances | `collapsed` and `width` restored |

---

### 4.4 `HauntedSidebarView.swift`

`HauntedSidebarModel` is a `@MainActor` singleton — make it instantiable (§5.4)
or every test poisons the next.

| ID | Case | Expect |
|---|---|---|
| MOD-01 | `start(identity:)` twice, same identity | one poll task |
| MOD-02 | `start(identity:)` with a different identity | poll restarted, `loaded == false` |
| MOD-03 | Poll throws | `errorMessage` set, **previous `workstations` retained** (no flash-to-empty) |
| MOD-04 | Poll recovers | `errorMessage` cleared |
| MOD-05 | First successful load | online workstations auto-expanded; offline ones not |
| MOD-06 | Second load | expansion **not** re-derived for hosts already present — a user collapse survives the poll |
| MOD-07 | `kill` | session optimistically removed from `sessionsByTarget` immediately |
| MOD-08 | `hauntedSessionsDidChange` posted | refresh fires after the 1.2s debounce, once |
| MOD-09 | Ordering | workstations by `target`, sessions by `name` |
| MOD-10 | `refreshSessions` with one workstation failing | other workstations still update |
| MOD-11 | Poll task cancelled (window closed) | no data reset; a later `start` resumes |
| MOD-12 | A host removed from the console vanishes from a later poll | its tabs closed (`closeWorkstation` seam), `sessionsByTarget` + `expanded` pruned; surviving hosts untouched |
| MOD-13 | A host added to the console appears on a later poll | it arrives auto-expanded (online only); a user's earlier collapse of another host survives |
| MOD-14 | `applyLocalTitle` for a session the model knows | the row's `title` updates **without a CLI round-trip** — the daemon pushes titles to attached clients instantly (that is what retitles the tab), so an open session's sidebar row follows its tab rather than the next list poll. Unknown target/session: strict no-op, no row fabricated. |

MOD-05/06/13 now share one path (`reconcile`): first-load expansion is the
`previous == []` case of "expand newly-appeared online hosts", so a broken
expand loop fails MOD-05 and MOD-13 together (verified by surgical revert). The
removal half (MOD-12) is independent. Discovery is poll-only — the client has no
push channel for topology (mesh read loop handles only heartbeat + punch), so
add/remove reflect within the poll interval (dropped to 4s), not instantly.

Views (L0 via `ViewInspector`, or fold into L3 if that dependency is unwanted —
prefer folding; do not add a dependency for four assertions):

- Offline workstation row is disabled and dimmed (`opacity 0.5`).
- `statusColor`: online→green, `state == "error"`→red, else grey.
- `isOpenHere` row uses accent color and medium weight.
- Session row shows `displayTitle` (never the raw `name`) and `cols×rows`.

---

### 4.5 `HauntedLogin.swift`

| ID | Case | Expect |
|---|---|---|
| START-01 | A Haunted window is open | focused; no new window, no login |
| START-02 | No identity | login window shown |
| START-03 | Identity present, `workstations` succeeds | `openWindow` called |
| START-04 | Identity present, `workstations` throws (revoked cert) | login window shown with the error text |
| START-05 | Identity present, zero workstations, no error | Haunted window opens anyway — offline ≠ logged out |
| WAIT-01 | `justStarted == true`, online on attempt 3 | breaks early, ≤ ~1.5s |
| WAIT-02 | `justStarted == true`, never online | 6 attempts, returns the last (offline) list, ~3s |
| WAIT-03 | `justStarted == true`, `workstations` throws on attempt 1 | propagates immediately — no retry. Confirm this is intended. |
| WAIT-04 | `justStarted == false` | exactly one `workstations` call |
| MENU-01 | `install()` | "Log in with DedMesh Console…" at File index 0, separator below, ⌘⇧L |
| MENU-02 | `install()` called twice | ⚠️ two items, two separators — no idempotency guard. **Expected to fail.** Cheap to fix, cheap to regress on a rebase. |
| MENU-03 | Main menu localized (no item titled "File") | falls back to `items[1]`; assert it does not crash or target the wrong menu |
| MENU-04 | `NSApp.mainMenu == nil` | no-op |

`HauntedLoginView` (L1):

| ID | Case | Expect |
|---|---|---|
| LGN-01 | `beginLogin` with `http://evil.com` | error shown, **no network call** |
| LGN-02 | `beginLogin` with an unparseable URL | error shown |
| LGN-03 | `beginLogin` success | `HauntedConsoleURL` persisted, `NSWorkspace.open(approvalURL)`, code field revealed |
| LGN-04 | `beginLogin` fails | `HauntedConsoleURL` **not** persisted |
| LGN-05 | Code field typed `"12ab34cd56"` | becomes `"123456"`, capped at 8 |
| LGN-06 | `finishLogin` with empty `requestID` | no-op |
| LGN-07 | `finishLogin` success | state cleared, `onLoggedIn()` fired once |
| LGN-08 | `busy` | button disabled; re-entrancy impossible |

`HauntedClientLoginAPI` (L1, `URLProtocol` stub — §5.2):

| ID | Case | Expect |
|---|---|---|
| API-01 | `start` | `POST /api/v0/client-login/start`, body `client_name: "term"`, `device_label:` host name |
| API-02 | Console URL has a path and query (`https://c.example/x?y=1`) | both replaced — request path is exactly the API path, query `nil` |
| API-03 | HTTP 400, body `"bad code"` | `HauntedCLIError("bad code")` |
| API-04 | HTTP 500, empty body | `"Console returned HTTP 500"` |
| API-05 | Non-HTTP response | `"No HTTP response from Console"` |
| API-06 | 200 with unparseable JSON | decode error propagates |
| API-07 | `http://evil.com` | throws before any request is issued |

`HauntedCLI.login` (L1, temp `HOME` + process seam):

| ID | Case | Expect |
|---|---|---|
| LOG-01 | Happy path | `~/.config/haunted` created `0700`, `ca.pem` written, `enroll` invoked with `host:controlPort` |
| LOG-02 | `control_port` empty | defaults to `9443` |
| LOG-03 | Console URL with no host | `"Invalid Console URL"`, nothing written |
| LOG-04 | State dir already exists as `0755` | ✅ **fixed** — `createDirectory(attributes:)` applies its mode only to dirs it creates, so an existing `0755` dir survived and `haunted enroll` wrote `key.pem` (the mTLS **private key**) into it. Now `setAttributes(0o700)` unconditionally. Decided §10 Q2: yes, harden. |
| LOG-05 | `enroll` fails | ⚠️ `ca.pem` from the failed attempt is left behind — **confirmed**, green characterization test. Harmless (a public CA cert) but it makes `hasLogin` half-true. See §11 BUG-7. |

---

### 4.6 Fork integration — "never a plain local terminal"

**This is the invariant a rebase onto upstream Ghostty will silently break**, and
the reason the fork exists in this shape. Upstream adds a new code path to
`TerminalController.newWindow(...)` and the app quietly opens an unattached local
shell. Nothing today would catch it.

L3 (XCUITest) unless noted:

| ID | Trigger | Expect |
|---|---|---|
| INV-01 | Cold launch, no identity | login window, **no terminal window** |
| INV-02 | Cold launch, identity present | Haunted window with a sidebar |
| INV-03 | ⌘N | `HauntedLoginController.startup()` — focuses the existing Haunted window; never a plain terminal |
| INV-04 | ⌘T with a Haunted parent | new tab on the focused daemon |
| INV-05 | ⌘T with no window | `startup()` |
| INV-06 | Dock reopen (`applicationShouldHandleReopen`, *not* `applicationOpenUntitledFile`) | `startup()`, returns `false` |
| INV-07 | `ghosttyNewWindow` notification | `startup()` |
| INV-08 | `ghosttyNewTab` from a non-`TerminalController` window | ignored |
| INV-09 | **L0**: `TerminalWindowRestoration.restoreWindow` | always `completionHandler(nil, nil)`, regardless of `window-save-state` |
| INV-10 | Relaunch after quit with 3 tabs open | zero windows restored |
| INV-11 | Every `TerminalController.newWindow` call site in `macos/Sources` | ✅ **implemented as an L0 grep test** (`newWindowCallSitesArePinned`), pulled forward into Phase 1 — it is the only guard that survives a rebase. It found that the invariant is **not** actually held: see §11, BUG-1. |

⚠️ INV-09 also documents dead code: everything after the unconditional `return`
in `TerminalRestorable.swift:142` is unreachable. Either delete it or leave a
comment saying it is kept for rebase context — right now it reads as live logic.

---

### 4.7 Session lifetime — a process exit must reap the session everywhere

When the remote shell ends — the user typed `exit`, or pressed ctrl-D — three
things must happen, in three different codebases. The chain is what makes this
worth its own section: any one link failing leaves a *corpse* in the sidebar, and
clicking a corpse reattaches to a session the daemon has already destroyed.

The chain, as implemented:

1. **Daemon (C).** `session_reap_children()` sees the pane's child exit. If a
   client is attached it delivers `MSG_EXIT_STATUS` and marks the session
   `exited`; `session_detach_client()` then destroys it once that client
   detaches. If nobody is attached it destroys the session immediately — "a dead
   session must not linger — it would show in the sidebar and let a click
   reattach to a corpse" (`apps/haunted-daemon/src/session.c`).
2. **CLI.** `haunted attach-remote` receives the exit status and exits **0**.
   `attach-loop.sh` treats 0 as "clean detach or session killed" and stops
   looping rather than reconnecting to a session that no longer exists.
3. **Terminal (Swift).** The surface's process has now exited. The fork's hook in
   `Ghostty/Ghostty.App.swift`'s `showChildExited` posts
   `.hauntedSessionsDidChange`, so the sidebar refreshes at once instead of
   showing the dead row for up to the 10 s poll interval. The **tab stays open**
   with its exit banner, deliberately: `waitAfterCommand = true`, because an
   empty surface tree closes the window and that reads to the user as a crash.

| ID | Case | Expect | Status |
|---|---|---|---|
| EXIT-01 | `Ghostty.App.swift` still posts `.hauntedSessionsDidChange` on child exit | grep guard passes | ✅ `HauntedForkInvariantTests` |
| EXIT-02 | An attached surface sets `waitAfterCommand` | exit banner, tab survives | ✅ `HauntedForkInvariantTests` |
| EXIT-03 | Daemon stops listing a session → refresh | its sidebar row disappears; the last one leaves an empty list | ✅ `HauntedSidebarModelTests` |
| EXIT-04 | `attach-remote` exits 0 | the loop stops, exactly one invocation | ✅ SH-01 |
| EXIT-05 | **C:** pane's child exits with **no** client attached | session destroyed immediately; absent from `haunted list` | ✅ `tests/haunted/test_daemon.c` |
| EXIT-06 | **C:** pane's child exits **while** a client is attached | `MSG_EXIT_STATUS` delivered, then reaped on detach | ✅ `tests/haunted/test_daemon.c` |
| EXIT-07 | **L4 manual:** type `exit` in a Haunted tab | banner appears, sidebar row vanishes within ~1.2 s, `haunted list` no longer shows it | ⬜ checklist |
| EXIT-08 | The **deployed** workstation daemon is as new as the source | see §11 BUG-10 | ⬜ nothing checks this |

EXIT-05/06 landed with `4fa71c2` ("session reaping when process exits"). Note what
that leaves uncovered: every one of these tests exercises the daemon **built from
this source tree**. Nothing anywhere checks the daemon *actually running on a
workstation*, which is how BUG-10 shipped a green suite and a broken product.

EXIT-01 is a **grep** rather than a runtime check on purpose. The hook is six
lines inside a file upstream owns; a rebase that resolves that switch statement
in upstream's favour drops the post silently, and nothing else in the app
notices. This is the same reasoning as INV-11.

EXIT-05/06 belong in `tests/haunted/test_daemon.c` — the reap-on-detach ordering
is a C-side invariant and a Swift test can only observe it through two
subprocesses. Not yet written.

**Open question.** Should a *clean* exit (status 0) close the tab, rather than
leave a banner? Today every exit leaves one, which is right for a crashed attach
(§4.1 SH-04 propagates the code so the user sees it) and arguably wrong for
`exit`, where the user has already said they are done and now has to close the
tab a second time. Changing it means distinguishing exit 0 from the rest, and
`waitAfterCommand` is a libghostty surface setting with no such distinction.

---

## 5. Refactors required (the actual blocker)

Almost nothing above L0 is reachable today. `HauntedCLI`,
`HauntedWorkstationSupervisor` and `HauntedClientLoginAPI` are `enum`s of static
funcs wired directly to `/bin/zsh`, `URLSession.shared`,
`FileManager.default.homeDirectoryForCurrentUser`, `UserDefaults.standard` and
`NSApp.delegate`. Each seam below is small, and each one unlocks a block of §4.

### 5.1 Process runner seam
```swift
protocol HauntedProcessRunning: Sendable {
    func run(_ command: String) async throws -> Data
    @discardableResult func spawn(_ command: String) -> Int32  // for the supervisor
}
```
`HauntedCLI` and `HauntedWorkstationSupervisor` take one, defaulting to the real
`zsh` implementation. Unlocks: RUN-*, SUP-*, LOG-*, MOD-*, OPEN-*.
The fake records invocations, so SUP-04's *ordering* assertion becomes trivial.

### 5.2 HTTP seam
Inject a `URLSession` (default `.shared`). Tests pass one built from
`URLSessionConfiguration.ephemeral` with a custom `URLProtocol`. No network.
Unlocks: API-*, LGN-*.

### 5.3 Filesystem root seam
`HauntedClientIdentity.defaultStateDir` / `legacyStateDir` and the supervisor's
`configDir` resolve from an injectable home, defaulting to
`homeDirectoryForCurrentUser`. Unlocks: ID-*, SUP-*, LOG-*.

### 5.4 Pull pure logic out of the singletons — ✅ **landed**
- `HauntedSessionRouter.route(lastAttached:workstations:) -> Route` where
  `Route = .resume(target,session) | .fresh(target) | .plainShell`. Unlocks
  OPEN-01…05 with no `NSApp`. `openWindow` calls it, so the tests exercise the
  real path rather than a copy of the decision.
- `HauntedSidebarLayout(defaults:)` and `HauntedSidebarModel(client:killSession:
  pollInterval:refreshDelay:)` are instantiable; `.shared` keeps the production
  defaults. Unlocks LAY-*, MOD-* with no cross-test contamination, no real
  `dedmeshctl`, and no ten-second waits.
- `HauntedManager.splitPlan(parentTarget:generateName:)` — the split decision.

**What is still out of reach, and why.** `TAB-01…04` and `SPL-03/04` are listed as
L1, but they are not: every one of them needs a live `Ghostty.SurfaceView`, whose
initializer takes a `ghostty_app_t`. Standing one up in a unit test means booting
libghostty. `NSMapTable` weak-value semantics (TAB-04) and the pending-name
hand-off (SPL-03) are only observable through it. They belong in §4.6's L3 tier
with the rest of the app-level invariants, not here.

### 5.5 ~~Extract `attach-loop.sh` to a bundle resource~~ — **not needed**
The original argument: the script is a Swift multiline string, so move it to
`Sources/Features/Haunted/attach-loop.sh`, ship it as a resource, and pass the
resolved `haunted` path in at run time. Two wins: directly executable under
`/bin/sh` in a test, and the escaping concern leaves the generation path.

Both wins are already available. §5.3's `HauntedFileSystem` seam lets a test point
`attachLoopPath(fs:)` at a temp Application Support root, and `resolve("haunted",
fs:)` at a stub binary under a temp `~/.local/bin` — so the test executes the
*real generated script*, escaping and all. A bundle resource would cost a
resource-build-phase hunk in `project.pbxproj`, which is the rebase surface §8
exists to avoid. `HauntedAttachLoopTests` covers SH-01…06 and LOOP-01…05 with no
project-file change.

One thing a test cannot reach: `HauntedCLI.attachLoopPath` memoizes written paths
in a plain `static var Set<String>`. Production only ever calls it from the main
thread, so `HauntedAttachLoopTests` is `@Suite(.serialized)` rather than the Set
being made thread-safe for the tests' benefit.

### 5.6 ~~Enable strict concurrency on the Haunted sources~~ — **not needed**
The gap SPL-05 was meant to catch — `splitConfiguration` non-isolated while
mutating `pendingSplitSessionName`, which the `@MainActor` `surfaceCreated` reads
— is closed by marking `splitConfiguration` `@MainActor`. Both calls already
happen back-to-back inside `BaseTerminalController.newSplit`, which is main-actor
context; the annotation states what was already true.

A per-file `-strict-concurrency=complete` flag would have to be scoped in
`project.pbxproj` (§8 again), and a whole-target flag drowns in upstream's own
diagnostics. Not worth it for one gap that a keyword closes.

---

## 6. Contract tests (C ↔ Swift)

The Swift structs are a *second* implementation of a protocol the C side already
speaks. Nothing keeps them in sync. Two cheap mechanisms:

### 6.1 Golden JSON fixtures

A new C test writes the exact bytes `haunted list --json` and
`dedmeshctl workstations -json` produce into `tests/haunted/fixtures/`:

```
tests/haunted/fixtures/
  sessions-v2.json        # with titles
  sessions-v1.json        # MSG_SESSION_LIST, no title field  → DEC-02
  workstations.json
  workstations-error.json # offline + state=error + error message
```

The Swift `HauntedTests` decode those same files. A daemon-side field rename
then fails a Swift test rather than silently producing an empty sidebar. Commit
the fixtures; regenerate them with a `make haunted-fixtures` target so drift is
a visible diff.

### 6.2 Exit-code contract for `attach-remote`

`attach-loop.sh` treats exit 0 as "clean detach or session killed — stop
looping" and anything else as "transport died — reconnect". Add a C integration
test in `tests/haunted/` asserting:

| Scenario | `haunted attach-remote` exit |
|---|---|
| Client detaches cleanly | 0 |
| Remote session is killed while attached | 0 |
| Daemon socket disappears mid-session | ≠ 0 |
| Target unreachable at attach time | ≠ 0 |

Without this, SH-01…04 test the script against an assumption rather than a
contract.

---

## 7. Phasing

Ordered by (security × likelihood of silent regression) ÷ cost.

**Phase 1 — ✅ done.** Pure L0 (plus QUOTE-01's real `zsh` round trip).
`SCHEME-*`, `ARG-*`, `QUOTE-*`, `TITLE-*`, `STAT-*`, `DEC-*`, `APPR-*`,
`NAME-01`, `TAB-05`, `INV-09`, and `INV-11` pulled forward from Phase 5.
Lives in `macos/Tests/Haunted/`; run with `make haunted-test-macos`.
TITLE-07 and APPR-05 failed as predicted and are fixed. Three small production
changes were needed to reach the code: `isSafeCLIArgument` made internal,
`HauntedCLI.decodeWorkstations`/`decodeSessions` split out of the process call
(this also gives Phase 4 its seam), and `HauntedManager.tabKey`/
`generateSessionName` made static.

**Phase 2 — ✅ done.** Seams §5.1–5.3 (`HauntedProcessRunning` in
`HauntedProcess.swift`, an injected `URLSession`, `HauntedFileSystem` in
`HauntedFileSystem.swift`), plus `RUN-*`, `SUP-*`, `ID-*`, `API-*`, `LOG-*` in five
new suites and `HauntedTestDoubles.swift`. Every seam is a defaulted parameter, so
production behavior is unchanged.

Predicted failures SUP-08 and ID-09 both materialized and are fixed. ID-11 was
predicted to fail and did *not* — because the tests initially pinned the broken
behavior; the underlying defect was real and is also fixed. Newly found and fixed:
LOG-04 and NAME-01. Still open: BUG-7, BUG-8 (§11).

Not covered by Phase 2, despite §5.3 unlocking them: `LOOP-04/05/06`. And RUN-07
landed as a *behavioral* proxy — its ThreadSanitizer requirement is unmet, which
is what leaves BUG-8 unsettled.

**Phase 3 — ✅ done.** `HauntedSessionRouter` (new file), `HauntedSidebarLayout` and
`HauntedSidebarModel` made instantiable with injected `UserDefaults` / client /
poll interval, and the split decision extracted as `HauntedManager.splitPlan`.
Four new suites: `HauntedSessionRouterTests`, `HauntedSidebarLayoutTests`,
`HauntedSidebarModelTests`, `HauntedAttachLoopTests`. Plus §4.7's EXIT-*.

Landed: `OPEN-01…05`, `SPL-01/02`, `LAY-01…08`, `MOD-01…11`, `SH-01…06`,
`LOOP-01…05`, `EXIT-01…04`.

Predicted failures, resolved:
- **LAY-07 was real** — see §11 BUG-9. Fixed; both directions now covered.
- **SPL-04 was real but narrower than described.** `splitConfiguration` overwrites
  `pendingSplitSessionName` on every Haunted-parent split, so the "next split
  adopts the wrong name" case needs a *plain-shell* parent in between: that path
  returns early without clearing, and `surfaceCreated` then adopts the stale name
  for a surface with no target. `splitConfiguration` now clears first.
- **SPL-05 needed no build flag.** `surfaceCreated` is already `@MainActor` and
  both calls happen in `BaseTerminalController.newSplit`, so marking
  `splitConfiguration` `@MainActor` closes the isolation gap outright — see §5.6.

Two deviations from the plan, both to avoid a `project.pbxproj` edit (§8):
- **§5.5 was not needed.** Extracting `attach-loop.sh` to a bundle resource costs a
  resource-build-phase hunk. The §5.3 filesystem seam already lets a test generate
  the *real* script into a temp Application Support root and run it under
  `/bin/sh` with a stub `haunted` at the path `resolve()` embeds. Same two wins,
  zero project-file change. `HauntedAttachLoopTests` does exactly that.
- **§5.6 was not needed** — see SPL-05 above.

Not landed: `TAB-01…04` and `SPL-03/04` as *runtime* tests. They need a live
`Ghostty.SurfaceView`, which needs a `ghostty_app_t`; the plan calls them L1, and
they are not. See §5.4's note.

**Phase 4 — contracts (§6).** Golden fixtures + `attach-remote` exit codes. This
is the piece that catches C↔Swift drift, which is the failure mode the current
suite structurally cannot see.

**Phase 5 — L3.** `INV-01…08`, `INV-10`. Slowest, flakiest. INV-09 and INV-11 are
L0 and already landed in Phase 1.

---

## 8. Fork-maintenance constraints

Every file added under `apps/haunted-terminal/macos/` widens the delta that must
be rebased onto upstream Ghostty.

- **Superseded advice.** This section used to say: put Haunted tests in their own
  `HauntedTests` target and `Haunted.xctestplan`, and accept the
  `project.pbxproj` hunk as "unavoidable". It is avoidable. The project is
  `objectVersion = 70`, and `Tests/` is a `PBXFileSystemSynchronizedRootGroup` —
  Xcode compiles whatever `.swift` files it finds on disk. Adding
  `Tests/Haunted/*.swift` changes **zero** lines of `project.pbxproj`; a new
  target changes many, in the one file every upstream target change also touches.
  The subdirectory serves this section's own goal better than its own advice did.
- We therefore do **not** touch `Ghostty.xctestplan` either. Suite selection is a
  `-only-testing:` flag in the Makefile, which lives in the outer monorepo and
  cannot conflict with upstream at all.
- The residual risk is a name collision — upstream adding its own
  `Tests/Haunted/`, or a type named `HauntedModelTests`. Both are implausible.
- The seams in §5 all live in Haunted-owned files, except §5.6's build setting.
  Scope that flag to the Haunted sources, not the whole target.
- INV-11's grep test is the cheapest possible rebase guard. It was written first,
  and it immediately found four unguarded `TerminalController.newWindow` call
  sites (see the status block at the top).

---

## 9. Non-goals

- Testing upstream Ghostty behavior, or libghostty-vt.
- Automating the mesh round trip (real console + real remote workstation). Keep
  it as an L4 manual checklist until the login and attach paths stop changing.
- Snapshot/pixel tests of the sidebar. The logic is in the model; the views are
  thin. `ViewInspector` would cost a submodule dependency for four assertions.
- Testing `HauntedContainerView`'s Auto Layout constraint math beyond OVL-04.

---

## 10. Open questions

1. **WAIT-03** — should a transient `workstations` error during the post-spawn
   wait abort to the login window, or retry? Today it aborts. That means a
   cold launch racing `dedmeshd`'s console connection can land the user on a
   login screen they do not need.
2. ~~**LOG-04** — is a pre-existing `0755` state dir worth hardening against?~~
   **Answered: yes.** It holds `key.pem`, the client's mTLS private key. Fixed in
   Phase 2. LOG-05's `ca.pem` leftover is separate and still open — §11 BUG-7.
3. **ID-11** — ~~If the console issues chains, `certIdentity` is already broken.~~
   The *if-then* is now **confirmed by test**: chains were already broken, and
   `certIdentity` is fixed. What remains is the product question no Swift test can
   answer: **does the Console ever issue a certificate chain to a client?** If it
   never will, the fix is merely defensive.
4. ~~Does `docs/haunted.md` need a "Testing the macOS app" section once Phase 1
   lands?~~ Yes; added as "Testing the macOS Terminal".
5. **BUG-1** — is "never a plain local terminal" meant to hold for the dock-drop,
   AppleScript, App Intents and Services entry points too? See §11.
6. **RUN-07** — BUG-8 is now confirmed and fixed, but §4.1's ThreadSanitizer
   requirement is still unmet; what runs is a behavioral proxy. A TSan pass over
   the process runner would turn "8 clean runs" into a guarantee.
8. **EXIT** (§4.7) — should a *clean* exit (status 0) close the tab instead of
   leaving an exit banner? And EXIT-05/06 want C-side tests in
   `tests/haunted/test_daemon.c` for the reap-on-detach ordering.
7. **NAME-01** — the generator is now 64-bit, so the 10 000-draw uniqueness
   assertion is sound. Is a *statistical* assertion wanted in a unit suite at all,
   or should it be replaced by the entropy-width check alone?

---

## 11. Confirmed defects, not yet fixed

Each was reproduced while implementing Phase 1 or Phase 2. These are **not** ⚠️
candidates — those live in §4 and are still unverified. Every entry below has
been observed.

**Fixed since:** TITLE-07 and APPR-05 (Phase 1); in Phase 2 — BUG-2 (`consoleHost`
IPv6), BUG-3 (`pgrep` ERE injection, was §4.2 SUP-08), BUG-4 (state-dir mode, was
LOG-04), BUG-5 (`certIdentity` chains, was ID-11), BUG-6 (`generateSessionName`
entropy); and in Phase 3 — BUG-8 (the short read below) and BUG-9 (LAY-07's
stranded reversal); and in Phase 4 — BUG-11 (startup auto-creates a session) and
BUG-12 (killing the last session crashes the app); and after Phase 4 —
BUG-13 (the sidebar poll loop freezes forever in `waitUntilExit`). Each has a
regression test named for its ID. §4 marks them ✅.

### BUG-13 — the sidebar silently stops refreshing forever — ✅ **confirmed, then fixed**

**Symptom (user):** "htop retitles the top tab immediately but the sidebar takes
dozens of seconds", and "⌘T / ⌘D sessions don't show up in the sidebar". Both
were one bug wearing two costumes.

**Reproduction (live app, not a test):** the running GUI spawned **zero**
poller children for 45+ seconds (the poll interval is 4s), while a `sample` of
the process showed a dispatch worker parked for 100% of the sample in
`HauntedProcessRunner.run` → `-[NSConcreteTask waitUntilExit]` →
`_CFRunLoopRunSpecificWithOptions` → `mach_msg` — waiting on a child that had
already exited and been reaped (no zombie, no live child, no peer holding the
pipes).

**Mechanism:** `run()` drained both pipes to EOF, then called
`Process.waitUntilExit()` from a dispatch worker. `waitUntilExit` spins the
calling thread's run loop waiting for a termination wakeup; that delivery can be
missed when the child exits in the window around the observation being set up,
and once missed it never re-fires — the continuation never resumes. The sidebar
poll loop (`HauntedSidebarModel.poll`) `await`s that call, so one lost wakeup
froze workstation *and* session refresh for the life of the app, with no error
surfaced. Titles then only moved when an open/kill posted
`hauntedSessionsDidChange` (whose refresh path spawns fresh children) — hence
"dozens of seconds", i.e. "whenever the user next did something".
`runToCompletion` had the same hazard on the supervisor path.

**Fix:** `HauntedProcessRunner` never calls `waitUntilExit`. Termination joins
the same `DispatchGroup` as the two pipe readers via `terminationHandler`
(armed *before* launch, dispatch-source based), and every child gets a hard
deadline (`timeout`, default 30s): a wedged child is SIGKILLed and the call
throws a timeout instead of hanging its caller — the poll loop degrades to an
`errorMessage` and keeps polling. Latency halves of the two symptoms got their
own fixes: `sessionLanded` tells the sidebar the moment a fresh ⌘T/⌘D session
exists daemon-side (LAND-01…04), and `applyLocalTitle` mirrors the local
surface title (which the daemon pushes on every change) straight into the row
(MOD-14). Tests: RUN-09/09b/10/11; the `noWaitUntilExitAnywhere` grep in
`HauntedForkInvariantTests` bans the API from the whole tree.

### BUG-11 — startup silently creates a session on every launch — ✅ **confirmed, then fixed**

**Symptom (user):** "It starts a new session on each workstation automatically."
The startup log showed `openWindow: target=luiz/test4/haunted session=gui-a487f63d13f14a75`
— a *generated* name, re-attached on every launch.

**Mechanism:** `openWindow` called `buildConfiguration(create: true)` for the
`.resume` route, and the router resumed whenever the workstation was online —
without checking the session still existed. So a remembered `gui-…` session that
had been killed (or whose daemon restarted) was re-minted with `--create` on the
next launch, forever. The old `.fresh` route made it worse: with nothing to
resume it auto-attached+created `default` on the first online workstation.

**Fix:** `HauntedSessionRouter.route` now takes the last target's session list
and returns `.resume` only when that session is still present; `openWindow`
resumes with `create: false`; `.fresh` is gone. Anything else → `.empty` (the
"Nothing here" state). Startup never creates. Tests: OPEN-01…06.

### BUG-12 — killing the last session crashes the whole app — ✅ **confirmed, then fixed**

**Symptom (user):** right-click the last session → "Kill Session" → the Terminal
crashes (`make haunted-run` exits non-zero; Sentry captured a minidump).

**Root cause (from the minidump, `arm64`):** `SIGABRT` in `objc_msgSend` called
from `Ghostty.App.scrollbar(_:target:v:)` (`Ghostty.App.swift:2062`) via
`Ghostty.App.action` (641). `HauntedManager.killSession` called
`controller.window?.close()` on the last tab; window teardown freed the attached
`SurfaceView`, and libghostty then delivered a `GHOSTTY_ACTION_SCROLLBAR` to it —
`surfaceView(from:)` returns a dangling `Unmanaged.takeUnretainedValue()`, and the
next message send aborts. A use-after-free.

**Fix:** killing the *last* session no longer closes the window. It drops to the
"Nothing here" empty state (empty surface tree + placeholder, sidebar kept) via
`hauntedEmptyState`, so no window/surface teardown happens under a live libghostty
action. The decision is the pure `sessionTabClosePlan`; the fork's
`surfaceTreeDidChange` honours the flag (guarded by the KILL-01 grep test against
an upstream "theirs" rebase). Tests: KILL-01 (`HauntedManagerLogicTests` +
`HauntedForkInvariantTests`).

### BUG-8 — short read in `HauntedProcessRunner.run` — ✅ **confirmed, then fixed**

Recorded in Phase 2 as *plausible but unreproduced*. Phase 3 added four suites,
the extra parallel load pushed the flake rate up, and **RUN-07 failed on the third
consecutive full-suite run** — the reproduction Phase 2 could not get.

The mechanism was exactly the one predicted:

```swift
process.terminationHandler = { proc in
    stdout.fileHandleForReading.readabilityHandler = nil   // does NOT join an in-flight handler
    collector.appendOut(stdout.fileHandleForReading.readDataToEndOfFile())
    let (out, err) = collector.snapshot()                  // may run before that handler's append
```

`OutputCollector` is correctly locked, so `Data` was never *corrupted*. The window
was elsewhere: a `readabilityHandler` block that had already returned from
`availableData` with N bytes but had not yet taken the lock appended **after**
`snapshot()` was taken and the continuation resumed. Those N bytes vanished.
Assigning `readabilityHandler = nil` cancels the dispatch source; it does not wait
for a block already executing. Truncated stdout means an empty sidebar; truncated
stderr means a CLI error the user never sees, replaced by `"command failed (1)"`.

**Pre-existing**, not introduced by Phase 2's seams — the code was byte-identical
to the original `HauntedCLI.run`, which §5.1 merely relocated.

**Fix (landed).** Both pipes are drained to EOF on their own queue, started before
`process.run()`, joined by a `DispatchGroup`; the continuation resumes from
`notify` after `waitUntilExit`. No `readabilityHandler` anywhere, so nothing can
append after the snapshot, and a chatty child still cannot fill a ~64 KiB pipe
buffer and deadlock. The failed-`run()` path closes the write ends so the readers
get their EOF instead of hanging.

Post-fix: **8 consecutive clean full-suite runs**. Against a ~1-in-3 flake rate
that is ~2.6% likely by luck, so: strong, not proof. §4.1 RUN-07's ThreadSanitizer
requirement remains unmet — what runs is a behavioral proxy (32 concurrent
children, distinct fill bytes). A TSan run would settle it; §10 Q6.

Known limitation, documented at the call site: if a child spawns a grandchild that
inherits the pipe write end, EOF waits for the grandchild too. Every command here
is a short CLI invocation, and `spawnDetached` is the path for anything meant to
outlive us.

### BUG-9 — a sidebar collapse/expand reversal stranded the sidebar — ✅ **fixed**

`HauntedSidebarLayout.setCollapsed` guarded on `collapsed`, which lags the user's
intent by one animation step. `setCollapsed(true)` set `contentVisible = false` but
left `collapsed == false` until its deferred closure ran, so an immediate
`setCollapsed(false)` — a double-click on the divider — saw "already expanded",
took the early return, and the pending closure then collapsed the sidebar the user
had just asked to reopen. Only that direction was broken, which is why it survived
casual use. Now both closures re-check a `desiredCollapsed` field that records
intent rather than animation state. LAY-07 covers both directions.

### BUG-1 — four entry points still open a plain local terminal

**Severity: high.** No hostile console required; a user gesture is enough.
**Found by:** `HauntedForkInvariantTests.newWindowCallSitesArePinned` (§4.6, INV-11).

The fork's central claim is that a window is *never* an unattached local shell.
⌘N, ⌘T, dock reopen (`applicationShouldHandleReopen`) and window restoration are
all closed — which is exactly why the invariant reads as airtight. It is not.
These four call `TerminalController.newWindow` for a fresh local shell:

| # | Site | Trigger |
|---|---|---|
| 1 | `macos/Sources/App/macOS/AppDelegate.swift:520` | drop a file on the dock icon with `macos-dock-drop-behavior = new_window` |
| 2 | `macos/Sources/Features/AppleScript/AppDelegate+AppleScript.swift:194` | AppleScript / `osascript` |
| 3 | `macos/Sources/Features/App Intents/NewTerminalIntent.swift:110` | App Intents, Shortcuts, Spotlight |
| 4 | `macos/Sources/Features/Services/ServiceProvider.swift:66` | the macOS Services menu ("New Ghostty Terminal Here") |

Site 1 is the cheapest to reach: it needs one drag, no scripting.

A fifth call site — `BaseTerminalController.swift:785`, dragging a split out of a
window — is **not** a hole: it re-homes an already-attached surface tree and
spawns no new shell. The three sites inside `TerminalController.swift` are its
own internal dispatch.

**Fix:** route 1–4 through `HauntedLoginController.startup()`, as
`AppDelegate.newWindow(_:)` already does. Then shrink the allowlist in
`newWindowCallSitesArePinned` to the five legitimate sites — the test will fail
until the map matches, which is the point.

Until then the allowlist records and classifies all nine sites, so a rebase
cannot add a tenth silently. **Do not silence a failure by bumping a count.**

### BUG-7 — `login()` writes and calls out before it validates, with no rollback

**Severity: low.** Latent, not live. No secret is leaked.
**Found by:** Phase 2, LOG-03/LOG-05. Predicted by §4.5 and §10 Q2.
**Tests:** LOG-03 and LOG-05 in `HauntedCLILoginTests` — both **green
characterization tests**: they pin what the code does, not what it should.

`HauntedCLI.login` runs `redeem(…)` → `createDirectory` → write `ca.pem` → *then*
`guard let host = consoleURL.host`. Two consequences:

- A host-less console URL still burns the **one-time** login code over the
  network, then fails, leaving `ca.pem` on disk.
- A failed `haunted enroll` likewise leaves `ca.pem` behind.

`hasLogin()` requires all four of `cert.pem`, `key.pem`, `settings.json`,
`ca.pem`, so a failed login supplies exactly one of them and makes that predicate
"half-true". Today `load()` still correctly reports *not enrolled*, which is why
this is latent rather than live. `ca.pem` is a public CA certificate, so nothing
secret is exposed.

**Fix:** hoist the `host` guard above `redeem`; delete `ca.pem` when `enroll`
fails. Then flip LOG-03/LOG-05 from characterization to regression tests.

### BUG-10 — a CMake-built `haunted-daemon` is not installable, and stale deployed daemons are invisible

**Severity: high in practice.** Two failure modes, one root: *what runs is not what
the tests test.* Found by reproducing a user-reported "the process closes but it
doesn't exit". No source defect; both C and Swift suites were green throughout.

**(a) Stale deployed daemon.** The reaping in `4fa71c2` makes a session die with its
process. Every deployed `haunted-daemon` predated it, so:

- the shell exits, `MSG_EXIT_STATUS` is delivered, `attach-remote` exits 0, the tab
  gets its banner — all correct;
- but `session_destroy` never runs, so the **session outlives its process**. It
  stays in `haunted list` and in the sidebar, and clicking that row reattaches to a
  corpse.

Confirmed by reverting exactly the 17 lines of `4fa71c2` and rebuilding:
*with* them the session is reaped and `attach` returns 0; *without* them
`attach` still returns 0 but the row remains. The C tests (EXIT-05/06) cover the
source; nothing covers the binary on the workstation.

**(b) The daemon `make haunted-build` produces cannot be installed.** Its
`LC_RPATH` is an **absolute path into the build tree**:

```
$ otool -l build/apps/haunted-daemon/haunted-daemon | grep -A2 LC_RPATH
    path /Users/luiz/projects/dednets-mono/apps/haunted-terminal/zig-out/lib
```

Copy it to `~/.local/bin` and it works until the repo moves. The monorepo
restructure (`vendor/ghostty` → `apps/haunted-terminal`, `1b5cd6e`) moved it, so an
installed daemon died at launch with `dyld: Library not loaded:
@rpath/libghostty-vt.dylib`. `HauntedWorkstationSupervisor.ensureHauntedDaemon()`
spawns it, sees a nonzero exit, and returns false — **silently**. The Mac then never
appears as a workstation and nobody is told why.

Only `scripts/build-dist.sh` output is installable: it links one target per prefix
and emits a self-contained binary with **no** `LC_RPATH`.

**Fixes.**
- Immediate (done): install `build/dist/<os>-<arch>/haunted-daemon`, and restart the
  workstation daemon (`systemctl --user restart haunted-daemon.service` in the Lima
  VM). Verified end-to-end against the live daemon.
- Code, not yet done: give the CMake build a relocatable rpath
  (`@loader_path`/`@executable_path`) or link `libghostty-vt` statically, so the
  `make haunted-build` artifact is installable. Until then, `docs/haunted.md` says
  not to copy it.
- Missing guard: nothing detects a workstation running an out-of-date daemon.
  EXIT-08. A version handshake — the daemon reporting its build in
  `MSG_SESSION_LIST_V2`, the console or sidebar warning on mismatch — would have
  turned three hours of debugging into a banner.

### Still unconfirmed

The remaining ⚠️ marks in §4 — SPL-04 (`pendingSplitSessionName` leaks into the
next split), SPL-05 (strict-concurrency isolation gap), LAY-07, WAIT-03 — are
candidates read off the code, not observations. They are all gated on the §5.4
extraction and land with Phase 3.
