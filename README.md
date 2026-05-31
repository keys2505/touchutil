# mac-touch-driver

Map an external **USB touchscreen** to its display on macOS so that *tapping
the screen clicks where you tap* — instead of clicking wherever the system
cursor happens to be.

macOS has no native support for absolute touch input on external displays. It
treats USB touchscreens like a plain mouse, so in an extended-desktop setup a
tap on the touchscreen registers on whichever display the cursor is on. This
tool reads the touchscreen's absolute coordinates directly via `IOHIDManager`
and warps + clicks the cursor on the display you choose.

- ✅ Works on **Apple Silicon (M-series)** and **Intel** Macs (universal binary)
- ✅ No kernel extension, no disabling SIP
- ✅ Works with any HID touchscreen that reports as a digitizer (tested with the
  SiS HID Touch Controller used by Goojodoq portable monitors)
- ✅ Supports tap, click-and-drag, and multi-display setups

> ⚠️ This gives you **single-pointer touch** (move cursor + click/drag). macOS
> has no public API to inject system-wide multi-touch gestures (pinch/rotate)
> for external displays, so those are out of scope.

---

## Requirements

- macOS 11 (Big Sur) or later
- Xcode Command Line Tools (`xcode-select --install`) — provides the Swift
  compiler. Full Xcode is **not** required.

## Install

Clone the repo and run the installer. It builds the universal binary, installs
it to `/usr/local/bin`, sets up a login agent, and prints the one-time
permission steps:

```bash
git clone <your-repo-url> mac-touch-driver
cd mac-touch-driver
chmod +x scripts/*.sh
./scripts/install.sh
```

Then grant **Input Monitoring** and **Accessibility** to `touchdriver` once (the
installer prints the exact commands). That's it — it auto-detects the
touchscreen and starts at every login.

The installer puts `touchdriver.app` (a background app, bundle id
`com.eriproject.touchdriver`) in `/Applications`, symlinks the CLI to
`/usr/local/bin/touchdriver` for `--setup` / `--list-*`, and registers the
login agent.

To remove it:

```bash
./scripts/uninstall.sh          # remove app + agent + CLI link, revoke permissions
./scripts/uninstall.sh --purge  # also delete saved config (~/.config/touchdriver)
```

Because it's a proper app bundle, `uninstall.sh` revokes the Input Monitoring /
Accessibility permissions automatically via `tccutil reset … com.eriproject.touchdriver`.

### Manual build (optional)

```bash
./scripts/build-universal.sh    # -> build/touchdriver (universal, ad-hoc signed)
```

This uses `swiftc` + `lipo`, so only the Command Line Tools are needed — full
Xcode is not. For a quick current-arch build via SwiftPM:

```bash
swift build -c release
.build/release/touchdriver --help
```

## Permissions (required)

The driver needs two macOS privacy permissions. They are granted to the app
that *launches* the binary:

1. **Input Monitoring** — to read the touchscreen.
2. **Accessibility** — to move the cursor and synthesize clicks.

On first launch the app **requests both permissions automatically** — a system
prompt appears, and it registers the launching app (e.g. **Terminal**, or the
`touchdriver` binary if run as a LaunchAgent) in these lists:

- System Settings → Privacy & Security → **Input Monitoring**
- System Settings → Privacy & Security → **Accessibility**

Approve the prompts (or enable the entry in **both** lists), then run again —
macOS only applies a new grant on a fresh start.

## Usage

Just run it — it auto-detects the touchscreen display:

```bash
touchdriver
```

Touch the screen and the cursor jumps to your finger and clicks/drags there.
Press **Ctrl+C** to stop.

**Auto-detection** picks the largest external (non-main) display. If that's the
wrong screen, lock the correct one once and it's remembered:

```bash
touchdriver --setup        # lists displays, asks you to pick one, saves it
```

Your choice is stored in `~/.config/touchdriver/config.json` and reused on every
run — no flags needed afterwards. Matching is by display vendor/model, so it
survives reboots, re-arrangement, and unplug/replug.

To inspect or pin things manually:

```bash
touchdriver --list-devices     # confirm the touchscreen is detected
touchdriver --list-displays    # see display indices/vendor/model
touchdriver --display-index 1  # one-off override (also remembered)
```

### Options

| Option | Description |
| --- | --- |
| *(none)* | Auto-detect the touchscreen display, or use your saved `--setup` choice |
| `--no-gestures` | Single-finger pointer only (disable multi-finger gestures) |
| `--setup` | Interactively pick & remember the touchscreen display |
| `--list-displays` | List displays (marks the configured touchscreen) plus detected touch devices and their max finger count, then exit |
| `--list-devices` | List HID devices (find your touchscreen), then exit |
| `--inspect` | Dump a touchscreen's HID capabilities (multi-touch, contacts), then exit |
| `--display-index N` | Map touch to the display at index `N` (also remembered) |
| `--display-vendor V` | Match the target display by vendor number (also remembered) |
| `--display-model M` | Match the target display by model number |
| `--vendor-id 0xVVVV` | Match a specific touch device (default: any touchscreen) |
| `--product-id 0xPPPP` | Match a specific touch device |
| `--debug` | Log raw HID page/usage/value (useful for diagnosing other panels) |
| `-h`, `--help` | Show help |

> **Note on permissions and rebuilds:** the app bundle is ad-hoc code-signed
> with the stable identifier `com.eriproject.touchdriver`. Because rebuilding
> changes the binary's code hash, macOS may ask you to re-grant **Input
> Monitoring** / **Accessibility** after a rebuild. The driver only prompts for
> Accessibility when it isn't already granted — it won't nag you on every run
> once permission is in place, and `uninstall.sh` revokes both via `tccutil`.

## Run automatically at login

`./scripts/install.sh` already sets up a per-user LaunchAgent
(`~/Library/LaunchAgents/com.touchdriver.agent.plist`) with `RunAtLoad` and
`KeepAlive`, so the driver starts at login and restarts itself if it stops.

If auto-detection picks the wrong screen, lock the right one once:

```bash
touchdriver --setup
```

To stop/remove it, use `./scripts/uninstall.sh` (see **Install** above).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `IOHIDManagerOpen failed` | Grant **Input Monitoring** to the launching app, then re-run. |
| Cursor doesn't move / no clicks | `Accessibility trusted: false` — grant **Accessibility**, then re-run. |
| `--list-devices` shows nothing | Plug in the touchscreen's **USB data cable** (separate from the video cable). Grant Input Monitoring. |
| Touch lands on the wrong screen | Use `--list-displays` and pass the correct `--display-index`. |
| Touch is slightly offset | Your panel may report a non-standard coordinate range; open an issue with your `--list-devices` output. |

## How it works

1. `IOHIDManager` matches the touchscreen (a HID *digitizer*, usage page `0x0D`,
   usage `0x04`) or an explicit vendor/product you pass.
2. For each input report it reads the absolute **X** / **Y** (normalised using
   the element's logical min/max) and the **Tip Switch** (finger down/up).
3. It maps the normalised coordinates onto the chosen display's bounds and uses
   `CGWarpMouseCursorPosition` + `CGEvent` to move the cursor and post
   `leftMouseDown` / `leftMouseDragged` / `leftMouseUp`.
4. A display-reconfiguration callback refreshes the target bounds when you
   rearrange or hot-plug displays.

## License

Currently private. A license will be added if/when this is made public.
