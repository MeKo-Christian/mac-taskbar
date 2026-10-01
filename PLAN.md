# MacTaskbar — Plan to Production

Phases are ordered by dependency; within a phase, items are roughly by priority. Findings about
macOS behaviour live in [docs/INSIGHTS.md](docs/INSIGHTS.md).

## Phase 0 — Make the PoC work reliably — ✅ DONE

- [x] Stable "MacTaskbar Dev" signing identity, so the Accessibility grant survives rebuilds.
- [x] Diagnostics: `os.Logger` (subsystem `io.github.cwbudde.mactaskbar`), `just logs`, `just dump`.
- [x] Git repository, LICENSE (MIT).

## Phase 1 — Correct, efficient window tracking

- [x] **Event-driven updates.** One `AXObserver` per app, bursts coalesced, 5 s reconciliation poll.
- [x] **AX off the main thread.** `WindowSource` enumerates and acts on a private serial queue.
- [x] **Stable window identity.** `WindowKey` by `CGWindowID` (`_AXUIElementGetWindow`), `CFEqual` fallback.
- [ ] **All Spaces.**
  - [x] Windows of other Spaces via SkyLight + remote AX tokens; falls back to the current Space.
  - [x] Setting *Windows from: All Spaces / Current Space*.
  - [ ] Verify with a regular second desktop (so far only full-screen Spaces).
- [ ] **Window filtering edge cases.**
  - [x] Minimized windows, TextEdit's `AXDialog` document windows, floating panels, sheets,
        Finder desktop, Electron apps, apps still launching.
  - [x] Tabs share one window (documented in README).
  - [ ] Java apps (none installed to verify).
  - [ ] Windows with an empty AX title (app-name fallback untested).
  - [ ] Hide the transient `AXUnknown` window some apps (Chess) show while launching.
- [x] **Full-screen apps.** Bar hidden on full-screen Spaces; full-screen windows listed, click switches Space.
- [ ] **Focus reliability.**
  - [x] Minimized windows, hidden apps, windows on another screen.
  - [ ] An app that ignores `kAXFrontmostAttribute` (none found yet).
- [ ] **Screen handling.**
  - [x] Windows moving between screens with different scale factors.
  - [x] Screen-parameter changes keep bars whose layout is unchanged (no flicker, no leaks).
  - [ ] Display sleep/wake.
  - [ ] Clamshell mode.
  - [ ] Unplugging and replugging a display while running.

## Phase 2 — UX

- [ ] **Screen space.** macOS cannot reserve a screen strip, so zoomed windows go under the bar.
  - [x] Keep-out: windows reaching into the bar are shrunk (or moved) via AX to end at its edge
        (`KeepOut`, setting *Keep windows clear of the bar*).
  - [ ] Keep-out on a second display.
  - [ ] Keep-out with Terminal-style size increments (Terminal, iTerm). (2026-10-01) — partial:
        Terminal fixed (overshooting heights are retried smaller until they fit); iTerm not installed.
  - [ ] Keep-out after drag-to-tile with a real mouse.
  - [x] Optional auto-hide of the bar (`AutoHide`, keep-out pauses while it is on).
  - [x] Onboarding hint: set the Dock to auto-hide (`DockHintWindow`).
- [x] **Incremental UI updates.** Buttons diffed per `WindowKey`, fade in, animated width changes.
- [ ] **Button states.**
  - [x] Hover, pressed, focused, minimized; light/dark; *Increase contrast* outline; Dock badges.
  - [ ] Attention (bouncing): no public signal found yet.
  - [ ] Verify *Reduce transparency* and *Increase contrast* live.
- [ ] **Interactions.**
  - [x] Middle-click to close.
  - [x] Drag to reorder (kept until MacTaskbar quits).
  - [x] Scroll to cycle windows (the bar's windows, wrapping; trackpad deltas add up).
  - [ ] Context menu: New Window, Hide, Quit App, Move to Screen. (2026-10-01) — partial: all built;
        New Window (the app's ⌘N item), Hide and Quit verified, Move to Screen needs a second display.
- [x] **Grouping.** Setting *Group windows by app*: one button per app with 2+ windows on a bar,
  with a count; click lists its windows, right-click offers *Close All Windows*.
- [x] **Hover previews** via ScreenCaptureKit (requires Screen Recording permission — keep optional).
  (2026-10-01) — Setting *Show window previews on hover* (off by default; asks for the permission,
  does nothing without it): thumbnails above the button, a group's windows in a row, click focuses.
- [ ] **Pinned launchers** (optional), so the Dock can be hidden completely.
- [ ] **Status area** (optional): clock, maybe a menu for settings/quit.
- [ ] **Dock interplay.** The Dock's reveal zone overlaps the bar; check Dock at bottom/left/right
  with auto-hide on and off.
- [ ] **Accessibility.**
  - [x] VoiceOver labels for the bar, its buttons (app, title, state) and every Settings control.
  - [ ] Keyboard navigation: the bar is a non-activating panel, so decide on a global hotkey.
- [ ] **Localization:** English + German.

## Phase 3 — Settings & lifecycle

- [x] Status bar item with Settings… and Quit.
- [x] **Settings window (SwiftUI).**
  - [x] Enabled screens, *Menu bar display only*, position, height, button width, Windows from,
        keep windows clear, launch at login.
  - [x] Grouping: *Group windows by app*; window previews: *Show window previews on hover*.
- [x] Settings persisted in `UserDefaults`, clamped on load.
- [x] Launch at login via `SMAppService.mainApp`.
- [ ] **Onboarding.**
  - [x] Window explaining the Accessibility permission; opens System Settings, closes once trusted.
  - [x] Revocation checked on every reconciliation poll.
  - [ ] Verify revocation (`tccutil reset`) with the screen unlocked.

## Phase 4 — Engineering quality

- [ ] Split into a library target (`TaskbarCore`: ordering, screen assignment,
  filtering, snapshot diffing — pure, AX-free) plus the app target.
- [ ] Unit tests for `TaskbarCore` (`swift test`), with fake window snapshots.
- [ ] Protocol around the AX layer so the UI can run against a fake source.
- [ ] Performance budget: idle CPU < 0.5 %, no memory growth over 24 h;
  measure with Instruments.
- [x] Linting/formatting: `just lint` / `just format` / `just lint-fix` (swift-format, `.swift-format`).
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
