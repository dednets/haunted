# Haunted macOS Terminal — Test Plan

Test plan for the **Haunted feature delta** carried on top of upstream Ghostty in
the `thenets/ghostty` fork (`apps/haunted-terminal`, branch `haunted`). When this
plan was written the delta had **zero automated coverage**: `macos/Tests/` and
`macos/GhosttyUITests/` were inherited upstream suites, and `grep -ril haunt` over
both returned nothing. `make haunted-test` runs six ctest targets, all C.

Status: **Phase 1 landed** (§7). `macos/Tests/Haunted/` holds ~97 tests, run by
`make haunted-test-macos`. Phases 2–5 are still plan only. Findings marked ⚠️
are defect *candidates* spotted while reading the code to write this plan; each
is phrased as a test that should fail today. Confirm before "fixing".

Confirmed and fixed in Phase 1:

- **APPR-05** — `approvalURL` returned `javascript:` / `file://` / any-scheme URLs
  straight to `NSWorkspace.shared.open`. Now both the absolute and the
  base-resolved branch must pass `isAllowedConsoleScheme`.
- **TITLE-07 / SH-07** — session `name` was never validated. Now rejected at the
  decode boundary by `isValidSessionName`, mirroring the daemon's
  `session_name_valid()` (`[A-Za-z0-9_-]{1,63}`), plus a leading-`-` ban. A name
  can no longer reach `attach-loop.sh`'s OSC-0 `printf` nor the sidebar fallback.
  `isSafeCLIArgument` (still used for `target`) additionally rejects control and
  format scalars.

Confirmed, **not yet fixed** — see §11 for detail: `BUG-1` (four ways to open a
plain local terminal) and `BUG-2` (`consoleHost` mangles IPv6).

Corrections to this plan, found by writing the tests:

- **SCHEME-05** — `URL.host` does yield `::1` unbracketed, so `http://[::1]:8080`
  is allowed. The plan's guess was right; there is now a test pinning it.
- **INV-06** — the fork overrides `applicationShouldHandleReopen`, not
  `applicationOpenUntitledFile`.
- **§2 / §8** — the separate-target advice was wrong for this project; see §8.

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
| `macos/Sources/App/macOS/AppDelegate.swift` | +22/−19 | Modified. "Never a plain local terminal" |
| `macos/Sources/Features/Terminal/TerminalRestorable.swift` | +5/−9 | Modified. Restoration disabled |
| `macos/Sources/Features/Terminal/BaseTerminalController.swift` | +3 | Modified. Split inheritance hooks |
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
| ID-09 | `consoleHost` of `"[::1]:9443"` | ⚠️ returns `"["` — split on `":"` takes the first component. **Confirmed; expected to fail.** See §11, BUG-2. |
| ID-10 | `certIdentity` from a fixture cert with `CN=alice/term` | `"alice/term"` |
| ID-11 | `certIdentity` from a **chain** PEM (leaf + intermediate) | ⚠️ all base64 lines are joined across both certs → invalid DER → `nil`. **Expected to fail** if the console ever issues chains. |
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
| SUP-08 | Config path `~/.config/dedmesh/a+b.toml` | ⚠️ `pgrep -f "dedmeshd -config <path>"` takes an **ERE**; `+` is a quantifier, `.` matches any char. A running daemon is missed → a second one spawns and the two fight the console for the identity. **Expected to fail.** Fix: `pgrep -f -- "$(escape)"`, or match on the pidfile instead. |
| SUP-09 | `pgrep` binary missing | returns `false`, no crash |

---

### 4.3 `HauntedManager.swift`

Pure logic first — extract `HauntedSessionRouter` (§5.4) so these are L0:

| ID | `lastAttached` | Workstations | Expect |
|---|---|---|---|
| OPEN-01 | `(box, work)` and `box` online | resume `box`/`work` |
| OPEN-02 | `(box, work)`, `box` **offline**, `other` online | `other`/`default` |
| OPEN-03 | `nil`, one online | that one, `default` |
| OPEN-04 | `nil`, none online | plain shell — `initialInput` empty, sidebar still shown |
| OPEN-05 | `(box, work)`, list empty | plain shell |

| ID | Case | Expect |
|---|---|---|
| TAB-01 | `focusOrOpen(sessionName: nil)` | generated `gui-xxxxxxxx` name, `create: true` |
| TAB-02 | `focusOrOpen(sessionName: "work")` | `create: false` — the daemon does not create on raw attach |
| TAB-03 | Session already open in a live window | focuses it, opens **no** new tab |
| TAB-04 | Session in `sessionTabs` but its window is gone | opens a new tab (weak value → `nil`) |
| TAB-05 | `tabKey("a/b", "c")` vs `tabKey("a", "b/c")` | distinct — the `\u{1}` separator is doing real work |
| KILL-01 | `killSession` | window closed **before** the CLI kill (the `waitAfterCommand` exit banner would otherwise strand the tab) |
| KILL-02 | CLI kill throws | logged, `hauntedSessionsDidChange` still posted |
| NAME-01 | `generateSessionName()` × 10 000 | all match `^gui-[0-9a-f]{8}$`, no collisions |
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
| MOD-06 | Second load | expansion set **not** re-derived (`!loaded` guard) — a user collapse survives the poll |
| MOD-07 | `kill` | session optimistically removed from `sessionsByTarget` immediately |
| MOD-08 | `hauntedSessionsDidChange` posted | refresh fires after the 1.2s debounce, once |
| MOD-09 | Ordering | workstations by `target`, sessions by `name` |
| MOD-10 | `refreshSessions` with one workstation failing | other workstations still update |
| MOD-11 | Poll task cancelled (window closed) | no data reset; a later `start` resumes |

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
| LOG-04 | State dir already exists as `0755` | ⚠️ `createDirectory(attributes:)` does not chmod an existing dir. Assert current behavior, then decide whether to enforce `0700`. |
| LOG-05 | `enroll` fails | ⚠️ `ca.pem` from the failed attempt is left behind. Assert, then decide (harmless — it is a public CA cert — but it makes `hasLogin` half-true). |

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

### 5.4 Pull pure logic out of the singletons
- `HauntedSessionRouter` — a pure function
  `(lastAttached, [HauntedWorkstation]) -> Action` where
  `Action = .resume(target,session) | .fresh(target) | .plainShell`.
  Unlocks OPEN-01…05 with no `NSApp`.
- Make `HauntedSidebarModel` and `HauntedSidebarLayout` instantiable
  (`init` non-private, keep `.shared`). Unlocks MOD-*, LAY-* without cross-test
  contamination.

### 5.5 Extract `attach-loop.sh` to a bundle resource
The script is a Swift multiline string with `\(quote(resolve("haunted")))`
interpolated at generation time. Move the body to
`Sources/Features/Haunted/attach-loop.sh`, ship it as a resource, and have
`attachLoopPath()` copy it out and pass the resolved `haunted` path as `$0`'s
environment or a fourth argument.

Two wins: the script becomes directly executable under `/bin/sh` in a test
(SH-01…07), and the escaping concern disappears from the generation path.

### 5.6 Enable strict concurrency on the Haunted sources
`-strict-concurrency=complete` for the five Haunted files. SPL-05 is not really
a test — it is a compiler flag that would have caught the
`pendingSplitSessionName` isolation gap for free.

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

**Phase 2 — seams §5.1–5.3.** `RUN-*`, `SUP-*`, `ID-*`, `API-*`, `LOG-*`.
Expected failures: SUP-08, ID-09, ID-11.

**Phase 3 — §5.4 + §5.5 + §5.6.** `OPEN-*`, `TAB-*`, `SPL-*`, `LAY-*`, `MOD-*`,
`SH-*`. Expected failures: SPL-04, SPL-05, LAY-07 (verify).

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
2. **LOG-04/05** — is a pre-existing `0755` state dir worth hardening against?
   It holds `key.pem`.
3. **ID-11** — will the console ever issue a certificate *chain* to a client?
   If yes, `certIdentity` is already broken and the sidebar silently drops the
   `@user/client` line.
4. ~~Does `docs/haunted.md` need a "Testing the macOS app" section once Phase 1
   lands?~~ Yes; added as "Testing the macOS Terminal".
5. **BUG-1** — is "never a plain local terminal" meant to hold for the dock-drop,
   AppleScript, App Intents and Services entry points too? See §11.

---

## 11. Confirmed defects, not yet fixed

Each was reproduced while implementing Phase 1. These are **not** ⚠️ candidates —
those live in §4 and are still unverified. Every entry below has been observed.

Two defects the plan predicted (TITLE-07, APPR-05) were confirmed the same way
and are already fixed; §4 marks them ✅.

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

### BUG-2 — `consoleHost` mangles a bracketed IPv6 console address

**Severity: low.** Display only, and no user has an IPv6-literal console today.
**Found by:** reading `HauntedClient.swift` for ID-09; reproduced standalone.
**Test:** ID-09 in §4.1, lands with Phase 2.

`macos/Sources/Features/Haunted/HauntedClient.swift:173`

```swift
return console.split(separator: ":").first.map(String.init) ?? console
```

`consoleHost` of `"[::1]:9443"` returns `"["`, which the sidebar then renders as
the console's name. Splitting on the *first* `:` is wrong for any bracketed
literal.

**Fix:** `URLComponents(string: "//\(console)")?.host ?? console`. Verified
against `[::1]:9443` → `[::1]`, `console.example.com:9443` → `console.example.com`,
`console.example.com` → itself, `[fe80::1%25en0]:9443` → `[fe80::1%en0]`.

Careful: `URLComponents.host` keeps the brackets (`[::1]`), while `URL.host`
strips them (`::1` — that is what SCHEME-05 pins, and what
`isAllowedConsoleScheme`'s loopback set matches against). The two disagree. For
`consoleHost`, which is display-only, the bracketed form is the correct one; do
not "unify" them without re-reading SCHEME-05.

### Still unconfirmed

The remaining ⚠️ marks in §4 — SUP-08 (`pgrep -f` takes an ERE, so a config path
with `+` or `.` misses a running daemon and a second one spawns), ID-11 (cert
chains), SPL-04 (`pendingSplitSessionName` leaks), LAY-07, LOG-04/05 — are
candidates read off the code, not observations. SUP-08 is the one most likely to
be real and the most damaging if it is: two `dedmeshd` instances fighting the
console for one identity. It lands with Phase 2.
