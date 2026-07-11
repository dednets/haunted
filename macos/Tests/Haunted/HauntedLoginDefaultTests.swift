import Testing
import Foundation
@testable import Ghostty

/// LGDF — the Console login default (HauntedLoginView.defaultConsoleURL).
///
/// A shipped build must sign in to production; every dev build must default to
/// staging so local work never enrolls a Terminal against the production
/// console by accident. The discriminator is the HAUNTED_RELEASE compilation
/// condition, injected only by scripts/build-app-dist.sh — so this test suite,
/// which always builds WITHOUT it, is the guard for the dev half. The shipped
/// half is guarded by the `console.dednets.com` strings check in
/// build-app-dist.sh (and its staging-refusal loop).
struct HauntedLoginDefaultTests {
    // LGDF-01: a non-release build (this test target, and every dev build)
    // defaults to the staging console — never production.
    @Test func devBuildDefaultsToStaging() {
        #if HAUNTED_RELEASE
        #expect(HauntedLoginView.defaultConsoleURL == "https://console.dednets.com")
        #else
        #expect(HauntedLoginView.defaultConsoleURL == "https://console.staging.dednets.com")
        #endif
    }

    // LGDF-02: whichever default this build carries, it is an allowed console
    // scheme (https, or http-to-loopback) — a malformed default would make the
    // login field unusable out of the box.
    @Test func defaultIsAWellFormedAllowedConsole() throws {
        let url = try #require(URL(string: HauntedLoginView.defaultConsoleURL))
        #expect(url.isAllowedConsoleScheme)
        #expect(url.host?.hasSuffix("dednets.com") == true)
    }
}
