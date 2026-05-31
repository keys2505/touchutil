//
//  touchutil — Map an external USB touchscreen to its display on macOS.
//
//  macOS does not natively route absolute touch input from external USB
//  touchscreens to the correct display. This tool reads the digitizer's
//  single-finger reports via IOHIDManager and:
//    • 1 finger      → move cursor, tap-to-click, drag
//    • double-tap    → double-click
//    • long-press    → right-click
//    • edge swipe    → Spaces / Mission Control / App Exposé (via shortcuts)
//
//  This is single-pointer touch only. Multi-touch would require a DriverKit HID
//  driver (paid Apple Developer account to sign/notarize). IOHIDManager is the
//  free, userspace alternative — the trade-off is single-finger only.
//
//  Works on Apple Silicon and Intel. No kernel extension, no SIP changes.
//
//  Requires (granted to the app, or to the launching Terminal). The app
//  requests both automatically on launch (and registers itself in each list):
//    • Input Monitoring   — to read the touchscreen
//    • Accessibility      — to move the cursor and synthesize input
//

import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

// MARK: - Config

struct Config {
    var vendorID: Int?
    var productID: Int?
    var displayIndex: Int?
    var displayVendor: UInt32?
    var displayModel: UInt32?
    var gestures = true
    var debug = false
    var debugLog = false    // write debug output to /tmp/touchutil.debug.log instead of stderr
}

struct SavedConfig: Codable {
    var displayVendor: UInt32
    var displayModel: UInt32
}

func configURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/touchutil/config.json")
}

func loadSavedConfig() -> SavedConfig? {
    guard let data = try? Data(contentsOf: configURL()) else { return nil }
    return try? JSONDecoder().decode(SavedConfig.self, from: data)
}

func saveConfig(_ c: SavedConfig) {
    let url = configURL()
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(c) { try? data.write(to: url) }
}

// MARK: - Helpers

let debugLogURL = URL(fileURLWithPath: "/tmp/touchutil.debug.log")
var debugLogHandle: FileHandle? = nil

func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func debugOut(_ s: String) {
    let line = s + "\n"
    if let h = debugLogHandle {
        h.write(line.data(using: .utf8)!)
    } else {
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displays, &count)
    return displays
}

// MARK: - List / inspect / setup modes

/// All connected touchscreen digitizers (usagePage 0x0D, usage 0x04).
func touchDevices() -> [IOHIDDevice] {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [
        kIOHIDDeviceUsagePageKey as String: 0x0D,
        kIOHIDDeviceUsageKey as String: 0x04,
    ] as CFDictionary)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    return (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>).map(Array.init) ?? []
}

func listDisplays() {
    let mainID = CGMainDisplayID()
    let saved = loadSavedConfig()
    let devices = touchDevices()
    let hasTouchHardware = !devices.isEmpty

    print("Active displays:")
    for (i, d) in activeDisplays().enumerated() {
        let b = CGDisplayBounds(d)
        let main = (d == mainID) ? "  [MAIN]" : ""
        // Touch column: mark the display configured as the touchscreen.
        var touch = "  touch: —"
        if let s = saved, CGDisplayVendorNumber(d) == s.displayVendor,
           CGDisplayModelNumber(d) == s.displayModel {
            touch = "  touch: ✓ configured"
        } else if hasTouchHardware {
            touch = "  touch: ? (run --setup to assign)"
        }
        print(String(format: "  [%d] id=%u  origin=(%d,%d)  size=%dx%d  vendor=%u  model=%u%@%@",
                     i, d, Int(b.origin.x), Int(b.origin.y),
                     Int(b.size.width), Int(b.size.height),
                     CGDisplayVendorNumber(d), CGDisplayModelNumber(d), main, touch))
    }

    print("\nDetected touchscreen devices:")
    if devices.isEmpty {
        print("  (none — no USB touchscreen detected, or Input Monitoring not granted)")
    } else {
        for dev in devices {
            let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
            let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? -1
            print(String(format: "  %@  vendor=0x%04X product=0x%04X", name, vid, pid))
        }
    }
    print("\nNote: macOS can't map a touch device to a specific display automatically;")
    print("use --setup to tell touchutil which display is the touchscreen.")
}

func listDevices() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, nil)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
        print("No HID devices found (Input Monitoring permission may be required)."); return
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

func inspectDevices() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, nil)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
        print("No HID devices (Input Monitoring may be required)."); return
    }
    for dev in set {
        let up = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
        guard up == 0x0D else { continue }
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        print("Device: \(name)")
        guard let elements = IOHIDDeviceCopyMatchingElements(dev, nil, 0) as? [IOHIDElement] else { continue }
        var seen = Set<String>()
        for e in elements {
            let p = IOHIDElementGetUsagePage(e), u = IOHIDElementGetUsage(e)
            let key = String(format: "0x%02X/0x%02X", p, u)
            if seen.insert(key).inserted {
                print(String(format: "  page=0x%02X usage=0x%02X  logical=[%d..%d]",
                             p, u, IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e)))
            }
        }
        print("")
    }
}

func runSetup() {
    listDisplays()
    print("\nEnter the index of the touchscreen display: ", terminator: "")
    guard let line = readLine(),
          let idx = Int(line.trimmingCharacters(in: .whitespaces)) else { err("Invalid input."); exit(1) }
    let displays = activeDisplays()
    guard idx >= 0, idx < displays.count else { err("Index out of range."); exit(1) }
    let d = displays[idx]
    let v = CGDisplayVendorNumber(d), m = CGDisplayModelNumber(d)
    saveConfig(SavedConfig(displayVendor: v, displayModel: m))
    print("Saved. Touchscreen display remembered (vendor=\(v) model=\(m)).")
}

// MARK: - Driver

final class TouchDriver {
    private let config: Config
    private var bounds: CGRect = .zero
    private let source = CGEventSource(stateID: .hidSystemState)
    private var manager: IOHIDManager!

    // Single-finger pointer state (Button 0x09/0x01 + GD X/Y "mouse collection").
    private var xLogicalMax = 4095.0
    private var yLogicalMax = 4095.0
    private var pNX = 0.0, pNY = 0.0
    private var pTip = false, pDown = false

    // Single-finger gesture recognizer state.
    private var fingerDown = false, mousePressed = false, movedBeyond = false
    private var edgeFired = false, longFired = false, edgeResolved = false
    private var nearL = false, nearR = false, nearT = false, nearB = false
    private var sStartPx = CGPoint.zero
    private var longTimer: Timer?
    private var lastTapTime = 0.0
    private var lastTapPx = CGPoint.zero
    private var lastClickCount = 0
    // Single-finger tunables.
    private let moveTol = 10.0
    private let longPressDelay = 0.5
    private let edgeMarginN = 0.05
    private let edgeSwipeThreshold = 100.0
    private let doubleTapInterval = 0.30
    private let doubleTapDist = 25.0

    init(config: Config) { self.config = config }

    // MARK: Display resolution

    private func resolveDisplay() -> CGRect {
        let displays = activeDisplays()
        let mainID = CGMainDisplayID()
        if let idx = config.displayIndex, idx >= 0, idx < displays.count {
            let d = displays[idx]
            saveConfig(SavedConfig(displayVendor: CGDisplayVendorNumber(d), displayModel: CGDisplayModelNumber(d)))
            return CGDisplayBounds(d)
        }
        if let v = config.displayVendor, let m = config.displayModel {
            for d in displays where CGDisplayVendorNumber(d) == v && CGDisplayModelNumber(d) == m {
                saveConfig(SavedConfig(displayVendor: v, displayModel: m)); return CGDisplayBounds(d)
            }
        }
        if let saved = loadSavedConfig() {
            for d in displays where CGDisplayVendorNumber(d) == saved.displayVendor
                && CGDisplayModelNumber(d) == saved.displayModel {
                err("Using saved touchscreen display (vendor=\(saved.displayVendor) model=\(saved.displayModel)).")
                return CGDisplayBounds(d)
            }
        }
        let externals = displays.filter { $0 != mainID }
        if let pick = externals.max(by: {
            let a = CGDisplayBounds($0).size, b = CGDisplayBounds($1).size
            return (a.width * a.height) < (b.width * b.height)
        }) {
            err("Auto-selected display vendor=\(CGDisplayVendorNumber(pick)) model=\(CGDisplayModelNumber(pick)). Use --setup to change.")
            return CGDisplayBounds(pick)
        }
        return CGDisplayBounds(mainID)
    }

    // MARK: Event synthesis

    private func screenPoint(_ n: CGPoint) -> CGPoint {
        CGPoint(x: bounds.origin.x + n.x * bounds.size.width,
                y: bounds.origin.y + n.y * bounds.size.height)
    }

    private func postMouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left) {
        CGWarpMouseCursorPosition(p)
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    private func postKey(_ key: CGKeyCode, control: Bool) {
        let d = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let u = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        if control { d?.flags = .maskControl; u?.flags = .maskControl }
        d?.post(tap: .cghidEventTap)
        u?.post(tap: .cghidEventTap)
    }

    // MARK: HID element setup

    /// Find the logical max for the General Desktop X / Y axes so we can
    /// normalize the panel's absolute coordinates to 0..1.
    private func setupElements(_ dev: IOHIDDevice) {
        guard let elements = IOHIDDeviceCopyMatchingElements(dev, nil, 0) as? [IOHIDElement] else { return }
        for e in elements {
            let p = IOHIDElementGetUsagePage(e), u = IOHIDElementGetUsage(e)
            if p == 0x01 && u == 0x30 { xLogicalMax = max(xLogicalMax, Double(IOHIDElementGetLogicalMax(e))) }
            else if p == 0x01 && u == 0x31 { yLogicalMax = max(yLogicalMax, Double(IOHIDElementGetLogicalMax(e))) }
        }
        err("Touch input mapped (gestures \(config.gestures ? "ON" : "OFF")).")
    }

    // MARK: Per-value input

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let v = IOHIDValueGetIntegerValue(value)

        if config.debug {
            debugOut(String(format: "page=0x%02X usage=0x%02X val=%d", page, usage, v))
        }

        var tipChanged = false
        switch (page, usage) {
        case (0x01, 0x30): pNX = Double(v) / xLogicalMax
        case (0x01, 0x31): pNY = Double(v) / yLogicalMax
        case (0x09, 0x01): let t = (v != 0); tipChanged = (t != pTip); pTip = t
        default: return
        }
        if !config.gestures { simplePrimary(); return }
        if tipChanged { pTip ? gestureDown() : gestureUp() }
        else if fingerDown { gestureMove() }
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Plain pointer (used with --no-gestures): press on touch, drag, release.
    private func simplePrimary() {
        let p = screenPoint(CGPoint(x: pNX, y: pNY))
        if pTip && !pDown { pDown = true; postMouse(.leftMouseDown, p) }
        else if pTip && pDown { postMouse(.leftMouseDragged, p) }
        else if !pTip && pDown { pDown = false; postMouse(.leftMouseUp, p) }
    }

    /// Click (or multi-click) with a proper click-state so double-tap → double-click.
    private func postClick(_ p: CGPoint, _ button: CGMouseButton, _ count: Int) {
        CGWarpMouseCursorPosition(p)
        let down: CGEventType = (button == .right) ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = (button == .right) ? .rightMouseUp : .leftMouseUp
        if let d = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: p, mouseButton: button) {
            d.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, count))); d.post(tap: .cghidEventTap)
        }
        if let u = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: p, mouseButton: button) {
            u.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, count))); u.post(tap: .cghidEventTap)
        }
    }

    private func startLongTimer() {
        cancelLongTimer()
        let t = Timer(timeInterval: longPressDelay, repeats: false) { [weak self] _ in self?.longPressFired() }
        RunLoop.current.add(t, forMode: .common)
        longTimer = t
    }
    private func cancelLongTimer() { longTimer?.invalidate(); longTimer = nil }

    private func longPressFired() {
        guard fingerDown, !movedBeyond, !edgeFired, !longFired else { return }
        longFired = true
        postClick(sStartPx, .right, 1)   // long-press → right-click
    }

    private func gestureDown() {
        fingerDown = true; mousePressed = false; movedBeyond = false
        edgeFired = false; longFired = false
        sStartPx = screenPoint(CGPoint(x: pNX, y: pNY))
        let m = edgeMarginN
        nearL = pNX < m; nearR = pNX > 1 - m; nearT = pNY < m; nearB = pNY > 1 - m
        edgeResolved = !(nearL || nearR || nearT || nearB)
        CGWarpMouseCursorPosition(sStartPx)
        startLongTimer()
    }

    private func gestureMove() {
        let cur = screenPoint(CGPoint(x: pNX, y: pNY))
        CGWarpMouseCursorPosition(cur)
        let dist = hypot(cur.x - sStartPx.x, cur.y - sStartPx.y)
        if dist <= moveTol { return }
        if !movedBeyond { movedBeyond = true; cancelLongTimer() }
        if edgeFired { return }
        if !edgeResolved {
            if dist < edgeSwipeThreshold { return }   // wait until clearly a swipe
            let dx = cur.x - sStartPx.x, dy = cur.y - sStartPx.y
            var fired = false
            if nearL && dx > abs(dy) { postKey(0x7B, control: true); fired = true }       // left edge → prev Space
            else if nearR && -dx > abs(dy) { postKey(0x7C, control: true); fired = true } // right edge → next Space
            else if nearT && dy > abs(dx) { postKey(0x7E, control: true); fired = true }  // top edge → Mission Control
            else if nearB && -dy > abs(dx) { postKey(0x7D, control: true); fired = true } // bottom edge → App Exposé
            if fired { edgeFired = true; return }
            edgeResolved = true   // not an inward edge swipe → treat as a drag
        }
        if !mousePressed { mousePressed = true; postMouse(.leftMouseDown, sStartPx) }
        postMouse(.leftMouseDragged, cur)
    }

    private func gestureUp() {
        fingerDown = false; cancelLongTimer()
        let cur = screenPoint(CGPoint(x: pNX, y: pNY))
        if mousePressed { postMouse(.leftMouseUp, cur); mousePressed = false; return }
        if edgeFired || longFired { return }   // gesture already acted
        // Tap → click, with double-tap → double-click.
        let t = now()
        var count = 1
        if t - lastTapTime < doubleTapInterval,
           hypot(cur.x - lastTapPx.x, cur.y - lastTapPx.y) < doubleTapDist {
            count = min(lastClickCount + 1, 3)
        }
        postClick(cur, .left, count)
        lastTapTime = t; lastTapPx = cur; lastClickCount = count
    }

    // MARK: Run loop

    private func ensureAccessibility() {
        if AXIsProcessTrusted() { err("Accessibility: granted."); return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        err("Accessibility: NOT granted. Enable this app under System Settings > Privacy & Security > Accessibility, then re-run.")
    }

    /// Ask macOS for Input Monitoring. IOHIDRequestAccess surfaces the system
    /// prompt (and registers the app in the Input Monitoring list) the first
    /// time; afterwards it just reports the current grant state.
    private func ensureInputMonitoring() {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            err("Input Monitoring: granted.")
        case kIOHIDAccessTypeDenied:
            err("Input Monitoring: DENIED. Enable this app under System Settings > Privacy & Security > Input Monitoring, then re-run.")
        default:
            // Unknown / not yet decided — prompt the user.
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            err("Input Monitoring: \(granted ? "granted." : "NOT granted — approve the prompt (or enable under System Settings > Privacy & Security > Input Monitoring), then re-run.")")
        }
    }

    func run() {
        ensureInputMonitoring()
        ensureAccessibility()
        bounds = resolveDisplay()
        err("Targeting display: origin=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y))) size=\(Int(bounds.size.width))x\(Int(bounds.size.height))")

        CGDisplayRegisterReconfigurationCallback({ _, _, ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(ctx).takeUnretainedValue()
            me.bounds = me.resolveDisplay()
        }, Unmanaged.passUnretained(self).toOpaque())

        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any]
        if let vid = config.vendorID, let pid = config.productID {
            match = [kIOHIDVendorIDKey as String: vid, kIOHIDProductIDKey as String: pid]
        } else {
            match = [kIOHIDDeviceUsagePageKey as String: 0x0D, kIOHIDDeviceUsageKey as String: 0x04]
        }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            err("ERROR: IOHIDManagerOpen failed (0x\(String(r, radix: 16))).")
            err("--> Grant Input Monitoring under System Settings > Privacy & Security > Input Monitoring.")
            exit(1)
        }

        // Map elements from the matching device, and re-do it whenever the
        // touchscreen is (re)connected.
        if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = set.first {
            setupElements(dev)
        } else {
            err("WARNING: no matching device to map elements from.")
        }
        let devCb: IOHIDDeviceCallback = { ctx, _, _, dev in
            guard let ctx = ctx else { return }
            let me = Unmanaged<TouchDriver>.fromOpaque(ctx).takeUnretainedValue()
            me.setupElements(dev)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, devCb, Unmanaged.passUnretained(self).toOpaque())

        let cb: IOHIDValueCallback = { ctx, _, _, value in
            guard let ctx = ctx else { return }
            Unmanaged<TouchDriver>.fromOpaque(ctx).takeUnretainedValue().handle(value: value)
        }
        IOHIDManagerRegisterInputValueCallback(manager, cb, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        err("Touch driver running. Press Ctrl+C to stop.")
        CFRunLoopRun()
    }
}

// MARK: - Argument parsing

let version = "1.0.0"

func printUsage() {
    print("""
    touchutil — map a USB touchscreen to its display on macOS

    USAGE:
      touchutil [options]

    With no options it auto-detects the touchscreen display (or uses your saved
    --setup choice) and enables single-finger gestures.

    Single-finger gestures (work on any panel):
      • move / tap        → cursor + click
      • double-tap        → double-click
      • long-press (~0.5s)→ right-click
      • drag              → move windows / select
      • edge swipe inward → left:prev Space  right:next Space
                            top:Mission Control  bottom:App Exposé

    OPTIONS:
      --no-gestures              Plain pointer only (no tap/long-press/edge gestures)
      --setup                    Interactively pick & remember the touchscreen display
      --list-displays            List displays, then exit
      --list-devices             List HID devices, then exit
      --inspect                  Show a touchscreen's HID capabilities, then exit
      --display-index N          Map touch to display at index N (remembered)
      --display-vendor V         Match target display by vendor number (remembered)
      --display-model M          Match target display by model number
      --vendor-id  0xVVVV        Match a specific touch device
      --product-id 0xPPPP        Match a specific touch device
      --debug                    Log raw HID page/usage/value to stderr
      --debug-log                Log raw HID page/usage/value to /tmp/touchutil.debug.log
      --version                  Print version and exit
      -h, --help                 Show this help
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
    case "--version": print("touchutil \(version)"); exit(0)
    case "--setup": runSetup(); exit(0)
    case "--list-displays": listDisplays(); exit(0)
    case "--list-devices": listDevices(); exit(0)
    case "--inspect": inspectDevices(); exit(0)
    case "--no-gestures": config.gestures = false
    case "--display-index":
        i += 1
        guard i < args.count, let v = parseInt(args[i]) else { err("--display-index requires a value"); exit(2) }
        config.displayIndex = v
    case "--display-vendor":
        i += 1
        guard i < args.count, let v = parseInt(args[i]) else { err("--display-vendor requires a value"); exit(2) }
        config.displayVendor = UInt32(v)
    case "--display-model":
        i += 1
        guard i < args.count, let v = parseInt(args[i]) else { err("--display-model requires a value"); exit(2) }
        config.displayModel = UInt32(v)
    case "--vendor-id":
        i += 1
        guard i < args.count, let v = parseInt(args[i]) else { err("--vendor-id requires a value"); exit(2) }
        config.vendorID = v
    case "--product-id":
        i += 1
        guard i < args.count, let v = parseInt(args[i]) else { err("--product-id requires a value"); exit(2) }
        config.productID = v
    case "--debug": config.debug = true
    case "--debug-log":
        config.debug = true
        config.debugLog = true
        FileManager.default.createFile(atPath: debugLogURL.path, contents: nil)
        debugLogHandle = try? FileHandle(forWritingTo: debugLogURL)
        debugLogHandle?.seekToEndOfFile()
    default:
        err("Unknown option: \(a)"); printUsage(); exit(2)
    }
    i += 1
}

TouchDriver(config: config).run()
