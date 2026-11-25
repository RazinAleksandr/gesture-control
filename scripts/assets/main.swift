// Renders README images from the app's own drawing code (no camera, no real windows):
//   docs/hud.png — camera HUD with a hand skeleton; frames for docs/demo.gif (assembled by scripts/render-assets.sh)
import AppKit

setenv("WINDOW_PICKER_FAKE", "6", 1)   // demo windows instead of the user's real ones
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let frames = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    // gesture cards
    let hud = HUD(session: nil)
    let c = CGPoint(x: 0.5, y: 0.47)
    let s: CGFloat = 0.2
    hud.renderDebugPNG(to: root.appendingPathComponent("hud.png"),
                       hand: SelfTest.hand(at: c, fingers: SelfTest.open, s: s, t: 0), mode: .picker, label: "раскрытая ладонь")

    // demo animation of the window picker
    let picker = WindowPicker()
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
    let start = CGPoint(x: 0.12, y: 0.78), safari = CGPoint(x: 0.25, y: 0.38), terminal = CGPoint(x: 0.585, y: 0.38)
    let notes = CGPoint(x: 0.75, y: 0.40), calendar = CGPoint(x: 0.583, y: 0.58), mailClose = CGPoint(x: 0.357, y: 0.509)
    move(start, safari, 14); move(safari, terminal, 14); move(terminal, notes, 8); move(notes, calendar, 12)
    hold(calendar, wait: 6, fill: 18, after: 6)
    move(calendar, mailClose, 14)
    hold(mailClose, wait: 6, fill: 22, after: 8)
    for (i, (p, d)) in path.enumerated() {
        picker.renderDebugPNG(to: frames.appendingPathComponent(String(format: "f%03d.png", i)),
                              pointer: p, size: CGSize(width: 1728, height: 1117), dwellProgress: d)
    }
    print("frames: \(path.count)")
}
