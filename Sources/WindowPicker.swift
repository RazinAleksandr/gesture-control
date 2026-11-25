import AppKit
import ApplicationServices
import QuartzCore

// MARK: - Window model

struct WindowInfo {
    let pid: pid_t
    let appName: String
    let title: String          // window title, or "" if unknown
    let icon: NSImage?
    let axWindow: AXUIElement? // nil in fallback mode
    let frame: CGRect          // global screen coords, origin top-left of the primary screen (AX / CGWindow convention)
    let isMinimized: Bool
}

/// Round glass window buttons in the top-right corner of a tile that has an AX handle (shown on the highlighted tile).
private enum PickerButtonKind: Int, CaseIterable {
    case close = 0, minimize, fullscreen
}

/// What the pointer is aiming at.
private enum PickerTarget: Equatable {
    case tile(Int)
    case button(Int, PickerButtonKind)

    var tile: Int {
        switch self {
        case .tile(let i), .button(let i, _): return i
        }
    }
}

// MARK: - Picker

/// Full-screen overlay that shows all open windows as tiles; the gesture engine drives it.
/// All coordinates passed in are normalized to the overlay's screen: 0...1, origin TOP-LEFT.
/// Selection is by DWELL: hold the pointer on a tile or a tile button until the ring around the pointer fills.
@MainActor final class WindowPicker {
    private(set) var isOpen: Bool = false

    /// Called when the overlay closes BY ITSELF (dwell activation / fullscreen, or no windows left).
    /// Not called for close() / select(at:) invoked from outside.
    var onClosed: (() -> Void)?
    /// Short log lines: "activate Chrome — Gmail", "close Notes — Untitled", "minimize …", "fullscreen …".
    var onEvent: ((String) -> Void)?

    private var panel: PickerPanel?
    private let canvas = PickerCanvas()
    private var windows: [WindowInfo] = []
    private var fadeGeneration = 0
    private var screenSize: CGSize = .zero
    private var screenScale: CGFloat = 2

    // Dwell state
    private var target: PickerTarget?
    private var targetSince: CFTimeInterval = 0
    private var firedTarget: PickerTarget?      // already triggered; re-armed when the target changes
    private var openedAt: CFTimeInterval = 0
    private var lastPointer: CGPoint?           // normalized, last value passed to updatePointer
    private var refreshPending = false          // close/minimize sent, waiting to re-enumerate
    private var actionGeneration = 0
    private var pinchProgress: CGFloat = 0          // tiles are selected by pinch (engine); ring shows it
    // Dwell is armed only after the finger has moved since open (the hand is still right after the gesture).
    private var firstPointer: CGPoint?
    private var armed = false
    private static let armDistance: CGFloat = 0.06
    // Dwell counts only while the finger stands still: moving more than stillRadius restarts it,
    // and the ring starts filling only after stillDelay of stillness (so browsing never selects).
    private var dwellAnchor: CGPoint?
    private var dwellStart: CFTimeInterval = 0
    private static let stillRadius: CGFloat = 0.03
    private static let stillDelay: CFTimeInterval = 0.35

    private static let warmUp: CFTimeInterval = 0.6
    private static let refreshDelay: TimeInterval = 0.35

    private static func dwellDuration(_ t: PickerTarget) -> CFTimeInterval {
        switch t {
        case .tile: return 1.2
        case .button(_, .close): return 1.5
        case .button: return 1.2
        }
    }

    init() {}

    /// Enumerate windows and show the overlay on the screen that contains the mouse cursor (else main screen).
    /// Returns number of windows; if 0, does NOT open.
    @discardableResult func open() -> Int {
        let list = WindowPicker.listWindows()
        guard !list.isEmpty, let screen = WindowPicker.targetScreen() else { return 0 }
        windows = list
        screenSize = screen.frame.size
        screenScale = screen.backingScaleFactor
        resetDwell()
        actionGeneration += 1
        openedAt = CACurrentMediaTime()
        firstPointer = nil
        armed = false

        let panel = ensurePanel()
        panel.setFrame(screen.frame, display: false)
        rebuildCanvas()
        canvas.setPointer(nil)

        fadeGeneration += 1
        if !isOpen { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        isOpen = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        return list.count
    }

    /// Pointer in normalized coords of the overlay's screen: 0...1, origin TOP-LEFT. nil hides the pointer.
    /// Resolves the target (a tile button within 1.3× its radius, else the nearest tile), highlights it and
    /// advances the dwell timer; when the dwell completes the target is triggered. Call ~30×/s.
    func updatePointer(_ p: CGPoint?) {
        guard isOpen else { return }
        let now = CACurrentMediaTime()
        lastPointer = p
        guard let p else {
            canvas.setPointer(nil)
            canvas.setPinch(0)
            if let t = target {
                canvas.setTarget(.tile(t.tile), animated: true)   // keep tile highlight, drop button focus
                target = nil
                firedTarget = nil
            }
            return
        }
        let lp = canvas.toLayer(p)
        canvas.setPointer(lp)
        let t = canvas.resolve(lp, current: target)
        if t != target {
            target = t
            targetSince = now
            firedTarget = nil                                   // re-arm on target change
            canvas.setTarget(t, animated: true)                 // nil = pointer over empty space: no highlight
            dwellAnchor = p
            dwellStart = now
        }
        if let a = dwellAnchor, hypot(p.x - a.x, p.y - a.y) <= WindowPicker.stillRadius {
            // still standing
        } else {
            dwellAnchor = p
            dwellStart = now
        }
        if !armed {
            if let f = firstPointer {
                if hypot(p.x - f.x, p.y - f.y) > WindowPicker.armDistance { armed = true; dwellStart = now; dwellAnchor = p }
            } else {
                firstPointer = p
            }
        }
        guard armed, let t, t != firedTarget, !refreshPending else {
            canvas.setPinch(0)
            return
        }
        let start = max(dwellStart + WindowPicker.stillDelay, openedAt + WindowPicker.warmUp)
        let progress = max(0, now - start) / WindowPicker.dwellDuration(t)
        canvas.setPinch(CGFloat(min(1, progress)))
        if progress >= 1 { fire(t) }
    }

    /// No-op since v2 (selection is by dwell). Kept for source compatibility.
    func setPinchProgress(_ v: CGFloat) { pinchProgress = v }   // not drawn: the ring shows dwell

    /// Activate the tile nearest to `p` (same coords), or the current highlight if p == nil.
    /// Closes the overlay (also when nothing is selected). Returns "AppName — Title" of the
    /// activated window ("AppName" if the title is empty), or nil if there is nothing to select.
    @discardableResult func select(at p: CGPoint?) -> String? {
        guard isOpen else { return nil }
        let index: Int?
        if let p {
            index = canvas.nearestTile(to: canvas.toLayer(p), current: canvas.highlightedTile)
        } else {
            index = canvas.highlightedTile ?? (windows.count == 1 ? 0 : nil)
        }
        let w = index.flatMap { $0 < windows.count ? windows[$0] : nil }
        close()
        guard let w else { return nil }
        WindowPicker.activate(w)
        let label = WindowPicker.label(w)
        onEvent?("activate \(label)")
        return label
    }

    /// Close without selecting.
    func close() {
        guard isOpen, let panel else { return }
        isOpen = false
        resetDwell()
        actionGeneration += 1
        fadeGeneration += 1
        let gen = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == gen, !self.isOpen else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    // MARK: Dwell actions

    private func resetDwell() {
        target = nil
        firedTarget = nil
        lastPointer = nil
        refreshPending = false
        targetSince = 0
    }

    private func fire(_ t: PickerTarget) {
        firedTarget = t
        canvas.setPinch(0)
        guard t.tile < windows.count else { return }
        let w = windows[t.tile]
        let label = WindowPicker.label(w)
        switch t {
        case .tile:
            close()
            WindowPicker.activate(w)
            onEvent?("activate \(label)")
            onClosed?()
        case .button(_, .fullscreen):
            close()
            WindowPicker.activate(w)
            let ok = WindowPicker.toggleFullScreen(w)
            onEvent?("fullscreen \(label)" + (ok ? "" : " (failed)"))
            onClosed?()
        case .button(let i, .close):
            let ok = WindowPicker.pressClose(w)
            onEvent?("close \(label)" + (ok ? "" : " (failed)"))
            scheduleRefresh(dimming: i)
        case .button(let i, .minimize):
            let ok = WindowPicker.minimize(w)
            onEvent?("minimize \(label)" + (ok ? "" : " (failed)"))
            scheduleRefresh(dimming: i)
        }
    }

    /// Overlay stays open after close/minimize: dim the tile now, re-enumerate and relayout shortly after.
    private func scheduleRefresh(dimming tile: Int) {
        refreshPending = true
        canvas.setTileDimmed(tile)
        actionGeneration += 1
        let gen = actionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowPicker.refreshDelay) { [weak self] in
            MainActor.assumeIsolated { self?.refreshAfterAction(gen) }
        }
    }

    private func refreshAfterAction(_ gen: Int) {
        guard isOpen, gen == actionGeneration else { return }
        refreshPending = false
        let list = WindowPicker.listWindows()
        guard !list.isEmpty else {
            close()
            onEvent?("no windows left")
            onClosed?()
            return
        }
        windows = list
        rebuildCanvas()
        // Whatever is under the pointer now starts DISARMED: the user must move to another target to re-arm,
        // so holding still after closing one window never closes the next one that slid into its place.
        if let p = lastPointer {
            let lp = canvas.toLayer(p)
            let t = canvas.resolve(lp, current: nil)
            target = t
            firedTarget = t
            targetSince = CACurrentMediaTime()
            if let t { canvas.setTarget(t, animated: false) }
            canvas.setPointer(lp)
        } else {
            target = nil
            firedTarget = nil
        }
    }

    private func rebuildCanvas() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.root.frame = CGRect(origin: .zero, size: screenSize)
        canvas.build(windows: windows, buttons: windows.map { $0.axWindow != nil }, size: screenSize, scale: screenScale)
        canvas.setPinch(0)
        CATransaction.commit()
    }

    private static func label(_ w: WindowInfo) -> String {
        w.title.isEmpty ? w.appName : "\(w.appName) — \(w.title)"
    }

    // MARK: Debug rendering

    /// Debug: render the overlay content offscreen into a PNG (no window shown, no permissions needed).
    /// Uses the real window list; if it is empty, uses ~8 fake entries so the layout can be inspected.
    /// `size` is the output size in PIXELS; widths >= 2000 px are rendered as a Retina (2x) screen.
    /// `dwellProgress` (0...1) fills the ring; the target under `pointer` is highlighted as in live mode.
    /// Env WINDOW_PICKER_FAKE=<n> forces n fake entries (fake entries always show the tile buttons).
    func renderDebugPNG(to url: URL, pointer: CGPoint, size: CGSize, dwellProgress: CGFloat = 0) {
        let forced = ProcessInfo.processInfo.environment["WINDOW_PICKER_FAKE"].flatMap { Int($0) }
        var list = forced == nil ? WindowPicker.listWindows() : []
        var buttons = list.map { $0.axWindow != nil }
        if list.isEmpty {
            list = WindowPicker.fakeWindows(count: forced ?? 8)
            buttons = Array(repeating: true, count: list.count)
        }
        let scale: CGFloat = size.width >= 2000 ? 2 : 1
        let pts = CGSize(width: size.width / scale, height: size.height / scale)
        let pxW = Int(size.width.rounded()), pxH = Int(size.height.rounded())
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }

        let c = PickerCanvas()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        c.root.frame = CGRect(origin: .zero, size: pts)
        c.build(windows: list, buttons: buttons, size: pts, scale: scale)
        let lp = c.toLayer(pointer)
        if let t = c.resolve(lp, current: nil) { c.setTarget(t, animated: false) }
        c.setPointer(lp)
        c.setPinch(max(0, min(1, dwellProgress)))
        CATransaction.commit()

        ctx.scaleBy(x: scale, y: scale)
        // Fake desktop behind the translucent overlay so the backdrop is visible in the preview.
        let colors = [CGColor(srgbRed: 0.16, green: 0.32, blue: 0.55, alpha: 1),
                      CGColor(srgbRed: 0.55, green: 0.30, blue: 0.45, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: pts.height), end: CGPoint(x: pts.width, y: 0), options: [])
        }
        c.root.render(in: ctx)

        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        rep.size = pts
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    // MARK: Panel

    private func ensurePanel() -> PickerPanel {
        if let panel { return panel }
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let p = PickerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let host = CALayer()          // layer-hosting view: we own the (non-flipped) layer tree
        v.layer = host
        v.wantsLayer = true
        v.autoresizingMask = [.width, .height]
        host.addSublayer(canvas.root)
        p.contentView = v
        panel = p
        return p
    }

    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: Window actions (AX)

    private static func activate(_ w: WindowInfo) {
        if let win = w.axWindow {
            AXUIElementSetMessagingTimeout(win, 0.25)
            if w.isMinimized {
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            let app = AXUIElementCreateApplication(w.pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        guard let app = NSRunningApplication(processIdentifier: w.pid) else { return }
        if app.isHidden { app.unhide() }
        if #available(macOS 14.0, *) {
            if NSApp?.isActive == true { NSApp.yieldActivation(to: app) }
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private static func axChild(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    @discardableResult private static func pressClose(_ w: WindowInfo) -> Bool {
        guard let win = w.axWindow else { return false }
        AXUIElementSetMessagingTimeout(win, 0.25)
        guard let button = axChild(win, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    @discardableResult private static func minimize(_ w: WindowInfo) -> Bool {
        guard let win = w.axWindow else { return false }
        AXUIElementSetMessagingTimeout(win, 0.25)
        return AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    @discardableResult private static func toggleFullScreen(_ w: WindowInfo) -> Bool {
        guard let win = w.axWindow else { return false }
        AXUIElementSetMessagingTimeout(win, 0.25)
        if let button = axChild(win, kAXFullScreenButtonAttribute),
           AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            return true
        }
        return AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanTrue) == .success
    }

    // MARK: Enumeration

    static func listWindows() -> [WindowInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        var appByPID: [pid_t: NSRunningApplication] = [:]
        for a in apps where appByPID[a.processIdentifier] == nil { appByPID[a.processIdentifier] = a }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // On-screen windows front-to-back (works without any permission; titles usually empty).
        let cg = cgWindows(appByPID: appByPID)
        var zRank: [pid_t: Int] = [:]
        for (i, w) in cg.enumerated() where zRank[w.pid] == nil { zRank[w.pid] = i }
        func order(_ pid: pid_t) -> Int { pid == frontPID ? -1 : (zRank[pid] ?? Int.max) }

        if AXIsProcessTrusted() {
            let sortedApps = apps.enumerated().sorted {
                let a = order($0.element.processIdentifier), b = order($1.element.processIdentifier)
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element)
            var result: [WindowInfo] = []
            for app in sortedApps {
                let pid = app.processIdentifier
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, 0.25)
                var value: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
                guard err == .success else {
                    // App does not answer AX: show its on-screen windows without AX handles.
                    result += cg.filter { $0.pid == pid }
                    continue
                }
                guard let axWindows = value as? [AXUIElement] else { continue }
                let name = app.localizedName ?? "?"
                let icon = app.icon
                for win in axWindows {
                    AXUIElementSetMessagingTimeout(win, 0.25)
                    guard axString(win, kAXSubroleAttribute) == kAXStandardWindowSubrole else { continue }
                    let minimized = axBool(win, kAXMinimizedAttribute) ?? false
                    let frame = axFrame(win) ?? .zero
                    if !minimized, frame.width < 50 || frame.height < 40 { continue }
                    result.append(WindowInfo(pid: pid, appName: name, title: axString(win, kAXTitleAttribute) ?? "",
                                             icon: icon, axWindow: win, frame: frame, isMinimized: minimized))
                }
            }
            if !result.isEmpty { return result }
        }

        // Fallback: CGWindowList, frontmost app's windows first, rest in z-order.
        return cg.filter { $0.pid == frontPID } + cg.filter { $0.pid != frontPID }
    }

    private static func cgWindows(appByPID: [pid_t: NSRunningApplication]) -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var out: [WindowInfo] = []
        for d in raw {
            guard (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let app = appByPID[pid],
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  frame.width >= 100, frame.height >= 60
            else { continue }
            if let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.01 { continue }
            let title = d[kCGWindowName as String] as? String ?? ""
            out.append(WindowInfo(pid: pid, appName: app.localizedName ?? (d[kCGWindowOwnerName as String] as? String ?? "?"),
                                  title: title, icon: app.icon, axWindow: nil, frame: frame, isMinimized: false))
        }
        return out
    }

    private static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func axBool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    private static func axFrame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    private static func fakeWindows(count: Int) -> [WindowInfo] {
        let entries: [(String, String, String)] = [
            ("Safari", "/Applications/Safari.app", "Apple — Официальный сайт"),
            ("Finder", "/System/Library/CoreServices/Finder.app", "Загрузки"),
            ("Terminal", "/System/Applications/Utilities/Terminal.app", "zsh — 120×40"),
            ("Notes", "/System/Applications/Notes.app", ""),
            ("Mail", "/System/Applications/Mail.app", "Входящие — 12 непрочитанных сообщений от коллег и рассылок, которые никто не читает"),
            ("Calendar", "/System/Applications/Calendar.app", "Ноябрь 2026"),
            ("Music", "/System/Applications/Music.app", "Недавно добавленные"),
            ("System Settings", "/System/Applications/System Settings.app", "Конфиденциальность и безопасность"),
        ]
        return (0..<max(1, count)).map { i in
            let e = entries[i % entries.count]
            return WindowInfo(pid: pid_t(1000 + i), appName: e.0, title: e.2, icon: NSWorkspace.shared.icon(forFile: e.1),
                              axWindow: nil, frame: CGRect(x: 40 * i, y: 40 * i, width: 900, height: 600), isMinimized: i == 6)
        }
    }
}

// MARK: - Panel that never takes focus

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Layer tree (shared by the live overlay and the offscreen debug render)

/// Glass look (see Theme.swift): dark vignetted backdrop, glass cards with a gradient selection border,
/// minimal round buttons in the card's top-right corner, gradient dwell rings.
@MainActor private final class PickerCanvas {
    let root = CALayer()
    private let vignette = CAGradientLayer()
    private let header = CALayer()
    private let hint = CALayer()
    // pointer: white dot + dwell ring (conic accent gradient masked by an arc)
    private let pointer = CALayer()
    private let dot = CALayer()
    private let track = CAShapeLayer()
    private let ring = CAGradientLayer()
    private let ringArc = CAShapeLayer()
    // dwell ring shown around the focused button instead of around the pointer
    private let buttonRing = CALayer()
    private let buttonTrack = CAShapeLayer()
    private let buttonRingGradient = CAGradientLayer()
    private let buttonRingArc = CAShapeLayer()

    private var tiles: [CALayer] = []
    private var selections: [CALayer] = []         // per tile: glow + gradient border (opacity 0/1)
    private(set) var tileFrames: [CGRect] = []     // layer coords (origin bottom-left), unscaled
    private var buttons: [[CALayer]] = []          // per tile, by PickerButtonKind.rawValue; [] if no AX handle
    private var buttonFills: [[CALayer]] = []
    private var buttonCenters: [[CGPoint]] = []    // layer coords, unscaled tile
    private var buttonRadius: CGFloat = 15
    private(set) var highlightedTile: Int?
    private var focusedButton: PickerTarget?
    private var size: CGSize = .zero
    private var progressValue: CGFloat = 0

    private static let hintText = "Задержите палец на окне или кнопке · ладонь → кулак — закрыть"
    private static let pointerBox: CGFloat = 48
    private static let ringDiameter: CGFloat = 34
    private static let ringWidth: CGFloat = 3
    private static let highlightScale: CGFloat = 1.05
    private static let focusScale: CGFloat = 1.2
    private static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    /// Left-to-right slot of each button in the right-aligned group.
    private static func slot(_ k: PickerButtonKind) -> Int {
        switch k {
        case .minimize: return 0
        case .fullscreen: return 1
        case .close: return 2
        }
    }
    private static func symbolName(_ k: PickerButtonKind) -> String {
        switch k {
        case .close: return "xmark"
        case .minimize: return "minus"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        }
    }
    /// Conic colors so that a clockwise sweep from 12 o'clock goes blue → violet → magenta.
    private static var conicAccent: [CGColor] { Theme.accentGradient.reversed() }

    init() {
        root.backgroundColor = CGColor(gray: 0, alpha: 0.58)
        vignette.type = .radial
        vignette.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.4)]
        vignette.locations = [0, 0.5, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.05, y: 1.1)
        root.addSublayer(vignette)
        root.addSublayer(header)
        root.addSublayer(hint)

        // Pointer
        let b = PickerCanvas.pointerBox
        pointer.bounds = CGRect(x: 0, y: 0, width: b, height: b)
        let c = CGPoint(x: b / 2, y: b / 2)
        PickerCanvas.setupRing(container: pointer, track: track, gradient: ring, arc: ringArc,
                               radius: PickerCanvas.ringDiameter / 2, colors: PickerCanvas.conicAccent)
        dot.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        dot.position = c
        dot.cornerRadius = 9
        dot.backgroundColor = CGColor(gray: 1, alpha: 1)
        dot.borderWidth = 0.5
        dot.borderColor = CGColor(gray: 0, alpha: 0.18)
        dot.shadowColor = CGColor(gray: 1, alpha: 1)
        dot.shadowOpacity = 0.7
        dot.shadowRadius = 9
        dot.shadowOffset = .zero
        dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
        pointer.addSublayer(dot)
        pointer.zPosition = 10
        pointer.isHidden = true
        root.addSublayer(pointer)

        buttonRing.bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
        buttonRing.zPosition = 9
        buttonRing.opacity = 0
        PickerCanvas.setupRing(container: buttonRing, track: buttonTrack, gradient: buttonRingGradient, arc: buttonRingArc,
                               radius: 24, colors: PickerCanvas.conicAccent)
        root.addSublayer(buttonRing)
    }

    /// Track circle + conic gradient masked by a progress arc (starts at 12 o'clock, clockwise).
    private static func setupRing(container: CALayer, track: CAShapeLayer, gradient: CAGradientLayer, arc: CAShapeLayer,
                                  radius: CGFloat, colors: [CGColor]) {
        let bounds = container.bounds
        track.frame = bounds
        track.fillColor = nil
        track.strokeColor = CGColor(gray: 1, alpha: 0.16)
        track.lineWidth = ringWidth
        track.opacity = 0
        container.addSublayer(track)
        gradient.type = .conic
        gradient.frame = bounds
        gradient.colors = colors
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.opacity = 0
        arc.frame = bounds
        arc.fillColor = nil
        arc.strokeColor = CGColor(gray: 0, alpha: 1)
        arc.lineWidth = ringWidth
        arc.lineCap = .round
        arc.strokeEnd = 0
        gradient.mask = arc
        container.addSublayer(gradient)
        setRingRadius(radius, track: track, arc: arc, in: bounds)
    }

    private static func setRingRadius(_ r: CGFloat, track: CAShapeLayer, arc: CAShapeLayer, in bounds: CGRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let p = CGMutablePath()
        p.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        track.path = p
        arc.path = p
    }

    func toLayer(_ n: CGPoint) -> CGPoint {
        CGPoint(x: n.x * size.width, y: (1 - n.y) * size.height)
    }

    // MARK: Hit testing

    /// Nearest tile center, with a little hysteresis around the current tile to avoid flicker.
    func nearestTile(to p: CGPoint, current: Int?) -> Int? {
        guard !tileFrames.isEmpty else { return nil }
        func dist(_ i: Int) -> CGFloat { hypot(tileFrames[i].midX - p.x, tileFrames[i].midY - p.y) }
        var best = 0, bestD = CGFloat.greatestFiniteMagnitude
        for i in tileFrames.indices {
            let d = dist(i)
            if d < bestD { best = i; bestD = d }
        }
        if let cur = current, cur < tileFrames.count, cur != best,
           !tileFrames[best].contains(p),
           dist(cur) <= bestD + tileFrames[cur].width * 0.08 {
            return cur
        }
        return best
    }

    /// Button within 1.3× its radius (the currently targeted button stays sticky up to 1.5×), else nearest tile.
    func resolve(_ p: CGPoint, current: PickerTarget?) -> PickerTarget? {
        if case .button(let ci, let ck)? = current, let c = buttonCenter(ci, ck.rawValue),
           hypot(c.x - p.x, c.y - p.y) <= 1.5 * visualRadius(ci) {
            return current
        }
        var best: PickerTarget?
        var bestD = CGFloat.greatestFiniteMagnitude
        for i in buttonCenters.indices {
            let limit = 1.3 * visualRadius(i)
            for k in buttonCenters[i].indices {
                guard let c = buttonCenter(i, k) else { continue }
                let d = hypot(c.x - p.x, c.y - p.y)
                if d <= limit, d < bestD, let kind = PickerButtonKind(rawValue: k) {
                    best = .button(i, kind)
                    bestD = d
                }
            }
        }
        if let best { return best }
        // only a tile actually under the pointer (small margin around the current one against flicker)
        if let cur = current?.tile, cur < tileFrames.count,
           tileFrames[cur].insetBy(dx: -tileFrames[cur].width * 0.04, dy: -tileFrames[cur].height * 0.04).contains(p) {
            return .tile(cur)
        }
        return tileFrames.firstIndex(where: { $0.contains(p) }).map { .tile($0) }
    }

    /// Visual button center: the highlighted tile is scaled about its center.
    private func buttonCenter(_ i: Int, _ k: Int) -> CGPoint? {
        guard i < buttonCenters.count, k < buttonCenters[i].count else { return nil }
        let c = buttonCenters[i][k]
        guard i == highlightedTile else { return c }
        let f = tileFrames[i], m = PickerCanvas.highlightScale
        return CGPoint(x: f.midX + (c.x - f.midX) * m, y: f.midY + (c.y - f.midY) * m)
    }

    private func visualRadius(_ i: Int) -> CGFloat {
        buttonRadius * (i == highlightedTile ? PickerCanvas.highlightScale : 1)
    }

    // MARK: Layout

    func build(windows: [WindowInfo], buttons hasButtons: [Bool], size: CGSize, scale: CGFloat) {
        self.size = size
        vignette.frame = CGRect(origin: .zero, size: size)
        for l in [root, vignette, header, hint, pointer, dot, track, ring, ringArc,
                  buttonRing, buttonTrack, buttonRingGradient, buttonRingArc] { l.contentsScale = scale }

        tiles.forEach { $0.removeFromSuperlayer() }
        tiles = []
        selections = []
        tileFrames = []
        buttons = []
        buttonFills = []
        buttonCenters = []
        highlightedTile = nil
        focusedButton = nil
        progressValue = 0
        buttonRing.opacity = 0

        let n = windows.count
        var gridTop = size.height / 2
        if n > 0 {
            let cols = max(1, min(6, n, Int(ceil(sqrt(Double(n) * 1.6)))))
            let rows = (n + cols - 1) / cols
            let baseW: CGFloat = 248, baseH: CGFloat = 176, baseGap: CGFloat = 24
            let topMargin: CGFloat = 120, bottomReserve: CGFloat = 110
            let availW = size.width * 0.92, availH = max(100, size.height - topMargin - bottomReserve)
            let gridW1 = CGFloat(cols) * baseW + CGFloat(cols - 1) * baseGap
            let gridH1 = CGFloat(rows) * baseH + CGFloat(rows - 1) * baseGap
            let s = max(0.3, min(1.1, availW / gridW1, availH / gridH1))
            let tw = (baseW * s).rounded(), th = (baseH * s).rounded(), gap = (baseGap * s).rounded()
            let gridH = CGFloat(rows) * th + CGFloat(rows - 1) * gap
            let centerY = bottomReserve + availH / 2
            gridTop = (centerY + gridH / 2).rounded()
            let radius = max(10, (18 * s).rounded())

            // Window buttons: ≈30 pt round glass buttons (min 24 pt), right-aligned group in the top-right corner.
            let inset = max(6, (12 * s).rounded()), spacing = max(4, (8 * s).rounded())
            let d = min(max(24, (30 * s).rounded()), ((tw - 2 * inset - 2 * spacing) / 3).rounded(.down))
            buttonRadius = d / 2
            let groupW = 3 * d + 2 * spacing
            let glyphSize = max(10, (12 * s).rounded())
            let symbolImages = PickerButtonKind.allCases.map {
                PickerCanvas.symbolImage(PickerCanvas.symbolName($0), side: d, pointSize: glyphSize, scale: scale)
            }
            PickerCanvas.setRingRadius(d * PickerCanvas.focusScale / 2 + 5, track: buttonTrack, arc: buttonRingArc,
                                       in: buttonRing.bounds)

            for (i, w) in windows.enumerated() {
                let r = i / cols, col = i % cols
                let inRow = min(cols, n - r * cols)
                let rowW = CGFloat(inRow) * tw + CGFloat(inRow - 1) * gap
                let x = (size.width / 2 - rowW / 2).rounded() + CGFloat(col) * (tw + gap)
                let y = gridTop - CGFloat(r) * (th + gap) - th
                let frame = CGRect(x: x, y: y, width: tw, height: th)
                let bounds = CGRect(origin: .zero, size: frame.size)
                let cardPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

                // Glass card
                let t = CALayer()
                t.frame = frame
                t.contentsScale = scale
                t.cornerRadius = radius
                t.cornerCurve = .continuous
                t.backgroundColor = Theme.surface.cgColor
                t.borderWidth = 1
                t.borderColor = Theme.hairline.cgColor
                t.shadowColor = CGColor(gray: 0, alpha: 1)
                t.shadowOpacity = 0.28
                t.shadowRadius = 16
                t.shadowOffset = CGSize(width: 0, height: -6)
                t.shadowPath = cardPath

                // Soft top sheen
                let sheen = CAGradientLayer()
                sheen.frame = bounds
                sheen.cornerRadius = radius
                sheen.cornerCurve = .continuous
                sheen.masksToBounds = true
                sheen.colors = [CGColor(gray: 1, alpha: 0.07), CGColor(gray: 1, alpha: 0)]
                sheen.locations = [0, 0.6]
                sheen.startPoint = CGPoint(x: 0.5, y: 1)
                sheen.endPoint = CGPoint(x: 0.5, y: 0)
                t.addSublayer(sheen)

                // Selection: soft accent glow + 2 pt accent-gradient border (gradient masked by a bordered layer)
                let sel = CALayer()
                sel.frame = bounds
                sel.opacity = 0
                let glow = CAShapeLayer()           // stroke under the gradient border; its shadow is the glow
                glow.frame = bounds
                glow.contentsScale = scale
                glow.path = cardPath
                glow.fillColor = nil
                glow.strokeColor = Theme.accentB.cgColor
                glow.lineWidth = 2
                glow.shadowPath = cardPath.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 1)
                glow.shadowColor = Theme.accentB.cgColor
                glow.shadowOpacity = 0.95
                glow.shadowRadius = 18
                glow.shadowOffset = .zero
                sel.addSublayer(glow)
                let border = CAGradientLayer()
                border.frame = bounds
                border.colors = Theme.accentGradient
                border.startPoint = CGPoint(x: 0, y: 1)
                border.endPoint = CGPoint(x: 1, y: 0)
                let borderMask = CALayer()
                borderMask.frame = bounds
                borderMask.cornerRadius = radius
                borderMask.cornerCurve = .continuous
                borderMask.borderWidth = 2
                borderMask.borderColor = CGColor(gray: 0, alpha: 1)
                border.mask = borderMask
                sel.addSublayer(border)
                t.addSublayer(sel)

                let content = CALayer()
                content.frame = bounds
                content.contentsScale = scale
                content.contents = PickerCanvas.tileImage(w, size: frame.size, s: s, scale: scale)
                t.addSublayer(content)

                var bl: [CALayer] = [], fl: [CALayer] = [], centers: [CGPoint] = []
                if i < hasButtons.count && hasButtons[i] {
                    for kind in PickerButtonKind.allCases {
                        let local = CGPoint(x: tw - inset - groupW + d / 2 + CGFloat(PickerCanvas.slot(kind)) * (d + spacing),
                                            y: th - inset - d / 2)
                        let glowColor = kind == .close ? Theme.danger.cgColor : Theme.accentB.cgColor
                        let b = CALayer()
                        b.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                        b.position = local
                        b.contentsScale = scale
                        b.cornerRadius = d / 2
                        b.backgroundColor = CGColor(gray: 1, alpha: 0.12)
                        b.borderWidth = 1
                        b.borderColor = Theme.hairline.cgColor
                        b.opacity = 0
                        b.shadowColor = glowColor
                        b.shadowOpacity = 0
                        b.shadowRadius = 12
                        b.shadowOffset = .zero
                        b.shadowPath = CGPath(ellipseIn: b.bounds, transform: nil)
                        let fill: CALayer
                        if kind == .close {
                            fill = CALayer()
                            fill.backgroundColor = Theme.danger.cgColor
                        } else {
                            let g = CAGradientLayer()
                            g.colors = Theme.accentGradient
                            g.startPoint = CGPoint(x: 0, y: 1)
                            g.endPoint = CGPoint(x: 1, y: 0)
                            fill = g
                        }
                        fill.frame = b.bounds
                        fill.cornerRadius = d / 2
                        fill.masksToBounds = true
                        fill.opacity = 0
                        b.addSublayer(fill)
                        let sym = CALayer()
                        sym.frame = b.bounds
                        sym.contentsScale = scale
                        sym.contents = symbolImages[kind.rawValue]
                        b.addSublayer(sym)
                        t.addSublayer(b)
                        bl.append(b)
                        fl.append(fill)
                        centers.append(CGPoint(x: frame.minX + local.x, y: frame.minY + local.y))
                    }
                }
                root.insertSublayer(t, below: header)
                tiles.append(t)
                selections.append(sel)
                tileFrames.append(frame)
                buttons.append(bl)
                buttonFills.append(fl)
                buttonCenters.append(centers)
            }
        }

        if let img = PickerCanvas.headerImage(count: n, scale: scale) {
            let hs = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
            header.contents = img
            header.frame = CGRect(x: ((size.width - hs.width) / 2).rounded(), y: (gridTop + 30).rounded(),
                                  width: hs.width, height: hs.height)
            header.isHidden = header.frame.maxY > size.height - 8
        }
        if let img = PickerCanvas.hintImage(scale: scale) {
            let hs = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
            hint.contents = img
            hint.frame = CGRect(x: ((size.width - hs.width) / 2).rounded(), y: 36, width: hs.width, height: hs.height)
        }
    }

    // MARK: State

    /// Lifts the target's tile (scale, gradient border, glow, buttons fade in) and fills/glows a targeted button.
    func setTarget(_ t: PickerTarget?, animated: Bool) {
        let newTile = t?.tile
        var newFocus: PickerTarget?
        if case .button? = t { newFocus = t }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(PickerCanvas.ease)
        if newFocus != focusedButton, case .button(let i, let k)? = focusedButton {
            styleButton(i, k.rawValue, focused: false)
        }
        if newTile != highlightedTile {
            if let old = highlightedTile { styleTile(old, on: false) }
            if let nt = newTile { styleTile(nt, on: true) }
            highlightedTile = newTile
        }
        if newFocus != focusedButton, case .button(let i, let k)? = newFocus {
            styleButton(i, k.rawValue, focused: true)
        }
        focusedButton = newFocus
        CATransaction.commit()

        // Park the button dwell ring on the focused button (final, lifted position).
        if case .button(let i, let k)? = newFocus, let c = buttonCenter(i, k.rawValue) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            buttonRing.position = CGPoint(x: c.x.rounded(), y: c.y.rounded())
            buttonRingGradient.colors = k == .close
                ? [Theme.danger.cgColor, NSColor(srgbRed: 1, green: 0.55, blue: 0.5, alpha: 1).cgColor, Theme.danger.cgColor]
                : PickerCanvas.conicAccent
            CATransaction.commit()
        }
        applyProgress()
    }

    private func styleTile(_ k: Int, on: Bool) {
        guard k < tiles.count else { return }
        let t = tiles[k]
        let m = PickerCanvas.highlightScale
        t.transform = on ? CATransform3DMakeScale(m, m, 1) : CATransform3DIdentity
        t.backgroundColor = on ? CGColor(gray: 1, alpha: 0.14) : Theme.surface.cgColor
        t.borderColor = on ? CGColor(gray: 1, alpha: 0) : Theme.hairline.cgColor
        t.shadowOpacity = on ? 0.55 : 0.28
        t.shadowRadius = on ? 30 : 16
        t.shadowOffset = CGSize(width: 0, height: on ? -16 : -6)
        t.zPosition = on ? 1 : 0
        selections[k].opacity = on ? 1 : 0
        for b in buttons[k] { b.opacity = on ? 1 : 0 }
    }

    private func styleButton(_ i: Int, _ k: Int, focused: Bool) {
        guard i < buttons.count, k < buttons[i].count else { return }
        let b = buttons[i][k]
        let m = PickerCanvas.focusScale
        b.transform = focused ? CATransform3DMakeScale(m, m, 1) : CATransform3DIdentity
        b.shadowOpacity = focused ? 0.9 : 0
        b.borderColor = focused ? CGColor(gray: 1, alpha: 0.35) : Theme.hairline.cgColor
        b.zPosition = focused ? 2 : 0
        buttonFills[i][k].opacity = focused ? 1 : 0
    }

    /// Immediate feedback after close/minimize while the window list is being refreshed.
    func setTileDimmed(_ i: Int) {
        guard i < tiles.count else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        tiles[i].opacity = 0.3
        CATransaction.commit()
    }

    func setPointer(_ p: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let p {
            pointer.position = CGPoint(x: p.x.rounded(), y: p.y.rounded())
            pointer.isHidden = false
        } else {
            pointer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Dwell progress 0...1: ring around the focused button if a button is targeted, else around the pointer.
    func setPinch(_ v: CGFloat) {
        progressValue = v
        applyProgress()
    }

    private func applyProgress() {
        let v = progressValue
        let onButton = focusedButton != nil
        let show = v > 0.01
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringArc.strokeEnd = v
        buttonRingArc.strokeEnd = v
        let pointerRing: Float = show && !onButton ? 1 : 0
        track.opacity = pointerRing
        ring.opacity = pointerRing
        buttonTrack.opacity = 1
        buttonRingGradient.opacity = 1
        buttonRing.opacity = show && onButton ? 1 : 0
        // On a button the dot shrinks so the button glyph stays readable; on a tile it tightens as the ring fills.
        let k = onButton ? 0.5 : 1 - 0.15 * v
        dot.transform = CATransform3DMakeScale(k, k, 1)
        dot.shadowOpacity = onButton ? 0.35 : 0.7
        CATransaction.commit()
    }

    // MARK: Static images (drawn once per build)

    /// Draws into a bitmap with a flipped (top-left origin) AppKit context.
    private static func makeImage(size: CGSize, scale: CGFloat, draw: (CGRect) -> Void) -> CGImage? {
        let w = Int(ceil(size.width * scale)), h = Int(ceil(size.height * scale))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Line height the text system actually uses (SF Rounded is taller than ascender - descender).
    private static func lineHeight(_ f: NSFont) -> CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: f)) }

    /// SF Symbol tinted with `color`, centered in a `side`×`side` box (natural symbol size).
    private static func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, in box: CGRect) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let img = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        else { return }
        let sz = img.size
        let r = CGRect(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2, width: sz.width, height: sz.height)
        // Tint: draw into its own transparency layer, then fill with sourceAtop.
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(in: r.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill()
        r.insetBy(dx: -2, dy: -2).fill(using: .sourceAtop)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func symbolImage(_ name: String, side: CGFloat, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        makeImage(size: CGSize(width: side, height: side), scale: scale) { rect in
            drawSymbol(name, pointSize: pointSize, weight: .semibold, color: .white, in: rect)
        }
    }

    /// Card content: icon (top-left, soft shadow), app name, window title (2 lines).
    private static func tileImage(_ w: WindowInfo, size: CGSize, s: CGFloat, scale: CGFloat) -> CGImage? {
        makeImage(size: size, scale: scale) { rect in
            let trunc = NSMutableParagraphStyle()
            trunc.lineBreakMode = .byTruncatingTail
            let wrap = NSMutableParagraphStyle()
            wrap.lineBreakMode = .byWordWrapping

            let f = min(1, s)                      // type and icon never grow past the spec sizes
            let nameFont = Theme.font(max(10, 15 * f), .semibold)
            let titleFont = Theme.font(max(9, 12.5 * f))
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: Theme.textPrimary, .paragraphStyle: trunc]
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: Theme.textSecondary, .paragraphStyle: wrap]
            let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]

            let pad = (18 * s).rounded()
            let iconSide = min(72, (68 * s).rounded())
            let textW = rect.width - 2 * pad
            if let icon = w.icon {
                NSGraphicsContext.saveGraphicsState()
                let sh = NSShadow()
                sh.shadowColor = NSColor(white: 0, alpha: 0.45)
                sh.shadowBlurRadius = 8 * s
                sh.shadowOffset = NSSize(width: 0, height: -3 * s)
                sh.set()
                icon.draw(in: CGRect(x: pad - 4 * s, y: pad - 4 * s, width: iconSide, height: iconSide),
                          from: .zero, operation: .sourceOver, fraction: w.isMinimized ? 0.5 : 1,
                          respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
                NSGraphicsContext.restoreGraphicsState()
            }
            var y = pad + iconSide - 4 * s + 10 * s
            let nameH = lineHeight(nameFont)
            (w.appName as NSString).draw(with: CGRect(x: pad, y: y, width: textW, height: nameH), options: opts, attributes: nameAttrs)
            y += nameH + 2 * s
            if !w.title.isEmpty {
                let maxH = min(lineHeight(titleFont) * 2 + 2, rect.height - y - 4 * s)
                if maxH > lineHeight(titleFont) * 0.9 {
                    (w.title as NSString).draw(with: CGRect(x: pad, y: y, width: textW, height: maxH), options: opts, attributes: titleAttrs)
                }
            }
            if w.isMinimized {
                // small glass pill to the right of the icon
                let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font(max(8, 11 * s), .medium), .foregroundColor: Theme.textSecondary]
                let str = "свёрнуто" as NSString
                let ts = str.size(withAttributes: attrs)
                let pill = CGRect(x: pad + iconSide + 4 * s, y: pad + iconSide - 4 * s - ts.height - 8 * s,
                                  width: ts.width + 14 * s, height: ts.height + 6 * s)
                let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
                NSColor(white: 1, alpha: 0.10).setFill()
                path.fill()
                Theme.hairline.setStroke()
                path.lineWidth = 1
                path.stroke()
                str.draw(at: CGPoint(x: pill.minX + 7 * s, y: pill.minY + 3 * s), withAttributes: attrs)
            }
        }
    }

    /// «Окна» + count pill, shown above the grid.
    private static func headerImage(count: Int, scale: CGFloat) -> CGImage? {
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: Theme.font(22, .bold), .foregroundColor: Theme.textPrimary]
        let countAttrs: [NSAttributedString.Key: Any] = [.font: Theme.font(13, .semibold), .foregroundColor: Theme.textSecondary]
        let title = "Окна" as NSString, num = "\(count)" as NSString
        let ts = title.size(withAttributes: titleAttrs), cs = num.size(withAttributes: countAttrs)
        let pillW = max(cs.width + 16, 26), pillH = cs.height + 6
        let size = CGSize(width: ceil(ts.width + 10 + pillW) + 2, height: ceil(ts.height) + 2)
        return makeImage(size: size, scale: scale) { rect in
            title.draw(at: CGPoint(x: 1, y: 1), withAttributes: titleAttrs)
            let pill = CGRect(x: 1 + ts.width + 10, y: (rect.height - pillH) / 2 + 1, width: pillW, height: pillH)
            let p = NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2)
            NSColor(white: 1, alpha: 0.10).setFill()
            p.fill()
            Theme.hairline.setStroke()
            p.lineWidth = 1
            p.stroke()
            num.draw(at: CGPoint(x: pill.midX - cs.width / 2, y: pill.midY - cs.height / 2), withAttributes: countAttrs)
        }
    }

    /// Bottom glass pill with a hand glyph and the hint text.
    private static func hintImage(scale: CGFloat) -> CGImage? {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font(13, .medium), .foregroundColor: Theme.textSecondary]
        let text = hintText as NSString
        let ts = text.size(withAttributes: attrs)
        let glyph: CGFloat = 16, padX: CGFloat = 16, gapG: CGFloat = 8
        let h = max(34, ceil(ts.height) + 16)
        let size = CGSize(width: ceil(padX + glyph + gapG + ts.width + padX), height: h)
        return makeImage(size: size, scale: scale) { rect in
            let pill = rect.insetBy(dx: 0.5, dy: 0.5)
            let p = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            NSColor(white: 0, alpha: 0.30).setFill()
            p.fill()
            NSColor(white: 1, alpha: 0.07).setFill()
            p.fill()
            Theme.hairline.setStroke()
            p.lineWidth = 1
            p.stroke()
            drawSymbol("hand.point.up.left", pointSize: 13, weight: .medium, color: Theme.textSecondary,
                       in: CGRect(x: padX, y: 0, width: glyph, height: rect.height))
            text.draw(at: CGPoint(x: padX + glyph + gapG, y: (rect.height - ts.height) / 2), withAttributes: attrs)
        }
    }
}
