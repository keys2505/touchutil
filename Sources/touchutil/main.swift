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

import AppKit
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
    var debugLog = false
    var test = false
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

/// Human-readable name for a display. Some panels (e.g. cheap touchscreens)
/// report no EDID name — macOS returns "" — so fall back to a usable label.
func displayName(_ id: CGDirectDisplayID) -> String {
    for screen in NSScreen.screens {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           num == id {
            let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
    }
    return "Unnamed display"
}

/// Name of the first detected touchscreen digitizer, if any.
func touchDeviceName() -> String? {
    guard let dev = touchDevices().first else { return nil }
    return IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String
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
    private var tipTimer: Timer?
    private let tipDebounce = 0.05   // 50 ms — coalesces rapid tip=1/tip=0 cycles per sample

    // Single-finger gesture recognizer state.
    private var fingerDown = false, mousePressed = false, movedBeyond = false
    private var edgeFired = false, longFired = false, edgeResolved = false
    private var scrollMode = false, dragEnabled = false
    private var nearL = false, nearR = false, nearT = false, nearB = false
    private var sStartPx = CGPoint.zero
    private var lastScrollPx = CGPoint.zero
    private var longTimer: Timer?
    private var dragTimer: Timer?
    private var lastTapTime = 0.0
    private var lastTapPx = CGPoint.zero
    private var lastClickCount = 0
    // Single-finger tunables.
    private let moveTol = 10.0
    private let longPressDelay = 0.5
    private let dragHoldDelay = 0.35  // hold 350ms before horizontal drag enables selection
    private let edgeMarginN = 0.12    // 12% from edge triggers edge-swipe mode
    private let edgeSwipeThreshold = 40.0  // px to travel before edge key fires
    private let doubleTapInterval = 0.6    // max gap between two taps to count as double-tap
    private let doubleTapDist = 70.0       // max finger travel between taps (px)
    private let scrollScale = 3.0

    var testWindow: TestWindow? = nil   // set when running --test
    private var signalSource: DispatchSourceSignal? = nil
    private var appDelegate: NSObject? = nil

    init(config: Config) { self.config = config }

    /// Expose resolved display bounds without starting the full driver (used by --test setup).
    func boundsForTest() -> CGRect { resolveDisplay() }

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
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)?
            .post(tap: .cgAnnotatedSessionEventTap)
    }

    private func postKey(_ key: CGKeyCode, control: Bool) {
        let d = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let u = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        if control { d?.flags = .maskControl; u?.flags = .maskControl }
        d?.post(tap: .cghidEventTap)
        u?.post(tap: .cghidEventTap)
    }

    /// Trigger Mission Control (show all windows) via the F3 / Mission Control key.
    /// Falls back to Ctrl+Up which is the default keyboard shortcut.
    private func postMissionControl() {
        // Key code 160 = F3 / Mission Control on Apple keyboards.
        // Ctrl+Up (0x7E) is the default shortcut — use both for reliability.
        let mc = CGEvent(keyboardEventSource: source, virtualKey: 160, keyDown: true)
        let mcu = CGEvent(keyboardEventSource: source, virtualKey: 160, keyDown: false)
        if mc == nil {
            postKey(0x7E, control: true)
        } else {
            mc?.post(tap: .cghidEventTap)
            mcu?.post(tap: .cghidEventTap)
        }
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

        switch (page, usage) {
        case (0x01, 0x30):
            pNX = Double(v) / xLogicalMax
            if fingerDown { gestureMove() }
        case (0x01, 0x31):
            pNY = Double(v) / yLogicalMax
            if fingerDown { gestureMove() }
        case (0x09, 0x01):
            let newTip = (v != 0)
            if newTip {
                // Finger (re)touching — cancel any pending tip-off and continue
                // or start the gesture if not already active.
                tipTimer?.invalidate(); tipTimer = nil
                if !fingerDown {
                    pTip = true
                    if !config.gestures { simplePrimary(); return }
                    gestureDown()
                }
            } else {
                // Finger may have lifted — debounce before ending gesture.
                // Many digitizers pulse tip=0 between samples; we wait tipDebounce
                // before treating it as a real lift.
                pTip = false
                tipTimer?.invalidate()
                tipTimer = Timer(timeInterval: tipDebounce, repeats: false) { [weak self] _ in
                    guard let self = self, !self.pTip else { return }
                    if !self.config.gestures { self.simplePrimary(); return }
                    self.gestureUp()
                }
                RunLoop.current.add(tipTimer!, forMode: .common)
            }
        default: return
        }
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Plain pointer (used with --no-gestures): press on touch, drag, release.
    private func simplePrimary() {
        let p = screenPoint(CGPoint(x: pNX, y: pNY))
        if pTip && !pDown  { pDown = true;  postMouse(.leftMouseDown, p) }
        else if pTip       { postMouse(.leftMouseDragged, p) }
        else if pDown      { pDown = false; postMouse(.leftMouseUp, p) }
    }

    /// Send a click with an explicit clickState so macOS and apps know exactly
    /// whether this is a single (1) or double (2) click — no timing ambiguity.
    /// Without clickState, macOS infers count from timing: two taps within the
    /// system double-click window (~500ms) would be escalated to clickCount=2,
    /// causing one physical tap to behave like a double-click.
    private func postClick(_ p: CGPoint, _ button: CGMouseButton, _ count: Int = 1) {
        // Tap-level routing — each fixes a different problem:
        //  • Single left click → annotated-session tap. The HID tap double-fires
        //    a single click in some apps (YouTube play button), so use the
        //    session tap which delivers it exactly once.
        //  • Right-click & double-click → HID tap. The session tap silently drops
        //    right-click context menus and clickState=2 double-clicks; the HID
        //    tap delivers them reliably.
        let isSingleLeft = (button == .left && count == 1)
        let tap: CGEventTapLocation = isSingleLeft ? .cgAnnotatedSessionEventTap : .cghidEventTap

        let down: CGEventType = (button == .right) ? .rightMouseDown : .leftMouseDown
        let up:   CGEventType = (button == .right) ? .rightMouseUp   : .leftMouseUp
        if let d = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: p, mouseButton: button) {
            d.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, count)))
            d.post(tap: tap)
        }
        if let u = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: p, mouseButton: button) {
            u.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, count)))
            u.post(tap: tap)
        }
    }

    private func startLongTimer() {
        cancelLongTimer()
        let t = Timer(timeInterval: longPressDelay, repeats: false) { [weak self] _ in self?.longPressFired() }
        RunLoop.current.add(t, forMode: .common)
        longTimer = t
    }
    private func cancelLongTimer() { longTimer?.invalidate(); longTimer = nil }

    private func startDragTimer() {
        dragTimer?.invalidate()
        let t = Timer(timeInterval: dragHoldDelay, repeats: false) { [weak self] _ in
            self?.dragEnabled = true
        }
        RunLoop.current.add(t, forMode: .common)
        dragTimer = t
    }
    private func cancelDragTimer() { dragTimer?.invalidate(); dragTimer = nil }

    private func longPressFired() {
        guard fingerDown, !movedBeyond, !edgeFired, !longFired else { return }
        longFired = true
        testWindow?.send(.gesture("⚙️ Long Press → Right-click", .systemOrange))
        postClick(sStartPx, .right, 1)
    }

    private func postScroll(deltaY: Double) {
        // Use pixel units for smooth continuous scrolling.
        // Finger moves down → content scrolls down (natural touch direction).
        let px = Int32((deltaY * scrollScale).rounded())
        guard px != 0 else { return }
        CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                wheelCount: 1, wheel1: px, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private func gestureDown() {
        if config.debug { debugOut(String(format: "DOWN  nx=%.3f ny=%.3f  t=%.3f", pNX, pNY, now())) }
        fingerDown = true; mousePressed = false; movedBeyond = false
        edgeFired = false; longFired = false; scrollMode = false; dragEnabled = false
        sStartPx = clamp(screenPoint(CGPoint(x: pNX, y: pNY)))
        lastScrollPx = sStartPx
        let m = edgeMarginN
        nearL = pNX < m; nearR = pNX > 1 - m; nearT = pNY < m; nearB = pNY > 1 - m
        edgeResolved = !(nearL || nearR || nearT || nearB)
        // Warp the cursor to the touch point immediately on touch-down so the
        // first tap lands on the touchscreen — not on whatever display the
        // cursor was previously on. Harmless for scroll (no button is pressed,
        // so the cursor just sits at the touch point without selecting).
        CGWarpMouseCursorPosition(sStartPx)
        testWindow?.send(.touch(normX: pNX, normY: pNY))
        if config.debug {
            debugOut(String(format: "touch: nx=%.3f ny=%.3f  nearL=%d nearR=%d nearT=%d nearB=%d edgeResolved=%d",
                pNX, pNY, nearL ? 1:0, nearR ? 1:0, nearT ? 1:0, nearB ? 1:0, edgeResolved ? 1:0))
        }
        startLongTimer()
        startDragTimer()
    }

    /// Clamp a screen point to the touchscreen display bounds so the cursor
    /// never jumps to another monitor due to edge noise or coordinate rounding.
    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: max(bounds.minX, min(bounds.maxX - 1, p.x)),
            y: max(bounds.minY, min(bounds.maxY - 1, p.y))
        )
    }

    private func gestureMove() {
        let cur = clamp(screenPoint(CGPoint(x: pNX, y: pNY)))
        let dist = hypot(cur.x - sStartPx.x, cur.y - sStartPx.y)
        if dist <= moveTol { return }   // wait for clear movement before committing to any gesture

        if !movedBeyond {
            movedBeyond = true
            cancelLongTimer()
            cancelDragTimer()
            let dx = cur.x - sStartPx.x
            let dy = cur.y - sStartPx.y
            // Scroll when movement is vertical, UNLESS near top/bottom edge
            // (those have their own vertical gesture — Mission Control / App Exposé).
            // Near left/right edges still allow vertical scroll — only horizontal
            // movement near left/right triggers edge swipe.
            let nearVerticalEdge = nearT || nearB
            if abs(dy) > abs(dx) && !nearVerticalEdge {
                scrollMode = true
                lastScrollPx = cur
            }
            if config.debug {
                debugOut(String(format: "gesture: dx=%.1f dy=%.1f → %@", dx, dy, scrollMode ? "SCROLL" : "DRAG"))
            }
        }

        // Scroll mode — post wheel events, cursor stays put.
        if scrollMode {
            let deltaY = cur.y - lastScrollPx.y
            if abs(deltaY) > 0.5 {
                let dir = deltaY < 0 ? "↑ Scroll Up" : "↓ Scroll Down"
                testWindow?.send(.gesture(dir, .systemBlue))
            }
            postScroll(deltaY: deltaY)
            lastScrollPx = cur
            return
        }

        if edgeFired { return }
        if !edgeResolved {
            if dist < edgeSwipeThreshold { return }
            let dx = cur.x - sStartPx.x, dy = cur.y - sStartPx.y
            // Only the bottom-left corner triggers Mission Control. Left/right
            // edges fall through to normal drag so window resizing works there.
            if nearL && nearB && (dx > abs(dy) || -dy > abs(dx)) {
                testWindow?.send(.gesture("⬆ Corner → All Windows", .systemPurple))
                postMissionControl()
                edgeFired = true
                return
            }
            edgeResolved = true
        }
        // Drag/select only if: held long enough AND clearly more horizontal than vertical.
        // The 1.5x factor prevents an accidental horizontal wobble during a vertical
        // scroll from triggering drag/selection.
        let adx = abs(cur.x - sStartPx.x), ady = abs(cur.y - sStartPx.y)
        guard dragEnabled && adx > ady * 1.5 else { return }
        if !mousePressed {
            mousePressed = true
            testWindow?.send(.gesture("✊ Dragging…", .systemYellow))
            // Force the cursor to the touch start before grabbing, so the drag
            // grabs whatever is under the touchscreen point — not whatever the
            // cursor was previously over on another display.
            CGWarpMouseCursorPosition(sStartPx)
            postMouse(.mouseMoved, sStartPx)
            postMouse(.leftMouseDown, sStartPx)
        }
        testWindow?.send(.touch(normX: pNX, normY: pNY))
        postMouse(.leftMouseDragged, cur)
    }

    private func gestureUp() {
        guard fingerDown else { return }  // ignore spurious tip=0 after gesture already ended
        fingerDown = false; cancelLongTimer(); cancelDragTimer()
        let cur = clamp(screenPoint(CGPoint(x: pNX, y: pNY)))
        testWindow?.send(.lift)
        if mousePressed { postMouse(.leftMouseUp, cur); mousePressed = false; return }
        if edgeFired || longFired || scrollMode { scrollMode = false; return }

        // Tap → click. Explicit clickState tells macOS + apps exactly what this is:
        // count=1 = single click, count=2 = double-click. This prevents macOS from
        // inferring a double-click from timing alone (which caused one tap to behave
        // like a double-click when two taps arrived within the 500ms system window).
        let time = now()
        var count = 1
        if time - lastTapTime < doubleTapInterval,
           hypot(cur.x - lastTapPx.x, cur.y - lastTapPx.y) < doubleTapDist {
            count = min(lastClickCount + 1, 3)
        }
        let label = count == 1 ? "👆 Tap" : count == 2 ? "👆👆 Double Tap" : "👆👆👆 Triple Tap"
        testWindow?.send(.gesture(label, .systemGreen))
        if config.debug { debugOut(String(format: "CLICK count=%d  t=%.3f", count, time)) }
        postClick(cur, .left, count)
        lastTapTime = time; lastTapPx = cur; lastClickCount = count
    }

    // MARK: Run loop

    // Check permissions silently — never pop a system dialog automatically.
    // Showing the dialog on every launch is intrusive; users grant once via
    // System Settings and the app remembers it. If not yet granted, print
    // clear instructions to stderr/log and let the run loop retry naturally.
    private func ensureAccessibility() {
        if AXIsProcessTrusted() { err("Accessibility: granted."); return }
        // Show system prompt — this fires after a fresh install/upgrade when
        // tccutil reset was run in the installer preflight.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        err("Accessibility: not granted — approve the prompt or enable in System Settings → Privacy & Security → Accessibility.")
    }

    private func ensureInputMonitoring() {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            err("Input Monitoring: granted.")
        case kIOHIDAccessTypeDenied:
            err("Input Monitoring: denied — enable in System Settings → Privacy & Security → Input Monitoring.")
        default:
            // Unknown = fresh install or reset — show system banner once.
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            err("Input Monitoring: requested — approve in System Settings → Privacy & Security → Input Monitoring.")
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

        // Handle SIGUSR1 — show the test window when signalled by a Finder launch.
        signal(SIGUSR1, SIG_IGN)
        let sigSrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        let driverRef = self
        sigSrc.setEventHandler { driverRef.showTestWindow() }
        sigSrc.resume()
        self.signalSource = sigSrc   // retain so it isn't deallocated

        err("Touch driver running. Press Ctrl+C to stop.")
        // Run through NSApplication so the reopen event (double-click in Finder
        // while already running) and signals are handled.
        let app = NSApplication.shared
        let delegate = AppReopenDelegate(driver: self)
        app.delegate = delegate
        self.appDelegate = delegate   // retain
        app.setActivationPolicy(testWindow != nil ? .regular : .accessory)
        if testWindow != nil { app.activate(ignoringOtherApps: true) }
        app.run()
    }

    /// Open the gesture test window (or bring it to front if already open).
    func showTestWindow() {
        if testWindow == nil {
            let overlay = TestWindow()
            overlay.displayOptions = buildDisplayOptions()
            overlay.touchHardwareName = touchDeviceName()
            overlay.onSelectDisplay = { [weak self] id in
                self?.selectDisplay(id)
            }
            overlay.open(on: boundsForTest())
            testWindow = overlay
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        testWindow?.send(.gesture("👋 Gesture tester", .systemGreen))
    }

    /// Build the picker list from currently connected displays.
    private func buildDisplayOptions() -> [DisplayOption] {
        let mainID = CGMainDisplayID()
        let saved = loadSavedConfig()
        return activeDisplays().enumerated().map { (i, d) in
            let b = CGDisplayBounds(d)
            let isMain = d == mainID
            let isCurrent = saved.map {
                CGDisplayVendorNumber(d) == $0.displayVendor && CGDisplayModelNumber(d) == $0.displayModel
            } ?? false
            // Index prefix distinguishes displays with identical names/resolutions.
            var label = "[\(i)] \(displayName(d))  ·  \(Int(b.width))×\(Int(b.height))"
            if isMain { label += "  (main)" }
            if isCurrent { label += "  ✓ current" }   // your saved touchscreen pick
            return DisplayOption(id: d, label: label, isCurrent: isCurrent)
        }
    }

    /// Save the chosen display and switch touch mapping to it immediately.
    private func selectDisplay(_ id: CGDirectDisplayID) {
        let v = CGDisplayVendorNumber(id), m = CGDisplayModelNumber(id)
        saveConfig(SavedConfig(displayVendor: v, displayModel: m))
        bounds = CGDisplayBounds(id)
        err("Touchscreen display set via GUI: vendor=\(v) model=\(m).")
    }
}

/// Handles the Finder "reopen" event (double-click the app while it's already
/// running as the LaunchAgent). macOS routes the open to the existing instance
/// instead of spawning a new process, so we show the test window here.
final class AppReopenDelegate: NSObject, NSApplicationDelegate {
    weak var driver: TouchDriver?
    init(driver: TouchDriver) { self.driver = driver }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        driver?.showTestWindow()
        return true
    }
}

// MARK: - Argument parsing

let version = "1.2.8"

func printUsage() {
    print("""
    touchutil — map a USB touchscreen to its display on macOS

    USAGE:
      touchutil [options]

    With no options it auto-detects the touchscreen display (or uses your saved
    --setup choice) and enables single-finger gestures.

    Single-finger gestures (work on any panel):
      • move              → cursor
      • tap               → click
      • double-tap        → double-click
      • long-press (~0.5s)→ right-click
      • vertical drag     → scroll up / down
      • horizontal drag   → drag / select text / move windows
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
      --test                     Open a gesture-feedback window on the touchscreen display
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

// If launched with no arguments (double-clicked from Finder):
// signal the running agent to show its test window and exit.
// The LaunchAgent always passes --agent so we can tell them apart.
let pidFile = "/tmp/touchutil.pid"
let selfPID = ProcessInfo.processInfo.processIdentifier
// --agent = started by LaunchAgent (background). No args = opened from Finder.
let isAgent = CommandLine.arguments.contains("--agent")
let launchedFromFinder = !isAgent && CommandLine.arguments.count == 1

if launchedFromFinder,
   let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8),
   let runningPID = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
   runningPID != selfPID,
   kill(runningPID, 0) == 0 {
    kill(runningPID, SIGUSR1)
    Thread.sleep(forTimeInterval: 0.3)
    exit(0)
}
// No running agent — Finder launch starts driver + test window automatically.

// Write PID file now (before any error exits) so Finder launches can find us.
if !launchedFromFinder {
    try? String(selfPID).write(toFile: pidFile, atomically: true, encoding: .utf8)
}

var config = Config()
if launchedFromFinder { config.test = true }   // show test window when opened from Finder
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
    case "--agent": break   // passed by LaunchAgent — background mode, no UI on startup
    case "--test": config.test = true
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

let driver = TouchDriver(config: config)

if config.test {
    let overlay = TestWindow()
    // Resolve display bounds early so the window opens on the right screen.
    let testBounds: CGRect = {
        var cfg = config; cfg.test = false
        // Use a temporary driver just for display resolution.
        return TouchDriver(config: cfg).boundsForTest()
    }()
    overlay.open(on: testBounds)
    driver.testWindow = overlay
}

driver.run()
