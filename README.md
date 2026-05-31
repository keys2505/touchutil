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

## Build

Clone the repo, then build a universal binary:

```bash
git clone <your-repo-url> mac-touch-driver
cd mac-touch-driver
chmod +x scripts/*.sh
./scripts/build-universal.sh
```

This produces `build/touchdriver` (a universal binary). It uses `swiftc` +
`lipo`, so only the Command Line Tools are needed — full Xcode is not.

Install the binary system-wide:

```bash
sudo cp build/touchdriver /usr/local/bin/touchdriver
```

Or, for a quick local (current-arch only) build:

```bash
swift build -c release
.build/release/touchdriver --help
```

## Permissions (required)

The driver needs two macOS privacy permissions. They are granted to the app
that *launches* the binary:

1. **Input Monitoring** — to read the touchscreen.
2. **Accessibility** — to move the cursor and synthesize clicks.

The first time you run it, macOS adds the launching app (e.g. **Terminal**, or
the `touchdriver` binary if run as a LaunchAgent) to these lists:

- System Settings → Privacy & Security → **Input Monitoring**
- System Settings → Privacy & Security → **Accessibility**

Enable the entry in **both** lists, then run again.

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
| `--setup` | Interactively pick & remember the touchscreen display |
| `--list-displays` | List displays with index, vendor and model, then exit |
| `--list-devices` | List HID devices (find your touchscreen), then exit |
| `--display-index N` | Map touch to the display at index `N` (also remembered) |
| `--display-vendor V` | Match the target display by vendor number (also remembered) |
| `--display-model M` | Match the target display by model number |
| `--vendor-id 0xVVVV` | Match a specific touch device (default: any touchscreen) |
| `--product-id 0xPPPP` | Match a specific touch device |
| `--debug` | Log raw HID page/usage/value (useful for diagnosing other panels) |
| `-h`, `--help` | Show help |

> **Note on permissions and rebuilds:** the binary is ad-hoc code-signed during
> the build. Because rebuilding changes the binary, macOS may ask you to
> re-grant **Input Monitoring** / **Accessibility** after a rebuild. The driver
> only prompts for Accessibility when it isn't already granted — it won't nag
> you on every run once permission is in place.

## Run automatically at login

Install a per-user LaunchAgent (pass the same options you use when running
manually):

```bash
./scripts/install-launch-agent.sh --display-index 1
```

The binary appears in the Input Monitoring / Accessibility lists the first time
the agent runs — enable it in both, then it persists across reboots.

To remove the agent:

```bash
launchctl unload ~/Library/LaunchAgents/com.touchdriver.agent.plist
rm ~/Library/LaunchAgents/com.touchdriver.agent.plist
```

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
