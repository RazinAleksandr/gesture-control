// Real screenshots of the live UI for the README, taken over a neutral wallpaper window so that
// nothing from the user's desktop gets into the frame. The camera is never opened.
//   shots <out dir>   → <out>/<lang>/{hud,hud-collapsed,guide,toast}.png and <out>/<lang>/frames/f###.jpg
import AppKit
import SwiftUI

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

/// macOS-like abstract wallpaper.
struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.16), Color(red: 0.13, green: 0.05, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.16, green: 0.38, blue: 1.0)).frame(width: 900).blur(radius: 180).offset(x: -520, y: -300).opacity(0.75)
            Circle().fill(Color(red: 0.55, green: 0.25, blue: 0.95)).frame(width: 800).blur(radius: 170).offset(x: 260, y: -60).opacity(0.65)
            Circle().fill(Color(red: 0.92, green: 0.30, blue: 0.62)).frame(width: 760).blur(radius: 170).offset(x: 600, y: 380).opacity(0.6)
            Circle().fill(Color(red: 0.10, green: 0.75, blue: 0.85)).frame(width: 520).blur(radius: 150).offset(x: -380, y: 420).opacity(0.45)
            // soft light ribbons
            ForEach(0..<4) { i in
                Capsule().fill(Color.white.opacity(0.06))
                    .frame(width: 1600, height: 90 + CGFloat(i) * 30)
                    .blur(radius: 30)
                    .rotationEffect(.degrees(-24 + Double(i) * 7))
                    .offset(x: CGFloat(i) * 80 - 120, y: CGFloat(i) * 120 - 220)
            }
        }
        .ignoresSafeArea()
    }
}

func capture(_ rect: CGRect, _ path: String, jpg: Bool = false) {
    // rect in Cocoa global coordinates (bottom-left origin) → screencapture's top-left points
    let top = (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY
    let r = "\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o"] + (jpg ? ["-t", "jpg"] : []) + ["-R", r, path]
    try? p.run()
    p.waitUntilExit()
}

/// Runs steps one after another with a delay before each.
final class Script {
    private var steps: [(Double, () -> Void)] = []
    func then(_ delay: Double, _ f: @escaping () -> Void) { steps.append((delay, f)) }
    func run(done: @escaping () -> Void) {
        guard !steps.isEmpty else { done(); return }
        let (d, f) = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { f(); self.run(done: done) }
    }
}

MainActor.assumeIsolated {
    setenv("WINDOW_PICKER_FAKE", "6", 1)
    guard let screen = NSScreen.main else { exit(1) }

    let backdrop = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    backdrop.level = NSWindow.Level(rawValue: 22)         // above normal windows and the Dock, below the menu bar
    func raisePanels() {                                   // our panels must sit above the backdrop
        for w in NSApp.windows where w !== backdrop && w.level.rawValue < 23 { w.level = NSWindow.Level(rawValue: 23) }
    }
    backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    backdrop.contentView = NSHostingView(rootView: Wallpaper())
    backdrop.setFrame(screen.frame, display: true)
    backdrop.orderFrontRegardless()

    let hud = HUD(session: nil)
    let guide = GestureGuide()
    let toast = Toast()
    let picker = WindowPicker()
    let hand = SelfTest.hand(at: CGPoint(x: 0.5, y: 0.47), fingers: SelfTest.open, s: 0.2, t: 0)

    // picker animation path (normalized screen coords) and ring progress
    var path: [(CGPoint, CGFloat)] = []
    func move(_ a: CGPoint, _ b: CGPoint, _ n: Int) {
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1), e = t * t * (3 - 2 * t)
            path.append((CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e), 0))
        }
    }
    func hold(_ p: CGPoint, wait: Int, fill: Int, after: Int) {
        for _ in 0..<wait { path.append((p, 0)) }
        for i in 1...fill { path.append((p, CGFloat(i) / CGFloat(fill))) }
        for _ in 0..<after { path.append((p, 1)) }
    }
    let start = CGPoint(x: 0.12, y: 0.80), safari = CGPoint(x: 0.24, y: 0.42), terminal = CGPoint(x: 0.587, y: 0.42)
    let notes = CGPoint(x: 0.76, y: 0.43), calendar = CGPoint(x: 0.587, y: 0.61), mailClose = CGPoint(x: 0.473, y: 0.545)
    move(start, safari, 14); move(safari, terminal, 14); move(terminal, notes, 8); move(notes, calendar, 12)
    hold(calendar, wait: 6, fill: 18, after: 6)
    move(calendar, mailClose, 14)
    hold(mailClose, wait: 6, fill: 22, after: 8)

    let s = Script()
    for lang in Lang.allCases {
        let dir = out.appendingPathComponent(lang.rawValue)
        let frames = dir.appendingPathComponent("frames")
        let label = { tr("point & hold", "наведите и задержите", "指向并停留") }
        s.then(0.3) {
            try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            L10n.shared.lang = lang
            hud.setCollapsed(false)
            hud.show()
            hud.update(hand: hand, mode: .picker, label: label())
            raisePanels()
            hud.demoCenter(on: screen)
        }
        s.then(0.6) { hud.demoCenter(on: screen) }
        s.then(0.4) {
            hud.update(hand: hand, mode: .picker, label: label())
            if let f = hud.demoFrame { capture(f.insetBy(dx: -56, dy: -56), dir.appendingPathComponent("hud.png").path) }
            hud.setCollapsed(true)
        }
        s.then(0.5) { hud.demoCenter(on: screen) }
        s.then(0.3) {
            hud.update(hand: hand, mode: .picker, label: label())
            if let f = hud.demoFrame { capture(f.insetBy(dx: -40, dy: -40), dir.appendingPathComponent("hud-collapsed.png").path) }
            hud.hide()
            guide.show()
            raisePanels()
        }
        s.then(1.0) {
            if let f = guide.demoFrame { capture(f.insetBy(dx: -60, dy: -60), dir.appendingPathComponent("guide.png").path) }
            guide.close()
            toast.show(enabled: true)
        }
        s.then(0.55) {
            if let f = toast.demoFrame {
                var r = f.insetBy(dx: -70, dy: -34)
                r.size.height = min(r.maxY, screen.visibleFrame.maxY) - r.minY   // stay below the menu bar / notch
                capture(r, dir.appendingPathComponent("toast.png").path)
            }
            toast.demoHide()
        }
        s.then(2.0) { picker.demoOpen(count: 6) }   // after the badge has faded out
        for (i, (p, ring)) in path.enumerated() {
            s.then(i == 0 ? 0.6 : 0.05) {
                picker.demoSet(pointer: p, ring: ring)
            }
            s.then(0.06) {
                // full screen without the menu bar (it shows the user's apps and clock)
                let r = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width,
                               height: screen.visibleFrame.maxY - screen.frame.minY)
                capture(r, frames.appendingPathComponent(String(format: "f%03d.jpg", i)).path, jpg: true)
            }
        }
        s.then(0.1) { picker.close() }
    }
    s.run {
        backdrop.orderOut(nil)
        print("done")
        exit(0)
    }
}
app.run()
