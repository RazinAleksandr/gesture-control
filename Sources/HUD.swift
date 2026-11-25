import AppKit
import AVFoundation
import QuartzCore

// MARK: - HUD (public API)

/// Small always-on-top floating panel (bottom-right of the main screen) that shows
/// the mirrored webcam picture, the detected hand skeleton and a status line.
@MainActor final class HUD {
    private let tree: HUDLayerTree
    private var panel: NSPanel?
    private var mirrorFallbackApplied = false

    // Last state, so show() can re-apply what update() skipped while hidden.
    private var lastHand: HandFrame?
    private var lastMode: GestureMode = .idle
    private var lastLabel: String = ""

    init(session: AVCaptureSession?) {
        tree = HUDLayerTree(session: session, scale: NSScreen.main?.backingScaleFactor ?? 2)
        tree.apply(hand: nil, mode: lastMode, label: lastLabel)
        configureMirroring()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        placeBottomRight(panel)
        tree.apply(hand: lastHand, mode: lastMode, label: lastLabel)
        configureMirroring()
        panel.orderFrontRegardless()
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
        tree.apply(hand: hand, mode: mode, label: label)
    }

    /// Debug: offscreen render to PNG (camera area black), no window shown.
    func renderDebugPNG(to url: URL, hand: HandFrame?, mode: GestureMode, label: String) {
        let scale: CGFloat = 2
        let debugTree = HUDLayerTree(session: nil, scale: scale)
        debugTree.apply(hand: hand, mode: mode, label: label)

        let size = debugTree.root.bounds.size
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            NSLog("HUD.renderDebugPNG: cannot create bitmap context")
            return
        }
        ctx.scaleBy(x: scale, y: scale)
        debugTree.root.render(in: ctx)

        guard let image = ctx.makeImage() else {
            NSLog("HUD.renderDebugPNG: cannot make image")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
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

    // MARK: Private

    private func makePanel() -> NSPanel {
        let size = tree.root.bounds.size
        let p = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.isMovable = false
        p.isExcludedFromWindowsMenu = true
        p.animationBehavior = .none

        // Layer-hosting view: our own layer tree is the view's layer.
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.layer = tree.root
        view.wantsLayer = true
        p.contentView = view
        return p
    }

    private func placeBottomRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let size = tree.root.bounds.size
        let origin = NSPoint(x: vf.maxX - size.width - HUDLayerTree.margin,
                             y: vf.minY + HUDLayerTree.margin)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func configureMirroring() {
        guard let preview = tree.preview, let conn = preview.connection else { return }
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

// MARK: - Panel that never takes focus

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Layer tree (shared by the live panel and the offscreen debug render)

@MainActor
private final class HUDLayerTree {
    static let cameraWidth: CGFloat = 320
    static let cameraHeight: CGFloat = 180
    static let statusHeight: CGFloat = 30
    static let margin: CGFloat = 16
    static let cornerRadius: CGFloat = 12

    let root = CALayer()
    let camera = CALayer()
    let preview: AVCaptureVideoPreviewLayer?
    let skeleton = CALayer()
    let boneShadow = CAShapeLayer()
    let bones = CAShapeLayer()
    let joints = CAShapeLayer()
    let tip = CAShapeLayer()
    let statusBar = CALayer()
    let dot = CALayer()
    let modeText = CATextLayer()
    let labelText = CATextLayer()

    private let modeFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let labelFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private let textHeight: CGFloat = 16

    private var currentMode: GestureMode?
    private var currentLabel: String?
    private var hasSkeleton = false

    init(session: AVCaptureSession?, scale: CGFloat) {
        let w = Self.cameraWidth, camH = Self.cameraHeight, barH = Self.statusHeight

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Root: regular (bottom-left origin) geometry; camera on top, status bar below.
        root.frame = CGRect(x: 0, y: 0, width: w, height: camH + barH)
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.cornerRadius = Self.cornerRadius
        root.masksToBounds = true
        root.borderWidth = 0.5
        root.borderColor = CGColor(gray: 1, alpha: 0.18)

        camera.frame = CGRect(x: 0, y: barH, width: w, height: camH)
        camera.backgroundColor = CGColor(gray: 0, alpha: 1)
        camera.masksToBounds = true
        root.addSublayer(camera)

        if let session {
            let p = AVCaptureVideoPreviewLayer(session: session)
            p.videoGravity = .resize   // normalized coords map linearly onto the area
            p.frame = camera.bounds
            camera.addSublayer(p)
            preview = p
        } else {
            preview = nil
        }

        // Skeleton container: flipped so (0,0) is top-left, matching HandFrame coords.
        skeleton.frame = camera.bounds
        skeleton.isGeometryFlipped = true
        camera.addSublayer(skeleton)

        for layer in [boneShadow, bones, joints, tip] {
            layer.frame = skeleton.bounds
            layer.contentsScale = scale
            layer.lineCap = .round
            layer.lineJoin = .round
            skeleton.addSublayer(layer)
        }
        boneShadow.fillColor = nil
        boneShadow.strokeColor = CGColor(gray: 0, alpha: 0.45)
        boneShadow.lineWidth = 4
        bones.fillColor = nil
        bones.lineWidth = 2
        joints.strokeColor = nil
        tip.strokeColor = CGColor(gray: 0, alpha: 0.6)
        tip.lineWidth = 1.5

        // Status bar.
        statusBar.frame = CGRect(x: 0, y: 0, width: w, height: barH)
        statusBar.backgroundColor = CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        root.addSublayer(statusBar)

        dot.frame = CGRect(x: 10, y: (barH - 8) / 2, width: 8, height: 8)
        dot.cornerRadius = 4
        statusBar.addSublayer(dot)

        for (layer, font) in [(modeText, modeFont), (labelText, labelFont)] {
            layer.contentsScale = scale
            layer.font = font
            layer.fontSize = font.pointSize
            layer.isWrapped = false
            layer.truncationMode = .end
            layer.alignmentMode = .left
            statusBar.addSublayer(layer)
        }
        modeText.foregroundColor = CGColor(gray: 1, alpha: 1)
        labelText.foregroundColor = CGColor(gray: 1, alpha: 0.75)
    }

    func apply(hand: HandFrame?, mode: GestureMode, label: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if mode != currentMode {
            currentMode = mode
            let color = Self.color(for: mode)
            bones.strokeColor = color
            joints.fillColor = color
            tip.fillColor = color
            dot.backgroundColor = color

            let title = Self.title(for: mode)
            modeText.string = title
            let titleWidth = ceil((title as NSString).size(withAttributes: [.font: modeFont]).width) + 2
            let y = (Self.statusHeight - textHeight) / 2
            modeText.frame = CGRect(x: 24, y: y, width: titleWidth, height: textHeight)
            let labelX = modeText.frame.maxX + 8
            labelText.frame = CGRect(x: labelX, y: y,
                                     width: max(0, Self.cameraWidth - labelX - 10), height: textHeight)
        }

        if label != currentLabel {
            currentLabel = label
            labelText.string = label
        }

        guard let hand else {
            if hasSkeleton {
                boneShadow.path = nil
                bones.path = nil
                joints.path = nil
                tip.path = nil
                hasSkeleton = false
            }
            return
        }

        let w = skeleton.bounds.width, h = skeleton.bounds.height
        @inline(__always) func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }

        let bonePath = CGMutablePath()
        for (a, b) in HandFrame.bones {
            guard let pa = hand.point(a), let pb = hand.point(b) else { continue }
            bonePath.move(to: map(pa))
            bonePath.addLine(to: map(pb))
        }

        let jointPath = CGMutablePath()
        let r: CGFloat = 1.5   // 3 pt dots
        for j in hand.points.keys where j != .indexTip {
            guard let p = hand.point(j) else { continue }
            let q = map(p)
            jointPath.addEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
        }

        var tipPath: CGPath?
        if let p = hand.point(.indexTip) {
            let q = map(p)
            let tr: CGFloat = 4   // 8 pt fingertip
            tipPath = CGPath(ellipseIn: CGRect(x: q.x - tr, y: q.y - tr, width: 2 * tr, height: 2 * tr),
                             transform: nil)
        }

        boneShadow.path = bonePath
        bones.path = bonePath
        joints.path = jointPath
        tip.path = tipPath
        hasSkeleton = true
    }

    static func color(for mode: GestureMode) -> CGColor {
        switch mode {
        case .idle:     return CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1)
        case .scroll:   return CGColor(red: 0.20, green: 0.85, blue: 1.00, alpha: 1)
        case .picker:   return CGColor(red: 1.00, green: 0.84, blue: 0.10, alpha: 1)
        case .cooldown: return CGColor(red: 0.60, green: 0.60, blue: 0.62, alpha: 1)
        case .paused:   return CGColor(red: 1.00, green: 0.30, blue: 0.28, alpha: 1)
        }
    }

    static func title(for mode: GestureMode) -> String {
        switch mode {
        case .idle:     return "Ожидание"
        case .scroll:   return "Прокрутка"
        case .picker:   return "Выбор окна"
        case .cooldown: return "Пауза…"
        case .paused:   return "Выключено"
        }
    }
}
