//
//  touchdriver — Map an external USB touchscreen to its display on macOS.
//
//  macOS does not natively route absolute touch input from external USB
//  touchscreens to the correct display — it treats them like a mouse and
//  clicks wherever the system cursor happens to be. This tool reads the
//  digitizer's absolute X/Y via IOHIDManager and warps/clicks the cursor on
//  the chosen display, giving proper "touch where you tap" behaviour.
//
//  Works on Apple Silicon and Intel. No kernel extension, no SIP changes.
//
//  Requires (granted to the launching app, e.g. Terminal, or to this binary
//  if run as a LaunchAgent):
//    • Input Monitoring   — to read the touchscreen
//    • Accessibility      — to move the cursor and synthesize clicks
//

import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

// MARK: - Config

struct Config {
    var vendorID: Int?          // optional explicit device match
    var productID: Int?
    var displayIndex: Int?      // index into active display list
    var displayVendor: UInt32?  // match display by vendor number
    var displayModel: UInt32?   // match display by model number
    var debug = false
}

/// Persisted choice so the touchscreen display is remembered across runs.
struct SavedConfig: Codable {
    var displayVendor: UInt32
    var displayModel: UInt32
}

func configURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/touchdriver/config.json")
}

func loadSavedConfig() -> SavedConfig? {
    guard let data = try? Data(contentsOf: configURL()) else { return nil }
    return try? JSONDecoder().decode(SavedConfig.self, from: data)
}

func saveConfig(_ c: SavedConfig) {
    let url = configURL()
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(c) {
        try? data.write(to: url)
    }
}

// MARK: - Helpers

func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displays, &count)
    return displays
}

// MARK: - List / setup modes

func listDisplays() {
    let mainID = CGMainDisplayID()
    print("Active displays:")
    for (i, d) in activeDisplays().enumerated() {
        let b = CGDisplayBounds(d)
        let main = (d == mainID) ? "  [MAIN]" : ""
        print(String(format: "  [%d] id=%u  origin=(%d,%d)  size=%dx%d  vendor=%u  model=%u%@",
                     i, d, Int(b.origin.x), Int(b.origin.y),
                     Int(b.size.width), Int(b.size.height),
                     CGDisplayVendorNumber(d), CGDisplayModelNumber(d), main))
    }
}

func listDevices() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, nil)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
        print("No HID devices found (Input Monitoring permission may be required).")
        return
    }
    print("HID devices (touchscreens are usagePage=13 / usage=4):")
    for dev in set {
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? -1
        let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? -1
        let up = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
        let u  = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
        let touch = (up == 0x0D) ? "  <-- digitizer/touch" : ""
        print(String(format: "  %@  vendor=0x%04X product=0x%04X  usagePage=%d usage=%d%@",
                     name, vid, pid, up, u, touch))
    }
}

func runSetup() {
    listDisplays()
    print("\nEnter the index of the touchscreen display: ", terminator: "")
    guard let line = readLine(),
          let idx = Int(line.trimmingCharacters(in: .whitespaces)) else {
        err("Invalid input."); exit(1)
    }
    let displays = activeDisplays()
    guard idx >= 0, idx < displays.count else {
        err("Index out of range."); exit(1)
    }
    let d = displays[idx]
    let v = CGDisplayVendorNumber(d), m = CGDisplayModelNumber(d)
    saveConfig(SavedConfig(displayVendor: v, displayModel: m))
    print("Saved. Touchscreen display remembered (vendor=\(v) model=\(m)).")
    print("Run `touchdriver` with no arguments from now on.")
}

// MARK: - Driver

final class TouchDriver {
    private let config: Config
    private var bounds: CGRect = .zero
    private var touching = false
    private var normX: Double = 0
    private var normY: Double = 0
    private let source = CGEventSource(stateID: .hidSystemState)
    private var manager: IOHIDManager!

    init(config: Config) {
        self.config = config
    }

    /// Decide which display the touchscreen maps to.
    /// Priority: explicit flags > saved config > auto-pick (largest external).
    private func resolveDisplay() -> CGRect {
        let displays = activeDisplays()
        let mainID = CGMainDisplayID()

        // 1. Explicit display index (and remember it).
        if let idx = config.displayIndex, idx >= 0, idx < displays.count {
            let d = displays[idx]
            saveConfig(SavedConfig(displayVendor: CGDisplayVendorNumber(d),
                                   displayModel: CGDisplayModelNumber(d)))
            return CGDisplayBounds(d)
        }

        // 2. Explicit vendor/model (and remember it).
        if let v = config.displayVendor, let m = config.displayModel {
            for d in displays where CGDisplayVendorNumber(d) == v && CGDisplayModelNumber(d) == m {
                saveConfig(SavedConfig(displayVendor: v, displayModel: m))
                return CGDisplayBounds(d)
            }
        }

        // 3. Previously saved choice.
        if let saved = loadSavedConfig() {
            for d in displays where CGDisplayVendorNumber(d) == saved.displayVendor
                && CGDisplayModelNumber(d) == saved.displayModel {
                err("Using saved touchscreen display (vendor=\(saved.displayVendor) model=\(saved.displayModel)).")
                return CGDisplayBounds(d)
            }
        }

        // 4. Auto-pick: the largest external (non-main) display.
        let externals = displays.filter { $0 != mainID }
        if let pick = externals.max(by: {
            let a = CGDisplayBounds($0).size, b = CGDisplayBounds($1).size
            return (a.width * a.height) < (b.width * b.height)
        }) {
            err("Auto-selected touchscreen display vendor=\(CGDisplayVendorNumber(pick)) model=\(CGDisplayModelNumber(pick)). Use --setup to lock a specific one.")
            return CGDisplayBounds(pick)
        }

        // 5. Last resort: main display.
        return CGDisplayBounds(mainID)
    }

    private func point() -> CGPoint {
        CGPoint(x: bounds.origin.x + CGFloat(normX) * bounds.size.width,
                y: bounds.origin.y + CGFloat(normY) * bounds.size.height)
    }

    private func post(_ type: CGEventType, _ p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGEvent(mouseEventSource: source, mouseType: type,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usage = IOHIDElementGetUsage(element)
        let page = IOHIDElementGetUsagePage(element)
        let v = IOHIDValueGetIntegerValue(value)

        if config.debug {
            err(String(format: "HID page=0x%02X usage=0x%02X value=%d", page, usage, v))
        }

        // X (0x30) / Y (0x31) on Generic Desktop (0x01) or Digitizer (0x0D)
        if usage == 0x30 && (page == 0x01 || page == 0x0D) {
            let lo = IOHIDElementGetLogicalMin(element)
            let hi = IOHIDElementGetLogicalMax(element)
            if hi > lo { normX = Double(v - lo) / Double(hi - lo) }
            if touching { post(.leftMouseDragged, point()) }
        } else if usage == 0x31 && (page == 0x01 || page == 0x0D) {
            let lo = IOHIDElementGetLogicalMin(element)
            let hi = IOHIDElementGetLogicalMax(element)
            if hi > lo { normY = Double(v - lo) / Double(hi - lo) }
            if touching { post(.leftMouseDragged, point()) }
        } else if (usage == 0x42 && page == 0x0D)   // Digitizer Tip Switch
                || (usage == 0x01 && page == 0x09) { // Button 1 (some SiS panels)
            if v == 1 && !touching {
                touching = true
                post(.leftMouseDown, point())
            } else if v == 0 && touching {
                touching = false
                post(.leftMouseUp, point())
            }
        }
    }

    /// Prompt for Accessibility only if it has not already been granted.
    private func ensureAccessibility() {
        if AXIsProcessTrusted() {
            err("Accessibility: granted.")
            return
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        err("Accessibility: NOT granted. Enable this app under System Settings > Privacy & Security > Accessibility, then re-run. (This prompt only appears until you grant it.)")
    }

    func run() {
        ensureAccessibility()

        bounds = resolveDisplay()
        err("Targeting display: origin=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y))) size=\(Int(bounds.size.width))x\(Int(bounds.size.height))")

        // Refresh target bounds when displays change (hot-plug / rearrange).
        CGDisplayRegisterReconfigurationCallback({ _, _, ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(ctx).takeUnretainedValue()
            me.bounds = me.resolveDisplay()
        }, Unmanaged.passUnretained(self).toOpaque())

        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match an explicit device, or any touchscreen digitizer.
        let match: [String: Any]
        if let vid = config.vendorID, let pid = config.productID {
            match = [kIOHIDVendorIDKey as String: vid, kIOHIDProductIDKey as String: pid]
        } else {
            match = [kIOHIDDeviceUsagePageKey as String: 0x0D,  // Digitizer
                     kIOHIDDeviceUsageKey as String: 0x04]      // Touch Screen
        }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let cb: IOHIDValueCallback = { ctx, _, _, value in
            guard let ctx = ctx else { return }
            Unmanaged<TouchDriver>.fromOpaque(ctx).takeUnretainedValue().handle(value: value)
        }
        IOHIDManagerRegisterInputValueCallback(manager, cb, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            err("ERROR: IOHIDManagerOpen failed (0x\(String(r, radix: 16))).")
            err("--> Grant Input Monitoring to this app under System Settings > Privacy & Security > Input Monitoring.")
            exit(1)
        }

        err("Touch driver running. Touch the screen. Press Ctrl+C to stop.")
        CFRunLoopRun()
    }
}

// MARK: - Argument parsing

func printUsage() {
    print("""
    touchdriver — map a USB touchscreen to its display on macOS

    USAGE:
      touchdriver [options]

    With no options it auto-detects the touchscreen display (or uses your saved
    choice from --setup). Run --setup once if auto-detection picks the wrong screen.

    OPTIONS:
      --setup                    Interactively pick & remember the touchscreen display
      --list-displays            List displays with index/vendor/model, then exit
      --list-devices             List HID devices (find your touchscreen), then exit
      --display-index N          Map touch to display at index N (also remembered)
      --display-vendor V         Match target display by vendor number (also remembered)
      --display-model M          Match target display by model number
      --vendor-id  0xVVVV        Match a specific touch device (default: any touchscreen)
      --product-id 0xPPPP        Match a specific touch device
      --debug                    Log raw HID page/usage/value (for diagnosing panels)
      -h, --help                 Show this help

    EXAMPLES:
      touchdriver                       # auto-detect / use saved choice
      touchdriver --setup               # pick and remember the touchscreen display
      touchdriver --list-displays
    """)
}

func parseInt(_ s: String) -> Int? {
    if s.hasPrefix("0x") || s.hasPrefix("0X") { return Int(s.dropFirst(2), radix: 16) }
    return Int(s)
}

var config = Config()
let args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help": printUsage(); exit(0)
    case "--setup": runSetup(); exit(0)
    case "--list-displays": listDisplays(); exit(0)
    case "--list-devices": listDevices(); exit(0)
    case "--display-index": i += 1; config.displayIndex = parseInt(args[i])
    case "--display-vendor": i += 1; config.displayVendor = parseInt(args[i]).map { UInt32($0) }
    case "--display-model": i += 1; config.displayModel = parseInt(args[i]).map { UInt32($0) }
    case "--vendor-id": i += 1; config.vendorID = parseInt(args[i])
    case "--product-id": i += 1; config.productID = parseInt(args[i])
    case "--debug": config.debug = true
    default:
        err("Unknown option: \(a)")
        printUsage(); exit(2)
    }
    i += 1
}

TouchDriver(config: config).run()
