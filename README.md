# Didact (previously BtnQ)

A tiny macOS menu-bar app to control an external monitor over DDC/CI — no settings
window, no ~1 GB control panel, just standard macOS menus.

Initially built for the **BenQ RD280UG** (which it ships with a profile for),
Didact now works toward supporting any DDC/CI monitor: a built-in wizard detects
the standard controls and learns the rest, and every monitor-specific detail lives
in a shareable JSON profile — so new monitors need **no code changes**.

<img width="472" height="536" alt="Didact Light Mode" src="https://github.com/user-attachments/assets/6e3e6b7a-fd4c-4bd3-bb48-cf05da2d98e3" /> <img width="472" height="536" alt="Didact Dark Mode" src="https://github.com/user-attachments/assets/6df68a1a-b997-4fb8-a16e-4915e1dd0b81" />

## Didact vs BenQ Display Pilot 2

|           | Didact       | Display Pilot 2 |
|-----------|:----------:|:---------------:|
| Download  | **517 KB** | 404 MB          |
| Installed | **578 KB** | 936 MB          |

…about **800× smaller to download** and **over 1,600× smaller installed**, for the
controls you actually use.

## Requirements

- Apple Silicon Mac (DDC is done via `IOAVService`, Apple-Silicon only).
- A monitor connected over DisplayPort / USB-C / HDMI with DDC/CI enabled.
- macOS 13.0 or later.

## How it works

- **DDC transport** is a vendored copy of [AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC)
  (MIT). The private CoreDisplay/IOKit symbols it needs are declared in
  `AppleSiliconDDCBridge.swift` via `@_silgen_name`, so the whole library is just
  two Swift files — no bridging header, no SPM dependency. `CoreDisplay.framework`
  is linked via `OTHER_LDFLAGS = -framework CoreDisplay`.
- **The app is not sandboxed** (`ENABLE_APP_SANDBOX = NO`): DDC needs raw IOKit
  access, which the App Sandbox forbids.
- The DDC/VCP map was ported from [bebenqli](https://github.com/iurev/bebenqli),
  a Linux TUI for the same panel.

## Adding support for another monitor

Drop a JSON file into either:

- the app bundle (`Didact/Monitors/`), or
- `~/Library/Application Support/Didact/Monitors/` (no rebuild — use
  **Didact ▸ Open Monitors Folder**, then **Reload Configs**).

### Config format

```jsonc
{
  "name": "BenQ RD280UG",          // shown in the menu
  "match": ["RD280U", "RD280UG"],  // case-insensitive substrings of the display's product name
  "controls": [
    { "kind": "group",   "label": "Image" },
    { "kind": "section", "label": "Night Protection" },

    // Slider. min/max/step are decimal.
    { "kind": "range", "label": "Brightness", "vcp": "10", "min": 0, "max": 100 },

    // Pick-one. Each option value mirrors the DDC docs (hex string) or a decimal number.
    { "kind": "cycle", "label": "Source", "vcp": "60",
      "options": [
        { "value": "0x0f", "label": "DisplayPort" },
        { "value": "0x11", "label": "HDMI" },
        { "value": "0x13", "label": "USB-C" }
      ] },

    // On/off.
    { "kind": "toggle", "label": "Auto Brightness", "vcp": "e2", "onValue": 255, "offValue": 0 }
  ]
}
```

**Field reference**

| Field | Applies to | Meaning |
|-------|-----------|---------|
| `kind` | all | `group`, `section`, `range`, `cycle`, or `toggle` |
| `label` | all | Menu text |
| `vcp` | range/cycle/toggle | VCP feature code, **hexadecimal** (e.g. `"60"`, `"d9"`) |
| `min`/`max`/`step` | range | Slider bounds (decimal); `step` defaults to 1 |
| `options` | cycle | List of `{ value, label }` |
| `onValue`/`offValue` | toggle | Values written for on/off |
| `channel` | range/cycle/toggle | High byte **written** for 16-bit multiplexed registers (e.g. Moon Halo on `d9`) |
| `readChannels` | range/cycle/toggle | High byte(s) that identify this control's value on **read** (a multiplexed read returns only the last-touched channel). Defaults to `channel`. |
| `noRead` | any control | Value can't be read back; Didact remembers the last value you set |
| `noVerify` | any control | Monitor reports a bogus value after a write |

**Values**: a JSON **number** is decimal; a JSON **string** is hexadecimal
(`"0x30"` or `"30"`). `vcp` is always hex.

**Multiplexed registers**: some BenQ features share one VCP code, selected by the
high byte. Moon Halo brightness and colour temperature both live on `d9`
(`channel: "0x01"` and `channel: "0x07"`); Didact writes `(channel << 8) | value`.

## Debugging — dump DDC values

`Tools/dump.sh` compiles a small CLI from the app's own DDC code and prints the
current value of every candidate VCP code, decoded against the config:

```
./Tools/dump.sh                       # uses Didact/Monitors/BenQ-RD280UG.json
./Tools/dump.sh path/to/other.json    # decode against another config
```

## Thanks

Didact is built directly on these two projects:

- **[AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC)** by [@waydabber](https://github.com/waydabber) (MIT) — the DDC/CI transport, vendored into Didact.
- **[bebenqli](https://github.com/iurev/bebenqli)** by [@iurev](https://github.com/iurev) (MIT) — the BenQ RD280UG DDC/VCP map and the baseline-sweep discovery behind Listen mode.

## License

Didact is released under the [MIT License](LICENSE). Both vendored/ported
components above are also MIT-licensed; their notices are reproduced in the
[`LICENSE`](LICENSE) file.
