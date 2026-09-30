# Insights

macOS behaviour that shaped the code and is easy to get wrong again. This is not a changelog:
every entry states something that holds today, found while building and verifying MacTaskbar.

## Signing and the Accessibility grant

- TCC ties the Accessibility grant to the signature's designated requirement. An ad-hoc signature
  puts the cdhash into it, so every build is a new app to macOS: it stays listed in System
  Settings, but `AXIsProcessTrusted` is false and nothing says why. A self-signed identity
  ("MacTaskbar Dev", `just dev-cert`) gives a requirement of identifier + certificate leaf, which
  survives rebuilds. A grant stuck on an old signature: `just reset-permission`, run, grant again.
- Run from a terminal (`just dump`), the Accessibility check applies to the terminal app, not to
  MacTaskbar.app.
- `tccutil reset` while the screen was locked did not revoke the grant (still trusted 8 s later).
  Test revocation with the screen unlocked.

## Accessibility API

- AX calls block for up to the messaging timeout when an app is unresponsive, so they never run
  on the main thread: `WindowSource` owns a private serial queue and hands immutable `TaskWindow`
  snapshots to the UI. Check with `kill -STOP <app>` + `sample`: no AX frames on the main thread.
- Coordinates: AX is top-left of the primary screen with y pointing down, Cocoa is bottom-left.
  `axY = primaryHeight − cocoa.maxY`.
- Window identity: `_AXUIElementGetWindow` (private, as AltTab and Rectangle use it) returns the
  `CGWindowID`. It is stable across enumerations, kept while minimized, and matches the owner PID
  in `CGWindowListCopyWindowInfo`. `CFEqual` on the element is the fallback.
- Notifications: register app-level ones (window created, focused window changed, hidden/shown)
  on the app element and window-level ones (destroyed, title, moved, resized, (de)miniaturized)
  per window. They arrive in bursts, so coalesce (50 ms). Apps still launching can refuse an
  observer; retry on the next refresh. A slow reconciliation poll (5 s) stays as a safety net.
- Subroles are unreliable for filtering:
  - Minimized windows report `AXDialog`.
  - TextEdit document windows report `AXDialog` until the app is first activated. They differ
    from real dialogs by an enabled minimize button, which About boxes and the Fonts panel lack.
  - Floating panels are `AXFloatingWindow`, sheets are not in `kAXWindows` at all, and the Finder
    desktop is an `AXScrollArea`.
  - Electron and Java apps may use non-standard subroles; large role-only `AXWindow`s are accepted.
  - A launching app can briefly expose an extra `AXUnknown` window (Chess).
- Tabs (Safari, Finder, Terminal, browsers) share one AX window; they cannot be listed separately.
- `kAXWindows` also lists minimized windows that belong to other Spaces (they keep their Space).

## Spaces

- AX only sees the current Space. SkyLight functions (resolved with `dlsym`; missing → current
  Space only) give each display's current Space and each window's Spaces.
- Windows only on other Spaces are reached through their remembered AX element, else through
  `_AXUIElementCreateWithRemoteToken`, as AltTab does. Budget it (100 ms per app) and retry a
  failed window only when it moves: helper windows that never resolve would otherwise cost a
  lookup on every Space switch.
- Full-screen windows live on their own Space. Panels with `.canJoinAllSpaces` and without
  `.fullScreenAuxiliary` stay off full-screen Spaces with no extra code.
- AX raise + `kAXFrontmostAttribute` switches to the window's Space by itself.

## Focus

- Hidden app: the AX activation arrives while the app is still unhiding and is lost. If the app
  is not active 100 ms later, `NSApp.yieldActivation(to:)` + `activate()` and raise again.
- Window on another screen: activation lands asynchronously and brings the app's previous key
  window forward. Raising only before activation fails; raise again after it (at the 100 ms check).

## Screens, panels and drawing

- Screen-parameter notifications also fire for changes that leave every bar frame alone (e.g.
  toggling Dock auto-hide). Compare `TaskbarBar.Layout`s and keep the bars when equal instead of
  recreating the panels.
- `NSMenuItem.representedObject` retains its object; pointing it at a button leaked buttons.
- Layer colours are resolved once at creation. Draw tints in `draw(_:)` so they follow light/dark
  and contrast changes.
- Dock badges are the `AXStatusLabel` of the app's Dock item. Attention (bouncing) has no public
  or AX signal.
- A SwiftUI `Toggle`/`Picker` in the Settings window has no AX title of its own (the label is a
  sibling `AXStaticText`); give each one an `.accessibilityLabel`.

## Keeping windows clear of the bar

- macOS cannot reserve a screen strip: `visibleFrame` only leaves out the menu bar and the Dock,
  so zoom and tiling size windows under the bar. The only option is correcting them afterwards
  through AX, as Rectangle does.
- Only windows whose edge lies inside the bar strip are adjusted. A bottom edge below the screen
  edge means the window was parked there on purpose.
- Wait while a mouse button is down (`NSEvent.pressedMouseButtons`) and adjust on the next
  `.leftMouseUp` (global monitor): during drags and resizes the frame keeps changing.
- Apps apply frames partly, late, or not at all:
  - Firefox applies a size asynchronously and drops a move that directly follows a resize. Set
    move → resize → move, and move again 100 ms later if only the size took.
  - Fixed-size apps (Calculator) keep their height; move them up instead.
  - Skip `AXFullScreen` windows and windows as large as the screen (games, presentations).
- A rule-based adjuster loops when an app only partly accepts a frame (Firefox shrank 12 pt per
  refresh). Never re-adjust a frame an adjustment produced, and cap adjustments per window
  (3 in 10 s).

## Auto-hide

- Global event monitors only see events delivered to other apps. A hidden bar sets
  `ignoresMouseEvents`, so the pointer over it reaches the apps below and the global `.mouseMoved`
  monitor sees it; once the bar is shown, the pointer is over our own panel and has to be polled
  (`NSEvent.mouseLocation`).
- Reveal only after the pointer rests at the edge for a moment: the strip under a top bar is
  crossed on every trip to the menu bar or a window's title bar.
- Slide the bar's content inside the panel, not the panel itself: the panel clips its content,
  whereas a panel moved past the screen edge shows up on a display adjoining that edge.
- `NSMenu.didBeginTracking`/`didEndTracking` tell when a bar's context menu is open; the pointer
  is outside the bar then, but the bar must stay.

## Tooling and verification

- `just logs` streams the app's log; `just dump` prints the enumeration (`id=`, role/subrole,
  `+min`, `spaces=`, `badge=`) without the UI.
- Debug modes of the binary: `--focus <title>` (the click path), `--render-buttons <dir>` (every
  button state, light and dark), `--login-item register|status|unregister`.
- Settings can be set without the UI: `defaults write io.github.cwbudde.mactaskbar <key> <value>`.
  The running app doesn't notice; restart it.
- Pointer and clicks can be scripted with `CGEvent(mouseEventSource:mouseType:…)` posted to
  `.cghidEventTap` (needs Accessibility for the terminal); `kCGWindowAlpha` in
  `CGWindowListCopyWindowInfo` shows whether a bar is shown.
- Leak checks: `heap <pid>` counts live `NSPanel`/`TaskbarBar`/`TaskButton` instances. Panel
  visibility per Space: the `onscreen` flag in `CGWindowListCopyWindowInfo`. Panel pixels:
  `screencapture -l <windowID>`.
- zsh has a `log` builtin; use `/usr/bin/log show` / `/usr/bin/log stream`.
- Not scriptable: adding a desktop via Mission Control, writing `com.apple.universalaccess`
  (Reduce transparency, Increase contrast), display sleep/wake, clamshell, replugging displays.
