# MacTaskbar

Proof of concept of a Windows/GNOME-style window list for macOS: a bar at the
bottom of every screen with one button per open window.

- Click a window to focus it (also restores minimized windows and unhides hidden apps).
- Click the focused window to minimize it.
- Middle-click a window to close it. Drag buttons to reorder them (until MacTaskbar quits).
- Scroll over the bar to focus the next or previous window, wrapping around.
- Right-click a window button → *New Window* (the app's ⌘N item), *Move to Screen* (with more
  than one display), *Close Window*, *Hide* / *Quit* the app; right-click the empty bar → *Quit*.
- Buttons show the app's Dock badge (e.g. unread count), highlight on hover and press, and
  follow light/dark mode and *Increase contrast*.
- Each screen lists the windows whose center lies on that screen.
- Windows on other Spaces, full-screen apps included, are listed too; clicking one switches to
  its Space. Settings → *Windows from: Current Space* limits the bar to the Spaces on screen.
- Windows that reach under the bar (zoomed, tiled, resized to the screen edge) are shrunk to end
  at its edge, once the mouse is released; windows that can't shrink are moved up instead.
  Windows dragged partly off-screen are left alone. Settings → *Keep windows clear of the bar*.
- Optional auto-hide (Settings → *Automatically hide and show the bar*): the bar slides out of sight
  and comes back when the pointer rests at its outer edge — the screen edge for a bottom bar, just
  below the menu bar for a top bar. Windows keep the whole screen then.
- A visible Dock at the bottom covers the bar. MacTaskbar then offers to set the Dock to hide
  automatically (or to move the bar to the top); the hint comes once per launch until dismissed.

## Build & run

Requires Xcode command line tools (Swift) and [just](https://github.com/casey/just)
(`brew install just`).

```sh
just dev-cert # once: create a self-signed "MacTaskbar Dev" signing identity (asks for your password)
just run      # swift build, wrap into dist/MacTaskbar.app, sign, launch
just lint     # check formatting and lint rules (swift-format, config in .swift-format)
just format   # format in place; `just lint-fix` formats and then lints
```

`just lint` / `just format` use the `swift format` bundled with Swift 6 (Xcode 16) and
later. On older toolchains, install the standalone formatter (`brew install swift-format`);
the recipes pick it up automatically.

On first launch, grant Accessibility access in System Settings → Privacy &
Security → Accessibility. With the `MacTaskbar Dev` identity the grant survives
rebuilds. Without it, `just` falls back to ad-hoc signing, which changes on every
build, and macOS silently stops applying the old grant.

## Troubleshooting: the bar is empty

1. `just logs` (in a second terminal) streams the app's log. It shows
   `AXIsProcessTrusted = …` and, per app, the result of reading its windows
   (`apiDisabled` means the app is not trusted for Accessibility).
2. `just dump` prints the same enumeration to stdout without starting the UI. Run
   from a terminal, the Accessibility check applies to the terminal app, so this
   shows whether enumeration itself works.
3. If the app is not trusted although it is listed in System Settings, the grant
   belongs to an older signature: `just reset-permission`, `just run`, grant again.

## Limitations (PoC)

- The Accessibility API only sees the current Space. Windows on other Spaces are found with
  private macOS functions (SkyLight, remote AX tokens), as AltTab does; if a macOS update removes
  them, the bar falls back to the current Space.
- The bar is not shown on full-screen Spaces.
- macOS has no API to reserve screen space, so zoom and tiling still size windows to reach under
  the bar; the bar corrects them afterwards through the Accessibility API. Apps that resist a new
  frame are adjusted at most 3 times in 10 s, then left alone.
- With auto-hide, a bottom bar shares the screen edge with an auto-hidden Dock at the bottom, so
  both come up together; an edge shared with another display is crossed rather than rested on.
- Tabs are not listed separately: Safari, Finder, Terminal and browser tabs share one
  window, so they get one button.
- Floating panels (e.g. Fonts, Inspector), sheets and dialogs such as About boxes are not listed.
