import AppKit
import AVFoundation
import QuartzCore

// MARK: - HUD (public API)

/// Floating glass panel with the mirrored webcam picture, the live hand skeleton and a
/// status row. Draggable, never takes focus. Can collapse into a compact status pill.
@MainActor final class HUD {
    /// Help button pressed.
    var onHelp: (() -> Void)?
    var onQuit: (() -> Void)?                 // power button: quit the app
    /// Camera hidden/shown via the panel's eye button (not called for `setCollapsed`).
    var onCollapsedChanged: ((Bool) -> Void)?
    private(set) var isCollapsed = false

    private let canvas: HUDCanvas
    private var panel: HUDPanel?
    private var rootView: HUDRootView?
    private var mirrorFallbackApplied = false
    private var isAnimating = false
    private var clampPending = false
    private var observers: [NSObjectProtocol] = []

    // Last state, so show()/expand can re-apply what update() skipped.
    private var lastHand: HandFrame?
    private var lastMode: GestureMode = .idle
    private var lastLabel: String = ""

    private static let autosaveName = "GestureHUD"

    init(session: AVCaptureSession?) {
        canvas = HUDCanvas(session: session, scale: NSScreen.main?.backingScaleFactor ?? 2)
        canvas.setCollapsedImmediately(false)
        canvas.layout(size: HUDMetrics.size(collapsed: false))
        canvas.apply(hand: nil, mode: lastMode, label: lastLabel, collapsed: false)
        configureMirroring()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if let panel {
            clampToScreen(panel, animated: false)
        } else {
            let p = makePanel()
            panel = p
            restoreFrame(p)
        }
        canvas.apply(hand: lastHand, mode: lastMode, label: lastLabel, collapsed: isCollapsed)
        configureMirroring()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Called on main thread ~30 times/s. hand == nil → no skeleton.
    func update(hand: HandFrame?, mode: GestureMode, label: String) {
        lastHand = hand
        lastMode = mode
        lastLabel = label
        // The preview connection may only appear after the session starts: retry here.
        configureMirroring()
        guard isVisible else { return }
        canvas.apply(hand: hand, mode: mode, label: label, collapsed: isCollapsed)
    }

    /// Programmatic collapse (e.g. menu item «Показывать камеру»). Does not call onCollapsedChanged.
    func setCollapsed(_ c: Bool) {
        setCollapsed(c, notify: false)
    }

    /// Debug: offscreen render to PNG (camera area dark, fake desktop behind the glass), no window shown.
    func renderDebugPNG(to url: URL, hand: HandFrame?, mode: GestureMode, label: String,
                        collapsed: Bool = false) {
        let scale: CGFloat = 2
        let c = HUDCanvas(session: nil, scale: scale)
        let size = HUDMetrics.size(collapsed: collapsed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        c.root.frame = CGRect(origin: .zero, size: size)
        c.setCollapsedImmediately(collapsed)
        c.layout(size: size)
        c.apply(hand: hand, mode: mode, label: label, collapsed: collapsed)
        CATransaction.commit()

        let margin: CGFloat = 28
        let stage = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        let pw = Int(stage.width * scale), ph = Int(stage.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            NSLog("HUD.renderDebugPNG: cannot create bitmap context")
            return
        }
        ctx.scaleBy(x: scale, y: scale)

        // Fake desktop.
        let colors = [CGColor(srgbRed: 0.16, green: 0.32, blue: 0.55, alpha: 1),
                      CGColor(srgbRed: 0.55, green: 0.30, blue: 0.45, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: stage.height),
                                   end: CGPoint(x: stage.width, y: 0), options: [])
        }

        // Approximation of Theme.glass (the real one is a behind-window blur).
        let panelRect = CGRect(origin: CGPoint(x: margin, y: margin), size: size)
        let radius = min(Theme.panelRadius, size.height / 2)
        let shape = CGPath(roundedRect: panelRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        let outside = CGMutablePath()
        outside.addRect(CGRect(origin: .zero, size: stage))
        outside.addPath(shape)
        ctx.addPath(outside)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.80))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: panelRect.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
        ctx.setStrokeColor(Theme.hairline.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        ctx.translateBy(x: margin, y: margin)
        c.root.render(in: ctx)

        guard let image = ctx.makeImage() else {
            NSLog("HUD.renderDebugPNG: cannot make image")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = stage
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("HUD.renderDebugPNG: PNG encoding failed")
            return
        }
        do {
            try data.write(to: url)
        } catch {
            NSLog("HUD.renderDebugPNG: write failed: \(error)")
        }
    }

    // MARK: Collapse

    private func setCollapsed(_ c: Bool, notify: Bool) {
        guard c != isCollapsed else { return }
        isCollapsed = c
        canvas.apply(hand: lastHand, mode: lastMode, label: lastLabel, collapsed: c)
        let newSize = HUDMetrics.size(collapsed: c)

        if let panel, panel.isVisible {
            let anchors = Self.anchors(for: panel.frame)
            canvas.anchorRight = anchors.right
            canvas.anchorBottom = anchors.bottom
            let target = Self.clamped(Self.anchoredFrame(from: panel.frame, size: newSize))
            canvas.beginTransition(toCollapsed: c, duration: 0.2)
            rootView?.layoutContent()
            isAnimating = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.finishTransition() }
            })
        } else {
            canvas.setCollapsedImmediately(c)
            if let panel {
                let anchors = Self.anchors(for: panel.frame)
                canvas.anchorRight = anchors.right
                canvas.anchorBottom = anchors.bottom
                panel.setFrame(Self.clamped(Self.anchoredFrame(from: panel.frame, size: newSize)), display: false)
                rootView?.layoutContent()
            }
        }
        if notify { onCollapsedChanged?(c) }
    }

    private func finishTransition() {
        isAnimating = false
        canvas.endTransition()
        rootView?.layoutContent()
        panel?.invalidateShadow()
        if let panel { clampToScreen(panel, animated: true) }
    }

    private func buttonPressed(_ kind: HUDButton.Kind) {
        switch kind {
        case .help: onHelp?()
        case .quit: onQuit?()
        case .collapse: setCollapsed(true, notify: true)
        case .expand: setCollapsed(false, notify: true)
        }
    }

    // MARK: Panel

    private func makePanel() -> HUDPanel {
        let size = HUDMetrics.size(collapsed: isCollapsed)
        let p = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.isMovable = true
        p.isMovableByWindowBackground = true
        p.isExcludedFromWindowsMenu = true
        p.animationBehavior = .none

        canvas.setCollapsedImmediately(isCollapsed)
        let view = HUDRootView(canvas: canvas, size: size)
        view.onButton = { [weak self] kind in self?.buttonPressed(kind) }
        p.contentView = view
        rootView = view

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDidMove() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.clampToScreen(panel, animated: false)
            }
        })
        return p
    }

    /// Restore the remembered position (keeping the corner nearest to the screen corner),
    /// or default to bottom-right of the visible frame.
    private func restoreFrame(_ panel: HUDPanel) {
        let size = HUDMetrics.size(collapsed: isCollapsed)
        var frame: NSRect
        if panel.setFrameUsingName(Self.autosaveName) {
            frame = Self.anchoredFrame(from: panel.frame, size: size)
        } else {
            let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            frame = NSRect(x: vf.maxX - size.width - HUDMetrics.screenMargin,
                           y: vf.minY + HUDMetrics.screenMargin,
                           width: size.width, height: size.height)
        }
        panel.setFrame(Self.clamped(frame), display: false)
        panel.setFrameAutosaveName(Self.autosaveName)
        rootView?.layoutContent()
    }

    private func panelDidMove() {
        guard !isAnimating, let panel else { return }
        if NSEvent.pressedMouseButtons != 0 {
            // Still dragging: clamp once the mouse is released.
            guard !clampPending else { return }
            clampPending = true
            Task { @MainActor [weak self] in
                while NSEvent.pressedMouseButtons != 0 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let self else { return }
                self.clampPending = false
                if let panel = self.panel { self.clampToScreen(panel, animated: true) }
            }
        } else {
            clampToScreen(panel, animated: true)
        }
    }

    private func clampToScreen(_ panel: NSPanel, animated: Bool) {
        let target = Self.clamped(panel.frame)
        guard target != panel.frame else { return }
        if animated {
            isAnimating = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.isAnimating = false }
            })
        } else {
            panel.setFrame(target, display: false)
        }
    }

    // MARK: Geometry helpers

    private static func screen(for rect: NSRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let i = s.frame.intersection(rect)
            let area = i.isNull ? 0 : i.width * i.height
            if area > bestArea { bestArea = area; best = s }
        }
        return best ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func anchors(for rect: NSRect) -> (right: Bool, bottom: Bool) {
        guard let vf = screen(for: rect)?.visibleFrame else { return (true, true) }
        return (rect.midX > vf.midX, rect.midY < vf.midY)
    }

    /// Resize `rect` to `size`, keeping the corner that is nearest to the screen's corner fixed.
    private static func anchoredFrame(from rect: NSRect, size: CGSize) -> NSRect {
        let a = anchors(for: rect)
        let x = a.right ? rect.maxX - size.width : rect.minX
        let y = a.bottom ? rect.minY : rect.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func clamped(_ rect: NSRect) -> NSRect {
        guard let vf = screen(for: rect)?.visibleFrame else { return rect }
        var r = rect
        r.origin.x = min(max(r.minX, vf.minX), vf.maxX - r.width)
        r.origin.y = min(max(r.minY, vf.minY), vf.maxY - r.height)
        return r
    }

    private func configureMirroring() {
        guard let preview = canvas.preview, let conn = preview.connection else { return }
        if conn.isVideoMirroringSupported {
            if conn.automaticallyAdjustsVideoMirroring { conn.automaticallyAdjustsVideoMirroring = false }
            if !conn.isVideoMirrored { conn.isVideoMirrored = true }
        } else if !mirrorFallbackApplied {
            // Fallback: flip the preview layer itself.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            CATransaction.commit()
            mirrorFallbackApplied = true
        }
    }
}

// MARK: - Metrics

private enum HUDMetrics {
    static let pad: CGFloat = 8
    static let video = CGSize(width: 300, height: 169)        // ~16:9
    static let videoRadius: CGFloat = 14
    static let rowHeight: CGFloat = 32
    static let expanded = CGSize(width: 316, height: 8 + 169 + 32)
    static let collapsed = CGSize(width: 292, height: 40)
    static let screenMargin: CGFloat = 20

    static func size(collapsed c: Bool) -> CGSize { c ? collapsed : expanded }
}

// MARK: - Views

/// Panel that accepts clicks but never becomes key/main (never steals focus).
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Background that drags the window (also over the video area).
private class HUDDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        // Fallback if the window server didn't already start a background drag.
        window?.performDrag(with: event)
    }
}

/// Layer-hosting view for the canvas layer tree.
private final class HUDCanvasView: HUDDragView {}

private final class HUDRootView: HUDDragView {
    let canvas: HUDCanvas
    var onButton: ((HUDButton.Kind) -> Void)?
    private var buttonViews: [HUDButtonView] = []

    init(canvas: HUDCanvas, size: NSSize) {
        self.canvas = canvas
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        autoresizesSubviews = true

        let glass = Theme.glass(cornerRadius: Theme.panelRadius)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        let canvasView = HUDCanvasView(frame: bounds)
        canvasView.layer = canvas.root       // layer-hosting: set layer before wantsLayer
        canvasView.wantsLayer = true
        canvasView.autoresizingMask = [.width, .height]
        addSubview(canvasView)

        // Transparent hit targets above the canvas (layer-hosting views must not have subviews).
        for b in canvas.buttons {
            let v = HUDButtonView(button: b)
            v.onClick = { [weak self] in self?.onButton?(b.kind) }
            addSubview(v)
            buttonViews.append(v)
        }
        layoutContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    func layoutContent() {
        canvas.layout(size: bounds.size)
        for v in buttonViews {
            v.frame = canvas.frameInRoot(v.button)
            let active = canvas.isActive(v.button)
            if v.isHidden == active {
                v.isHidden = !active
                if !active { v.button.hovered = false; v.button.pressed = false }
            }
        }
    }
}

private final class HUDButtonView: NSView {
    let button: HUDButton
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    init(button: HUDButton) {
        self.button = button
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseEntered(with event: NSEvent) { button.hovered = true }
    override func mouseExited(with event: NSEvent) { button.hovered = false; button.pressed = false }

    override func mouseDown(with event: NSEvent) { button.pressed = true }

    override func mouseDragged(with event: NSEvent) {
        button.pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        button.pressed = false
        if inside { onClick?() }
    }
}

// MARK: - Canvas (layer tree shared by the live panel and the offscreen debug render)

@MainActor
private final class HUDCanvas {
    let root = CALayer()
    let expandedGroup = CALayer()
    let collapsedGroup = CALayer()
    let video = CALayer()
    let preview: AVCaptureVideoPreviewLayer?
    let skeleton: HUDSkeleton
    let expandedRow: HUDStatusRow
    let collapsedRow: HUDStatusRow
    let buttons: [HUDButton]

    var anchorRight = true
    var anchorBottom = true
    private(set) var collapsed = false

    init(session: AVCaptureSession?, scale: CGFloat) {
        let m = HUDMetrics.self
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        root.frame = CGRect(origin: .zero, size: m.expanded)
        root.cornerRadius = Theme.panelRadius
        root.cornerCurve = .continuous
        root.masksToBounds = true
        root.contentsScale = scale

        // Expanded: video on top, status row below.
        expandedGroup.frame = CGRect(origin: .zero, size: m.expanded)
        root.addSublayer(expandedGroup)

        video.frame = CGRect(x: m.pad, y: m.rowHeight, width: m.video.width, height: m.video.height)
        video.backgroundColor = CGColor(srgbRed: 0.055, green: 0.055, blue: 0.065, alpha: 1)
        video.cornerRadius = m.videoRadius
        video.cornerCurve = .continuous
        video.masksToBounds = true
        video.borderWidth = 0.5
        video.borderColor = CGColor(gray: 1, alpha: 0.10)
        expandedGroup.addSublayer(video)

        if let session {
            let p = AVCaptureVideoPreviewLayer(session: session)
            p.videoGravity = .resize   // fills the 16:9 area, no letterbox; coords map linearly
            p.backgroundColor = nil
            p.frame = video.bounds
            video.addSublayer(p)
            preview = p
        } else {
            preview = nil
        }

        // Soft top shade so the round buttons read on bright video.
        let shade = CAGradientLayer()
        shade.colors = [CGColor(gray: 0, alpha: 0.32), CGColor(gray: 0, alpha: 0)]
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        shade.frame = CGRect(x: 0, y: m.video.height - 54, width: m.video.width, height: 54)
        video.addSublayer(shade)

        skeleton = HUDSkeleton(frame: video.bounds, scale: scale)
        video.addSublayer(skeleton.container)

        let help = HUDButton(kind: .help, symbol: "questionmark", diameter: 28, pointSize: 12,
                             onVideo: true, scale: scale)
        let collapse = HUDButton(kind: .collapse, symbol: "eye.slash", diameter: 28, pointSize: 12,
                                 onVideo: true, scale: scale)
        let quit = HUDButton(kind: .quit, symbol: "power", diameter: 28, pointSize: 12,
                             onVideo: true, scale: scale)
        let inset: CGFloat = 8
        quit.layer.frame = CGRect(x: m.video.width - inset - 28, y: m.video.height - inset - 28,
                                  width: 28, height: 28)
        collapse.layer.frame = quit.layer.frame.offsetBy(dx: -(28 + 6), dy: 0)
        help.layer.frame = collapse.layer.frame.offsetBy(dx: -(28 + 6), dy: 0)
        video.addSublayer(help.layer)
        video.addSublayer(collapse.layer)
        video.addSublayer(quit.layer)

        expandedRow = HUDStatusRow(parent: expandedGroup, x: m.pad + 7, centerY: m.rowHeight / 2,
                                   maxX: m.expanded.width - m.pad - 7, scale: scale)

        // Collapsed pill: dot + name + label, buttons on the right.
        collapsedGroup.frame = CGRect(origin: .zero, size: m.collapsed)
        root.addSublayer(collapsedGroup)
        let small: CGFloat = 26
        let expand = HUDButton(kind: .expand, symbol: "eye", diameter: small, pointSize: 11,
                               onVideo: false, scale: scale)
        let help2 = HUDButton(kind: .help, symbol: "questionmark", diameter: small, pointSize: 11,
                              onVideo: false, scale: scale)
        let quit2 = HUDButton(kind: .quit, symbol: "power", diameter: small, pointSize: 11,
                              onVideo: false, scale: scale)
        let by = (m.collapsed.height - small) / 2
        quit2.layer.frame = CGRect(x: m.collapsed.width - by - small, y: by, width: small, height: small)
        expand.layer.frame = quit2.layer.frame.offsetBy(dx: -(small + 4), dy: 0)
        help2.layer.frame = expand.layer.frame.offsetBy(dx: -(small + 4), dy: 0)
        collapsedGroup.addSublayer(help2.layer)
        collapsedGroup.addSublayer(expand.layer)
        collapsedGroup.addSublayer(quit2.layer)
        collapsedRow = HUDStatusRow(parent: collapsedGroup, x: 16, centerY: m.collapsed.height / 2,
                                    maxX: help2.layer.frame.minX - 8, scale: scale)

        buttons = [help, collapse, quit, help2, expand, quit2]
    }

    func isActive(_ b: HUDButton) -> Bool {
        (b.layer.superlayer === collapsedGroup) == collapsed
    }

    func frameInRoot(_ b: HUDButton) -> CGRect {
        guard let parent = b.layer.superlayer else { return .zero }
        return root.convert(b.layer.frame, from: parent)
    }

    /// Pin both groups to the anchor corner of the (possibly animating) panel size.
    func layout(size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (g, s) in [(expandedGroup, HUDMetrics.expanded), (collapsedGroup, HUDMetrics.collapsed)] {
            g.frame = CGRect(x: anchorRight ? size.width - s.width : 0,
                             y: anchorBottom ? 0 : size.height - s.height,
                             width: s.width, height: s.height)
        }
        CATransaction.commit()
    }

    func setCollapsedImmediately(_ c: Bool) {
        collapsed = c
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        expandedGroup.isHidden = c
        expandedGroup.opacity = c ? 0 : 1
        collapsedGroup.isHidden = !c
        collapsedGroup.opacity = c ? 1 : 0
        CATransaction.commit()
    }

    func beginTransition(toCollapsed c: Bool, duration: CFTimeInterval) {
        collapsed = c
        let incoming = c ? collapsedGroup : expandedGroup
        let outgoing = c ? expandedGroup : collapsedGroup
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.isHidden = false
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        incoming.opacity = 1
        outgoing.opacity = 0
        CATransaction.commit()
    }

    func endTransition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (collapsed ? expandedGroup : collapsedGroup).isHidden = true
        CATransaction.commit()
    }

    func apply(hand: HandFrame?, mode: GestureMode, label: String, collapsed c: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if c {
            collapsedRow.set(mode: mode, label: label)   // skeleton not visible: skip it
        } else {
            expandedRow.set(mode: mode, label: label)
            skeleton.set(mode: mode)
            skeleton.set(hand: hand)
        }
        CATransaction.commit()
    }
}

// MARK: - Skeleton

@MainActor
private final class HUDSkeleton {
    let container = CALayer()
    private let glow = CAShapeLayer()
    private let fingers: [CAShapeLayer] = (0..<6).map { _ in CAShapeLayer() }   // thumb…little, palm
    private let joints = CAShapeLayer()
    private let tipHalo = CAShapeLayer()
    private let tip = CAShapeLayer()
    private var mode: GestureMode?
    private var hasPaths = false

    /// HandFrame.bones with a group index: 0 thumb, 1 index, 2 middle, 3 ring, 4 little, 5 palm.
    private static let groupedBones: [(Joint, Joint, Int)] = {
        let finger: [Joint: Int] = [
            .thumbCMC: 0, .thumbMP: 0, .thumbIP: 0, .thumbTip: 0,
            .indexMCP: 1, .indexPIP: 1, .indexDIP: 1, .indexTip: 1,
            .middleMCP: 2, .middlePIP: 2, .middleDIP: 2, .middleTip: 2,
            .ringMCP: 3, .ringPIP: 3, .ringDIP: 3, .ringTip: 3,
            .littleMCP: 4, .littlePIP: 4, .littleDIP: 4, .littleTip: 4,
        ]
        let mcps: Set<Joint> = [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
        return HandFrame.bones.map { a, b in
            (a, b, (mcps.contains(a) && mcps.contains(b)) ? 5 : (finger[b] ?? 5))
        }
    }()

    init(frame: CGRect, scale: CGFloat) {
        container.frame = frame
        container.isGeometryFlipped = true   // (0,0) top-left, like HandFrame
        for l in [glow] + fingers + [joints, tipHalo, tip] {
            l.frame = container.bounds
            l.contentsScale = scale
            l.lineCap = .round
            l.lineJoin = .round
            container.addSublayer(l)
        }
        glow.fillColor = nil
        glow.lineWidth = 5
        for f in fingers {
            f.fillColor = nil
            f.lineWidth = 1.5
        }
        joints.fillColor = CGColor(gray: 1, alpha: 0.92)
        joints.strokeColor = nil
        tipHalo.strokeColor = nil
        tip.strokeColor = CGColor(gray: 1, alpha: 0.95)
        tip.lineWidth = 1.25
        tip.shadowOpacity = 1
        tip.shadowRadius = 5
        tip.shadowOffset = .zero
    }

    func set(mode m: GestureMode) {
        guard m != mode else { return }
        mode = m
        let base = Theme.modeColor(m)
        if m == .picker {
            // Accent gradient across the fingers (thumb → little).
            for (i, f) in fingers.prefix(5).enumerated() {
                f.strokeColor = HUDColor.accent(at: CGFloat(i) / 4)
            }
            fingers[5].strokeColor = HUDColor.accent(at: 0.5)
            glow.strokeColor = Theme.accentB.withAlphaComponent(0.38).cgColor
            tip.fillColor = Theme.accentC.cgColor
            tip.shadowColor = Theme.accentC.cgColor
            tipHalo.fillColor = Theme.accentC.withAlphaComponent(0.28).cgColor
        } else {
            for f in fingers { f.strokeColor = base.cgColor }
            glow.strokeColor = base.withAlphaComponent(base.alphaComponent * 0.28).cgColor
            tip.fillColor = base.cgColor
            tip.shadowColor = base.cgColor
            tipHalo.fillColor = base.withAlphaComponent(base.alphaComponent * 0.25).cgColor
        }
    }

    func set(hand: HandFrame?) {
        guard let hand else {
            if hasPaths {
                glow.path = nil
                for f in fingers { f.path = nil }
                joints.path = nil
                tipHalo.path = nil
                tip.path = nil
                tip.shadowPath = nil
                hasPaths = false
            }
            return
        }

        let w = container.bounds.width, h = container.bounds.height
        @inline(__always) func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }

        let all = CGMutablePath()
        let paths = (0..<6).map { _ in CGMutablePath() }
        for (a, b, g) in Self.groupedBones {
            guard let pa = hand.point(a), let pb = hand.point(b) else { continue }
            let qa = map(pa), qb = map(pb)
            paths[g].move(to: qa); paths[g].addLine(to: qb)
            all.move(to: qa); all.addLine(to: qb)
        }

        let jointPath = CGMutablePath()
        let r: CGFloat = 1.4
        for j in hand.points.keys where j != .indexTip {
            guard let p = hand.point(j) else { continue }
            let q = map(p)
            jointPath.addEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
        }

        if let p = hand.point(.indexTip) {
            let q = map(p)
            let core = CGPath(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4, width: 8, height: 8), transform: nil)
            tip.path = core
            tip.shadowPath = core
            tipHalo.path = CGPath(ellipseIn: CGRect(x: q.x - 9, y: q.y - 9, width: 18, height: 18), transform: nil)
        } else {
            tip.path = nil
            tip.shadowPath = nil
            tipHalo.path = nil
        }

        glow.path = all
        for (f, p) in zip(fingers, paths) { f.path = p }
        joints.path = jointPath
        hasPaths = true
    }
}

// MARK: - Status row

@MainActor
private final class HUDStatusRow {
    private let dot = CALayer()
    private let modeText = CATextLayer()
    private let labelText = CATextLayer()
    private let x: CGFloat
    private let maxX: CGFloat
    private let modeFont = Theme.font(13, .semibold)
    private let labelFont = Theme.font(12)
    private let baseline: CGFloat
    private var mode: GestureMode?
    private var label: String?

    init(parent: CALayer, x: CGFloat, centerY: CGFloat, maxX: CGFloat, scale: CGFloat) {
        self.x = x
        self.maxX = maxX
        // Optically center the cap height of the mode name on the row.
        baseline = (centerY - modeFont.capHeight / 2).rounded()

        let d: CGFloat = 7
        dot.frame = CGRect(x: x, y: centerY - d / 2, width: d, height: d)
        dot.cornerRadius = d / 2
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 3.5
        dot.shadowOffset = .zero
        dot.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
        parent.addSublayer(dot)

        for (l, f, c) in [(modeText, modeFont, Theme.textPrimary), (labelText, labelFont, Theme.textSecondary)] {
            l.contentsScale = scale
            l.font = f
            l.fontSize = f.pointSize
            l.foregroundColor = c.cgColor
            l.isWrapped = false
            l.truncationMode = .end
            l.alignmentMode = .left
            parent.addSublayer(l)
        }
    }

    /// CATextLayer puts the first baseline `ascender` below its top edge.
    private func textFrame(x: CGFloat, width: CGFloat, font: NSFont) -> CGRect {
        let h = ceil(font.ascender - font.descender) + 2
        return CGRect(x: x, y: baseline + font.ascender - h, width: max(0, width), height: h)
    }

    func set(mode m: GestureMode, label l: String) {
        if m != mode {
            mode = m
            let color = Theme.modeColor(m)
            let solid = m == .picker ? Theme.accentB : color
            dot.backgroundColor = solid.cgColor
            dot.shadowColor = solid.cgColor
            let name = Theme.modeName(m)
            modeText.string = name
            let nameW = ceil((name as NSString).size(withAttributes: [.font: modeFont]).width) + 2
            let textX = x + 7 + 8
            modeText.frame = textFrame(x: textX, width: min(nameW, maxX - textX), font: modeFont)
            let labelX = modeText.frame.maxX + 7
            labelText.frame = textFrame(x: labelX, width: maxX - labelX, font: labelFont)
        }
        if l != label {
            label = l
            labelText.string = l
        }
    }
}

// MARK: - Round icon button (visual part; hit-testing is HUDButtonView)

@MainActor
private final class HUDButton {
    enum Kind { case help, collapse, expand, quit }

    let kind: Kind
    let layer = CALayer()
    private let icon = CALayer()
    private let normalFill: CGColor
    private let hoverFill: CGColor
    private let pressedFill: CGColor

    var hovered = false { didSet { if hovered != oldValue { refresh() } } }
    var pressed = false { didSet { if pressed != oldValue { refresh() } } }

    init(kind: Kind, symbol: String, diameter: CGFloat, pointSize: CGFloat, onVideo: Bool, scale: CGFloat) {
        self.kind = kind
        if onVideo {
            normalFill = CGColor(gray: 0, alpha: 0.35)
            hoverFill = CGColor(gray: 0.35, alpha: 0.55)
            pressedFill = CGColor(gray: 0.5, alpha: 0.65)
        } else {
            normalFill = Theme.surface.cgColor
            hoverFill = Theme.surfaceHover.cgColor
            pressedFill = CGColor(gray: 1, alpha: 0.24)
        }
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.cornerRadius = diameter / 2
        layer.borderWidth = 0.5
        layer.borderColor = Theme.hairline.cgColor
        layer.backgroundColor = normalFill
        layer.contentsScale = scale

        if let (img, size) = HUDSymbols.whiteImage(symbol, pointSize: pointSize, scale: scale) {
            icon.contents = img
            icon.contentsGravity = .resizeAspect
            icon.contentsScale = scale
            let ox = ((diameter - size.width) / 2 * scale).rounded() / scale
            let oy = ((diameter - size.height) / 2 * scale).rounded() / scale
            icon.frame = CGRect(x: ox, y: oy, width: size.width, height: size.height)
        }
        icon.opacity = 0.9
        layer.addSublayer(icon)
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        layer.backgroundColor = pressed ? pressedFill : (hovered ? hoverFill : normalFill)
        icon.opacity = hovered || pressed ? 1 : 0.9
        CATransaction.commit()
    }
}

// MARK: - Helpers

@MainActor
private enum HUDSymbols {
    /// SF Symbol rasterized in white (for CALayer contents; also works with render(in:)).
    static func whiteImage(_ name: String, pointSize: CGFloat, scale: CGFloat) -> (CGImage, CGSize)? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let img = base.withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold)) ?? base
        let size = img.size
        let pw = max(1, Int(ceil(size.width * scale))), ph = max(1, Int(ceil(size.height * scale)))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        guard let cg = ctx.makeImage() else { return nil }
        return (cg, size)
    }
}

private enum HUDColor {
    /// Point on the accent gradient A → B → C, t in 0...1.
    static func accent(at t: CGFloat) -> CGColor {
        t < 0.5 ? mix(Theme.accentA, Theme.accentB, t * 2) : mix(Theme.accentB, Theme.accentC, (t - 0.5) * 2)
    }

    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> CGColor {
        let ca = a.usingColorSpace(.sRGB) ?? a, cb = b.usingColorSpace(.sRGB) ?? b
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return CGColor(srgbRed: l(ca.redComponent, cb.redComponent), green: l(ca.greenComponent, cb.greenComponent),
                       blue: l(ca.blueComponent, cb.blueComponent), alpha: l(ca.alphaComponent, cb.alphaComponent))
    }
}
