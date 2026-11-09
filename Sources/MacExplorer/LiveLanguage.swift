import AppKit
import SwiftUI

/// Dili uygulamayı yeniden başlatmadan değiştirir. Tüm `String(localized:)` çağrıları `bundle: .live` ile
/// seçilen dilin `.lproj` klasöründen okur; SwiftUI görünümleri dili `liveLocale()` ile alır. Dil değişince
/// menüler ve pencereler yeniden kurulur (bkz. AppDelegate.applyLanguage).
@MainActor
enum LiveLanguage {
    /// Seçilen dilin çevirileri (nil: açılıştaki dil).
    nonisolated(unsafe) static var bundle: Bundle?

    /// Şu anda kullanılan dil kodu ("tr", "en").
    static var code: String? {
        bundle.map { ($0.bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".lproj", with: "") }
            ?? Bundle.main.preferredLocalizations.first
    }

    static var locale: Locale { code.map(Locale.init(identifier:)) ?? .current }

    static func use(_ code: String?) {
        bundle = code.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:))
    }
}

extension Bundle {
    /// Çevirilerin okunduğu paket: seçilen dilin `.lproj` klasörü (dil çalışırken değişebilir).
    nonisolated static var live: Bundle { LiveLanguage.bundle ?? .main }
}

extension View {
    /// SwiftUI metinleri (Text, Button, Toggle …) seçilen dilde aransın.
    @MainActor
    func liveLocale() -> some View { environment(\.locale, LiveLanguage.locale) }
}
