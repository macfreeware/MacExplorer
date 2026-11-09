import SwiftUI

/// Arayüz dili (Ayarlar ▸ Genel ▸ Dil). Hemen uygulanır (bkz. LiveLanguage); `AppleLanguages` ile sonraki açılışlarda da geçerlidir.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, tr, en
    var id: String { rawValue }

    static let defaultsKey = "language"

    var title: LocalizedStringKey {
        switch self {
        case .system: return "Sistem dili"
        case .tr: return "Türkçe"
        case .en: return "English"
        }
    }

    var flag: String {
        switch self {
        case .system: return "🌐"
        case .tr: return "🇹🇷"
        case .en: return "🇬🇧"
        }
    }

    /// Bu seçimle açıldığında kullanılacak çevirinin dil kodu ("tr", "en").
    var code: String? {
        var preferences = [rawValue]
        if self == .system {
            preferences = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? []
        }
        return Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences).first
    }

    /// Seçimi, Bundle'ın bir sonraki açılışta okuyacağı yere yazar.
    func save() {
        let d = UserDefaults.standard
        d.set(rawValue, forKey: Self.defaultsKey)
        if self == .system { d.removeObject(forKey: "AppleLanguages") } else { d.set([rawValue], forKey: "AppleLanguages") }
    }

    static var saved: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

}
