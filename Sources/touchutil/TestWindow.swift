// TestWindow.swift — visual gesture feedback overlay (touchutil --test)
//
// Opens a floating window on the touchscreen display that shows which gesture
// is being detected in real time. Useful for debugging and hardware testing.

import AppKit

// MARK: - Gesture event sent from TouchDriver to the overlay

enum GestureEvent {
    case touch(normX: Double, normY: Double)
    case gesture(String, NSColor)
    case lift
}

// MARK: - Overlay window

final class TestWindow: NSObject {
    private var window: NSWindow!
    private var gestureLabel: NSTextField!
    private var posLabel: NSTextField!
    private var touchDot: NSView!
    private var miniScreen: NSView!
    private var clearTimer: Timer?

    func open(on displayBounds: CGRect) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let w: CGFloat = 460, h: CGFloat = 320
        let origin = CGPoint(
            x: displayBounds.midX - w / 2,
            y: displayBounds.midY - h / 2
        )

        window = NSWindow(
            contentRect: NSRect(x: origin.x, y: origin.y, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "touchutil — gesture tester"
        window.level = .floating
        window.backgroundColor = NSColor(white: 0.08, alpha: 1)
        window.isReleasedWhenClosed = false

        buildUI(w: w, h: h)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }

    private func buildUI(w: CGFloat, h: CGFloat) {
        guard let content = window.contentView else { return }
        content.wantsLayer = true

        // Subtitle
        let sub = label("Touch the touchscreen to see gestures", size: 12, weight: .regular,
                        color: NSColor(white: 0.45, alpha: 1))
        sub.frame = NSRect(x: 0, y: h - 36, width: w, height: 20)
        content.addSubview(sub)

        // Big gesture label
        gestureLabel = label("Waiting for touch…", size: 34, weight: .bold, color: .white)
        gestureLabel.frame = NSRect(x: 20, y: h / 2 - 10, width: w - 40, height: 50)
        content.addSubview(gestureLabel)

        // Position readout
        posLabel = label("", size: 11, weight: .regular,
                         color: NSColor(white: 0.4, alpha: 1))
        posLabel.frame = NSRect(x: 0, y: h / 2 - 36, width: w, height: 18)
        content.addSubview(posLabel)

        // Mini screen map
        let mapW: CGFloat = 120, mapH: CGFloat = 80
        miniScreen = NSView(frame: NSRect(x: (w - mapW) / 2, y: 20, width: mapW, height: mapH))
        miniScreen.wantsLayer = true
        miniScreen.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        miniScreen.layer?.cornerRadius = 4
        miniScreen.layer?.borderWidth = 1
        miniScreen.layer?.borderColor = NSColor(white: 0.3, alpha: 1).cgColor
        content.addSubview(miniScreen)

        // Touch dot on mini map
        let dotSize: CGFloat = 12
        touchDot = NSView(frame: NSRect(x: -dotSize, y: -dotSize, width: dotSize, height: dotSize))
        touchDot.wantsLayer = true
        touchDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        touchDot.layer?.cornerRadius = dotSize / 2
        touchDot.alphaValue = 0
        miniScreen.addSubview(touchDot)
    }

    // Called from TouchDriver on every gesture event (may be called off main thread).
    func send(_ event: GestureEvent) {
        DispatchQueue.main.async { self.handle(event) }
    }

    private func handle(_ event: GestureEvent) {
        switch event {
        case .touch(let nx, let ny):
            posLabel.stringValue = String(format: "x = %.3f   y = %.3f", nx, ny)
            moveDot(nx: nx, ny: ny)

        case .gesture(let name, let color):
            clearTimer?.invalidate()
            gestureLabel.stringValue = name
            gestureLabel.textColor = color
            clearTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.gestureLabel.stringValue = "Waiting for touch…"
                    self?.gestureLabel.textColor = .white
                }
            }

        case .lift:
            posLabel.stringValue = ""
            touchDot.alphaValue = 0
        }
    }

    private func moveDot(nx: Double, ny: Double) {
        let mw = miniScreen.bounds.width
        let mh = miniScreen.bounds.height
        let dotSize: CGFloat = 12
        // macOS Y is bottom-up; touch Y is top-down → flip.
        let x = CGFloat(nx) * (mw - dotSize)
        let y = (1 - CGFloat(ny)) * (mh - dotSize)
        touchDot.frame = NSRect(x: x, y: y, width: dotSize, height: dotSize)
        touchDot.alphaValue = 1
    }

    // MARK: Helpers

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.alignment = .center
        f.autoresizingMask = []
        return f
    }
}
