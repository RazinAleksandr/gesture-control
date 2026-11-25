import Foundation
import Combine

/// Interface language. Default: the system language (Chinese, Russian, otherwise English);
/// the choice from the guide window or the menu is remembered.
enum Lang: String, CaseIterable, Identifiable {
    case en, ru, zh
    var id: String { rawValue }
    var title: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .zh: return "中文"
        }
    }
}

extension Notification.Name {
    static let gcLanguageChanged = Notification.Name("gc.languageChanged")
}

final class L10n: ObservableObject {
    static let shared = L10n()
    private static let key = "gc.lang"

    @Published var lang: Lang {
        didSet {
            guard lang != oldValue else { return }
            UserDefaults.standard.set(lang.rawValue, forKey: L10n.key)
            NotificationCenter.default.post(name: .gcLanguageChanged, object: nil)
        }
    }

    private init() {
        if let s = UserDefaults.standard.string(forKey: L10n.key), let l = Lang(rawValue: s) {
            lang = l
        } else {
            lang = L10n.systemDefault()
        }
    }

    static func systemDefault() -> Lang {
        let p = (Locale.preferredLanguages.first ?? "en").lowercased()
        if p.hasPrefix("zh") { return .zh }
        if p.hasPrefix("ru") { return .ru }
        return .en
    }
}

/// Inline translation: tr("English", "Русский", "中文").
func tr(_ en: String, _ ru: String, _ zh: String) -> String {
    switch L10n.shared.lang {
    case .en: return en
    case .ru: return ru
    case .zh: return zh
    }
}
