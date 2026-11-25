import AppKit
import SwiftUI

// MARK: - Shared SwiftUI bits

extension Color {
    static let gcA = Color(nsColor: Theme.accentA)
    static let gcB = Color(nsColor: Theme.accentB)
    static let gcC = Color(nsColor: Theme.accentC)
    static let gcAccent = LinearGradient(colors: [.gcA, .gcB, .gcC], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Behind-window blur for SwiftUI content.
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        // dark tint: keeps the glass dark over light windows too
        let tint = NSView(frame: v.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0.05, alpha: Theme.glassTint).cgColor
        tint.autoresizingMask = [.width, .height]
        v.addSubview(tint)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// App mark: hand symbol on the accent gradient (works without an .icns in dev builds).
struct AppMark: View {
    var size: CGFloat = 56
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color.gcAccent)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "hand.raised.fingers.spread.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white))
            .shadow(color: .gcB.opacity(0.5), radius: size * 0.2, y: size * 0.06)
    }
}

// MARK: - Gesture guide window

private struct GestureItem: Identifiable {
    let id = UUID()
    let glyph: String
    let title: String
    let text: String
}

private func gestureSections() -> [(String, [GestureItem])] { [
    (tr("Getting started", "Начало", "开始"), [
        GestureItem(glyph: "👍", title: tr("Turn on and off", "Включить и выключить", "开启与关闭"),
                    text: tr("Thumb up, hold for a second. Gestures start switched off, so nothing fires by accident.",
                             "Большой палец вверх, держите секунду. После запуска жесты выключены — ничего не сработает случайно.",
                             "竖起大拇指并保持一秒。启动后手势默认关闭，不会误触。")),
        GestureItem(glyph: "📷", title: tr("Camera panel", "Окно камеры", "摄像头面板"),
                    text: tr("Drag it anywhere. The eye hides the video, “?” opens this guide, ⏻ quits.",
                             "Его можно перетаскивать. Кнопка с глазом прячет видео, «?» открывает эту справку, ⏻ — выход.",
                             "可以随意拖动。眼睛图标隐藏画面，“?” 打开本说明，⏻ 退出。")),
    ]),
    (tr("Windows", "Окна", "窗口"), [
        GestureItem(glyph: "✊ → 🖐", title: tr("Show all windows", "Показать все окна", "显示所有窗口"),
                    text: tr("Make a quick fist, then open your palm with all fingers spread.",
                             "Быстро сожмите кулак и раскройте ладонь, растопырив все пальцы.",
                             "快速握拳，然后张开手掌，五指分开。")),
        GestureItem(glyph: "☝️", title: tr("Open a window", "Открыть окно", "打开窗口"),
                    text: tr("Point at a card and hold still — the ring fills up and the window opens.",
                             "Наведите палец на плитку и задержите — круг заполнится, окно откроется.",
                             "指向一张卡片并保持不动，圆环填满后窗口就会打开。")),
        GestureItem(glyph: "✕  −  ⤢", title: tr("Close, minimize, full screen", "Закрыть, свернуть, во весь экран", "关闭、最小化、全屏"),
                    text: tr("Hold your finger on a button in the card's corner.",
                             "Задержите палец на кнопке в углу плитки.",
                             "手指停在卡片角落的按钮上。")),
        GestureItem(glyph: "🖐 → ✊", title: tr("Close the picker", "Закрыть выбор", "关闭选择器"),
                    text: tr("Palm, then fist — at least 1.5 s after opening. Or just lower your hand.",
                             "Ладонь, затем кулак — через полторы секунды после открытия. Или просто опустите руку.",
                             "手掌，然后握拳（打开 1.5 秒后）。或者直接把手放下。")),
    ]),
    (tr("Scrolling & desktops", "Прокрутка и столы", "滚动与桌面"), [
        GestureItem(glyph: "✌️", title: tr("Scroll", "Прокрутка", "滚动"),
                    text: tr("Two fingers up: the page follows your hand like a trackpad. Flick and fold your fingers for inertia.",
                             "Два пальца вверх: страница движется за рукой, как на тачпаде. Взмах и сжатые пальцы — инерция.",
                             "竖起两根手指：页面像触控板一样跟随你的手。快速一挥再收拢手指即可惯性滚动。")),
        GestureItem(glyph: "🖐 ⇄", title: tr("Desktops", "Рабочие столы", "桌面"),
                    text: tr("Show a calm palm, then swipe quickly left or right.",
                             "Спокойно покажите ладонь, затем быстрый взмах влево или вправо.",
                             "先平稳地展示手掌，再快速向左或向右挥动。")),
    ]),
] }

private struct GestureCard: View {
    let item: GestureItem
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(item.glyph)
                .font(.system(size: item.glyph.count > 2 ? 22 : 30))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 6)
                .frame(width: 76, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.gcAccent.opacity(0.22))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.gcAccent.opacity(0.7), lineWidth: 1))
                )
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(item.text)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1))
        )
    }
}

struct GestureGuideView: View {
    var onClose: () -> Void = {}
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                AppMark(size: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Gestures", "Жесты", "手势"))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(tr("The camera sees your hand — everything is processed on this Mac and never leaves it.",
                            "Камера видит руку — всё обрабатывается на этом Mac и никуда не отправляется.",
                            "摄像头识别你的手——所有处理都在这台 Mac 上完成，数据不会离开设备。"))
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 12)
                Picker("", selection: $l10n.lang) {
                    ForEach(Lang.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
            }
            .padding(.top, 8)

            ForEach(gestureSections(), id: \.0) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.0.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.45))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(section.1) { GestureCard(item: $0) }
                    }
                }
            }

            HStack(alignment: .center) {
                Label(tr("Hand 40–70 cm from the camera, palm towards the screen, good light",
                         "Рука в 40–70 см от камеры, ладонью к экрану, при хорошем свете",
                         "手离摄像头 40–70 厘米，掌心朝向屏幕，光线充足"), systemImage: "lightbulb")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button(action: onClose) {
                    Text(tr("Got it", "Понятно", "知道了"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26).padding(.vertical, 10)
                        .background(Capsule().fill(Color.gcAccent))
                        .shadow(color: .gcB.opacity(0.5), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .background(Button("", action: onClose).keyboardShortcut(.cancelAction).opacity(0))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 24)
        .frame(width: 780)
        .background(
            ZStack {
                GlassBackground(material: .hudWindow)
                LinearGradient(colors: [.gcA.opacity(0.18), .clear, .gcC.opacity(0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .environment(\.colorScheme, .dark)
    }
}

@MainActor final class GestureGuide {
    private var window: NSWindow?
    var demoFrame: CGRect? { window?.frame }   // for README screenshots

    func show() {
        let w = window ?? makeWindow()
        window = w
        w.center()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil) }

    private func makeWindow() -> NSWindow {
        let host = NSHostingView(rootView: GestureGuideView(onClose: { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }))
        let size = host.fittingSize
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.contentView = host
        // text length differs between languages: refit the height, keeping the top edge in place
        NotificationCenter.default.addObserver(forName: .gcLanguageChanged, object: nil, queue: .main) { [weak w, weak host] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let w, let host else { return }
                    host.layoutSubtreeIfNeeded()
                    let fit = host.fittingSize
                    guard fit.width > 0, fit.height > 0 else { return }
                    var f = w.frameRect(forContentRect: CGRect(origin: .zero, size: fit))
                    f.origin = CGPoint(x: w.frame.minX, y: w.frame.maxY - f.height)
                    w.setFrame(f, display: true, animate: true)
                }
            }
        }
        // no title-bar buttons: the guide closes with «Понятно» (Enter) or Esc
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        return w
    }

    /// Debug: render the guide to a PNG (no window shown).
    static func renderPNG(to url: URL) {
        let host = NSHostingView(rootView: GestureGuideView().background(Color(white: 0.09)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
