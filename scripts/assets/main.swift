// Renders README images from the app's own drawing code (no camera, no real windows).
//   render-assets <docs dir> <frames dir> <icon 512 png>
//   For each language (en, ru, zh): docs/banner[-ru|-zh].png, hud…, hud-collapsed…, guide….png,
//   and frames in <frames dir>/<lang>/ for demo[-ru|-zh].gif (assembled by scripts/render-assets.sh)
import AppKit
import SwiftUI

setenv("WINDOW_PICKER_FAKE", "6", 1)   // demo windows instead of the user's real ones
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let frames = URL(fileURLWithPath: CommandLine.arguments[2])
let iconPath = CommandLine.arguments[3]
try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

func snapshot<V: View>(_ view: V, to url: URL) {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(0.08)).overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1)))
    }
}

struct Banner: View {
    let icon: NSImage
    let shot: NSImage
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.03, blue: 0.07), Color(red: 0.08, green: 0.04, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.gcA.opacity(0.45)).frame(width: 520).blur(radius: 140).offset(x: -460, y: -220)
            Circle().fill(Color.gcC.opacity(0.35)).frame(width: 560).blur(radius: 160).offset(x: 520, y: 240)
            HStack(spacing: 56) {
                VStack(alignment: .leading, spacing: 18) {
                    Image(nsImage: icon).resizable().frame(width: 112, height: 112)
                        .shadow(color: .gcB.opacity(0.6), radius: 30, y: 10)
                    Text("Gesture Control")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(tr("Control your Mac with your hand.\nJust the camera. Fully on-device.",
                            "Управляйте Mac рукой.\nТолько камера. Всё на устройстве.",
                            "用手控制你的 Mac。\n只需摄像头，完全本地运行。"))
                        .font(.system(size: 24, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineSpacing(4)
                    HStack(spacing: 10) {
                        Chip(text: "macOS 14+"); Chip(text: "Apple Vision")
                        Chip(text: tr("On-device", "На устройстве", "本地运行")); Chip(text: tr("Open source", "Открытый код", "开源"))
                    }
                    .padding(.top, 6)
                }
                Image(nsImage: shot).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 600)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
                    .shadow(color: .gcB.opacity(0.35), radius: 60)
                    .rotation3DEffect(.degrees(-10), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            }
        }
        .frame(width: 1280, height: 520)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

MainActor.assumeIsolated {
  for lang in Lang.allCases {
    L10n.shared.lang = lang
    let sfx = lang == .en ? "" : "-\(lang.rawValue)"
    let langFrames = frames.appendingPathComponent(lang.rawValue)
    try? FileManager.default.createDirectory(at: langFrames, withIntermediateDirectories: true)

    // camera HUD, expanded and collapsed
    let hud = HUD(session: nil)
    let hand = SelfTest.hand(at: CGPoint(x: 0.5, y: 0.47), fingers: SelfTest.open, s: 0.2, t: 0)
    let label = tr("point & hold", "наведите и задержите", "指向并停留")
    hud.renderDebugPNG(to: root.appendingPathComponent("hud\(sfx).png"), hand: hand, mode: .picker, label: label)
    hud.renderDebugPNG(to: root.appendingPathComponent("hud-collapsed\(sfx).png"), hand: hand, mode: .picker, label: label,
                       collapsed: true)

    // gesture guide
    GestureGuide.renderPNG(to: root.appendingPathComponent("guide\(sfx).png"))

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
    let start = CGPoint(x: 0.12, y: 0.80), safari = CGPoint(x: 0.24, y: 0.42), terminal = CGPoint(x: 0.587, y: 0.42)
    let notes = CGPoint(x: 0.76, y: 0.43), calendar = CGPoint(x: 0.587, y: 0.61), mailClose = CGPoint(x: 0.473, y: 0.545)
    move(start, safari, 14); move(safari, terminal, 14); move(terminal, notes, 8); move(notes, calendar, 12)
    hold(calendar, wait: 6, fill: 18, after: 6)
    move(calendar, mailClose, 14)
    hold(mailClose, wait: 6, fill: 22, after: 8)
    for (i, (p, d)) in path.enumerated() {
        picker.renderDebugPNG(to: langFrames.appendingPathComponent(String(format: "f%03d.png", i)),
                              pointer: p, size: CGSize(width: 1728, height: 1117), dwellProgress: d)
    }

    // banner: icon + title + a picker frame
    let shot = NSImage(contentsOf: langFrames.appendingPathComponent(String(format: "f%03d.png", 58)))!
    let renderer = ImageRenderer(content: Banner(icon: NSImage(contentsOfFile: iconPath)!, shot: shot))
    renderer.scale = 2
    if let cg = renderer.cgImage {
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
            .write(to: root.appendingPathComponent("banner\(sfx).png"))
    }
    print("\(lang.rawValue): frames \(path.count)")
  }
}
