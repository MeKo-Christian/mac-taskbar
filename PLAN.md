# MacTaskbar — Plan to Production

Current state: proof of concept. A borderless panel per screen, windows read via
the Accessibility (AX) API, polled every 0.5 s, buttons rebuilt on every change.

Phases are ordered by dependency; within a phase, items are roughly by priority.

## Phase 0 — Make the PoC work reliably

- [ ] **Fix the empty bar.** Confirmed symptom: bar appears, no windows listed.
  - Check whether `AXIsProcessTrusted()` returns true (the bar should show the
    "Grant Accessibility access…" message if not). Log it via `os.Logger`.
  - Ad-hoc signing (`codesign --sign -`) changes the code identity on every
    build, so a grant made for an older build silently stops applying. Remove the
    stale entry in System Settings / `just reset-permission`, then grant again.
  - If trusted but still empty: log per app the `AXError` of
    `kAXWindowsAttribute` and the subroles returned; verify the
    `kAXStandardWindowSubrole` filter isn't dropping everything.
  - Done: trust + per-app AX diagnostics (`just logs`, `just dump`); filter also
    accepts large role-only windows (Electron/Java). Open until confirmed with the
    stable signing identity.
- [x] **Stable signing identity for development.** Create a self-signed
  "MacTaskbar Dev" code-signing certificate in the login keychain and sign with it
  in the justfile, so the Accessibility grant survives rebuilds.
- [x] **Diagnostics.** `os.Logger` with subsystem `io.github.cwbudde.mactaskbar`
  (view with `log stream --predicate 'subsystem == "io.github.cwbudde.mactaskbar"'`).
- [x] `git init`, first commit, LICENSE (MIT).

## Phase 1 — Correct, efficient window tracking

- [x] **Event-driven updates.** Replace polling with one `AXObserver` per app
  (`kAXWindowCreated`, `kAXUIElementDestroyed`, `kAXTitleChanged`,
  `kAXFocusedWindowChanged`, `kAXWindowMiniaturized`/`Deminiaturized`,
  `kAXWindowMoved`/`Resized`, `kAXApplicationHidden`/`Shown`). Attach on app
  launch, detach on terminate. Keep a slow (e.g. 5 s) reconciliation poll as a
  safety net. (2026-09-28) — `WindowObserver`: app-level notifications on the app
  element, window-level ones per window, bursts coalesced (50 ms); attach/detach
  reconciled on every refresh (retries apps still launching); poll 0.5 s → 5 s.
  Verified with Finder/TextEdit via osascript: every listed notification fires and
  the bar updates 70–100 ms later (incl. moving a window to the other screen); idle
  CPU ≈0.2 % vs ≈2.1 % before.
- [ ] **Keep AX off the main thread.** AX calls block up to the messaging timeout
  per unresponsive app. Run enumeration on a background queue/actor and publish
  immutable snapshots to the UI.
- [ ] **Stable window identity.** `CFEqual` on `AXUIElement` works but is opaque.
  Evaluate `_AXUIElementGetWindow` (private, used by AltTab/Rectangle) to get the
  `CGWindowID`; needed anyway for previews and cross-Space tracking.
- [ ] **All Spaces.** AX only sees windows on the current Space. Options:
  (a) show current Space only (document it), (b) combine
  `CGWindowListCopyWindowInfo` with private CGS Space APIs like AltTab does.
  Decide and make it a setting.
- [ ] **Window filtering edge cases:** sheets/dialogs, utility/floating panels,
  untitled windows, Electron/Java apps with non-standard subroles, Finder
  desktop, windows of apps that are still launching, tabbed windows
  (Safari/Finder/Terminal tabs share one AX window).
  (2026-09-28) — partial: minimized windows report subrole `AXDialog` and were
  dropped; now accepted by role + `kAXMinimizedAttribute`. Rest still open.
- [ ] **Full-screen apps.** Hide the bar on full-screen Spaces; list full-screen
  windows and switch to their Space when clicked.
- [ ] **Focus reliability.** Verify focusing works for minimized windows, hidden
  apps, windows on another screen, and apps that ignore `kAXFrontmostAttribute`;
  fall back to `NSRunningApplication.activate()` with `NSApp.yieldActivation(to:)`
  (cooperative activation, macOS 14+).
- [ ] **Screen handling.** Windows moving between screens, displays with
  different scale factors, display sleep/wake, clamshell mode, screens added or
  removed while running (already rebuilds bars — verify no leaks/flicker).

## Phase 2 — UX

- [ ] **Screen space.** macOS has no API to reserve a screen strip, so maximized
  and zoomed windows go under the bar. Options, to be evaluated:
  - optional auto-hide of the bar,
  - when a window is zoomed or sized to fill the screen, shrink it via AX
    to end above the bar (as Rectangle does),
  - document "set the Dock to auto-hide" in onboarding.
- [ ] **Incremental UI updates.** Diff snapshots and update/insert/remove buttons
  instead of rebuilding all of them; animate changes.
- [ ] **Button states:** hover, pressed, focused, minimized, attention/badge;
  correct colours in light/dark mode and with "Reduce transparency".
- [ ] **Interactions:** middle-click to close, drag to reorder, scroll to cycle
  windows, context menu (New Window, Hide, Quit App, Move to Screen).
- [ ] **Grouping.** Optional "group by app" with a window count and a popup list.
- [ ] **Hover previews** via ScreenCaptureKit (requires Screen Recording
  permission — keep optional).
- [ ] **Pinned launchers** (optional), so the Dock can be hidden completely.
- [ ] **Status area** (optional): clock, maybe a menu for settings/quit.
- [ ] **Dock interplay.** The Dock's reveal zone overlaps the bar; check behaviour
  with Dock at bottom/left/right and auto-hide on/off.
- [ ] **Accessibility:** VoiceOver labels for buttons, keyboard navigation.
- [ ] **Localization:** English + German.

## Phase 3 — Settings & lifecycle

- [ ] Status bar item (`NSStatusItem`) with Settings… and Quit.
- [ ] Settings window (SwiftUI): enabled screens, bar position (top/bottom),
  height, button max width, grouping, current Space vs. all Spaces, launch at login.
- [ ] Persist settings in `UserDefaults`.
- [ ] Launch at login via `SMAppService.mainApp.register()`.
- [ ] Onboarding window explaining and requesting the Accessibility permission;
  detect when the permission is revoked while running.

## Phase 4 — Engineering quality

- [ ] Split into a library target (`TaskbarCore`: ordering, screen assignment,
  filtering, snapshot diffing — pure, AX-free) plus the app target.
- [ ] Unit tests for `TaskbarCore` (`swift test`), with fake window snapshots.
- [ ] Protocol around the AX layer so the UI can run against a fake source.
- [ ] Performance budget: idle CPU < 0.5 %, no memory growth over 24 h;
  measure with Instruments.
- [ ] Linting/formatting: `swift-format` (or SwiftLint) in `just lint`.
- [ ] CI: GitHub Actions on a macOS runner — build, test, lint.
- [ ] Switch to Swift 6 language mode with strict concurrency once AX work is
  moved to an actor.

## Phase 5 — Distribution

- [ ] App icon and proper `Info.plist` metadata (copyright, category).
- [ ] Universal binary (arm64 + x86_64) if Intel Macs should be supported.
- [ ] Developer ID signing with hardened runtime (requires Apple Developer
  Program membership), notarization via `notarytool`, stapling.
- [ ] Release artifacts: zipped `.app` or `.dmg`, built by a GitHub Actions
  release workflow on tags.
- [ ] Auto-update via Sparkle, or rely on Homebrew.
- [ ] Homebrew cask in a personal tap (`CWBudde/homebrew-tap`).
- [ ] Note: the App Store is not an option — sandboxed apps cannot use the
  Accessibility API to control other apps.
