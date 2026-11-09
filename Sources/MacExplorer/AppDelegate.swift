import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Açık gezgin pencereleri (pencere kapanınca listeden çıkar).
    private var controllers: [BrowserWindowController] = []
    /// Açılış sırasında gelen "klasörü aç" / "Finder'da göster" istekleri: oturum yerine bunlar açılır.
    private var launching = true
    private var launchRequests: [() -> Void] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        SettingsMigration.run()
    }

    /// Klasör açma isteği (Dock simgesine bırakma, Birlikte Aç, `open -a`).
    /// Windows Gezgini gibi her klasör kendi penceresinde açılır.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { !folders.contains($0) }
        run {
            for folder in folders { self.newWindow(at: folder) }
            if !files.isEmpty { self.reveal(files) }
        }
    }

    /// Öğelerin klasörünü açıp onları seçili gösterir; aynı klasördekiler tek pencerede.
    func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        run {
            let groups = Dictionary(grouping: urls.map(\.standardizedFileURL)) { $0.deletingLastPathComponent() }
            for (directory, items) in groups.sorted(by: { $0.key.path < $1.key.path }) {
                self.newWindow(at: directory)
                self.controllers.last?.show(items, in: directory)
            }
        }
    }

    private func run(_ request: @escaping () -> Void) {
        if launching { launchRequests.append(request) } else { request() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LiveLanguage.use(AppLanguage.saved.code)
        Theme.applyAppearance()
        NSWindow.allowsAutomaticWindowTabbing = false   // sekmeler bizim; macOS pencere sekmeleri kapalı
        NSApp.mainMenu = MainMenu.build()
        // Başka uygulamada kopyalama yapılınca kesilen öğelerin soluk görünümü kalksın.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FileClipboard.notify() }
        }
        // Oturum: kapanırken açık olan pencereler kaldığı gibi açılır (Ayarlar ▸ Genel'den kapatılabilir).
        launching = false
        if !launchRequests.isEmpty {
            launchRequests.forEach { $0() }
            launchRequests = []
        } else if !restoreSession() {
            newWindow(nil)
        }
        NSApp.activate()
        if let first = controllers.first { DebugSnapshot.runIfRequested(first) }
        Updater.checkAutomatically()
        NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { saveSession() }

    /// Açık pencerelerin durumunu kaydeder (pencere yoksa son kaydedilen korunur).
    func saveSession() {
        SessionStore.save(controllers.map { $0.captureState() })
    }

    /// Kaydedilmiş pencereleri açar; açacak bir şey yoksa false.
    @discardableResult
    private func restoreSession() -> Bool {
        let states = SessionStore.load()
        for state in states {
            newWindow(at: state.left[min(state.leftSelected, state.left.count - 1)].url)
            controllers.last?.restore(state)
        }
        return !states.isEmpty
    }

    /// Dock simgesine tıklama: hiç pencere yoksa yeni pencere açılır; varsa macOS her zamanki gibi öne getirir.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty {
            // Son kapatılan pencere kaldığı gibi geri gelir.
            if !restoreSession() { newWindow(nil) }
            return false
        }
        return true
    }

    /// Dock simgesine sağ tık menüsü.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: String(localized: "Yeni Pencere", bundle: .live), action: #selector(newWindow(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// Son pencere kapansa da uygulama Dock'ta açık kalır (Finder gibi); Dock'a tıklayınca yeni pencere açılır.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dosya ▸ Yeni Pencere (⌘N / Ctrl+N): gezgin penceresi öndeyse o yanıtlar (etkin klasörde açar); yoksa Ana Klasör.
    @objc func newWindowHere(_ sender: Any?) { newWindow(sender) }

    @objc func newWindow(_ sender: Any?) {
        newWindow(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Taşınan sekmeyle yeni pencere; `point` verilirse pencere sekmenin bırakıldığı yerde açılır.
    func newWindow(with tab: TabState, at point: NSPoint?) {
        newWindow(at: tab.url)
        guard let controller = controllers.last else { return }
        controller.adoptTabs([tab])
        if let point, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: point.x - 80, y: point.y + 16))
        }
    }

    func newWindow(at url: URL) {
        let controller = BrowserWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            // Son pencere kapanıyor: durumu saklanır (Dock'tan ya da sonraki açılışta geri gelir).
            if self.controllers.count == 1, let controller, self.controllers.first === controller {
                SessionStore.save([controller.captureState()])
            }
            self.controllers.removeAll { $0 === controller }
        }
        if let last = controllers.last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            controller.window?.center()
        }
        controllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate()
    }

    @objc func openMacRARPage(_ sender: Any?) { MacRARInstaller.openPage() }

    @objc func openSourcePage(_ sender: Any?) {
        if let url = URL(string: "https://gitlab.com/freeware2/macexplorer") { NSWorkspace.shared.open(url) }
    }

    @objc func showShortcuts(_ sender: Any?) {
        ShortcutsWindowController.shared.present(over: NSApp.keyWindow?.windowController is BrowserWindowController ? NSApp.keyWindow : nil)
    }

    @objc func showAbout(_ sender: Any?) {
        AboutWindowController.shared.present()
    }

    /// Dili yeniden başlatmadan değiştirir: menü çubuğu, gezgin pencereleri (sekmeleri, klasörleri, görünümleri
    /// ve konumlarıyla), Ayarlar, Hakkında ve Kısayollar yeni dilde yeniden kurulur.
    func applyLanguage(_ language: AppLanguage) {
        language.save()
        LiveLanguage.use(language.code)
        NSApp.mainMenu = MainMenu.build()
        let key = NSApp.keyWindow
        var newKey: BrowserWindowController?
        for old in controllers {
            let state = old.captureState()
            newWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            guard let fresh = controllers.last else { continue }
            fresh.restore(state)
            if old.window === key { newKey = fresh }
            old.window?.close()
        }
        SettingsWindowController.rebuild()
        if AboutWindowController.shared.window?.isVisible == true { AboutWindowController.shared.present() }
        if ShortcutsWindowController.shared.window?.isVisible == true { ShortcutsWindowController.shared.present(over: nil) }
        if SettingsWindowController.shared.window?.isVisible == true {
            SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
        } else {
            newKey?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) { Updater.check(userInitiated: true) }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.keepOnScreen()
        SettingsWindowController.shared.showWindow(nil)
        NSApp.activate()
    }
}
