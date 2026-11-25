import AppKit
import SwiftUI

/// Compact glass badge at the top of the screen (gestures on/off feedback), slides in and fades out.
private struct ToastView: View {
    let enabled: Bool
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(enabled ? AnyShapeStyle(Color.gcAccent) : AnyShapeStyle(Color.white.opacity(0.14)))
                Image(systemName: enabled ? "hand.raised.fingers.spread.fill" : "hand.raised.slash.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: enabled ? .gcB.opacity(0.6) : .clear, radius: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(enabled ? tr("Gestures on", "Жесты включены", "手势已开启") : tr("Gestures off", "Жесты выключены", "手势已关闭"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(enabled ? tr("👍 to turn off", "👍 — выключить", "👍 即可关闭") : tr("👍 to turn on", "👍 — включить", "👍 即可开启"))
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.leading, 8).padding(.trailing, 20).padding(.vertical, 8)
        .background(
            Capsule().fill(.clear)
                .background(GlassBackground(material: .hudWindow).clipShape(Capsule()))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        )
        .environment(\.colorScheme, .dark)
    }
}

@MainActor final class Toast {
    private var panel: NSPanel?
    private var generation = 0

    func show(enabled: Bool) {
        let host = NSHostingView(rootView: ToastView(enabled: enabled))
        let size = host.fittingSize
        let p = panel ?? makePanel()
        panel = p
        p.contentView = host
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let target = CGRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 14, width: size.width, height: size.height)
        generation += 1
        let gen = generation
        p.setFrame(target.offsetBy(dx: 0, dy: 16), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, let p = self.panel else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    p.animator().alphaValue = 0
                    p.animator().setFrame(target.offsetBy(dx: 0, dy: 10), display: true)
                }, completionHandler: {
                    MainActor.assumeIsolated { if gen == self.generation { p.orderOut(nil) } }
                })
            }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }
}
