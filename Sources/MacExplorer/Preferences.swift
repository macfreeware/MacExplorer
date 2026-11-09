import AppKit
import MacExplorerCore
import UniformTypeIdentifiers

enum ToolbarDisplay: String, CaseIterable {
    case icon, iconAndLabel, label

    var mode: NSToolbar.DisplayMode {
        switch self {
        case .icon: return .iconOnly
        case .iconAndLabel: return .iconAndLabel
        case .label: return .labelOnly
        }
    }

    init(_ mode: NSToolbar.DisplayMode) {
        switch mode {
        case .iconAndLabel: self = .iconAndLabel
        case .labelOnly: self = .label
        default: self = .icon
        }
    }
}

/// Klavye düzeni (Ayarlar ▸ Klavye).
enum KeyboardMode: String, CaseIterable {
    /// Enter açar, Backspace üst klasöre çıkar, F2 yeniden adlandırır, Delete siler; Ctrl kısayolları ⌘ gibi çalışır.
    case windows
    /// Finder davranışı: ⌘↓ açar, ⌘↑ üst klasör, Enter yeniden adlandırır, ⌘⌫ siler.
    case mac
}

/// Açılıp kapatılabilen arayüz öğeleri (Ayarlar ▸ Arayüz); hepsi varsayılan olarak açık.
enum UIElement: String, CaseIterable {
    case statusBar, viewButtons, functionBar, toolbarEdit, toolbarViewMode, toolbarTerminal, toolbarHidden, toolbarDualPane, toolbarPreview, toolbarNewWindow

    var key: String { "show." + rawValue }
    var isShown: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Boyut sütununun biçimi (Ayarlar ▸ Genel).
enum SizeDisplay: String, CaseIterable {
    /// KB, MB, GB … (Finder gibi; varsayılan).
    case automatic
    /// Her zaman KB (Windows Gezgini gibi).
    case kilobytes

    func string(_ bytes: Int64) -> String {
        switch self {
        case .automatic: return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case .kilobytes: return SizeFormat.kilobytes(bytes)
        }
    }
}

enum Preferences {
    enum Key {
        static let keyboardMode = "keyboardMode"
        static let showHidden = "showHidden"
        static let appearance = "appearance"
        static let theme = "theme"
        static let viewMode = "viewMode"
        static let toolbarDisplay = "toolbarDisplay"
        static let editorApp = "editorApp"
        static let restoreSession = "restoreSession"
        static let dimInactivePane = "dimInactivePane"
        static let previewPane = "previewPane"
        static let searchSubfolders = "searchSubfolders"
        static let previewPaneWidth = "previewPaneWidth"
        static let sizeDisplay = "sizeDisplay"
        static let columnWidths = "columnWidths"
        static let selectIncludesFolders = "selectIncludesFolders"
        static let updateAutoCheck = "updateAutoCheck"
        static let updateLastCheck = "updateLastCheck"
        static let updateSkippedVersion = "updateSkippedVersion"
    }

    /// Güncellemeler günde bir kez kendiliğinden denetlenir (Ayarlar ▸ Genel; varsayılan açık).
    static var updateAutoCheck: Bool { UserDefaults.standard.object(forKey: Key.updateAutoCheck) as? Bool ?? true }

    static var updateLastCheck: Double {
        get { UserDefaults.standard.double(forKey: Key.updateLastCheck) }
        set { UserDefaults.standard.set(newValue, forKey: Key.updateLastCheck) }
    }

    /// "Bu sürümü atla" denen sürüm: otomatik denetleme onu bir daha sormaz.
    static var updateSkippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Key.updateSkippedVersion) }
        set { UserDefaults.standard.set(newValue, forKey: Key.updateSkippedVersion) }
    }

    /// Desene göre seçim (Num + / Num −) ve tersine çevirme (Num *) klasörleri de kapsar mı (Ayarlar ▸ Genel; varsayılan kapalı).
    static var selectIncludesFolders: Bool { UserDefaults.standard.bool(forKey: Key.selectIncludesFolders) }

    /// Ayrıntılar görünümünde kullanıcının verdiği sütun genişlikleri (sütun kimliği → genişlik); tüm pencereler için.
    /// "Ad" sütunu kayıtlı değilse kalan alanı doldurur (en çok `Preferences.defaultNameWidth`).
    static var columnWidths: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Key.columnWidths) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Key.columnWidths) }
    }

    /// Geniş pencerede "Ad" sütunu en çok bu kadar genişler; diğer sütunlar en sağa kaçmaz (Windows Gezgini gibi).
    static let defaultNameWidth: CGFloat = 480

    static var sizeDisplay: SizeDisplay {
        SizeDisplay(rawValue: UserDefaults.standard.string(forKey: Key.sizeDisplay) ?? "") ?? .automatic
    }

    /// Önizleme bölmesi açık mı (tüm pencereler için, Windows Gezgini gibi) ve genişliği.
    static var previewPane: Bool {
        get { UserDefaults.standard.bool(forKey: Key.previewPane) }
        set { UserDefaults.standard.set(newValue, forKey: Key.previewPane) }
    }

    static var previewPaneWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: Key.previewPaneWidth) as? Double ?? 300) }
        set { UserDefaults.standard.set(Double(newValue), forKey: Key.previewPaneWidth) }
    }

    static var keyboardMode: KeyboardMode {
        KeyboardMode(rawValue: UserDefaults.standard.string(forKey: Key.keyboardMode) ?? "") ?? .windows
    }

    /// Araç çubuğu gösterimi: Yalnızca simge / Simge ve metin / Yalnızca metin.
    static var toolbarDisplay: ToolbarDisplay {
        get { ToolbarDisplay(rawValue: UserDefaults.standard.string(forKey: Key.toolbarDisplay) ?? "") ?? .icon }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.toolbarDisplay) }
    }

    /// F4 Düzenle'nin uygulaması; seçilmediyse sistemin metin düzenleyicisi.
    static var editorApp: URL? {
        get {
            if let path = UserDefaults.standard.string(forKey: Key.editorApp), FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return NSWorkspace.shared.urlForApplication(toOpen: .plainText)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: Key.editorApp) }
    }

    /// Çift panelde etkin olmayan panel soluk (Ayarlar ▸ Arayüz; varsayılan açık).
    static var dimInactivePane: Bool {
        UserDefaults.standard.object(forKey: Key.dimInactivePane) as? Bool ?? true
    }

    /// Arama kutusu alt klasörlerde de arar (Windows Gezgini gibi; varsayılan açık).
    static var searchSubfolders: Bool {
        get { UserDefaults.standard.object(forKey: Key.searchSubfolders) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.searchSubfolders) }
    }

    static var showHidden: Bool {
        get { UserDefaults.standard.bool(forKey: Key.showHidden) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showHidden) }
    }
}

/// Uygulama kimliği `local.macexplorer.app`'ten `com.freeware2.macexplorer`'a geçti: ayarlar (pencereler, sunucular,
/// görünümler, dil …) eski kimliğin ayar dosyasından bir kez kopyalanır. Eski dosya silinmez.
enum SettingsMigration {
    static let oldDomain = "local.macexplorer.app"
    private static let doneKey = "migratedFromLocalDomain"

    static func run() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != oldDomain, !defaults.bool(forKey: doneKey) else { return }
        if let old = defaults.persistentDomain(forName: oldDomain) {
            for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: doneKey)
    }
}
