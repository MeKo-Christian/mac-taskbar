# MacTaskbar — Plan to Production

Current state: proof of concept. A borderless panel per screen, windows read via
the Accessibility (AX) API, polled every 0.5 s, buttons rebuilt on every change.

Phases are ordered by dependency; within a phase, items are roughly by priority.

## Phase 0 — Make the PoC work reliably — ✅ DONE (2026-09-28)

- [x] **Fix the empty bar.** (2026-09-28) — Root cause: ad-hoc signing tied the
  Accessibility grant to one build's cdhash. Signed with "MacTaskbar Dev" (designated
  requirement = identifier + certificate leaf), `just reset-permission`, granted
  once: log shows `AXIsProcessTrusted = true`, `Windows per bar: [7, 1]`, and a
  rebuilt app stays trusted without re-granting. Diagnostics via `just logs` /
  `just dump`; filter also accepts large role-only windows (Electron/Java).
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
- [x] **Keep AX off the main thread.** AX calls block up to the messaging timeout
  per unresponsive app. Run enumeration on a background queue/actor and publish
  immutable snapshots to the UI. (2026-09-28) — `WindowSource` runs enumeration and
  focus/minimize/close on a private serial queue; the main thread passes in an
  `EnumerationContext` (apps, frontmost pid, screen height) and gets `TaskWindow`
  snapshots back; one enumeration in flight at a time, later refreshes coalesce.
  Verified with `sample` while TextEdit was stopped (`kill -STOP`): AX calls on the
  main thread 1391 samples before → 0 after (1375 now on the AX queue).
- [x] **Stable window identity.** `CFEqual` on `AXUIElement` works but is opaque.
  Evaluate `_AXUIElementGetWindow` (private, used by AltTab/Rectangle) to get the
  `CGWindowID`; needed anyway for previews and cross-Space tracking.
  (2026-09-29) — adopted: `WindowKey` looks up the `CGWindowID` via `_AXUIElementGetWindow`
  and compares by it, falling back to `CFEqual` when no ID is reported; the bar's change
  signature uses the same identity. `--dump` prints `id=` per window and cross-checks against
  `CGWindowListCopyWindowInfo`: 8/8 windows (Firefox, Teams, VS Code, System Settings,
  TextEdit) have an ID with matching owner PID, also while minimized; IDs are identical
  across separate enumerations. The `CFEqual` fallback is untested (no window without ID found).
- [ ] **All Spaces.** AX only sees windows on the current Space. Options:
  (a) show current Space only (document it), (b) combine
  `CGWindowListCopyWindowInfo` with private CGS Space APIs like AltTab does.
  Decide and make it a setting.
  (2026-09-29) — partial: decided (b). `Spaces` reads each display's current Space and each
  window's Spaces via SkyLight (`dlsym`, falls back to the current Space if missing). Windows
  only on other Spaces are reached through their remembered AX element, else via
  `_AXUIElementCreateWithRemoteToken` (100 ms budget per app; failures retried only when the
  window moves). Setting "Windows from: All Spaces / Current Space" (default all). Checked
  with a TextEdit window made full-screen (Space 723) while on Desktop 1: `--dump` lists it
  `spaces=[723] (other Space)` via remote token; the bar shows `Windows per bar: [9]`, with
  `defaults write … spaces current` `[8]`. `kAXWindows` also lists minimized windows of other
  Spaces (they keep their Space); current mode drops them now. Space switches: one lookup per
  app for helper windows that never resolve, then none over 3 round trips; idle CPU 0.19 s
  per 60 s. Remaining: a regular second desktop (could not add one via Mission Control
  automation), and the Settings picker itself (only tested via `defaults write`).
  (2026-09-29) — partial: Settings picker checked via AX (now labelled "Windows from"), with a
  TextEdit window full-screen on Space 748: "Current Space" stores `spaces = current` and gives
  `Windows per bar: [5, 1]`, "All Spaces" `[6, 1]`. Remaining: a regular second desktop.
- [ ] **Window filtering edge cases:** sheets/dialogs, utility/floating panels,
  untitled windows, Electron/Java apps with non-standard subroles, Finder
  desktop, windows of apps that are still launching, tabbed windows
  (Safari/Finder/Terminal tabs share one AX window).
  (2026-09-28) — partial: minimized windows report subrole `AXDialog` and were
  dropped; now accepted by role + `kAXMinimizedAttribute`. Rest still open.
  (2026-09-28) — found: TextEdit document windows report subrole `AXDialog` even
  when not minimized, so they are dropped (also on the pre-change build).
  (2026-09-29) — partial: the `AXDialog` document windows only occur until TextEdit is
  first activated; accepted when their minimize button is enabled, which About boxes
  and the Fonts panel lack (both stay hidden). `--dump` now reports role/subrole and
  `+min` per window. Checked: floating panels (`AXFloatingWindow`) hidden, sheets are
  not in `kAXWindows`, Finder desktop is `AXScrollArea` (hidden), Electron apps (VS
  Code, Claude, Teams) listed, a launching app (Chess) appears ~1.6 s after launch
  via observer retry, tabs share one AX window (documented in README). Remaining:
  Java apps (none installed to verify); no app found with an empty AX title (apps
  report "Untitled" themselves, the app-name fallback is untested); Chess briefly
  shows an extra `AXUnknown` window while launching.
- [x] **Full-screen apps.** Hide the bar on full-screen Spaces; list full-screen
  windows and switch to their Space when clicked.
  (2026-09-29) — the panels (`.canJoinAllSpaces`, no `.fullScreenAuxiliary`) already stay off
  full-screen Spaces: with TextEdit full-screen on the Dell, `CGWindowListCopyWindowInfo` shows
  the Dell panel `onscreen=0` and the built-in one `onscreen=1`, both `1` back on the desktop.
  Full-screen windows are listed through All Spaces (on the bar of their display, `[8, 1]`).
  `--focus` (the click path) switches to their Space and back without extra code: Desktop →
  full-screen window (Space 1 → 723), full-screen → minimized desktop window (→ 1), and with
  TextEdit hidden; AX raise + `kAXFrontmostAttribute` alone already switches Space.
- [ ] **Focus reliability.** Verify focusing works for minimized windows, hidden
  apps, windows on another screen, and apps that ignore `kAXFrontmostAttribute`;
  fall back to `NSRunningApplication.activate()` with `NSApp.yieldActivation(to:)`
  (cooperative activation, macOS 14+).
  (2026-09-29) — partial: if the app isn't active 100 ms after the AX sequence,
  `focus` yields activation, calls `activate()` and raises the window again. Verified
  with the new `--focus <title>` debug mode: background, minimized, hidden and
  hidden+minimized TextEdit windows get focus. Before the change, the hidden case left
  Finder frontmost (AX activation arrives while the app is still unhiding). The
  fallback fired only there. VS Code, Firefox, Teams, Claude and Bionic focus via AX
  alone. Remaining: windows on another screen (only one display attached); no app
  found that ignores `kAXFrontmostAttribute`.
  (2026-09-29) — partial: windows on another screen lost focus to the app's previous key
  window: activation lands asynchronously and brings that window forward. Raising only
  before activation failed 3/3 and raising again afterwards passed 3/3 (AX probe). `focus`
  now raises again at the 100 ms activation check. With `--focus` (now preferring an
  exact title match), TextEdit on Dell (1×) + built-in (2×): built-in window from Finder
  5/5 (before: 0/8), minimized and hidden+minimized OK, and the other direction 3/3. VS
  Code windows on the same screen are unchanged. Remaining: no app found that ignores
  `kAXFrontmostAttribute`.
- [ ] **Screen handling.** Windows moving between screens, displays with
  different scale factors, display sleep/wake, clamshell mode, screens added or
  removed while running (already rebuilds bars — verify no leaks/flicker).
  (2026-09-29) — partial: screen-parameter changes that leave every bar's frame alone (Dock
  auto-hide toggled 10×) recreated all panels; now `rebuildBars` compares
  `TaskbarBar.Layout`s and keeps the bars. The log shows `Screens or settings changed` per
  toggle and no `Bars rebuilt`, and `heap` counts 2 `NSPanel`/2 `TaskbarBar` before and
  after. Toggling "Menu bar display only" still rebuilds (`Bars rebuilt: 1 on 2 screens`,
  heap 1/1, the old panel freed). Moving a TextEdit window Dell ↔ built-in (1× / 2×) moves
  its button (`Windows per bar` `[5, 2]` → `[6, 1]` → `[5, 2]`). Remaining, needs someone
  at the Mac: display sleep/wake (locks the screen immediately), clamshell mode, unplugging
  and replugging a display.

## Phase 2 — UX

- [ ] **Screen space.** macOS has no API to reserve a screen strip, so maximized
  and zoomed windows go under the bar. Options, to be evaluated:
  - optional auto-hide of the bar,
  - when a window is zoomed or sized to fill the screen, shrink it via AX
    to end above the bar (as Rectangle does),
  - document "set the Dock to auto-hide" in onboarding.
- [x] **Incremental UI updates.** Diff snapshots and update/insert/remove buttons
  instead of rebuilding all of them; animate changes.
  (2026-09-29) — `TaskbarBar` keeps one button per `WindowKey` and re-applies title, tooltip,
  tint and alpha in place; new buttons fade in, width changes animate (none with Reduce
  motion). Debug log per update: opening a Finder window `+1 −0 =6`, changing its folder
  `+0 −0 =7`, closing it `+0 −1 =6`; moving a TextEdit window Dell → built-in `−1` on one bar
  and `+1` on the other, and back. Fixed a leak found on the way: the Close Window item's
  `representedObject` retained its button (`heap`: 17 `TaskButton`s for 7 windows); now 7
  before and after 10 open/close cycles.
- [ ] **Button states:** hover, pressed, focused, minimized, attention/badge;
  correct colours in light/dark mode and with "Reduce transparency".
  (2026-09-29) — partial: buttons draw their tint in `draw(_:)`, so it follows the appearance
  (layer colours were fixed at creation); hover via tracking area, pressed via the cell's
  highlight, "Increase contrast" adds an outline; the app's Dock badge (`AXStatusLabel` of its
  Dock item) shows as a red capsule. `--render-buttons <dir>` renders every state light and dark
  (checked). Live: posted mouse events log hover on/off and pressed true/false, the click focuses
  TextEdit; switching the system to light and back redraws the panel (`screencapture -l`);
  `--dump` shows `badge=2` for Teams, matching the Dock. Remaining: attention (bouncing) has no
  public signal (the Dock items expose no such attribute); Reduce transparency and Increase
  contrast untested live (`com.apple.universalaccess` is not writable from a script).
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
  (2026-09-29) — found: the Settings window's toggles expose no AX title (the label is a
  sibling `AXStaticText`), so they can only be addressed by position.
  (2026-09-29) — partial: bar panels are titled "Taskbar"; each button's AX description is
  "App — Title" plus its state, read back e.g. "Firefox — Livestreams | OpenAI, focused",
  "Microsoft Teams — …, badge 2", "TextEdit — Ohne Titel 2, minimized". Every Settings
  toggle, picker and slider now has a description ("Menu bar display only", "DELL U3223QE",
  "Windows from", "Height", …; before: none). Remaining: keyboard navigation — the bar is a
  non-activating panel, so it needs a global hotkey (to be decided) or relies on VoiceOver.
- [ ] **Localization:** English + German.

## Phase 3 — Settings & lifecycle

- [x] Status bar item (`NSStatusItem`) with Settings… and Quit. (2026-09-29) — the menu
  shows both entries; Settings… opens the window in front even when activation is refused.
- [ ] Settings window (SwiftUI): enabled screens, bar position (top/bottom),
  height, button max width, grouping, current Space vs. all Spaces, launch at login.
  (2026-09-29) — partial: screens (plus "Menu bar display only": one bar on the first
  screen, which collects the windows of all screens; verified `Windows per bar: [5]` with
  two displays), position, height, button width and launch at login. Grouping and the
  Space option wait for those features.
  (2026-09-29) — partial: Space option added ("Windows from", see All Spaces). Remaining:
  grouping.
- [x] Persist settings in `UserDefaults`. (2026-09-29) — values clamped on load; verified
  via `defaults write`: top/bottom position, height clamping, a disabled screen gets no bar.
- [x] Launch at login via `SMAppService.mainApp.register()`. (2026-09-29) — verified with
  `--login-item register | status | unregister` (`enabled` → `notRegistered`).
- [ ] Onboarding window explaining and requesting the Accessibility permission;
  detect when the permission is revoked while running.
  (2026-09-29) — partial: the window replaces the system prompt, opens Privacy &
  Security → Accessibility and closes itself once trusted; a revoked permission is
  checked on every reconciliation poll. The app became trusted again after the re-grant.
  Remaining: the revocation test (`tccutil reset`) ran while the screen was locked and
  the app still reported `AXIsProcessTrusted = true` 8 s later — rerun unlocked.

## Phase 4 — Engineering quality

- [ ] Split into a library target (`TaskbarCore`: ordering, screen assignment,
  filtering, snapshot diffing — pure, AX-free) plus the app target.
- [ ] Unit tests for `TaskbarCore` (`swift test`), with fake window snapshots.
- [ ] Protocol around the AX layer so the UI can run against a fake source.
- [ ] Performance budget: idle CPU < 0.5 %, no memory growth over 24 h;
  measure with Instruments.
- [x] Linting/formatting: `swift-format` (or SwiftLint) in `just lint`. (2026-09-29) —
  `just lint` / `just format` / `just lint-fix` run the toolchain's bundled `swift format`
  (no install needed); `.swift-format` keeps the existing style (4 spaces, 120 columns) and
  disables `ReplaceForEachWithForLoop`. `just lint` failed before formatting, passes after.
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
