import AppKit

/// Shared visual language: dark "glass" surfaces, hairline borders, SF Pro Rounded,
/// and the blue → violet → magenta accent gradient from the app icon.
enum Theme {
    // accent gradient (same as the app icon)
    static let accentA = NSColor(srgbRed: 0.20, green: 0.42, blue: 1.00, alpha: 1)
    static let accentB = NSColor(srgbRed: 0.47, green: 0.27, blue: 0.95, alpha: 1)
    static let accentC = NSColor(srgbRed: 0.80, green: 0.25, blue: 0.75, alpha: 1)
    static var accentGradient: [CGColor] { [accentA.cgColor, accentB.cgColor, accentC.cgColor] }

    static let danger = NSColor(srgbRed: 1.00, green: 0.38, blue: 0.42, alpha: 1)
    static let scrollTint = NSColor(srgbRed: 0.35, green: 0.80, blue: 1.00, alpha: 1)
    static let textPrimary = NSColor(white: 1, alpha: 0.95)
    static let textSecondary = NSColor(white: 1, alpha: 0.62)
    static let hairline = NSColor(white: 1, alpha: 0.14)
    static let surface = NSColor(white: 1, alpha: 0.08)        // cards on glass
    static let surfaceHover = NSColor(white: 1, alpha: 0.16)

    static let panelRadius: CGFloat = 20
    static let cardRadius: CGFloat = 16

    /// SF Pro Rounded.
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }

    static func modeColor(_ m: GestureMode) -> NSColor {
        switch m {
        case .idle: return NSColor(white: 1, alpha: 0.9)
        case .scroll: return scrollTint
        case .picker: return accentB
        case .cooldown: return NSColor(white: 1, alpha: 0.45)
        case .paused: return NSColor(white: 1, alpha: 0.35)
        }
    }

    static func modeName(_ m: GestureMode) -> String {
        switch m {
        case .idle: return "Готов"
        case .scroll: return "Прокрутка"
        case .picker: return "Выбор окна"
        case .cooldown: return "Пауза"
        case .paused: return "Выключено"
        }
    }

    /// Dark frosted-glass view with rounded corners and a hairline border.
    static func glass(cornerRadius: CGFloat = panelRadius) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1
        v.layer?.borderColor = hairline.cgColor
        return v
    }

    /// Gradient layer with the accent colors (diagonal).
    static func accentGradientLayer() -> CAGradientLayer {
        let g = CAGradientLayer()
        g.colors = accentGradient
        g.startPoint = CGPoint(x: 0, y: 1)
        g.endPoint = CGPoint(x: 1, y: 0)
        return g
    }
}
