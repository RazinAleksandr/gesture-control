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

private let gestureSections: [(String, [GestureItem])] = [
    ("Начало", [
        GestureItem(glyph: "👍", title: "Включить и выключить",
                    text: "Большой палец вверх, держите секунду. После запуска жесты выключены — ничего не сработает случайно."),
        GestureItem(glyph: "📷", title: "Окно камеры",
                    text: "Его можно перетаскивать. Кнопка с глазом прячет видео, «?» открывает эту справку."),
    ]),
    ("Окна", [
        GestureItem(glyph: "✊ → 🖐", title: "Показать все окна",
                    text: "Быстро сожмите кулак и раскройте ладонь, растопырив все пальцы."),
        GestureItem(glyph: "☝️", title: "Открыть окно",
                    text: "Наведите палец на плитку и задержите — круг заполнится, окно откроется."),
        GestureItem(glyph: "✕  −  ⤢", title: "Закрыть, свернуть, во весь экран",
                    text: "Задержите палец на кнопке в углу плитки."),
        GestureItem(glyph: "🖐 → ✊", title: "Закрыть выбор",
                    text: "Ладонь, затем кулак — через полторы секунды после открытия. Или просто опустите руку."),
    ]),
    ("Прокрутка и столы", [
        GestureItem(glyph: "✌️", title: "Прокрутка",
                    text: "Два пальца вверх: страница движется за рукой, как на тачпаде. Взмах и сжатые пальцы — инерция."),
        GestureItem(glyph: "🖐 ⇄", title: "Рабочие столы",
                    text: "Спокойно покажите ладонь, затем быстрый взмах влево или вправо."),
    ]),
]

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
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                AppMark(size: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Жесты")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Камера видит руку — всё обрабатывается на этом Mac и никуда не отправляется.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.top, 8)

            ForEach(gestureSections, id: \.0) { section in
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
                Label("Рука в 40–70 см от камеры, ладонью к экрану, при хорошем свете", systemImage: "lightbulb")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button(action: onClose) {
                    Text("Понятно")
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
