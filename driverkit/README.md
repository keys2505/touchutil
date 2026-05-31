# TouchDriverKit — DriverKit multi-touch extension (scaffold)

This is an **early scaffold** of a DriverKit HID extension (`.dext`) that aims to
unlock *real* multi-touch for the SiS HID Touch Controller (VID `0x0457`,
PID `0x0819`) on macOS.

## Why this exists

The user-space `touchdriver` tool (in the repo root) works well for
single-pointer touch, but it **cannot** get multi-touch from this panel. We
proved why empirically:

- The panel's HID descriptor advertises **6 contacts** with a full digitizer
  (Tip Switch, Contact ID, Contact Count) — see `touchdriver --inspect`.
- But at runtime macOS binds the device as a **single-pointer mouse** and only
  ever delivers the mouse collection (`page=0x01` X/Y + `page=0x09` button).
- Sending the Windows-style "Device Mode" feature switch from user space is
  *accepted* by the firmware (`feature 0x52=3: ok`) but macOS still delivers
  only the mouse report — the system HID driver owns the device first.

A DriverKit extension is the only supported way to **claim the device below the
default binding**, switch it to multi-touch mode, and present the per-contact
digitizer events to macOS.

## ⚠️ Hard prerequisites (you don't have these yet)

This scaffold **cannot be built or run** in the current environment. To make
progress you need:

1. **Full Xcode** (not just Command Line Tools). The DriverKit SDK and the
   System Extension build/embed flow only exist in Xcode.
   - `xcode-select -p` currently points at `/Library/Developer/CommandLineTools`.
2. **Apple Developer Program membership** ($99/yr).
3. **Apple-approved entitlements** — `com.apple.developer.driverkit.transport.hid`
   and friends are *managed* entitlements. You must request them:
   https://developer.apple.com/contact/request/system-extension/
   A normal provisioning profile cannot self-assign them.
4. A **host app** that embeds the dext and activates it via the
   `SystemExtensions` framework (`OSSystemExtensionRequest`). A dext is not
   installed directly; it ships inside an app bundle's
   `Contents/Library/SystemExtensions/`.

For **development before entitlement approval**, you can test locally with:
```bash
systemextensionsctl developer on
# and SIP adjusted for driver development (csrutil) on a test machine
```

## What's in this scaffold

| File | Purpose |
|------|---------|
| `TouchDriverKit/TouchDriverKit.iig` | DriverKit interface (compiled by `iig`) — subclasses `IOUserHIDEventService` |
| `TouchDriverKit/TouchDriverKit.cpp` | Implementation skeleton — `Start`/`Stop`, `enableMultitouchMode()`, `handleReport()` |
| `TouchDriverKit/Info.plist` | `IOKitPersonalities` matching VID `0x0457` / PID `0x0819` with a high probe score |
| `TouchDriverKit/TouchDriverKit.entitlements` | The managed DriverKit/HID entitlements to request from Apple |

## Two TODOs that carry the real work

1. **`enableMultitouchMode()`** — build and send the Device Mode feature report
   (usage `0x0D/0x52` = 3) via `setReport()`. Confirm the real report ID/length
   from the feature descriptor.
2. **`handleReport()`** — parse multi-touch contacts from the input report and
   dispatch one digitizer event per contact so macOS routes it as multi-touch.
   Expected per-contact fields (from `--inspect`):
   - Tip Switch `0x0D/0x42`, Contact ID `0x0D/0x51`,
     X `0x01/0x30` (0..4095), Y `0x01/0x31` (0..4095), ContactCount `0x0D/0x54`.

## Suggested next steps

1. Install full Xcode; confirm `xcodebuild -showsdks | grep DriverKit`.
2. Create an Xcode project: a macOS host app + a **Driver Extension** target.
   Drop these source files into the extension target.
3. Request the DriverKit HID transport entitlement from Apple.
4. With `systemextensionsctl developer on`, activate the dext from the host app
   and watch `log stream --predicate 'sender == "TouchDriverKit"'`.
5. Fill in `handleReport()` once you can see real multi-touch reports arriving.

## Reality check

This is a substantial, multi-week effort gated on Apple approvals and a test
machine you're willing to modify SIP on. The single-pointer `touchdriver`
(v1.0.0) remains the practical, shippable tool. Treat this directory as the
research track toward true multi-touch.
