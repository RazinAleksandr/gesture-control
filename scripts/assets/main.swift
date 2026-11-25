// Renders README images from the app's own drawing code (no camera, no real windows).
//   render-assets <docs dir> <shots dir> <icon 512 png>
//   Banner per language (docs/banner[-ru|-zh].png) built around a real screenshot from scripts/shots.
import AppKit
import SwiftUI

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let frames = URL(fileURLWithPath: CommandLine.arguments[2])
let iconPath = CommandLine.arguments[3]

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
  // banner per language, using a real screenshot frame from scripts/shots
  for lang in Lang.allCases {
    L10n.shared.lang = lang
    let sfx = lang == .en ? "" : "-\(lang.rawValue)"
    let shotURL = frames.appendingPathComponent("\(lang.rawValue)/frames/f058.jpg")
    guard let shot = NSImage(contentsOf: shotURL) else { print("missing \(shotURL.path)"); continue }
    let renderer = ImageRenderer(content: Banner(icon: NSImage(contentsOfFile: iconPath)!, shot: shot))
    renderer.scale = 2
    if let cg = renderer.cgImage {
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
            .write(to: root.appendingPathComponent("banner\(sfx).png"))
    }
    print("banner \(lang.rawValue)")
  }
}
