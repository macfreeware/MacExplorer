import AppKit
import MacExplorerCore

/// Oturumu hatırlama: kapanırken açık pencereler (konum, kenar çubuğu, çift panel, etkin panel) ve her
/// sekme (klasör, Geri/İleri geçmişi, görünüm, sıralama, seçim) kaydedilir; açılışta kaldığı gibi geri yüklenir.
/// Son pencere kapatılınca onun durumu saklanır: Dock'tan yeniden açınca o pencere geri gelir.
@MainActor
enum SessionStore {
    /// Geliştirme denemeleri (MACEXPLORER_SESSION_TEST) ayrı anahtar kullanır: kullanıcının oturumu bozulmaz.
    private static var key: String { isSessionTest ? "session.test" : "session" }
    private static var isSessionTest: Bool { ProcessInfo.processInfo.environment["MACEXPLORER_SESSION_TEST"] != nil }

    struct SavedTab: Codable {
        var path: String
        var back: [String]
        var forward: [String]
        var viewMode: String
        var sortColumn: String
        var ascending: Bool
        var selected: [String]
    }

    struct SavedWindow: Codable {
        var frame: String
        var left: [SavedTab]
        var leftSelected: Int
        var right: [SavedTab]
        var rightSelected: Int
        var dualPane: Bool
        var rightActive: Bool
        var sidebarCollapsed: Bool
    }

    /// Ayarlar ▸ Genel ▸ Son pencereleri geri yükle (varsayılan açık).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Preferences.Key.restoreSession) as? Bool ?? true
    }

    /// Geliştirme ekran görüntüleri kullanıcının oturumunu okumaz ve bozmaz.
    private static var isDebugRun: Bool {
        ProcessInfo.processInfo.environment["MACEXPLORER_SNAPSHOT"] != nil && !isSessionTest
    }

    static func save(_ states: [BrowserWindowController.State]) {
        guard !isDebugRun, !states.isEmpty,
              let data = try? JSONEncoder().encode(states.map(encode)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [BrowserWindowController.State] {
        guard isEnabled, !isDebugRun, let data = UserDefaults.standard.data(forKey: key),
              let windows = try? JSONDecoder().decode([SavedWindow].self, from: data) else { return [] }
        return windows.compactMap(decode)
    }

    // MARK: Dönüştürme

    private static func encode(_ s: BrowserWindowController.State) -> SavedWindow {
        SavedWindow(frame: NSStringFromRect(s.frame ?? .zero), left: s.left.map(encode), leftSelected: s.leftSelected,
                    right: s.right.map(encode), rightSelected: s.rightSelected, dualPane: s.dualPane,
                    rightActive: s.rightActive, sidebarCollapsed: s.sidebarCollapsed)
    }

    /// Yerel konumlar yol olarak, sunucu konumları (sftp://…) tam adres olarak saklanır; parola saklanmaz.
    private static func encode(_ tab: TabState) -> SavedTab {
        SavedTab(path: string(tab.url), back: tab.history.backStack.map(string), forward: tab.history.forwardStack.map(string),
                 viewMode: tab.viewMode.rawValue, sortColumn: tab.sort.column.rawValue, ascending: tab.sort.ascending,
                 selected: tab.selectedURLs.map(string))
    }

    /// Arşivin içi saklanmaz: arşivin bulunduğu klasör olarak geri gelir.
    private static func string(_ url: URL) -> String {
        if Archives.isArchive(url) { return Archives.file(for: url)?.deletingLastPathComponent().path ?? FileManager.default.homeDirectoryForCurrentUser.path }
        return url.isRemote ? url.absoluteString : url.path
    }

    private static func url(_ text: String) -> URL {
        if text.contains("://"), let url = URL(string: text), url.isRemote { return url }
        return URL(fileURLWithPath: text)
    }

    private static func decode(_ w: SavedWindow) -> BrowserWindowController.State? {
        let left = w.left.map(decode), right = w.right.map(decode)
        guard !left.isEmpty else { return nil }
        let frame = NSRectFromString(w.frame)
        return BrowserWindowController.State(
            left: left, leftSelected: min(w.leftSelected, left.count - 1),
            right: right.isEmpty ? [TabState(url: left[0].url)] : right, rightSelected: right.isEmpty ? 0 : min(w.rightSelected, right.count - 1),
            dualPane: w.dualPane, rightActive: w.rightActive, sidebarCollapsed: w.sidebarCollapsed,
            frame: frame.width > 100 && isOnScreen(frame) ? frame : nil)
    }

    private static func decode(_ t: SavedTab) -> TabState {
        let saved = url(t.path)
        // Sunucu sekmesi geri gelir; sekmeye geçilince bağlanılır (parola gerekirse Anahtar Zinciri'nden ya da sorularak).
        let current = saved.isRemote ? saved : existingFolder(saved)
        let tab = TabState(url: current)
        tab.history = NavigationHistory(current: current, back: t.back.map(url), forward: t.forward.map(url))
        tab.viewMode = ViewMode(rawValue: t.viewMode) ?? .details
        tab.sort = FileSort(column: SortColumn(rawValue: t.sortColumn) ?? .name, ascending: t.ascending)
        tab.selectedURLs = t.selected.map(url)
        return tab
    }

    /// Klasör artık yoksa (silindi, disk çıkarıldı) var olan en yakın üst klasör; o da yoksa ana klasör.
    private static func existingFolder(_ url: URL) -> URL {
        var candidate = url
        while candidate.path != "/" {
            if FileInfo.isRealDirectory(candidate) || FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            candidate.deleteLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Kaydedilen konum bağlı bir ekranda görünüyor mu (ekran çıkarıldıysa pencere ortalanır).
    private static func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 40, dy: 40)) }
    }
}
