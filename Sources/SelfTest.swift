import Foundation
import CoreGraphics

/// Offline check of the gesture engine on synthetic hands (no camera, no permissions).
enum SelfTest {
    /// Synthetic hand pointing up. fingers = [index, middle, ring, little] extended?
    static func hand(at c: CGPoint, fingers: [Bool], pinch: Bool = false, thumbUp: Bool = false, spread: Bool = true,
                     s: CGFloat = 0.14, t: TimeInterval) -> HandFrame {
        var p: [Joint: CGPoint] = [:]
        let w = CGPoint(x: c.x, y: c.y + 0.6 * s)
        p[.wrist] = w
        let names: [(Joint, Joint, Joint, Joint)] = [
            (.indexMCP, .indexPIP, .indexDIP, .indexTip), (.middleMCP, .middlePIP, .middleDIP, .middleTip),
            (.ringMCP, .ringPIP, .ringDIP, .ringTip), (.littleMCP, .littlePIP, .littleDIP, .littleTip),
        ]
        let xo: [CGFloat] = [-0.3, -0.1, 0.1, 0.3]
        for (i, n) in names.enumerated() {
            let mcp = CGPoint(x: w.x + xo[i] * s, y: w.y - s)
            p[n.0] = mcp
            func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: mcp.x + dx * s, y: mcp.y + dy * s) }
            if i == 0 && pinch {
                p[n.1] = at(-0.05, -0.4); p[n.2] = at(-0.12, -0.55); p[n.3] = at(-0.2, -0.6)
            } else if fingers[i] {
                let fan: CGFloat = spread ? [-0.15, -0.05, 0.05, 0.15][i] : 0
                p[n.1] = at(fan * 0.4, -0.45); p[n.2] = at(fan * 0.7, -0.7); p[n.3] = at(fan, -0.9)
            } else {
                p[n.1] = at(0, -0.25); p[n.2] = at(0, -0.05); p[n.3] = at(0, 0.2)
            }
        }
        func tw(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: w.x + dx * s, y: w.y + dy * s) }
        p[.thumbCMC] = tw(-0.25, -0.15); p[.thumbMP] = tw(-0.45, -0.35); p[.thumbIP] = tw(-0.55, -0.5)
        p[.thumbTip] = spread ? tw(-0.8, -0.6) : tw(-0.45, -0.75)
        if pinch, let it = p[.indexTip] { p[.thumbTip] = CGPoint(x: it.x + 0.02 * s, y: it.y + 0.02 * s) }
        if thumbUp {
            p[.thumbCMC] = tw(-0.25, -0.3); p[.thumbMP] = tw(-0.35, -0.75); p[.thumbIP] = tw(-0.4, -1.1); p[.thumbTip] = tw(-0.42, -1.55)
        }
        var conf: [Joint: Float] = [:]
        for k in p.keys { conf[k] = 0.9 }
        return HandFrame(time: t, points: p, confidences: conf)
    }

    static let open = [true, true, true, true]
    static let fist = [false, false, false, false]
    static let two = [true, true, false, false]
    static let point = [true, false, false, false]

    final class Runner {
        let e = GestureEngine()   // enabled by default in the engine; the app starts it switched off
        var t: TimeInterval = 100
        var log: [EngineAction] = []
        func feed(_ seconds: Double, _ make: (Double) -> HandFrame?) {
            let n = Int(seconds * 30)
            for i in 0..<n {
                t += 1.0 / 30
                let frac = n > 1 ? Double(i) / Double(n - 1) : 1
                log += e.process(make(frac), now: t)
            }
        }
        func take() -> [EngineAction] { defer { log = [] }; return log }
    }

    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print((ok ? "PASS " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        let c = CGPoint(x: 0.5, y: 0.45)

        // 1. static open palm → nothing
        do {
            let r = Runner()
            r.feed(1.0) { _ in hand(at: c, fingers: open, t: r.t) }
            let a = r.take()
            check(a.isEmpty && r.e.stablePose == .open, "static palm: no actions, pose=open (got \(a.count), \(r.e.stablePose))")
        }
        // 2. picker: fist (still) → palm opens; index points; palm → fist closes
        do {
            let r = Runner()
            r.feed(0.3) { _ in hand(at: c, fingers: fist, t: r.t) }
            check(r.e.stablePose == .fist, "fist recognized (\(r.e.stablePose))")
            r.feed(0.8) { _ in hand(at: c, fingers: open, spread: false, t: r.t) }
            _ = r.take()
            r.feed(0.6) { _ in hand(at: c, fingers: fist, t: r.t) }
            r.feed(0.5) { _ in hand(at: c, fingers: open, t: r.t) }
            check(r.take().contains(.openPicker) && r.e.mode == .picker, "fist → palm opens picker")
            r.feed(1.2) { f in hand(at: CGPoint(x: 0.35 + 0.3 * f, y: 0.35 + 0.2 * f), fingers: point, t: r.t) }
            let ptrs = r.take().compactMap { if case .pickerPointer(let p) = $0 { return p } else { return nil } }
            let moved = (ptrs.last?.x ?? 0) - (ptrs.first?.x ?? 0)
            check(ptrs.count > 5 && moved > 0.2, "pointer follows index finger (n=\(ptrs.count), dx=\(String(format: "%.2f", moved)))")
            r.feed(0.4) { _ in hand(at: c, fingers: open, t: r.t) }
            r.feed(0.15) { _ in hand(at: c, fingers: fist, t: r.t) }
            check(!r.take().contains(.closePicker), "a brief fist does not close picker")
            r.feed(0.4) { _ in hand(at: c, fingers: fist, t: r.t) }
            check(r.take().contains(.closePicker) && r.e.mode == .cooldown, "palm → fist closes picker")
            r.feed(1.0) { _ in hand(at: c, fingers: open, t: r.t) }
            r.feed(0.6) { _ in hand(at: c, fingers: fist, t: r.t) }
            r.feed(0.5) { _ in hand(at: c, fingers: open, t: r.t) }
            check(r.take().contains(.openPicker), "picker reopens with fist → palm")
            r.feed(1.5) { _ in hand(at: c, fingers: fist, t: r.t) }
            check(!r.take().contains(.closePicker) && r.e.mode == .picker, "reflex fist right after opening does not close")
            r.feed(0.6) { _ in hand(at: c, fingers: point, pinch: true, t: r.t) }
            r.feed(0.4) { _ in hand(at: c, fingers: point, t: r.t) }
            r.feed(0.3) { _ in hand(at: c, fingers: point, pinch: true, t: r.t) }
            check(!r.take().contains(.closePicker), "pinch does nothing now")
            r.feed(2.5) { _ in nil }
            check(r.take().contains(.closePicker), "picker closes when the hand is gone for 2 s")
            let r2 = Runner()
            r2.feed(0.8) { _ in hand(at: c, fingers: point, t: r2.t) }
            r2.feed(0.4) { _ in hand(at: c, fingers: point, pinch: true, t: r2.t) }
            check(!r2.take().contains(.openPicker), "pinch in idle does not open picker")
            let r3 = Runner()
            r3.feed(0.8) { _ in hand(at: c, fingers: open, t: r3.t) }
            r3.feed(0.6) { _ in hand(at: c, fingers: fist, t: r3.t) }
            r3.feed(0.1) { _ in hand(at: c, fingers: open, t: r3.t) }
            r3.feed(0.5) { _ in hand(at: c, fingers: point, t: r3.t) }
            check(!r3.take().contains(.openPicker), "palm flashed for a moment does not open picker")
        }
        // 3. scroll
        do {
            let r = Runner()
            r.feed(0.5) { _ in hand(at: c, fingers: two, t: r.t) }
            check(r.e.mode == .scroll, "two fingers → scroll mode (\(r.e.mode))")
            _ = r.take()
            r.feed(0.6) { f in hand(at: CGPoint(x: c.x, y: c.y - 0.12 * f), fingers: two, t: r.t) }
            let dy = r.take().reduce(CGFloat(0)) { if case .scroll(_, let y) = $1 { return $0 + y } else { return $0 } }
            check(dy < -50, "hand up → negative scroll (content up), total dy=\(Int(dy))")
            r.feed(0.5) { _ in hand(at: c, fingers: two, t: r.t) }
            _ = r.take()
            r.feed(0.6) { _ in hand(at: c, fingers: fist, t: r.t) }
            check(r.e.mode == .idle, "fist leaves scroll mode (\(r.e.mode))")
            // flick up and fold the fingers → inertia keeps scrolling
            let rf = Runner()
            rf.feed(0.5) { _ in hand(at: c, fingers: two, t: rf.t) }
            rf.feed(0.2) { f in hand(at: CGPoint(x: c.x, y: c.y - 0.15 * f), fingers: two, t: rf.t) }
            _ = rf.take()
            rf.feed(0.6) { _ in hand(at: CGPoint(x: c.x, y: c.y - 0.15), fingers: fist, t: rf.t) }
            let inert = rf.take().reduce(CGFloat(0)) { if case .scroll(_, let y) = $1 { return $0 + y } else { return $0 } }
            check(rf.e.mode == .idle && inert < -30, "flick → inertia after fingers fold (dy=\(Int(inert)))")
            let still = Runner()
            still.feed(0.8) { _ in hand(at: c, fingers: two, t: still.t) }
            let jitter = still.take().filter { if case .scroll = $0 { return true } else { return false } }.count
            check(jitter == 0, "no scroll while holding still (\(jitter) events)")
        }
        // 4. swipes
        do {
            let r = Runner()
            r.feed(1.0) { _ in hand(at: c, fingers: open, t: r.t) }
            _ = r.take()
            r.feed(0.25) { f in hand(at: CGPoint(x: c.x - 0.3 * f, y: c.y), fingers: open, t: r.t) }
            check(r.take().contains(.swipe(.left)), "fast palm move left → swipe left")
            r.feed(1.0) { _ in hand(at: CGPoint(x: 0.2, y: c.y), fingers: open, t: r.t) }
            _ = r.take()
            r.feed(0.25) { f in hand(at: CGPoint(x: 0.2 + 0.3 * f, y: c.y), fingers: open, t: r.t) }
            check(r.take().contains(.swipe(.right)), "fast palm move right → swipe right")
            r.feed(1.0) { _ in hand(at: c, fingers: open, t: r.t) }
            _ = r.take()
            r.feed(0.6) { f in hand(at: CGPoint(x: c.x - 0.3 * f, y: c.y), fingers: open, t: r.t) }
            check(!r.take().contains { if case .swipe = $0 { return true } else { return false } }, "slow palm move → no swipe")
            // fast swipe with motion-blur dropouts (every 3rd frame lost, some frames pose unclear)
            r.feed(1.0) { _ in hand(at: c, fingers: open, t: r.t) }
            _ = r.take()
            var k = 0
            r.feed(0.25) { f in
                k += 1
                if k % 3 == 0 { return nil }
                return hand(at: CGPoint(x: c.x - 0.3 * f, y: c.y), fingers: k % 3 == 2 ? [true, true, false, true] : open, t: r.t)
            }
            check(r.take().contains(.swipe(.left)), "swipe left survives dropouts")
            // scroll survives short dropouts
            let rs = Runner()
            rs.feed(0.5) { _ in hand(at: c, fingers: two, t: rs.t) }
            var j = 0
            rs.feed(0.8) { f in
                j += 1
                return (j / 4) % 2 == 1 ? nil : hand(at: CGPoint(x: c.x, y: c.y - 0.12 * f), fingers: two, t: rs.t)
            }
            let sdy = rs.take().reduce(CGFloat(0)) { if case .scroll(_, let y) = $1 { return $0 + y } else { return $0 } }
            check(rs.e.mode == .scroll && sdy < -50, "scroll survives dropouts (mode=\(rs.e.mode), dy=\(Int(sdy)))")
            // hand entering from below must not trigger Mission Control
            let r2 = Runner()
            r2.feed(0.5) { _ in nil }
            r2.feed(0.3) { f in hand(at: CGPoint(x: c.x, y: 0.9 - 0.45 * f), fingers: open, t: r2.t) }
            check(!r2.take().contains(.swipe(.up)), "raising hand into view → no swipe up")
        }
        // 5. on/off with thumb up, false-positive guards
        do {
            let r = Runner()
            r.feed(0.5) { _ in hand(at: c, fingers: fist, thumbUp: true, t: r.t) }
            check(r.e.stablePose == .thumbUp && r.take().isEmpty, "thumb up recognized, not toggled before 1 s")
            r.feed(1.0) { _ in hand(at: c, fingers: fist, thumbUp: true, t: r.t) }
            check(r.take().contains(.setEnabled(false)) && !r.e.enabled, "thumb up held 1 s → off")
            r.feed(1.5) { _ in hand(at: c, fingers: fist, thumbUp: true, t: r.t) }
            check(r.take().isEmpty, "keeping the thumb up does not toggle again")
            r.feed(0.6) { _ in hand(at: c, fingers: fist, t: r.t) }
            r.feed(0.4) { _ in hand(at: c, fingers: open, t: r.t) }
            r.feed(0.4) { _ in hand(at: c, fingers: two, t: r.t) }
            check(r.take().isEmpty, "while off: fist→palm and two fingers do nothing")
            r.feed(1.3) { _ in hand(at: c, fingers: fist, thumbUp: true, t: r.t) }
            check(r.take().contains(.setEnabled(true)) && r.e.enabled, "thumb up again → on")
            // a plain fist is not a thumb up
            let rf = Runner()
            rf.feed(1.5) { _ in hand(at: c, fingers: fist, t: rf.t) }
            check(rf.e.stablePose == .fist && rf.take().isEmpty, "plain fist held is not a toggle")
            // quick fist → spread palm opens; palm with fingers together does not
            let rq = Runner()
            rq.feed(1.0) { _ in hand(at: c, fingers: open, t: rq.t) }
            rq.feed(0.25) { _ in hand(at: c, fingers: fist, t: rq.t) }
            rq.feed(0.4) { _ in hand(at: c, fingers: open, t: rq.t) }
            check(rq.take().contains(.openPicker), "quick fist → spread palm opens the picker")
            let rn = Runner()
            rn.feed(1.0) { _ in hand(at: c, fingers: open, spread: false, t: rn.t) }
            rn.feed(0.4) { _ in hand(at: c, fingers: fist, t: rn.t) }
            rn.feed(0.6) { _ in hand(at: c, fingers: open, spread: false, t: rn.t) }
            check(!rn.take().contains(.openPicker), "fist → palm with fingers together does not open")
            let rb = Runner()
            rb.feed(1.0) { _ in hand(at: c, fingers: open, t: rb.t) }
            rb.feed(0.08) { _ in hand(at: c, fingers: fist, t: rb.t) }
            rb.feed(0.5) { _ in hand(at: c, fingers: open, t: rb.t) }
            check(!rb.take().contains(.openPicker), "a fist flicker (<0.1 s) does not open")
            // a fast palm move right after the palm appears is not a swipe
            let rs = Runner()
            rs.feed(1.0) { _ in hand(at: c, fingers: point, t: rs.t) }
            rs.feed(0.25) { f in hand(at: CGPoint(x: c.x - 0.3 * f, y: c.y), fingers: open, t: rs.t) }
            check(!rs.take().contains { if case .swipe = $0 { return true } else { return false } }, "palm that was not shown calmly first → no swipe")
            // tiny (far) hand is ignored
            let rt = Runner()
            rt.feed(1.0) { _ in hand(at: c, fingers: fist, s: 0.03, t: rt.t) }
            check(rt.e.stablePose == .none, "far/small hand ignored")
        }
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
