# touchutil

Make an external **USB touchscreen** click where you tap on macOS.

## The problem this solves

I plugged a portable touchscreen monitor into my Mac and found that macOS
treats it like a plain mouse. On an extended desktop, tapping the touchscreen
doesn't click where you touch — it clicks wherever the system cursor already
happens to be, on whichever display. There's no native macOS setting to map an
external touchscreen's absolute touch input to its own display.

`touchutil` fixes exactly that one issue: it reads the touchscreen's absolute
coordinates via `IOHIDManager` and warps the cursor to your finger, then
clicks/drags there — so a tap lands where you tap.

> **Tested locally** with a **Goojodoq portable touchscreen monitor**
> (SiS HID Touch Controller). Other HID digitizer touchscreens should work too,
> but that's the panel it's been verified on.

- ✅ Apple Silicon + Intel (universal binary)
- ✅ No kernel extension, no SIP changes
- ✅ Single-finger: tap, double-tap, long-press (right-click), drag, edge swipes

## Limitations / disclaimer

- **This is not a driver.** It's a small userspace tool that reads HID input and
  moves the cursor. It does not install a kernel extension or system driver, and
  it does not require a paid Apple Developer account.
- **Single-finger only.** It does **not** support multi-finger gestures (pinch,
  rotate, two-finger scroll, etc.). True multi-touch on an external display
  would require a DriverKit HID driver, which needs a paid Apple Developer
  account to sign and notarize. This tool deliberately uses `IOHIDManager`
  (userspace, free, no entitlements) — the trade-off is single-finger only.

## Requirements

- macOS 11 or later
- Xcode Command Line Tools (`xcode-select --install`) — full Xcode not needed

## Install

```bash
git clone https://github.com/keys2505/touchutil.git
cd touchutil
chmod +x scripts/*.sh
./scripts/install.sh
```

The installer builds the app, copies it to `/Applications`, links the CLI to
`/usr/local/bin/touchutil`, and sets up a login agent so it starts
automatically.

On first launch, grant **Input Monitoring** and **Accessibility** to
`touchutil` (the installer prints the exact commands). macOS only applies a new
permission on a fresh start, so re-run after granting.

To remove:

```bash
./scripts/uninstall.sh          # remove app, agent, CLI link; revoke permissions
./scripts/uninstall.sh --purge  # also delete saved config
```

## Usage

```bash
touchutil           # auto-detects the touchscreen display
touchutil --setup   # pick the touchscreen display and remember it
```

Touch the screen — the cursor jumps to your finger and clicks/drags. Press
**Ctrl+C** to stop. Your `--setup` choice is saved to
`~/.config/touchutil/config.json` and reused on every run.

### Options

| Option | Description |
| --- | --- |
| `--setup` | Pick & remember the touchscreen display |
| `--no-gestures` | Plain pointer only (no tap / long-press / edge-swipe) |
| `--list-displays` | List displays and detected touch devices |
| `--list-devices` | List all HID devices |
| `--inspect` | Dump a touchscreen's HID capabilities |
| `--display-index N` | Map touch to display index `N` (remembered) |
| `--vendor-id 0xVVVV` / `--product-id 0xPPPP` | Match a specific touch device |
| `--debug` | Log raw HID page/usage/value |
| `-h`, `--help` | Show help |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `IOHIDManagerOpen failed` | Grant **Input Monitoring**, then re-run |
| Cursor doesn't move | Grant **Accessibility**, then re-run |
| `--list-devices` shows nothing | Plug in the touchscreen's **USB data cable** (separate from video) |
| Touch lands on the wrong screen | Run `--setup`, or pass `--display-index` |

## How it works

`IOHIDManager` matches the touchscreen digitizer, reads absolute X/Y + tip
switch from each report, maps the normalized coordinates onto the chosen
display, and posts cursor/click events via `CGEvent`. A reconfiguration
callback refreshes the target when you rearrange or hot-plug displays.

## License

MIT — see [LICENSE](LICENSE).
