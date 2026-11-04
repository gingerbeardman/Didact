# Didact — Features

A tiny macOS menu-bar app that controls an external monitor over DDC/CI — no
settings window, no bloated vendor control panel, just standard macOS menus.

## What it is

- **Menu-bar only** (`NSApplication.accessory`): every control lives in the
  status-bar menu. No dock icon, no preferences window.
- **Tiny**: ~529 KB to download, ~578 KB installed — roughly 760× smaller to
  download and 1,600× smaller installed than BenQ Display Pilot 2 (404 MB / 936 MB).
- **Free and open source** (MIT), distributed directly as a notarized DMG.

## Monitor control over DDC/CI

- Adjusts the physical monitor over DDC/CI — brightness, contrast, volume, input
  source, colour mode, and any vendor feature exposed as a VCP code.
- Control kinds rendered as native menu items: **range** (slider), **cycle**
  (pick-one), **toggle** (on/off), grouped under **group**/**section** headers.
- Live values are read back from the monitor and refreshed in the background;
  the menu reflects the monitor's real state.
- Ships with a profile for the **BenQ RD280UG**, including BenQ-specific features
  like Moon Halo (multiplexed VCP registers on a shared code).

## Works toward any DDC/CI monitor — no code changes

- Every monitor-specific detail lives in a **shareable JSON profile**; new
  monitors need no rebuild. Drop a profile into the bundle or
  `~/Library/Application Support/Didact/Monitors/` and **Reload Configs**.
- Profiles are matched by display product-name substrings and, more robustly, by
  **EDID** (vendor + product number) — surviving renames and localization.

## Teach wizard (learn a new monitor)

- A step-by-step wizard builds a profile for an unknown monitor.
- **Standard VESA controls** (brightness, contrast, volume, input) are
  **auto-detected** from the monitor's capabilities string with no user effort.
- **Everything else is taught**: the user works the physical OSD button while
  Didact watches which VCP code moves the most, then confirms it.
- Each step ends on **test-and-confirm**: a live, working control bound to the
  detected code, so the user verifies it actually moves the monitor before saving.
- **Known-profile auto-fill**: if the monitor resembles one already known,
  matching controls are imported automatically (conservative, capabilities-verified).

## Listen mode (discover unmapped features)

- A logging window that polls candidate VCP codes and reports any that change —
  press buttons on the monitor's own OSD and watch which code moves.
- Searchable, selectable log with Copy All / Clear. Runs only while open.

## Media keys

- Optional: the Mac's brightness, volume and mute keys control the external
  monitor instead of doing nothing.
- Offered once in the first-run setup wizard. **Brightness Keys** and **Volume &
  Mute Keys** both start enabled; the master switch is off until you enable it.
- **Brightness** follows the display under the mouse pointer.
- **Volume and mute** follow the default audio output's display, so the keys
  change the speakers you're actually hearing; if the name doesn't match a
  display, they fall back to the pointer display.
- Keys pass through untouched when the pointer is over the built-in display, the
  Mac audio device has its own volume control, no supported control exists, a key
  group is switched off, or a modifier key is held.
- A small 16-segment on-screen display confirms handled changes.
- Requires Accessibility permission, requested only after the wizard or menu
  explains what it is used for. No special entitlement, login helper or driver.
- **Touch Bar:** not supported. The Touch Bar's brightness/volume controls are
  system-reserved and cannot be redirected to DDC; see the README note.

## Menu editor

- Reorder the top-level controls, remove ones you don't want, and insert
  dividers — saved as a user-directory profile that overrides the bundled one.

## Share with the community

- One action submits a profile (plus its raw DDC capabilities dump) to the
  project's GitHub so others with the same monitor benefit. Full payload is
  always copied to the clipboard; a pre-filled GitHub issue is opened as a convenience.

## Platform & implementation

- **Apple Silicon only** — DDC is done via the private `IOAVService` (Apple-Silicon).
- **macOS 13.0 (Ventura)** or later.
- DDC transport is a vendored copy of AppleSiliconDDC (MIT); private
  CoreDisplay/IOKit symbols declared via `@_silgen_name`.
- **Not sandboxed** (DDC needs raw IOKit access), **hardened runtime** enabled,
  Apple-notarized for Gatekeeper.
- **Accessibility permission** is optional and used only to read the five media
  keys; the event tap is limited to system-defined media-key events, not ordinary
  keystrokes.
- Auto re-scans displays when monitors are plugged in/out or rearranged.
