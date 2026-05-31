//
//  touchdriver — Map an external USB touchscreen to its display on macOS,
//  with trackpad-style multi-touch gestures.
//
//  macOS does not natively route absolute touch input from external USB
//  touchscreens to the correct display, and it cannot inject real multi-touch
//  gestures. This tool reads the digitizer's raw multi-touch contacts via
//  IOHIDManager and:
//    • 1 finger      → move cursor, tap-to-click, drag
//    • 2-finger drag → scroll
//    • 2-finger tap  → right-click
//    • 3/4-finger swipe → Spaces / Mission Control / App Exposé (via shortcuts)
//
//  Works on Apple Silicon and Intel. No kernel extension, no SIP changes.
//
//  Requires (granted to the app, or to the launching Terminal):
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
    var gestures = true     // multi-finger gestures on by default
    var debug = false
}

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
    if let data = try? JSONEncoder().encode(c) { try? data.write(to: url) }
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

// MARK: - List / inspect / setup modes

/// Count the touch capabilities of a digitizer device:
/// (fingerGroups = simultaneous contacts reported, contactCountMax = declared max).
func touchCapabilities(_ dev: IOHIDDevice) -> (fingerGroups: Int, contactCountMax: Int) {
    guard let elements = IOHIDDeviceCopyMatchingElements(dev, nil, 0) as? [IOHIDElement] else {
        return (0, 0)
    }
    struct G { var x = false; var y = false; var tip = false }
    var groups: [UInt32: G] = [:]
    var contactCountMax = 0
    for e in elements {
        let p = IOHIDElementGetUsagePage(e), u = IOHIDElementGetUsage(e)
        if p == 0x0D && u == 0x54 { contactCountMax = max(contactCountMax, IOHIDElementGetLogicalMax(e)) }
        let isX = (p == 0x01 && u == 0x30)
        let isY = (p == 0x01 && u == 0x31)
        let isTip = (p == 0x0D && u == 0x42)
        guard isX || isY || isTip, let parent = IOHIDElementGetParent(e) else { continue }
        let pc = IOHIDElementGetCookie(parent)
        if groups[pc] == nil { groups[pc] = G() }
        if isX { groups[pc]!.x = true }
        if isY { groups[pc]!.y = true }
        if isTip { groups[pc]!.tip = true }
    }
    let fingerGroups = groups.values.filter { $0.x && $0.y && $0.tip }.count
    return (fingerGroups, contactCountMax)
}

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
            let cap = touchCapabilities(dev)
            let fingers = cap.contactCountMax > 0
                ? "\(cap.fingerGroups) simultaneous (declared max \(cap.contactCountMax))"
                : "\(cap.fingerGroups) simultaneous"
            let multi = cap.fingerGroups >= 2 ? "multi-touch" : "single-touch"
            print(String(format: "  %@  vendor=0x%04X product=0x%04X  →  %@, %@ fingers",
                         name, vid, pid, multi, fingers))
        }
    }
    print("\nNote: macOS can't map a touch device to a specific display automatically;")
    print("use --setup to tell touchdriver which display is the touchscreen.")
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
        var contactCountSeen = false
        var xCount = 0
        for e in elements {
            let p = IOHIDElementGetUsagePage(e), u = IOHIDElementGetUsage(e)
            if p == 0x0D && u == 0x54 { contactCountSeen = true }
            if (p == 0x01 || p == 0x0D) && u == 0x30 { xCount += 1 }
            let key = String(format: "0x%02X/0x%02X", p, u)
            if seen.insert(key).inserted {
                print(String(format: "  page=0x%02X usage=0x%02X  logical=[%d..%d]",
                             p, u, IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e)))
            }
        }
        print("  --> Contact Count present: \(contactCountSeen)")
        print("  --> Number of X elements (≈ max simultaneous contacts): \(xCount)\n")
    }
    print("Multi-touch needs 'Contact Count' present and multiple X elements.")
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

private enum Role { case x, y, tip }

private struct Contact {
    var nx = 0.0      // normalized 0..1
    var ny = 0.0
    var tip = false
}

final class TouchDriver {
    private let config: Config
    private var bounds: CGRect = .zero
    private let source = CGEventSource(stateID: .hidSystemState)
    private var manager: IOHIDManager!

    // Multi-touch element mapping.
    private var roleByCookie: [UInt32: (idx: Int, role: Role)] = [:]
    private var contactCountCookie: UInt32?
    private var contacts: [Contact] = []
    private var xLogicalMax = 4095.0
    private var yLogicalMax = 4095.0

    // Gesture sequence state.
    private var seqActive = false
    private var seqMaxFingers = 0
    private var seqStart = CGPoint.zero       // normalized centroid at start
    private var seqStartTime = 0.0
    private var lastCentroid = CGPoint.zero   // normalized
    private var pointerDown = false
    private var swipeFired = false

    // Tunables.
    private let tapMaxTime = 0.30             // seconds for a tap
    private let dragThreshold = 8.0          // px before 1-finger press-drag
    private let tapMoveTol = 12.0            // px max movement for a tap
    private let swipeThreshold = 90.0        // px for a 3/4-finger swipe
    private let scrollGain = 1.2

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

    private func postScroll(dx: Double, dy: Double) {
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?.post(tap: .cghidEventTap)
    }

    private func postKey(_ key: CGKeyCode, control: Bool) {
        let d = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let u = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        if control { d?.flags = .maskControl; u?.flags = .maskControl }
        d?.post(tap: .cghidEventTap)
        u?.post(tap: .cghidEventTap)
    }

    // MARK: HID element setup

    private func setupElements(_ dev: IOHIDDevice) {
        guard let elements = IOHIDDeviceCopyMatchingElements(dev, nil, 0) as? [IOHIDElement] else { return }
        // Group X/Y/Tip by parent collection; keep only groups that have all three
        // (this excludes the single-finger mouse collection which has no digitizer tip).
        struct Group { var x: UInt32?; var y: UInt32?; var tip: UInt32? }
        var groups: [UInt32: Group] = [:]
        var order: [UInt32] = []
        for e in elements {
            let p = IOHIDElementGetUsagePage(e), u = IOHIDElementGetUsage(e)
            let role: Role?
            if p == 0x01 && u == 0x30 { role = .x }
            else if p == 0x01 && u == 0x31 { role = .y }
            else if p == 0x0D && u == 0x42 { role = .tip }
            else {
                if p == 0x0D && u == 0x54 { contactCountCookie = IOHIDElementGetCookie(e) }
                continue
            }
            guard let parent = IOHIDElementGetParent(e) else { continue }
            let pc = IOHIDElementGetCookie(parent)
            if groups[pc] == nil { groups[pc] = Group(); order.append(pc) }
            let c = IOHIDElementGetCookie(e)
            switch role! {
            case .x: groups[pc]!.x = c; xLogicalMax = max(1, Double(IOHIDElementGetLogicalMax(e)))
            case .y: groups[pc]!.y = c; yLogicalMax = max(1, Double(IOHIDElementGetLogicalMax(e)))
            case .tip: groups[pc]!.tip = c
            }
        }
        var idx = 0
        for pc in order {
            guard let g = groups[pc], let xc = g.x, let yc = g.y, let tc = g.tip else { continue }
            roleByCookie[xc] = (idx, .x)
            roleByCookie[yc] = (idx, .y)
            roleByCookie[tc] = (idx, .tip)
            idx += 1
        }
        contacts = Array(repeating: Contact(), count: max(1, idx))
        err("Multi-touch contacts tracked: \(idx) (gestures \(config.gestures ? "ON" : "OFF")).")
    }

    // MARK: Per-value input

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let cookie = IOHIDElementGetCookie(element)
        let v = IOHIDValueGetIntegerValue(value)

        if config.debug {
            err(String(format: "page=0x%02X usage=0x%02X val=%d",
                       IOHIDElementGetUsagePage(element), IOHIDElementGetUsage(element), v))
        }

        if let (idx, role) = roleByCookie[cookie] {
            switch role {
            case .x: contacts[idx].nx = Double(v) / xLogicalMax
            case .y: contacts[idx].ny = Double(v) / yLogicalMax
            case .tip: contacts[idx].tip = (v != 0)
            }
            // If the device has no contact-count element, evaluate on tip changes.
            if contactCountCookie == nil && role == .tip { processFrame() }
        } else if cookie == contactCountCookie {
            processFrame()
        }
    }

    // MARK: Gesture recognition (called once per HID frame)

    private func processFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let active = contacts.filter { $0.tip }
        let n = active.count

        // Centroid in normalized coords.
        func centroid() -> CGPoint {
            var sx = 0.0, sy = 0.0
            for c in active { sx += c.nx; sy += c.ny }
            return CGPoint(x: sx / Double(max(1, n)), y: sy / Double(max(1, n)))
        }

        if n == 0 {
            if seqActive { endSequence(now: now) }
            return
        }

        let cen = centroid()
        if !seqActive {
            seqActive = true
            seqMaxFingers = n
            seqStart = cen
            lastCentroid = cen
            seqStartTime = now
            pointerDown = false
            swipeFired = false
        } else {
            seqMaxFingers = max(seqMaxFingers, n)
        }

        // Effective gesture class is the max number of fingers seen this sequence.
        let fingers = config.gestures ? seqMaxFingers : 1
        let startPx = screenPoint(seqStart)
        let curPx = screenPoint(cen)
        let lastPx = screenPoint(lastCentroid)

        switch fingers {
        case 1:
            let p = screenPoint(cen)
            CGWarpMouseCursorPosition(p)
            let moved = hypot(curPx.x - startPx.x, curPx.y - startPx.y)
            if !pointerDown && moved > dragThreshold {
                pointerDown = true
                postMouse(.leftMouseDown, p)
            } else if pointerDown {
                postMouse(.leftMouseDragged, p)
            }
        case 2:
            let dx = Double(curPx.x - lastPx.x) * scrollGain
            let dy = Double(curPx.y - lastPx.y) * scrollGain
            if abs(dx) >= 1 || abs(dy) >= 1 { postScroll(dx: dx, dy: dy) }
        default: // 3+ fingers → swipe to a system shortcut
            if !swipeFired {
                let dx = curPx.x - startPx.x, dy = curPx.y - startPx.y
                if abs(dx) > swipeThreshold || abs(dy) > swipeThreshold {
                    swipeFired = true
                    if abs(dx) > abs(dy) {
                        // Horizontal: switch Spaces. (Ctrl+←/→)
                        postKey(dx > 0 ? 0x7B : 0x7C, control: true)
                    } else if dy < 0 {
                        postKey(0x7E, control: true)   // up → Mission Control (Ctrl+↑)
                    } else {
                        postKey(0x7D, control: true)   // down → App Exposé (Ctrl+↓)
                    }
                }
            }
        }

        lastCentroid = cen
    }

    private func endSequence(now: Double) {
        let dur = now - seqStartTime
        let fingers = config.gestures ? seqMaxFingers : 1
        let startPx = screenPoint(seqStart)
        let lastPx = screenPoint(lastCentroid)
        let moved = hypot(lastPx.x - startPx.x, lastPx.y - startPx.y)

        switch fingers {
        case 1:
            if pointerDown {
                postMouse(.leftMouseUp, lastPx)
            } else if dur < tapMaxTime && moved < tapMoveTol {
                postMouse(.leftMouseDown, startPx)   // tap → click
                postMouse(.leftMouseUp, startPx)
            }
        case 2:
            if dur < tapMaxTime && moved < tapMoveTol {
                postMouse(.rightMouseDown, startPx, button: .right)  // two-finger tap → right click
                postMouse(.rightMouseUp, startPx, button: .right)
            }
        default:
            break // 3/4-finger swipes already fired on threshold
        }

        seqActive = false
        pointerDown = false
        swipeFired = false
    }

    // MARK: Run loop

    private func ensureAccessibility() {
        if AXIsProcessTrusted() { err("Accessibility: granted."); return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        err("Accessibility: NOT granted. Enable this app under System Settings > Privacy & Security > Accessibility, then re-run.")
    }

    func run() {
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

        // Map elements from the first matching digitizer device.
        if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = set.first {
            setupElements(dev)
        } else {
            err("WARNING: no matching device to map elements from.")
        }

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

func printUsage() {
    print("""
    touchdriver — map a USB touchscreen to its display on macOS, with gestures

    USAGE:
      touchdriver [options]

    With no options it auto-detects the touchscreen display (or uses your saved
    --setup choice) and enables gestures:
      • 1 finger      → move cursor, tap to click, drag
      • 2-finger drag → scroll
      • 2-finger tap  → right-click
      • 3/4-finger swipe → switch Spaces (←/→), Mission Control (↑), App Exposé (↓)

    OPTIONS:
      --no-gestures              Single-finger pointer only (no multi-finger gestures)
      --setup                    Interactively pick & remember the touchscreen display
      --list-displays            List displays, then exit
      --list-devices             List HID devices, then exit
      --inspect                  Show a touchscreen's HID capabilities, then exit
      --display-index N          Map touch to display at index N (remembered)
      --display-vendor V         Match target display by vendor number (remembered)
      --display-model M          Match target display by model number
      --vendor-id  0xVVVV        Match a specific touch device
      --product-id 0xPPPP        Match a specific touch device
      --debug                    Log raw HID page/usage/value
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
    case "--setup": runSetup(); exit(0)
    case "--list-displays": listDisplays(); exit(0)
    case "--list-devices": listDevices(); exit(0)
    case "--inspect": inspectDevices(); exit(0)
    case "--no-gestures": config.gestures = false
    case "--display-index": i += 1; config.displayIndex = parseInt(args[i])
    case "--display-vendor": i += 1; config.displayVendor = parseInt(args[i]).map { UInt32($0) }
    case "--display-model": i += 1; config.displayModel = parseInt(args[i]).map { UInt32($0) }
    case "--vendor-id": i += 1; config.vendorID = parseInt(args[i])
    case "--product-id": i += 1; config.productID = parseInt(args[i])
    case "--debug": config.debug = true
    default:
        err("Unknown option: \(a)"); printUsage(); exit(2)
    }
    i += 1
}

TouchDriver(config: config).run()
