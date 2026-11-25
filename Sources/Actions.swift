import AppKit
import CoreGraphics
import ApplicationServices

/// System actions. Posting events needs the Accessibility permission.
enum Actions {
    private static var accum = CGPoint.zero

    /// Pixel scroll for the window under the mouse cursor (fractions are accumulated).
    static func scroll(dx: CGFloat, dy: CGFloat) {
        accum.x += dx
        accum.y += dy
        let ix = Int32(accum.x.rounded(.towardZero)), iy = Int32(accum.y.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return }
        accum.x -= CGFloat(ix)
        accum.y -= CGFloat(iy)
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Ctrl+→ / Ctrl+← (system shortcut "Move right/left a space").
    static func switchSpace(toRight: Bool) {
        key(toRight ? 124 : 123, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
    }

    static func missionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Frame of the focused window of the frontmost app (global coords, top-left origin).
    static func focusedWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let win = w as! AXUIElement
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, let sv = sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// Scroll goes to the window under the mouse cursor, so put the cursor into the active window if it is elsewhere.
    static func ensureCursorInFocusedWindow() {
        guard let f = focusedWindowFrame(), f.width > 50, f.height > 50 else { return }
        let cur = CGEvent(source: nil)?.location ?? .zero
        if !f.contains(cur) { CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY)) }
    }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}
