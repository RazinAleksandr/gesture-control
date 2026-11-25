import Foundation
import CoreGraphics

/// Hand pose classes recognized per frame.
enum Pose: String {
    case none, fist, open, two, point, thumbUp, other

    var ru: String {
        switch self {
        case .none: return tr("no hand", "нет руки", "未检测到手")
        case .fist: return tr("fist", "кулак", "握拳")
        case .open: return tr("palm", "ладонь", "手掌")
        case .two: return tr("two fingers", "два пальца", "两根手指")
        case .point: return tr("pointing", "указательный", "食指")
        case .thumbUp: return tr("thumb up", "большой вверх", "竖起大拇指")
        case .other: return "—"
        }
    }
}

/// Direction the hand moved (in the mirrored picture, i.e. from the user's point of view).
enum SwipeDirection: String { case left, right, up }

enum EngineAction: Equatable {
    case setEnabled(Bool)                   // on/off gesture (thumb up held)
    case scrollBegin                        // two-finger scrolling started
    case scroll(dx: CGFloat, dy: CGFloat)   // pixels for this frame
    case swipe(SwipeDirection)
    case openPicker
    case pickerPointer(CGPoint?)            // 0...1 screen coords, top-left origin
    case pickerPinch(CGFloat)               // 0...1 closeness
    case pickerSelect(CGPoint?)             // where to select (pointer a moment before the pinch)
    case closePicker
}

struct GestureConfig {
    // finger state: tip-to-wrist / pip-to-wrist distance ratio
    var extendedRatio: CGFloat = 1.12
    var foldedRatio: CGFloat = 1.0
    var debounceFrames = 4
    var minPalmLength: CGFloat = 0.045      // ignore small (far away / background) hands
    var toggleHold: TimeInterval = 1.0      // thumb up held this long toggles gestures on/off
    var thumbTopMargin: CGFloat = 0.15      // thumb tip must be this much (× palm length) above all other joints
    // "unfold": fist held, then open palm within the window
    var bloomEnabled = true                 // fist (held still) → open palm (held) opens the picker
    var bloomOpenHold: TimeInterval = 0.15  // spread palm must be held this long after the fist
    var bloomMinSpread: CGFloat = 0.7       // index tip – little tip distance / palm length (fingers spread)
    var bloomMinThumbOut: CGFloat = 0.55    // thumb tip – index MCP distance / palm length (thumb spread too)
    var closeGrace: TimeInterval = 1.5      // a fist that starts this soon after opening does not close the picker
    var closeOpenHold: TimeInterval = 0.2   // in the picker: palm held, then …
    var closeFistHold: TimeInterval = 0.35  // … fist held this long closes it
    var closeWindow: TimeInterval = 0.8     // max gap between palm end and fist start
    var pinchGestures = false               // pinch open/close switched off (unreliable on real hands)
    var bloomWindow: TimeInterval = 0.6
    var minFistForBloom: TimeInterval = 0.1   // a quick fist is fine
    var bloomMaxFistMotion: CGFloat = 10      // stillness check off: a closing hand moves its palm center
    // swipes with open palm
    var swipeWindow: TimeInterval = 0.35
    var swipeMinDX: CGFloat = 0.24
    var swipeOpenHold: TimeInterval = 0.3   // palm shown calmly before the swipe
    var swipeMinDYUp: CGFloat = 0.28
    var swipeMinPresence: TimeInterval = 0.7
    var scrollEnterHold: TimeInterval = 0.2
    var cooldown: TimeInterval = 0.8
    // scrolling with two fingers (joystick around the start point)
    var scrollDeadzone: CGFloat = 0.025
    var scrollGain: CGFloat = 9000          // px/s per unit of offset beyond the deadzone
    var scrollHorizontalFactor: CGFloat = 0.6
    var scrollSign: CGFloat = 1             // flip if direction feels wrong (env GC_SCROLL_SIGN=-1)
    // picker
    var scrollDragGain: CGFloat = 2600      // px of scroll per unit of palm movement (like a trackpad)
    var scrollMomentumMin: CGFloat = 400    // px/s needed to keep scrolling by inertia after the fingers fold
    var scrollMomentumTau: Double = 0.35
    var pinchFrames = 2                     // frames below pinchOn to confirm
    var pinchCloseWithin: TimeInterval = 0.5 // a pinch is a QUICK close: apart → together within this time
    var pickerFistCancelEnabled = false     // a held pinch looks like a fist to the camera, so no fist-cancel
    var pinchOn: CGFloat = 0.25             // thumb-index distance / palm length
    var pinchOff: CGFloat = 0.45
    var pinchLookback: TimeInterval = 0.25
    var pickerMinOpen: TimeInterval = 0.4
    var pickerFistCancel: TimeInterval = 0.45
    var pickerLostCancel: TimeInterval = 2
    var pinchSelect = true                  // tiles: pinch; buttons: dwell (handled by the picker)
    var swipeUpEnabled = false              // swipe up → Mission Control misfired when raising the hand
    /// Part of the camera picture mapped onto the whole screen (less arm travel).
    var box = CGRect(x: 0.18, y: 0.12, width: 0.64, height: 0.58)
}

struct HandMetrics {
    var pose: Pose
    var palm: CGPoint
    var palmLength: CGFloat
    var indexTip: CGPoint?
    var twoMid: CGPoint?
    var pinch: CGFloat?        // thumb tip – index tip distance / palm length
    var spread: CGFloat = 0    // index tip – little tip distance / palm length
    var thumbOut: CGFloat = 0  // thumb tip – index MCP distance / palm length
    var ratios: [CGFloat]      // index, middle, ring, little
}

/// One Euro filter (low jitter at rest, low lag when moving).
struct OneEuro {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double = 1.0
    private var x: Double?
    private var dx: Double = 0
    private var t: Double?

    init(minCutoff: Double, beta: Double) { self.minCutoff = minCutoff; self.beta = beta }

    mutating func reset() { x = nil; t = nil; dx = 0 }

    mutating func filter(_ v: Double, _ now: Double) -> Double {
        guard let px = x, let pt = t, now > pt else { x = v; t = now; return v }
        let dt = now - pt
        func alpha(_ cutoff: Double) -> Double { let tau = 1 / (2 * Double.pi * cutoff); return 1 / (1 + tau / dt) }
        dx += alpha(dCutoff) * ((v - px) / dt - dx)
        let nx = px + alpha(minCutoff + beta * abs(dx)) * (v - px)
        x = nx; t = now
        return nx
    }
}

struct OneEuro2D {
    private var fx: OneEuro
    private var fy: OneEuro
    init(minCutoff: Double, beta: Double) {
        fx = OneEuro(minCutoff: minCutoff, beta: beta)
        fy = OneEuro(minCutoff: minCutoff, beta: beta)
    }
    mutating func reset() { fx.reset(); fy.reset() }
    mutating func filter(_ p: CGPoint, _ now: Double) -> CGPoint {
        CGPoint(x: fx.filter(Double(p.x), now), y: fy.filter(Double(p.y), now))
    }
}

@inline(__always) func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

/// Turns a stream of hand frames into actions. Pure logic, no side effects (testable).
final class GestureEngine {
    var cfg = GestureConfig()
    private(set) var mode: GestureMode = .idle
    var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            mode = enabled ? .idle : .paused
            scrollFilter.reset(); pointerFilter.reset(); palmHistory.removeAll()
        }
    }
    private(set) var rawPose: Pose = .none
    private(set) var stablePose: Pose = .none
    private(set) var lastMetrics: HandMetrics?
    private(set) var label = ""

    private var candidate: Pose = .none
    private var candidateCount = 0
    private var stableSince: TimeInterval = 0
    private var handSince: TimeInterval?
    private var lastHandTime: TimeInterval = -100
    private var lastFistEnd: TimeInterval = -100
    private var lastFistDuration: TimeInterval = 0
    private var bloomBlocked = false           // after closing the picker, a fresh fist is required
    private var palmHistory: [(t: TimeInterval, p: CGPoint, open: Bool, held: TimeInterval)] = []
    private var toggleArmed = true
    private var fistPalmStart: CGPoint?
    private var fistMotion: CGFloat = 0
    private var lastFistMotion: CGFloat = 0
    private var pinchFired = false
    private var lastApartTime: TimeInterval = -100
    private var lastOpenEnd: TimeInterval = -100
    private var lastOpenDuration: TimeInterval = 0             // a quick pinch (fingers apart → together) happened this frame
    private var cooldownUntil: TimeInterval = 0
    private var lastFrameTime: TimeInterval?

    private var anchor = CGPoint.zero
    private var scrollFilter = OneEuro2D(minCutoff: 2.0, beta: 1.0)
    private var lastScrollOffset = CGPoint.zero

    private var pickerOpenedAt: TimeInterval = 0
    private var pointerFilter = OneEuro2D(minCutoff: 1.5, beta: 2.0)
    private var pointerHistory: [(t: TimeInterval, p: CGPoint)] = []
    private var pinching = false
    private var pointerVisible = false
    private var pinchReleased = false          // fingers must be seen apart before a pinch counts
    private var pinchCount = 0
    private var lastScrollPalm: CGPoint?
    private var lastScrollPalmTime: TimeInterval = 0
    private var scrollVel = CGPoint.zero       // px/s
    private var momentum = CGPoint.zero        // px/s, inertia after scrolling ends

    // MARK: per-frame analysis

    static func analyze(_ h: HandFrame, cfg: GestureConfig) -> HandMetrics? {
        let c: Float = 0.1
        guard let w = h.point(.wrist, minConfidence: c), let mm = h.point(.middleMCP, minConfidence: c) else { return nil }
        let L = dist(w, mm)
        guard L > cfg.minPalmLength else { return nil }
        let fingers: [(Joint, Joint)] = [(.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP)]
        var states: [Int] = []
        var ratios: [CGFloat] = []
        for (tj, pj) in fingers {
            guard let tp = h.point(tj, minConfidence: c), let pp = h.point(pj, minConfidence: c) else {
                states.append(0); ratios.append(0); continue
            }
            let r = dist(w, tp) / max(dist(w, pp), 1e-4)
            ratios.append(r)
            states.append(r > cfg.extendedRatio ? 1 : (r < cfg.foldedRatio ? -1 : 0))
        }
        // thumb up: fingers folded, thumb extended and clearly the highest point of the hand
        var thumbUp = false
        if states.allSatisfy({ $0 != 1 }) && states.filter({ $0 == -1 }).count >= 3,
           let tt = h.point(.thumbTip, minConfidence: c), let ti = h.point(.thumbIP, minConfidence: c),
           let im = h.point(.indexMCP, minConfidence: c) {
            let thumbChain: Set<Joint> = [.thumbTip, .thumbIP, .thumbMP, .thumbCMC]
            let others = h.points.filter { !thumbChain.contains($0.key) && (h.confidences[$0.key] ?? 0) >= c }.map(\.value.y)
            if let top = others.min() {
                thumbUp = tt.y < top - cfg.thumbTopMargin * L && dist(w, tt) > dist(w, ti) * 1.05 && dist(tt, im) > 0.5 * L
            }
        }
        let pose: Pose
        if thumbUp { pose = .thumbUp }
        else if states.allSatisfy({ $0 == -1 }) { pose = .fist }
        else if states.allSatisfy({ $0 == 1 }) { pose = .open }
        else if states[0] == 1 && states[1] == 1 && states[2] != 1 && states[3] != 1 { pose = .two }
        else if states[0] == 1 && states[1] != 1 && states[2] != 1 && states[3] != 1 { pose = .point }
        else { pose = .other }

        let palmJoints: [Joint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let pp = palmJoints.compactMap { h.point($0, minConfidence: c) }
        let palm = CGPoint(x: pp.map(\.x).reduce(0, +) / CGFloat(pp.count), y: pp.map(\.y).reduce(0, +) / CGFloat(pp.count))

        let it = h.point(.indexTip, minConfidence: 0.2)
        var mid: CGPoint? = nil
        if let a = it, let b = h.point(.middleTip, minConfidence: 0.2) { mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var pinch: CGFloat? = nil
        if let a = it, let b = h.point(.thumbTip, minConfidence: 0.2) { pinch = dist(a, b) / L }
        var spread: CGFloat = 0, thumbOut: CGFloat = 0
        if let a = h.point(.indexTip, minConfidence: c), let b = h.point(.littleTip, minConfidence: c) { spread = dist(a, b) / L }
        if let a = h.point(.thumbTip, minConfidence: c), let b = h.point(.indexMCP, minConfidence: c) { thumbOut = dist(a, b) / L }
        return HandMetrics(pose: pose, palm: palm, palmLength: L, indexTip: it, twoMid: mid, pinch: pinch,
                           spread: spread, thumbOut: thumbOut, ratios: ratios)
    }

    func mapToScreen(_ p: CGPoint) -> CGPoint {
        let b = cfg.box
        return CGPoint(x: min(max((p.x - b.minX) / b.width, 0), 1), y: min(max((p.y - b.minY) / b.height, 0), 1))
    }

    // MARK: main step

    func process(_ hand: HandFrame?, now: TimeInterval) -> [EngineAction] {
        let dt = min(max(now - (lastFrameTime ?? now), 0), 0.1)
        lastFrameTime = now
        let m = hand.flatMap { Self.analyze($0, cfg: cfg) }
        lastMetrics = m
        rawPose = m?.pose ?? .none
        if m != nil {
            if handSince == nil { handSince = now }
            lastHandTime = now
        } else if now - lastHandTime > 0.3 {
            handSince = nil
        }

        // debounce poses
        let prevStable = stablePose
        if rawPose == candidate { candidateCount += 1 } else { candidate = rawPose; candidateCount = 1 }
        if candidateCount >= cfg.debounceFrames && candidate != stablePose {
            if stablePose == .fist { lastFistEnd = now; lastFistDuration = now - stableSince; lastFistMotion = fistMotion; fistPalmStart = nil }
            if stablePose == .open { lastOpenEnd = now; lastOpenDuration = now - stableSince }
            if candidate == .fist { bloomBlocked = false }
            stablePose = candidate
            stableSince = now
        }
        let changed = prevStable != stablePose
        if stablePose == .fist, let m {
            if let s0 = fistPalmStart { fistMotion = max(fistMotion, dist(m.palm, s0)) } else { fistPalmStart = m.palm; fistMotion = 0 }
        }

        // on/off: thumb up held (works in idle and when switched off)
        var out: [EngineAction] = []
        if stablePose == .thumbUp && (mode == .idle || mode == .paused) {
            let held = now - stableSince
            if toggleArmed && held >= cfg.toggleHold {
                toggleArmed = false
                enabled.toggle()
                bloomBlocked = true
                if enabled { enterCooldown(now) }
                label = enabled ? tr("gestures on", "жесты включены", "手势已开启") : tr("gestures off", "жесты выключены", "手势已关闭")
                return [.setEnabled(enabled)]
            }
            if toggleArmed { label = String(format: "👍 %.0f%%", min(held / cfg.toggleHold, 1) * 100); return [] }
        } else if stablePose != .thumbUp {
            toggleArmed = true
        }
        guard enabled else {
            label = tr("off · hold 👍 for 1 s to turn on", "выключено · 👍 подержите 1 с — включить", "已关闭 · 竖起 👍 1 秒即可开启")
            momentum = .zero
            return []
        }

        pinchFired = detectPinch(m, now: now)
        if mode != .scroll, momentum != .zero {
            out.append(.scroll(dx: momentum.x * CGFloat(dt), dy: momentum.y * CGFloat(dt)))
            let decay = CGFloat(exp(-dt / cfg.scrollMomentumTau))
            momentum = CGPoint(x: momentum.x * decay, y: momentum.y * decay)
            if hypot(momentum.x, momentum.y) < 40 { momentum = .zero }
        }
        if mode == .cooldown {
            if now >= cooldownUntil { mode = .idle } else { label = tr("short pause", "пауза после действия", "稍作停顿"); return out }
        }
        switch mode {
        case .idle: out += idleStep(m, now: now, changed: changed)
        case .scroll: out += scrollStep(m, now: now, dt: dt)
        case .picker: out += pickerStep(m, now: now)
        case .cooldown, .paused: break
        }
        if label.isEmpty || mode == .idle { label = tr("pose: ", "поза: ", "手势：") + stablePose.ru }
        return out
    }

    private func openPickerMode(_ now: TimeInterval) -> [EngineAction] {
        mode = .picker
        pickerOpenedAt = now
        momentum = .zero
        pointerVisible = false
        pointerFilter.reset()
        pointerHistory.removeAll()
        palmHistory.removeAll()
        label = tr("window picker", "выбор окна", "窗口选择")
        return [.openPicker]
    }

    /// A quick pinch: thumb and index tips were apart and came together within `pinchCloseWithin`.
    /// Pose is ignored on purpose: during a real pinch the other fingers curl and the camera sees a "fist".
    /// The hand entering already pinched or slowly closing does not count; thumb-up is excluded.
    private func detectPinch(_ m: HandMetrics?, now: TimeInterval) -> Bool {
        guard let m else { pinchReleased = false; pinchCount = 0; return false }
        guard let pr = m.pinch, m.pose != .thumbUp else { pinchCount = 0; return false }
        if pr > cfg.pinchOff { pinchReleased = true; pinchCount = 0; lastApartTime = now; return false }
        if pr < cfg.pinchOn && pinchReleased && now - lastApartTime <= cfg.pinchCloseWithin {
            pinchCount += 1
            if pinchCount >= cfg.pinchFrames { pinchReleased = false; pinchCount = 0; return true }
        } else if pr >= cfg.pinchOn {
            pinchCount = 0
        }
        return false
    }

    /// One line of per-frame measurements for tuning (written with --trace).
    var debugLine: String {
        guard let m = lastMetrics else { return "no hand" }
        let r = m.ratios.map { String(format: "%.2f", $0) }.joined(separator: " ")
        return String(format: "raw=%@ stable=%@ L=%.3f pinch=%@ ratios=[%@] released=%d count=%d mode=%@ spread=%.2f thumbOut=%.2f",
                      m.pose.rawValue, stablePose.rawValue, m.palmLength,
                      m.pinch.map { String(format: "%.2f", $0) } ?? "-", r,
                      pinchReleased ? 1 : 0, pinchCount, mode.rawValue, m.spread, m.thumbOut)
    }

    /// Call if the picker could not be opened (no windows) or was closed from outside.
    func pickerClosedExternally(now: TimeInterval) { if mode == .picker { finishPicker(now: now) } }

    private func enterCooldown(_ now: TimeInterval) {
        mode = .cooldown
        cooldownUntil = now + cfg.cooldown
    }

    private func finishPicker(now: TimeInterval) {
        pinching = false
        pointerVisible = false
        bloomBlocked = true
        enterCooldown(now)
    }

    private func idleStep(_ m: HandMetrics?, now: TimeInterval, changed: Bool) -> [EngineAction] {
        label = ""
        // quick pinch → window picker
        if cfg.pinchGestures, pinchFired, let hs = handSince, now - hs >= 0.3 {
            return openPickerMode(now)
        }
        // "unfold": fist → open palm (off by default)
        if cfg.bloomEnabled && stablePose == .open && !bloomBlocked
            && now - stableSince >= cfg.bloomOpenHold
            && (m?.spread ?? 0) >= cfg.bloomMinSpread && (m?.thumbOut ?? 0) >= cfg.bloomMinThumbOut
            && lastFistDuration >= cfg.minFistForBloom && stableSince - lastFistEnd <= cfg.bloomWindow
            && lastFistMotion <= cfg.bloomMaxFistMotion {
            lastFistDuration = 0
            return openPickerMode(now)
        }
        // two fingers → scroll
        if stablePose == .two, now - stableSince >= cfg.scrollEnterHold, let palm = m?.palm {
            mode = .scroll
            scrollFilter.reset()
            lastScrollPalm = scrollFilter.filter(palm, now)
            lastScrollPalmTime = now
            scrollVel = .zero
            momentum = .zero
            palmHistory.removeAll()
            return [.scrollBegin]
        }
        // swipes with open palm (fast motion blurs the hand, so short dropouts are tolerated)
        guard let m else {
            if now - lastHandTime > 0.3 { palmHistory.removeAll() }
            return []
        }
        if m.pose == .fist || m.pose == .two || m.pose == .thumbUp { palmHistory.removeAll(); return [] }
        palmHistory.append((now, m.palm, m.pose == .open, stablePose == .open ? now - stableSince : 0))
        palmHistory.removeAll { now - $0.t > cfg.swipeWindow }
        guard let hs = handSince, now - hs >= cfg.swipeMinPresence, palmHistory.count >= 3,
              let first = palmHistory.first, let last = palmHistory.last, last.t - first.t >= 0.06 else { return [] }
        let openShare = Double(palmHistory.filter { $0.open }.count) / Double(palmHistory.count)
        guard openShare >= 0.5, first.held >= cfg.swipeOpenHold else { return [] }
        let dx = last.p.x - first.p.x, dy = last.p.y - first.p.y
        var dir: SwipeDirection? = nil
        if abs(dx) >= cfg.swipeMinDX && abs(dx) > 2 * abs(dy) { dir = dx < 0 ? .left : .right }
        else if cfg.swipeUpEnabled && -dy >= cfg.swipeMinDYUp && abs(dy) > 2 * abs(dx) { dir = .up }
        guard let dir else { return [] }
        palmHistory.removeAll()
        enterCooldown(now)
        label = tr("swipe ", "взмах ", "挥动 ") + (dir == .left ? "←" : dir == .right ? "→" : "↑")
        return [.swipe(dir)]
    }

    /// Trackpad-like: the page follows the palm (palm, not fingertips, so folding fingers does not jerk it).
    private func scrollStep(_ m: HandMetrics?, now: TimeInterval, dt: TimeInterval) -> [EngineAction] {
        // leave only on a clearly different pose or when the hand is gone for a while (dropouts are common)
        let exitPoses: Set<Pose> = [.fist, .open, .point]
        if exitPoses.contains(stablePose) || (m == nil && now - lastHandTime > 0.5) {
            mode = .idle
            label = ""
            if hypot(scrollVel.x, scrollVel.y) >= cfg.scrollMomentumMin { momentum = scrollVel }
            return []
        }
        guard let palm = m?.palm else { return [] }
        if now - lastScrollPalmTime > 0.15 { scrollFilter.reset(); lastScrollPalm = nil }   // no jump after a dropout
        let p = scrollFilter.filter(palm, now)
        let prevTime = lastScrollPalmTime
        defer { lastScrollPalm = p; lastScrollPalmTime = now }
        guard let prev = lastScrollPalm else { return [] }
        var d = CGPoint(x: p.x - prev.x, y: p.y - prev.y)
        if abs(d.x) < abs(d.y) * 1.5 { d.x = 0 } else { d.y = 0 }   // axis lock
        let k = cfg.scrollDragGain * cfg.scrollSign
        let sx = d.x * k * cfg.scrollHorizontalFactor, sy = d.y * k
        let fdt = max(CGFloat(now - prevTime), 1.0 / 60)
        scrollVel = CGPoint(x: scrollVel.x * 0.6 + sx / fdt * 0.4, y: scrollVel.y * 0.6 + sy / fdt * 0.4)
        label = tr("scrolling", "прокрутка", "滚动中")
        if abs(sx) < 0.3 && abs(sy) < 0.3 { return [] }
        return [.scroll(dx: sx, dy: sy)]
    }

    private func pickerStep(_ m: HandMetrics?, now: TimeInterval) -> [EngineAction] {
        var out: [EngineAction] = []
        guard let m else {
            if pointerVisible { pointerVisible = false; out.append(.pickerPointer(nil)) }
            if now - lastHandTime > cfg.pickerLostCancel { finishPicker(now: now); out.append(.closePicker) }
            label = tr("hand not visible", "рука не видна", "看不到手")
            return out
        }
        if stablePose == .fist && stableSince > pickerOpenedAt + cfg.closeGrace && now - stableSince >= cfg.closeFistHold
            && lastOpenDuration >= cfg.closeOpenHold && stableSince - lastOpenEnd <= cfg.closeWindow {
            finishPicker(now: now)
            return [.closePicker]
        }
        if cfg.pickerFistCancelEnabled && stablePose == .fist && now - stableSince >= cfg.pickerFistCancel && now - pickerOpenedAt > 0.3 {
            finishPicker(now: now)
            return [.closePicker]
        }
        if stablePose != .fist, rawPose != .fist, let tip = m.indexTip {
            let p = pointerFilter.filter(mapToScreen(tip), now)
            pointerHistory.append((now, p))
            pointerHistory.removeAll { now - $0.t > 0.6 }
            pointerVisible = true
            out.append(.pickerPointer(p))
        }
        // a quick pinch closes the picker (selection itself is by dwell, done by the picker)
        if cfg.pinchGestures && pinchFired && now - pickerOpenedAt >= cfg.pickerMinOpen {
            finishPicker(now: now)
            return [.closePicker]
        }
        label = tr("hold on a window or button · palm → fist closes", "задержите палец на окне или кнопке · ладонь → кулак — закрыть", "手指停在窗口或按钮上 · 手掌 → 握拳关闭")
        return out
    }
}
