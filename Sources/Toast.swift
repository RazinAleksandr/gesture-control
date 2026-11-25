import AppKit

/// Big short message in the middle of the screen (on/off feedback).
@MainActor final class Toast {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var generation = 0

    func show(_ text: String, color: NSColor) {
        let p = panel ?? makePanel()
        label?.stringValue = text
        label?.textColor = .white
        p.contentView?.layer?.backgroundColor = color.withAlphaComponent(0.85).cgColor
        if let screen = NSScreen.main {
            let size = CGSize(width: 420, height: 110)
            let f = screen.frame
            p.setFrame(CGRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        generation += 1
        let gen = generation
        p.alphaValue = 1
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, let p = self.panel else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 },
                                                     completionHandler: { MainActor.assumeIsolated { if gen == self.generation { p.orderOut(nil) } } })
            }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 110),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView(frame: p.contentRect(forFrameRect: p.frame))
        v.wantsLayer = true
        v.layer?.cornerRadius = 22
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 30, weight: .semibold)
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                                     l.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        p.contentView = v
        panel = p
        label = l
        return p
    }
}
