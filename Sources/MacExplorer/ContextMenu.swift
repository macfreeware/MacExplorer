import AppKit
import FTPKit
import MacExplorerCore

/// Sağ tık menüleri. Adlar ve sıra Windows Gezgini'ndeki gibidir.
extension PaneViewController {
    func contextMenu(row: Int) -> NSMenu {
        let menu = NSMenu()
        defer { MenuSymbol.showAll(in: menu) }   // macOS 27 simgeleri ancak açıkça istenince gösterir
        menu.autoenablesItems = false
        if isArchive {
            if row >= 0, !selectedItems.isEmpty { buildArchiveItemMenu(menu, items: selectedItems) } else { buildArchiveBackgroundMenu(menu) }
        } else if isRemote {
            if row >= 0, !selectedItems.isEmpty { buildRemoteItemMenu(menu, items: selectedItems) } else { buildRemoteBackgroundMenu(menu) }
        } else if row >= 0, !selectedItems.isEmpty {
            buildItemMenu(menu, items: selectedItems)
        } else {
            buildBackgroundMenu(menu)
        }
        return menu
    }

    // MARK: Öğe menüsü

    private func buildItemMenu(_ menu: NSMenu, items: [FileItem]) {
        let urls = items.map(\.url)
        let folders = items.filter(\.isDirectory)
        let files = items.filter { !$0.isDirectory }

        let open = add(menu, String(localized: "Aç", bundle: .live), #selector(menuOpen))
        bold(open)   // Windows'taki gibi varsayılan komut kalın
        if isSearchingSubfolders, items.count == 1 {
            add(menu, String(localized: "Dosya konumunu aç", bundle: .live), #selector(menuOpenItemLocation))
        }
        if items.count == 1, DiskImage.isDiskImage(items[0].url) {
            add(menu, String(localized: "Bağla", bundle: .live), #selector(menuMount))
        }
        if items.count == 1, Archives.isBrowsable(items[0].url) {
            add(menu, String(localized: "İçine göz at", bundle: .live), #selector(menuBrowseArchive))
        }
        if !folders.isEmpty {
            add(menu, String(localized: "Yeni sekmede aç", bundle: .live), #selector(menuOpenInNewTab))
            add(menu, String(localized: "Yeni pencerede aç", bundle: .live), #selector(menuOpenInNewWindow))
        }
        if !files.isEmpty, folders.isEmpty {
            let openWith = add(menu, String(localized: "Birlikte aç", bundle: .live), nil)
            openWith.submenu = openWithMenu(for: files.map(\.url))
            openWith.setSymbol("arrow.up.forward.app")
        }
        add(menu, String(localized: "Hızlı Bakış", bundle: .live), #selector(menuQuickLook))
        if !files.isEmpty, let editor = Preferences.editorApp {
            let name = FileManager.default.displayName(atPath: editor.path).replacingOccurrences(of: ".app", with: "")
            add(menu, String(localized: "Düzenle (\(name))", bundle: .live), #selector(menuEdit)).image = icon(editor.path)
        }
        // F4 başka bir düzenleyiciye ayarlıysa MacNote++ ayrıca sunulur.
        if !files.isEmpty, let macNote = MacNoteInstaller.app, macNote != Preferences.editorApp {
            add(menu, String(localized: "MacNote++ ile düzenle", bundle: .live), #selector(menuEditInMacNote)).image = icon(macNote.path)
        }
        menu.addItem(.separator())

        // MacRAR komutları Finder'daki gibi doğrudan menüde, MacRAR simgesi ve aynı adlarla.
        let macRAR = macRARItems(for: urls)
        if !macRAR.isEmpty {
            macRAR.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        if folders.count == 1, files.isEmpty {
            let image = add(menu, String(localized: "Disk görüntüsü oluştur", bundle: .live), nil)
            let sub = NSMenu()
            sub.autoenablesItems = false
            add(sub, String(localized: "ISO (Windows, Linux ve Mac)", bundle: .live), #selector(menuMakeISO)).image =
                NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: nil)
            add(sub, String(localized: "DMG (Mac, sıkıştırılmış)", bundle: .live), #selector(menuMakeDMG)).image =
                NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
            image.submenu = sub
            image.setSymbol("opticaldisc")
        }
        add(menu, String(localized: "Paylaş…", bundle: .live), #selector(menuShare))
        let sendTo = add(menu, String(localized: "Gönder", bundle: .live), nil)
        sendTo.submenu = sendToMenu()
        sendTo.setSymbol("paperplane")
        menu.addItem(.separator())

        add(menu, String(localized: "Kes", bundle: .live), #selector(menuCut))
        add(menu, String(localized: "Kopyala", bundle: .live), #selector(menuCopy))
        add(menu, String(localized: "Yol olarak kopyala", bundle: .live), #selector(menuCopyAsPath))
        menu.addItem(.separator())

        add(menu, String(localized: "Kısayol oluştur", bundle: .live), #selector(menuCreateShortcut))
        add(menu, String(localized: "Sil", bundle: .live), #selector(menuDelete))
        add(menu, String(localized: "Yeniden adlandır", bundle: .live), #selector(menuRename)).isEnabled = items.count == 1
        menu.addItem(.separator())

        add(menu, String(localized: "Finder’da göster", bundle: .live), #selector(menuShowInFinder))
        add(menu, String(localized: "Terminalde aç", bundle: .live), #selector(menuOpenSelectionInTerminal))
        add(menu, String(localized: "Özellikler", bundle: .live), #selector(menuProperties))
    }

    // MARK: Sunucu (SFTP / FTP) menüleri

    private func buildRemoteItemMenu(_ menu: NSMenu, items: [FileItem]) {
        let folders = items.filter(\.isDirectory)
        bold(add(menu, String(localized: "Aç", bundle: .live), #selector(menuOpen)))
        if !folders.isEmpty {
            add(menu, String(localized: "Yeni sekmede aç", bundle: .live), #selector(menuOpenInNewTab))
            add(menu, String(localized: "Yeni pencerede aç", bundle: .live), #selector(menuOpenInNewWindow))
        }
        if folders.isEmpty, let editor = Preferences.editorApp {
            let name = FileManager.default.displayName(atPath: editor.path).replacingOccurrences(of: ".app", with: "")
            add(menu, String(localized: "Düzenle (\(name))", bundle: .live), #selector(menuEdit)).image = icon(editor.path)
        }
        add(menu, String(localized: "İndir…", bundle: .live), #selector(menuDownload))
        menu.addItem(.separator())
        add(menu, String(localized: "Kes", bundle: .live), #selector(menuCut))
        add(menu, String(localized: "Kopyala", bundle: .live), #selector(menuCopy))
        add(menu, String(localized: "Adresi kopyala", bundle: .live), #selector(menuCopyAddress))
        add(menu, String(localized: "Yol olarak kopyala", bundle: .live), #selector(menuCopyAsPath))
        menu.addItem(.separator())
        add(menu, String(localized: "Sil", bundle: .live), #selector(menuDelete))
        add(menu, String(localized: "Yeniden adlandır", bundle: .live), #selector(menuRename)).isEnabled = items.count == 1
        if tab.url.scheme == "sftp" {
            menu.addItem(.separator())
            add(menu, String(localized: "Terminalde aç (SSH)", bundle: .live), #selector(menuOpenSelectionInTerminal))
        }
    }

    private func buildRemoteBackgroundMenu(_ menu: NSMenu) {
        let viewItem = add(menu, String(localized: "Görünüm", bundle: .live), nil)
        viewItem.submenu = viewModeMenu()
        viewItem.setSymbol("square.grid.2x2")
        let sort = add(menu, String(localized: "Sıralama ölçütü", bundle: .live), nil)
        sort.submenu = sortMenu()
        sort.setSymbol("arrow.up.arrow.down")
        add(menu, String(localized: "Yenile", bundle: .live), #selector(menuRefresh))
        add(menu, String(localized: "Gizli öğeleri göster", bundle: .live), #selector(menuToggleHidden)).state = Preferences.showHidden ? .on : .off
        menu.addItem(.separator())
        add(menu, String(localized: "Yapıştır", bundle: .live), #selector(menuPaste)).isEnabled = FileClipboard.hasFiles
        add(menu, String(localized: "Dosya yükle…", bundle: .live), #selector(menuUpload))
        menu.addItem(.separator())
        let new = add(menu, String(localized: "Yeni", bundle: .live), nil)
        let newMenu = NSMenu()
        newMenu.autoenablesItems = false
        add(newMenu, String(localized: "Klasör", bundle: .live), #selector(menuNewFolder)).image = RemoteIcons.icon(for: URL(string: "sftp://x/a/")!, size: 16)
        add(newMenu, String(localized: "Metin Belgesi", bundle: .live), #selector(menuNewTextDocument)).image =
            NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        new.submenu = newMenu
        new.setSymbol("plus.circle")
        menu.addItem(.separator())
        if tab.url.scheme == "sftp" {
            add(menu, String(localized: "Terminalde aç (SSH)", bundle: .live), #selector(menuOpenInTerminal))
        }
        add(menu, String(localized: "Adresi kopyala", bundle: .live), #selector(menuCopyFolderAddress))
        add(menu, String(localized: "Klasör yolunu kopyala", bundle: .live), #selector(menuCopyFolderPath))
        add(menu, String(localized: "Bağlantıyı kes", bundle: .live), #selector(menuDisconnect))
    }

    /// İndir…: seçilen yerel klasöre (çift panelde diğer panel yerelse varsayılan o).
    // MARK: Arşivin içi

    private func buildArchiveItemMenu(_ menu: NSMenu, items: [FileItem]) {
        bold(add(menu, String(localized: "Aç", bundle: .live), #selector(menuOpen)))
        if items.contains(where: \.isDirectory) {
            add(menu, String(localized: "Yeni sekmede aç", bundle: .live), #selector(menuOpenInNewTab))
        }
        add(menu, String(localized: "Ayıkla…", bundle: .live), #selector(menuDownload))
        menu.addItem(.separator())
        add(menu, String(localized: "Kopyala", bundle: .live), #selector(menuCopy))
        add(menu, String(localized: "Yol olarak kopyala", bundle: .live), #selector(menuCopyAsPath))
    }

    private func buildArchiveBackgroundMenu(_ menu: NSMenu) {
        let viewItem = add(menu, String(localized: "Görünüm", bundle: .live), nil)
        viewItem.submenu = viewModeMenu()
        viewItem.setSymbol("square.grid.2x2")
        let sort = add(menu, String(localized: "Sıralama ölçütü", bundle: .live), nil)
        sort.submenu = sortMenu()
        sort.setSymbol("arrow.up.arrow.down")
        add(menu, String(localized: "Gizli öğeleri göster", bundle: .live), #selector(menuToggleHidden)).state = Preferences.showHidden ? .on : .off
        menu.addItem(.separator())
        add(menu, String(localized: "Tümünü ayıkla…", bundle: .live), #selector(menuExtractAll))
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacRARBridge.bundleIdentifier) {
            add(menu, String(localized: "MacRAR ile aç", bundle: .live), #selector(menuOpenArchiveInMacRAR)).image = icon(app.path)
        }
        menu.addItem(.separator())
        add(menu, String(localized: "Arşivi kapat", bundle: .live), #selector(menuCloseArchive))
    }

    @objc private func menuOpenItemLocation() {
        guard let url = selectedURLs.first else { return }
        openItemLocation(url)
    }

    @objc private func menuBrowseArchive() {
        guard let url = selectedURLs.first else { return }
        browseArchive(url)
    }

    /// Tümünü ayıkla… (Windows'taki gibi): arşivin adını taşıyan bir klasöre, seçilen yere.
    @objc func menuExtractAll() {
        guard let file = Archives.file(for: tab.url), let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = file.deletingLastPathComponent()
        panel.prompt = String(localized: "Ayıkla", bundle: .live)
        panel.message = String(localized: "Dosyaların ayıklanacağı yeri seçin. Arşivin adıyla bir klasör oluşturulur.", bundle: .live)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            ArchiveExtractor.extractAll(file, into: folder, window: window) { created in
                self?.navigate(to: created)
            }
        }
    }

    @objc private func menuOpenArchiveInMacRAR() {
        guard let file = Archives.file(for: tab.url),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacRARBridge.bundleIdentifier) else { return }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func menuCloseArchive() {
        let url = tab.url
        RemoteSessions.disconnect(url)
        if let file = Archives.file(for: url) { navigate(to: file.deletingLastPathComponent(), selecting: [file]) }
    }

    // MARK: Disk görüntüleri

    @objc private func menuMount() {
        guard let url = selectedURLs.first else { return }
        mountDiskImage(url)
    }

    /// Bağlar ve bağlanan diski bu panelde açar (Windows'ta ISO'ya çift tıklamak gibi).
    func mountDiskImage(_ url: URL) {
        DiskImage.mount(url, window: view.window) { [weak self] volume in self?.navigate(to: volume) }
    }

    @objc func menuEjectVolume() {
        let volume = tab.url
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        ServerConnector.eject(volume, over: view.window)
    }

    @objc private func menuMakeISO() { makeDiskImage(.iso) }
    @objc private func menuMakeDMG() { makeDiskImage(.dmg) }

    func makeDiskImage(_ format: DiskImage.Format) {
        guard let folder = selectedItems.first(where: \.isDirectory)?.url else { return }
        let directory = tab.url
        DiskImage.create(format, from: folder, window: view.window) { [weak self] image in self?.reveal([image], in: directory) }
    }

    @objc private func menuDownload() {
        let urls = selectedURLs
        guard !urls.isEmpty, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = isArchive ? String(localized: "Ayıkla", bundle: .live) : String(localized: "İndir", bundle: .live)
        panel.message = isArchive ? String(localized: "Dosyaların ayıklanacağı klasörü seçin.", bundle: .live)
            : String(localized: "İndirilecek klasörü seçin.", bundle: .live)
        if let other = delegate?.otherPane(of: self), !other.tab.url.isRemote { panel.directoryURL = other.tab.url }
        else if let file = Archives.file(for: tab.url) { panel.directoryURL = file.deletingLastPathComponent() }
        else { panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.transfer(.copy, urls, to: folder)
        }
    }

    /// Dosya yükle…: seçilen dosya ve klasörleri bu sunucu klasörüne.
    @objc private func menuUpload() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Yükle", bundle: .live)
        let destination = tab.url
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.transfer(.copy, panel.urls, to: destination)
        }
    }

    @objc private func menuCopyAddress() { copyAddresses(selectedURLs) }
    @objc private func menuCopyFolderAddress() { copyAddresses([tab.url]) }

    private func copyAddresses(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
        FileClipboard.notify()
    }

    @objc private func menuDisconnect() {
        let url = tab.url
        RemoteSessions.disconnect(url)
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    private func openWithMenu(for urls: [URL]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: urls[0])
        // Aynı uygulamanın birden çok kopyası (örn. bir de derleme klasöründe) tek girdi olsun.
        var seen = Set([defaultApp.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? ""])
        var apps = workspace.urlsForApplications(toOpen: urls[0]).filter { app in
            guard app != defaultApp else { return false }
            return seen.insert(Bundle(url: app)?.bundleIdentifier ?? app.path).inserted
        }
        apps.sort { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }
        if let defaultApp { apps.insert(defaultApp, at: 0) }
        for (i, app) in apps.enumerated() {
            let title = i == 0 && defaultApp != nil ? String(localized: "\(appName(app)) (varsayılan)", bundle: .live) : appName(app)
            let item = add(menu, title, #selector(menuOpenWith(_:)))
            item.representedObject = app
            item.image = icon(app.path)
            if i == 0 && defaultApp != nil && apps.count > 1 { menu.addItem(.separator()) }
        }
        if !apps.isEmpty { menu.addItem(.separator()) }
        add(menu, String(localized: "Başka bir uygulama seç…", bundle: .live), #selector(menuOpenWithOther))
        return menu
    }

    private func sendToMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        add(menu, String(localized: "Sıkıştırılmış (zip) klasör", bundle: .live), #selector(menuSendToZip)).image =
            NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        add(menu, String(localized: "Masaüstü (kısayol oluştur)", bundle: .live), #selector(menuSendToDesktop)).image =
            icon(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path)
        return menu
    }

    // MARK: MacRAR

    /// MacRAR girdileri ("MacRAR · …"); MacRAR kurulu değilse boş. MacRAR hiç açılmadıysa (anahtar yok) onu açan tek girdi.
    private func macRARItems(for urls: [URL]) -> [NSMenuItem] {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacRARBridge.bundleIdentifier) else { return [] }
        let image = icon(app.path)
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let entry = NSMenuItem(title: "MacRAR · " + title, action: action, keyEquivalent: "")
            entry.target = self
            entry.image = image
            return entry
        }
        guard MacRARBridge.token() != nil else {
            let launch = item(String(localized: "MacRAR’ı bir kez açın", bundle: .live), #selector(menuLaunchMacRAR(_:)))
            launch.representedObject = app
            return [launch]
        }
        return MacRARBridge.actions(for: urls, canCompressRAR: MacRARBridge.canCompressRAR()).map { action in
            let entry = item(macRARTitle(action, urls), #selector(menuMacRAR(_:)))
            entry.representedObject = action.rawValue
            return entry
        }
    }

    /// MacRAR'ın Finder menüsündeki adlar (MacRAR `FinderIntegration.menuItems` ile aynı).
    private func macRARTitle(_ action: MacRARAction, _ urls: [URL]) -> String {
        let single = urls.count == 1
        let base = single ? FileNaming.split(urls[0]).base : ""
        let rar = "rar", zip = "zip"
        switch action {
        case .add: return String(localized: "Arşive Ekle…", bundle: .live)
        case .compress: return single ? String(localized: "“\(base).\(rar)” olarak Sıkıştır", bundle: .live) : String(localized: "RAR’a Sıkıştır", bundle: .live)
        case .compressStamped: return String(localized: "Zaman Damgalı RAR’a Sıkıştır", bundle: .live)
        case .compressZip: return single ? String(localized: "“\(base).\(zip)” olarak Sıkıştır", bundle: .live) : String(localized: "ZIP’e Sıkıştır", bundle: .live)
        case .compressZipStamped: return String(localized: "Zaman Damgalı ZIP’e Sıkıştır", bundle: .live)
        case .open: return String(localized: "Aç", bundle: .live)
        case .extractDialog: return String(localized: "Dosyaları Çıkar…", bundle: .live)
        case .extractHere: return String(localized: "Buraya Çıkar", bundle: .live)
        case .extractFolder:
            guard single else { return String(localized: "Her birini kendi klasörüne Çıkar", bundle: .live) }
            var name = urls[0].deletingPathExtension().lastPathComponent
            if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
            return String(localized: "“\(name)/” klasörüne Çıkar", bundle: .live)
        }
    }

    // MARK: Boş alan menüsü

    private func buildBackgroundMenu(_ menu: NSMenu) {
        let viewItem = add(menu, String(localized: "Görünüm", bundle: .live), nil)
        viewItem.submenu = viewModeMenu()
        viewItem.setSymbol("square.grid.2x2")
        let sort = add(menu, String(localized: "Sıralama ölçütü", bundle: .live), nil)
        sort.submenu = sortMenu()
        sort.setSymbol("arrow.up.arrow.down")
        add(menu, String(localized: "Yenile", bundle: .live), #selector(menuRefresh))
        // Windows: Görünüm ▸ Göster ▸ Gizli öğeler
        add(menu, String(localized: "Gizli öğeleri göster", bundle: .live), #selector(menuToggleHidden)).state = Preferences.showHidden ? .on : .off
        menu.addItem(.separator())

        let hasFiles = FileClipboard.hasFiles
        add(menu, String(localized: "Yapıştır", bundle: .live), #selector(menuPaste)).isEnabled = hasFiles
        add(menu, String(localized: "Kısayol yapıştır", bundle: .live), #selector(menuPasteShortcut)).isEnabled = hasFiles
        menu.addItem(.separator())

        let new = add(menu, String(localized: "Yeni", bundle: .live), nil)
        let newMenu = NSMenu()
        newMenu.autoenablesItems = false
        add(newMenu, String(localized: "Klasör", bundle: .live), #selector(menuNewFolder)).image = icon(tab.url.path)
        add(newMenu, String(localized: "Metin Belgesi", bundle: .live), #selector(menuNewTextDocument)).image =
            NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        new.submenu = newMenu
        new.setSymbol("plus.circle")
        menu.addItem(.separator())

        add(menu, String(localized: "Terminalde aç", bundle: .live), #selector(menuOpenInTerminal))
        add(menu, String(localized: "Klasör yolunu kopyala", bundle: .live), #selector(menuCopyFolderPath))
        if DiskImage.ejectableVolume(tab.url) {
            add(menu, String(localized: "Çıkar", bundle: .live), #selector(menuEjectVolume))
        }
        add(menu, String(localized: "Özellikler", bundle: .live), #selector(menuProperties))
    }

    private func viewModeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in ViewMode.allCases {
            let item = add(menu, mode.title, #selector(menuViewMode(_:)))
            item.representedObject = mode.rawValue
            item.state = mode == viewMode ? .on : .off
            item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
        }
        return menu
    }

    @objc private func menuViewMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ViewMode(rawValue: raw) else { return }
        setViewMode(mode)
    }

    private func sortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let columns: [(SortColumn, String)] = [
            (.name, String(localized: "Ad", bundle: .live)), (.modified, String(localized: "Değiştirme tarihi", bundle: .live)),
            (.kind, String(localized: "Tür", bundle: .live)), (.size, String(localized: "Boyut", bundle: .live)),
        ]
        for (column, title) in columns {
            let item = add(menu, title, #selector(menuSortColumn(_:)))
            item.representedObject = column.rawValue
            item.state = tab.sort.column == column ? .on : .off
        }
        menu.addItem(.separator())
        let ascending = add(menu, String(localized: "Artan", bundle: .live), #selector(menuSortDirection(_:)))
        ascending.tag = 1
        ascending.state = tab.sort.ascending ? .on : .off
        add(menu, String(localized: "Azalan", bundle: .live), #selector(menuSortDirection(_:))).state = tab.sort.ascending ? .off : .on
        return menu
    }

    // MARK: Yardımcılar

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = MenuSymbol.image(for: action)
        MenuSymbol.show(item)
        menu.addItem(item)
        return item
    }

    private func bold(_ item: NSMenuItem) {
        item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
    }

    private func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func icon(_ path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: Komutlar

    @objc private func menuOpen() { openSelection() }
    @objc private func menuQuickLook() { toggleQuickLook() }
    @objc private func menuEdit() { editSelection() }
    @objc private func menuEditInMacNote() {
        let files = selectedItems.filter { !$0.isDirectory }.map(\.url)
        guard !files.isEmpty, let app = MacNoteInstaller.app else { return NSSound.beep() }
        if isRemote { return RemoteTransfers.open(files, with: app, window: view.window) }
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func menuOpenInNewTab() {
        for folder in selectedItems.filter(\.isDirectory) { newTab(url: folder.url, activate: false) }
    }

    @objc private func menuOpenInNewWindow() {
        for folder in selectedItems.filter(\.isDirectory) { (NSApp.delegate as? AppDelegate)?.newWindow(at: folder.url) }
    }

    @objc private func menuOpenWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func menuOpenWithOther() {
        let urls = selectedURLs
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Aç", bundle: .live)
        panel.message = String(localized: "Bu dosyayı açmak için bir uygulama seçin.", bundle: .live)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func menuShare() {
        guard let first = selectionIndexes.first else { return }
        let picker = NSSharingServicePicker(items: selectedURLs)
        let (rect, view) = frame(forRow: first)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    @objc private func menuSendToZip() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let dir = tab.url
        let name = selectedItems.first.map { FileNaming.split($0.url).base } ?? "Arşiv"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ZipMaker.zip(urls, in: dir, name: name) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    switch result {
                    case .success(let zip):
                        UndoCenter.shared.register([.trash(zip)], name: String(localized: "Sıkıştır", bundle: .live))
                        self?.revealAndRename(zip)
                    case .failure(let error):
                        let message = (error as? ZipError).map { if case .failed(let text) = $0 { return text }; return "" } ?? error.localizedDescription
                        self?.showError(String(localized: "Sıkıştırılmış klasör oluşturulamadı.", bundle: .live) + "\n" + message)
                    }
                }
            }
        }
    }

    @objc private func menuSendToDesktop() {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        var created: [FileUndoOp] = []
        do {
            for url in selectedURLs { created.append(.trash(try ShortcutMaker.createAlias(to: url, in: desktop, suffix: String(localized: "Kısayol", bundle: .live)))) }
        } catch {
            showError(error.localizedDescription)
        }
        UndoCenter.shared.register(created.reversed(), name: String(localized: "Kısayol Oluştur", bundle: .live))
    }

    @objc private func menuCut() { copySelection(cut: true) }
    @objc private func menuCopy() { copySelection(cut: false) }

    @objc private func menuCopyAsPath() { copyPaths(selectedURLs) }
    @objc private func menuCopyFolderPath() { copyPaths([tab.url]) }

    /// Yolları metin olarak panoya yazar (birden çoksa satır satır); terminale yapıştırılabilsin diye gerekirse tırnaklı.
    func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map { ShellQuote.quote($0.isRemote ? RemoteURL.path(of: $0) : $0.path) }.joined(separator: "\n"), forType: .string)
        FileClipboard.notify()
    }

    @objc private func menuCreateShortcut() {
        var created: [URL] = []
        do {
            for url in selectedURLs {
                created.append(try ShortcutMaker.createAlias(to: url, in: tab.url, suffix: String(localized: "Kısayol", bundle: .live)))
            }
        } catch {
            showError(error.localizedDescription)
        }
        UndoCenter.shared.register(created.reversed().map { .trash($0) }, name: String(localized: "Kısayol Oluştur", bundle: .live))
        if created.count == 1, selectedURLs.count == 1 { revealAndRename(created[0]) }
    }

    @objc private func menuDelete() { deleteSelection(permanently: false) }
    @objc private func menuRename() { beginRename() }
    @objc private func menuShowInFinder() { NSWorkspace.shared.activateFileViewerSelecting(selectedURLs) }
    @objc func menuProperties() { showProperties() }
    @objc private func menuRefresh() { refresh() }
    @objc private func menuToggleHidden() { Preferences.showHidden.toggle() }
    @objc private func menuPaste() { paste() }

    /// Panodaki öğelerin takma adlarını bu klasörde oluşturur (Windows "Kısayol yapıştır").
    @objc private func menuPasteShortcut() {
        var created: [FileUndoOp] = []
        do {
            for url in FileClipboard.read().urls {
                created.append(.trash(try ShortcutMaker.createAlias(to: url, in: tab.url, suffix: String(localized: "Kısayol", bundle: .live))))
            }
        } catch {
            showError(error.localizedDescription)
        }
        UndoCenter.shared.register(created.reversed(), name: String(localized: "Kısayol Yapıştır", bundle: .live))
    }

    @objc private func menuNewFolder() { createNewFolder() }
    @objc private func menuNewTextDocument() { createNewTextDocument() }

    @objc private func menuOpenInTerminal() { openInTerminal(tab.url) }

    /// Seçili klasörde; dosya seçiliyse bulunduğu klasörde.
    @objc private func menuOpenSelectionInTerminal() {
        guard let item = selectedItems.first else { return openInTerminal(tab.url) }
        openInTerminal(item.isDirectory ? item.url : item.url.deletingLastPathComponent())
    }

    /// F4 Düzenle: seçili dosyaları seçilen metin düzenleyicide açar (Midnight Commander gibi).
    func editSelection() {
        let files = selectedItems.filter { !$0.isDirectory }.map(\.url)
        guard !files.isEmpty, let editor = Preferences.editorApp else { return NSSound.beep() }
        if isRemote { return RemoteTransfers.open(files, with: editor, window: view.window) }
        NSWorkspace.shared.open(files, withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    func openInTerminal(_ directory: URL) {
        if directory.isRemote {
            // SFTP: sunucuya ssh ile bağlanan, o klasörde açılan bir Terminal penceresi. FTP'de kabuk yok.
            guard directory.scheme == "sftp", let server = RemoteSessions.existing(for: directory)?.server
                    ?? ServerBookmark(address: directory.absoluteString) else {
                return showError(String(localized: "Terminal yalnızca SFTP (SSH) sunucularında açılabilir.", bundle: .live))
            }
            return SSHConfig.openTerminal(server, path: RemoteURL.path(of: directory))
        }
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func menuSortColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        table.sortDescriptors = [NSSortDescriptor(key: raw, ascending: tab.sort.ascending)]
    }

    @objc private func menuSortDirection(_ sender: NSMenuItem) {
        table.sortDescriptors = [NSSortDescriptor(key: tab.sort.column.rawValue, ascending: sender.tag == 1)]
    }

    @objc private func menuLaunchMacRAR(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func menuMacRAR(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = MacRARAction(rawValue: raw) else { return }
        runMacRAR(action, on: selectedURLs)
    }

    /// MacRAR komutu: MacRAR'ı (kapalıysa başlatarak) tetikler; iş MacRAR'ın kendi ilerleme panelinde yapılır,
    /// sonuç bu klasöre düşünce liste kendiliğinden güncellenir.
    func runMacRAR(_ action: MacRARAction, on urls: [URL]) {
        guard let token = MacRARBridge.token(),
              let url = MacRARBridge.commandURL(action: action, paths: urls.map(\.path), token: token) else {
            showError(String(localized: "MacRAR’a ulaşılamadı. MacRAR’ı bir kez açıp yeniden deneyin.", bundle: .live))
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = action == .open || action == .add || action == .extractDialog
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.showError(error.localizedDescription) }
            }
        }
    }

    /// Özellikler: seçili öğelerin; seçim yoksa bu klasörün.
    func showProperties() {
        if isRemote { return NSSound.beep() }
        let urls = selectedURLs
        PropertiesWindowController.show(for: urls.isEmpty ? [tab.url] : urls, over: view.window)
    }
}
