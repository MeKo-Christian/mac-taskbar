# MacTaskbar

Proof of concept of a Windows/GNOME-style window list for macOS: a bar at the
bottom of every screen with one button per open window.

- Click a window to focus it (also restores minimized windows and unhides hidden apps).
- Click the focused window to minimize it.
- Right-click a window button → *Close Window*; right-click the empty bar → *Quit*.
- Each screen lists the windows whose center lies on that screen.

## Build & run

```sh
make dev-cert # once: create a self-signed "MacTaskbar Dev" signing identity (asks for your password)
make run      # swift build, wrap into dist/MacTaskbar.app, sign, launch
```

On first launch, grant Accessibility access in System Settings → Privacy &
Security → Accessibility. With the `MacTaskbar Dev` identity the grant survives
rebuilds. Without it, `make` falls back to ad-hoc signing, which changes on every
build, and macOS silently stops applying the old grant.

## Troubleshooting: the bar is empty

1. `make logs` (in a second terminal) streams the app's log. It shows
   `AXIsProcessTrusted = …` and, per app, the result of reading its windows
   (`apiDisabled` means the app is not trusted for Accessibility).
2. `make dump` prints the same enumeration to stdout without starting the UI. Run
   from a terminal, the Accessibility check applies to the terminal app, so this
   shows whether enumeration itself works.
3. If the app is not trusted although it is listed in System Settings, the grant
   belongs to an older signature: `make reset-permission`, `make run`, grant again.

## Limitations (PoC)

- Windows are read via the Accessibility API, which only sees the current Space.
- macOS has no API to reserve screen space, so maximized windows extend underneath the bar.
- State is polled every 0.5 s instead of using per-app `AXObserver` notifications.
