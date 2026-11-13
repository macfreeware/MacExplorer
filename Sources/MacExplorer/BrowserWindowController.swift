import AppKit
import Quartz
import MacExplorerCore

extension NSToolbarItem.Identifier {
    static let hiddenFiles = Self("hiddenFiles")
    static let dualPane = Self("dualPane")
    static let terminal = Self("terminal")
    static let previewPane = Self("previewPane")
    static let newWindow = Self("newWindow")
    static let viewMode = Self("viewMode")
    // Düzen düğmeleri (Windows 11 Gezgini'nin komut çubuğu gibi)
    static let newFolderItem = Self("newFolder")
    static let cutItem = Self("cut")
    static let copyItem = Self("copy")
    static let pasteItem = Self("paste")
    static let renameItem = Self("rename")
    static let deleteItem = Self("delete")
}

extension NSTouchBarItem.Identifier {
    static let functionKeys = Self("local.macexplorer.functionKeys")
}

/// Bir gezgin penceresi: solda kenar çubuğu, sağda tek ya da çift panel.
/// Menü komutları yanıtlayıcı zinciri üzerinden buraya gelir ve etkin panele iletilir.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
                                     NSToolbarItemValidation, NSTouchBarDelegate, WorkspaceHost {
    var onClose: (() -> Void)?
    /// Pencerenin altındaki işlev tuşu çubuğu (F2 Ad değiştir, F5 Kopyala …).
    private var functionBar: FunctionKeyBar?
    private let titleBand = TitleBandView()
    private var functionBarHeight: NSLayoutConstraint?
    private let content = NSViewController()
    private var touchBarDualPane: Bool?

    private let sidebar = SidebarViewController()
    let workspace: WorkspaceViewController
    private var monitors: [Any] = []
    private let dualPaneButton = NSButton()
    private let hiddenFilesButton = NSButton()
    private let previewButton = NSButton()
    /// Paneller | ayırıcı | önizleme bölmesi. Önizleme ve ayırıcı yalnızca bölme açıkken eklenir:
    /// kapalıyken sağ kenarda yakalanıp bölmeyi açan görünmez bir ayırıcı kalmaz.
    private let mainSplit = NSView()
    private let previewDivider = PaneDivider()
    private var workspaceTrailing: NSLayoutConstraint?
    private var previewConstraints: [NSLayoutConstraint] = []
    private let preview = PreviewPaneController()
    /// Önizleme bölmesinin genişliği: pencere boyutu değişince paneller büyür/küçülür, bölme yalnızca ayırıcı sürüklenince.
    private lazy var previewWidth: NSLayoutConstraint = {
        let c = preview.view.widthAnchor.constraint(equalToConstant: Preferences.previewPaneWidth)
        c.priority = .init(750)   // pencere en küçük boyuta inince paneller önce gelir (bkz. workspace en az genişliği)
        return c
    }()
    private weak var viewModeItem: NSMenuToolbarItem?

    init(url: URL) {
        workspace = WorkspaceViewController(url: url)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 400)
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .automatic

        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 170
        sideItem.maximumThickness = 320
        split.addSplitViewItem(sideItem)
        // Paneller ve altında işlev tuşu çubuğu
        content.view = NSView()
        content.addChild(workspace)
        content.addChild(preview)
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        workspace.view.translatesAutoresizingMaskIntoConstraints = false
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        // Önizleme bölmesi yalnızca açıkken bölünmüş görünümdedir: kapalıyken sağ kenarda yakalanacak bir ayırıcı kalmaz.
        mainSplit.addSubview(workspace.view)
        let trailing = workspace.view.trailingAnchor.constraint(equalTo: mainSplit.trailingAnchor)
        workspaceTrailing = trailing
        NSLayoutConstraint.activate([
            workspace.view.topAnchor.constraint(equalTo: mainSplit.topAnchor),
            workspace.view.bottomAnchor.constraint(equalTo: mainSplit.bottomAnchor),
            workspace.view.leadingAnchor.constraint(equalTo: mainSplit.leadingAnchor),
            trailing,
        ])
        previewDivider.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(mainSplit)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 720))

        super.init(window: window)
        window.delegate = self
        workspace.host = self
        sidebar.onNavigate = { [weak self] url in self?.workspace.activePane.navigate(to: url) }
        sidebar.onConnect = { [weak self] server in
            guard let self else { return }
            ConnectServerController.connect(server, over: self.window) { [weak self] url in self?.workspace.activePane.navigate(to: url) }
        }
        sidebar.onShowConnect = { [weak self] in self?.connectToServer(nil) }
        sidebar.onEditServer = { [weak self] server in ConnectServerController.present(over: self?.window, editing: server) }
        sidebar.onDeleteServer = { [weak self] server in ConnectServerController.confirmDelete(server, over: self?.window) }
        sidebar.onEject = { [weak self] url in ServerConnector.eject(url, over: self?.window) }

        window.toolbarStyle = .unified
        rebuildToolbar()

        installFunctionBar()
        installTitleBand()
        installMonitors()
        previewDivider.onDrag = { [weak self] delta in self?.dragPreviewDivider(delta) }
        previewDivider.onDragEnd = { [weak self] in
            guard let self else { return }
            Preferences.previewPaneWidth = self.previewWidth.constant
        }
        if Preferences.previewPane { setPreviewVisible(true) }
        workspaceActivePaneDidChange()
        NotificationCenter.default.addObserver(self, selector: #selector(paneSelectionChanged(_:)), name: PaneViewController.selectionDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Theme.didChange, object: nil)
        // Gizli öğeler sağ tık menüsünden ya da Ayarlar'dan değişince araç çubuğu düğmesi de güncellensin.
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    private var pane: PaneViewController { workspace.activePane }

    /// Klasörü açıp verilen öğeleri seçili gösterir (bkz. `AppDelegate.reveal`).
    func show(_ urls: [URL], in directory: URL) { pane.show(urls, in: directory) }

    // MARK: WorkspaceHost

    func workspaceActivePaneDidChange() {
        guard let window else { return }
        let tab = pane.tab
        window.title = tab.title
        if let file = Archives.file(for: tab.url) {
            // Arşivin içi: arşivin yolu ve içindeki klasör.
            let inner = RemoteURL.path(of: tab.url)
            window.subtitle = (file.path as NSString).abbreviatingWithTildeInPath + (inner == "/" ? "" : inner)
            window.representedURL = file
        } else if tab.url.isRemote {
            // Sunucu: alt başlıkta adres; pencere başlığındaki dosya simgesi yok.
            window.subtitle = RemoteURL.replacingPath(tab.url, with: RemoteURL.path(of: tab.url)).absoluteString
            window.representedURL = nil
        } else {
            window.subtitle = (tab.url.path as NSString).abbreviatingWithTildeInPath
            window.representedURL = tab.url
        }
        sidebar.highlight(tab.url)
        viewModeItem?.image = NSImage(systemSymbolName: pane.viewMode.symbol, accessibilityDescription: nil)
        functionBar?.update(dualPane: workspace.isDualPane)
        if touchBarDualPane != nil, touchBarDualPane != workspace.isDualPane { touchBar = nil }   // F5/F6 adları değişsin
        dualPaneButton.state = workspace.isDualPane ? .on : .off
        updatePreview()
        hiddenFilesButton.state = Preferences.showHidden ? .on : .off
        // Açık düğmeler temanın vurgu renginde (Sistem temasında macOS'un rengi).
        for button in [dualPaneButton, hiddenFilesButton, previewButton] { button.bezelColor = Theme.current.accent }
    }

    func workspaceWantsCloseWindow() { window?.performClose(nil) }

    /// Dil değişince pencere yeniden kurulurken taşınan durum.
    struct State {
        let left: [TabState], leftSelected: Int
        let right: [TabState], rightSelected: Int
        let dualPane: Bool, rightActive: Bool, sidebarCollapsed: Bool
        let frame: NSRect?
    }

    func captureState() -> State {
        for pane in [workspace.left, workspace.right] { pane.tab.selectedURLs = pane.selectedURLs }
        let split = window?.contentViewController as? NSSplitViewController
        return State(left: workspace.left.tabs, leftSelected: workspace.left.selectedTab,
                     // Gizli sağ panel saklanmaz: tek paneldeyken kaydedilirse sonraki açılışta eski (ör. SSH) sekmesi
                     // geri gelip sunucuya bağlanırdı. Çift panel açılınca sağ panel etkin klasörden başlar.
                     right: workspace.isDualPane ? workspace.right.tabs : [],
                     rightSelected: workspace.isDualPane ? workspace.right.selectedTab : 0,
                     dualPane: workspace.isDualPane, rightActive: workspace.activePane === workspace.right,
                     sidebarCollapsed: split?.splitViewItems.first?.isCollapsed ?? false, frame: window?.frame)
    }

    func restore(_ state: State) {
        if let frame = state.frame { window?.setFrame(frame, display: false) }
        workspace.restore(left: state.left, leftSelected: state.leftSelected, right: state.right,
                          rightSelected: state.rightSelected, dualPane: state.dualPane, rightActive: state.rightActive)
        (window?.contentViewController as? NSSplitViewController)?.splitViewItems.first?.isCollapsed = state.sidebarCollapsed
        workspaceActivePaneDidChange()
    }

    /// Taşınan sekmelerle açılan pencere (sol panel bu sekmeleri alır).
    func adoptTabs(_ tabs: [TabState]) {
        workspace.left.setTabs(tabs)
        workspaceActivePaneDidChange()
    }

    @objc private func defaultsChanged() {
        rebuildToolbar()
        applyFunctionBarVisibility()
        hiddenFilesButton.state = Preferences.showHidden ? .on : .off
    }

    @objc private func themeChanged() {
        titleBand.needsDisplay = true
        workspaceActivePaneDidChange()
        functionBar?.update(dualPane: workspace.isDualPane)
        sidebar.applyTheme()
        workspace.left.applyTheme()
        workspace.right.applyTheme()
        window?.contentView?.redrawSubtree()
    }

    /// Geri Al / Yinele: metin düzenlenirken metnin kendi geçmişi, değilse tüm pencereler için ortak dosya geçmişi.
    private let textUndoManager = UndoManager()

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSTextView ? textUndoManager : UndoCenter.shared.manager
    }

    func windowWillClose(_ notification: Notification) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        onClose?()
    }

    // MARK: Klavye ve fare

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
                return self.handleKeyDown(event)
            }
            return handled ? nil : event
        } as Any)
        // Bir panelin herhangi bir yerine tıklamak onu etkin panel yapar.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window else { return }
                // Araç çubuğu ve başlık alanı panellerin üstüne taşar (tam boy içerik): oraya tıklamak
                // (örn. Görünüm menüsü) etkin paneli değiştirmesin; komut o an etkin olan panele uygulanır.
                guard window.contentLayoutRect.contains(event.locationInWindow) else { return }
                for pane in self.workspace.visiblePanes {
                    let point = pane.view.convert(event.locationInWindow, from: nil)
                    if pane.view.bounds.contains(point) { self.workspace.activate(pane) }
                }
            }
            return event
        } as Any)
    }

    /// Menülerin karşılamadığı kısayollar. Windows düzeninde Ctrl+harf, ⌘+harf gibi çalışır.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let mode = Preferences.keyboardMode
        let editingText = window?.firstResponder is NSTextView
        let tableFocused = pane.isListFocused(window?.firstResponder)

        // Ctrl+Tab / Ctrl+Shift+Tab: sekmeler arasında (iki düzende de)
        if event.keyCode == KeyCode.tab, mods == [.control] { pane.selectNextTab(); return true }
        if event.keyCode == KeyCode.tab, mods == [.control, .shift] { pane.selectPreviousTab(); return true }

        // ⇧⌘. : gizli öğeler. Türkçe klavyede Shift+nokta ":" ürettiğinden menü kısayolu eşleşmez; tuşun kendisine bakılır.
        if mods == [.command, .shift], event.characters(byApplyingModifiers: []) == "." {
            toggleHiddenFiles(nil)
            return true
        }

        // Ctrl+Shift+1…6: görünümler (Windows Gezgini'ndeki gibi; Türkçe klavyede de tuş koduna bakılır)
        if mode == .windows, mods == [.control, .shift], let index = KeyCode.digits.firstIndex(of: event.keyCode),
           index < ViewMode.allCases.count {
            pane.setViewMode(ViewMode.allCases[index])
            return true
        }

        // Ctrl+Y: Yinele (Windows); ⌘Y'ye çevrilmez, çünkü ⌘Y Hızlı Bakış'tır.
        if mode == .windows, event.keyCode == KeyCode.y, mods == [.control] {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
            return true
        }

        if mode == .windows, mods.contains(.control), !mods.contains(.command),
           let translated = Self.replacingControlWithCommand(event),
           NSApp.mainMenu?.performKeyEquivalent(with: translated) == true {
            return true
        }

        guard !editingText else { return false }

        if mode == .windows {
            switch (event.keyCode, mods) {
            case (KeyCode.returnKey, []), (KeyCode.enter, []):
                if tableFocused { pane.openSelection(); return true }
            case (KeyCode.backspace, []):
                if tableFocused { pane.goUp(); return true }
            case (KeyCode.leftArrow, [.option]):
                pane.goBack(); return true
            case (KeyCode.rightArrow, [.option]):
                pane.goForward(); return true
            case (KeyCode.upArrow, [.option]):
                pane.goUp(); return true
            case (KeyCode.f5, []):
                functionF5(nil)
                return true
            case (KeyCode.forwardDelete, []):
                if tableFocused { pane.deleteSelection(permanently: false); return true }
            case (KeyCode.forwardDelete, [.shift]):
                if tableFocused { pane.deleteSelection(permanently: true); return true }
            case (KeyCode.d, [.option]):
                pane.focusAddressBar(); return true
            case (KeyCode.p, [.option]):
                togglePreviewPane(nil); return true
            case (KeyCode.returnKey, [.option]), (KeyCode.enter, [.option]):
                // Alt+Enter: Özellikler
                if tableFocused { pane.showProperties(); return true }
            default:
                break
            }
        } else if (event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.enter), mods.isEmpty, tableFocused {
            // Mac düzeni: Enter yeniden adlandırır (Finder gibi)
            pane.beginRename()
            return true
        }

        // Klavyeyle çoklu seçim (mc / Total Commander gibi): Windows düzeninde Boşluk, iki düzende Insert işaretler ve
        // imleci bir alta geçirir; Ctrl+Boşluk imleci yerinde bırakır. Mac düzeninde Boşluk Finder gibi Hızlı Bakış'tır.
        if tableFocused {
            if event.keyCode == KeyCode.space, mods.isEmpty {
                if mode == .windows { pane.toggleMark(advance: true) } else { pane.toggleQuickLook() }
                return true
            }
            if event.keyCode == KeyCode.space, mods == [.control] { pane.toggleMark(advance: false); return true }
            if event.keyCode == KeyCode.insert, mods.isEmpty { pane.toggleMark(advance: true); return true }
            // Sayısal tuş takımı (mc gibi): + desene göre seç, − seçimden çıkar, * tersine çevir.
            if mods.isEmpty, event.modifierFlags.contains(.numericPad) || event.keyCode == KeyCode.keypadMultiply {
                switch event.keyCode {
                case KeyCode.keypadPlus: pane.selectByPattern(adding: true); return true
                case KeyCode.keypadMinus: pane.selectByPattern(adding: false); return true
                case KeyCode.keypadMultiply: pane.invertSelection(); return true
                default: break
                }
            }
            // İşaretleme sürerken oklar yalnızca imleci gezdirir; Esc işaretleri kaldırır.
            if pane.isMarking, mods.isEmpty || mods == [.shift] {
                switch event.keyCode {
                case KeyCode.upArrow, KeyCode.downArrow, KeyCode.leftArrow, KeyCode.rightArrow,
                     KeyCode.home, KeyCode.end, KeyCode.pageUp, KeyCode.pageDown:
                    pane.moveMarkCursor(event.keyCode)
                    return true
                case KeyCode.escape:
                    pane.clearMarks()
                    return true
                default:
                    break
                }
            }
            // Home, End, Page Up, Page Down seçimi taşır (Windows Gezgini gibi); AppKit yalnızca kaydırırdı. Shift seçimi genişletir.
            if mods.isEmpty || mods == [.shift],
               [KeyCode.home, KeyCode.end, KeyCode.pageUp, KeyCode.pageDown].contains(event.keyCode) {
                pane.moveSelection(event.keyCode, extending: mods == [.shift])
                return true
            }
        }

        // İşlev tuşları (iki düzende de; çubuk ve Touch Bar ile aynı)
        if mods.isEmpty {
            switch event.keyCode {
            case KeyCode.f1: showShortcuts(); return true
            case KeyCode.f3 where tableFocused: pane.viewSelection(); return true
            case KeyCode.f4 where tableFocused: pane.editSelection(); return true
            case KeyCode.f7: pane.createNewFolder(); return true
            case KeyCode.f8 where tableFocused: pane.deleteSelection(permanently: false); return true
            default: break
            }
        }

        // Tab: çift panelde diğer panele geç
        if event.keyCode == KeyCode.tab, mods.isEmpty, tableFocused, workspace.isDualPane {
            workspace.switchPane()
            return true
        }
        return false
    }

    private static func replacingControlWithCommand(_ event: NSEvent) -> NSEvent? {
        var flags = event.modifierFlags
        flags.remove(.control)
        flags.insert(.command)
        return NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.charactersIgnoringModifiers ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode)
    }

    // MARK: Menü komutları

    @objc func newFileTab(_ sender: Any?) { pane.newTab() }
    @objc func closeFileTab(_ sender: Any?) { pane.closeCurrentTab() }
    @objc func nextFileTab(_ sender: Any?) { pane.selectNextTab() }
    @objc func previousFileTab(_ sender: Any?) { pane.selectPreviousTab() }
    @objc func goBack(_ sender: Any?) { pane.goBack() }
    @objc func goForward(_ sender: Any?) { pane.goForward() }
    @objc func goUp(_ sender: Any?) { pane.goUp() }
    @objc func openSelection(_ sender: Any?) { pane.openSelection() }
    @objc func refresh(_ sender: Any?) { pane.refresh() }
    @objc func focusAddressBar(_ sender: Any?) { pane.focusAddressBar() }
    @objc func focusSearch(_ sender: Any?) { pane.focusSearch() }
    @objc func switchPane(_ sender: Any?) { workspace.switchPane() }

    // Dosya işlemleri (Düzen ve Dosya menüleri)
    @objc func cut(_ sender: Any?) { pane.copySelection(cut: true) }
    @objc func copy(_ sender: Any?) { pane.copySelection(cut: false) }
    @objc func paste(_ sender: Any?) { pane.paste() }
    @objc func moveToTrash(_ sender: Any?) { pane.deleteSelection(permanently: false) }
    @objc func deletePermanently(_ sender: Any?) { pane.deleteSelection(permanently: true) }
    @objc func renameSelection(_ sender: Any?) { pane.beginRename() }
    @objc func newFolder(_ sender: Any?) { pane.createNewFolder() }
    @objc func newTextDocument(_ sender: Any?) { pane.createNewTextDocument() }
    @objc func showProperties(_ sender: Any?) { pane.showProperties() }

    /// Git ▸ Sunucuya Bağlan… (⌘K, Finder gibi): bağlanan sunucu etkin panelde açılır.
    @objc func connectToServer(_ sender: Any?) {
        ConnectServerController.present(over: window) { [weak self] url in self?.workspace.activePane.navigate(to: url) }
    }

    /// F5: çift panelde diğer panele kopyala (Total Commander gibi), tek panelde yenile (Windows gibi).
    @objc func functionF5(_ sender: Any?) {
        if workspace.isDualPane { transferToOtherPane(.copy) } else { pane.refresh() }
    }

    private func showShortcuts() { ShortcutsWindowController.shared.present(over: window) }

    @objc func selectViewMode(_ sender: NSMenuItem) {
        guard ViewMode.allCases.indices.contains(sender.tag) else { return }
        pane.setViewMode(ViewMode.allCases[sender.tag])
    }
    @objc func openInTerminal(_ sender: Any?) { pane.openInTerminal(pane.tab.url) }
    @objc func copyFolderPath(_ sender: Any?) {
        let urls = pane.selectedURLs
        pane.copyPaths(urls.isEmpty ? [pane.tab.url] : urls)
    }
    @objc func quickLook(_ sender: Any?) { pane.toggleQuickLook() }
    @objc func viewSelection(_ sender: Any?) { pane.viewSelection() }

    @objc func selectMatchingItems(_ sender: Any?) { pane.selectByPattern(adding: true) }
    @objc func deselectMatchingItems(_ sender: Any?) { pane.selectByPattern(adding: false) }
    /// Ad, AppKit'in kendi `invertSelection:` komutuyla çakışmasın (o liste görünümünde klasörleri de seçer).
    @objc func invertItemSelection(_ sender: Any?) { pane.invertSelection() }

    /// Yeni pencere, Windows Gezgini gibi etkin panelin klasöründe açılır (arşivin içindeyse Ana Klasör'de).
    @objc func newWindowHere(_ sender: Any?) {
        let url = pane.tab.url
        let start = Archives.isArchive(url) ? FileManager.default.homeDirectoryForCurrentUser : url
        (NSApp.delegate as? AppDelegate)?.newWindow(at: start)
    }
    @objc func editSelection(_ sender: Any?) { pane.editSelection() }
    @objc func copyToOtherPane(_ sender: Any?) { transferToOtherPane(.copy) }
    @objc func moveToOtherPane(_ sender: Any?) { transferToOtherPane(.move) }

    /// Kullanıcıya gösterilen konum: bu Mac'te "~/Belgeler/…", sunucuda "kullanıcı@sunucu: /yol", arşivde "arşiv.zip: /yol"
    /// (adresteki %20 gibi kodlar çözülmüş).
    static func readableLocation(_ url: URL) -> String {
        guard url.isRemote else { return (url.path as NSString).abbreviatingWithTildeInPath }
        let path = RemoteURL.path(of: url)
        if Archives.isArchive(url) { return Archives.displayName(url) + ": " + path }
        var server = url.host ?? ""
        if let user = url.user?.removingPercentEncoding ?? url.user, !user.isEmpty { server = user + "@" + server }
        if let port = url.port { server += ":\(port)" }
        return server + ": " + path
    }

    /// F5 / F6: seçili öğeleri diğer panelin klasörüne kopyalar / taşır (onay sorulur, Enter onaylar).
    private func transferToOtherPane(_ kind: TransferKind) {
        guard let other = workspace.otherPane, let window else { return }
        let urls = pane.selectedURLs
        guard !urls.isEmpty else { return }
        let destination = other.tab.url
        let alert = NSAlert()
        alert.messageText = kind == .copy
            ? String(localized: "\(urls.count) öğe şuraya kopyalansın mı?", bundle: .live)
            : String(localized: "\(urls.count) öğe şuraya taşınsın mı?", bundle: .live)
        alert.informativeText = Self.readableLocation(destination)
        alert.addButton(withTitle: kind == .copy ? String(localized: "Kopyala", bundle: .live) : String(localized: "Taşı", bundle: .live))
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let source = self.pane
            source.transfer(kind, urls, to: destination) { result in
                other.reveal(result.created, in: destination)
                if !source.isRemote { source.reload() }
            }
        }
    }

    // MARK: Önizleme bölmesi

    /// Alt+P (Windows) / ⇧⌘P (Finder): önizleme bölmesi. Açık / kapalı durumu tüm pencereler için hatırlanır.
    @objc func togglePreviewPane(_ sender: Any?) {
        let show = !isPreviewVisible
        Preferences.previewPane = show
        setPreviewVisible(show)
    }

    private func setPreviewVisible(_ show: Bool) {
        previewButton.state = show ? .on : .off
        guard isPreviewVisible != show else { return }
        if show {
            mainSplit.addSubview(preview.view)
            mainSplit.addSubview(previewDivider)   // en üstte: yakalama alanı önizlemenin kenarına da taşar
            workspaceTrailing?.isActive = false
            previewWidth.constant = max(200, Preferences.previewPaneWidth)
            previewConstraints = [
                workspace.view.trailingAnchor.constraint(equalTo: previewDivider.leadingAnchor),
                previewDivider.trailingAnchor.constraint(equalTo: preview.view.leadingAnchor),
                previewDivider.topAnchor.constraint(equalTo: mainSplit.topAnchor),
                previewDivider.bottomAnchor.constraint(equalTo: mainSplit.bottomAnchor),
                previewDivider.widthAnchor.constraint(equalToConstant: 1),
                preview.view.topAnchor.constraint(equalTo: mainSplit.topAnchor),
                preview.view.bottomAnchor.constraint(equalTo: mainSplit.bottomAnchor),
                preview.view.trailingAnchor.constraint(equalTo: mainSplit.trailingAnchor),
                preview.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
                workspace.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
                previewWidth,
            ]
            NSLayoutConstraint.activate(previewConstraints)
            updatePreview()
        } else {
            preview.clear()
            NSLayoutConstraint.deactivate(previewConstraints)
            previewConstraints = []
            preview.view.removeFromSuperview()
            previewDivider.removeFromSuperview()
            workspaceTrailing?.isActive = true
            // Ayırıcının olduğu şerit hemen yeniden çizilsin (yoksa pencere boyutu değişene kadar ince bir çizgi kalır).
            mainSplit.layoutSubtreeIfNeeded()
            workspace.view.redrawSubtree()
        }
    }

    var isPreviewVisible: Bool { preview.view.superview === mainSplit }

    /// Ayırıcı sürükleniyor: sola çekmek bölmeyi genişletir. Panellere en az 360 pt kalır.
    private func dragPreviewDivider(_ delta: CGFloat) {
        let maxWidth = max(200, mainSplit.bounds.width - 360 - 1)
        previewWidth.constant = min(max(200, previewWidth.constant - delta), maxWidth)
    }

    @objc private func paneSelectionChanged(_ note: Notification) {
        guard (note.object as? PaneViewController) === pane else { return }
        updatePreview()
    }

    private func updatePreview() {
        guard isPreviewVisible else { return }
        preview.show(selection: pane.selectedItems, folder: pane.tab.url, folderItemCount: pane.shown.count)
    }

    @objc func toggleDualPane(_ sender: Any?) {
        workspace.toggleDualPane()
        workspaceActivePaneDidChange()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        Preferences.showHidden.toggle()
        workspaceActivePaneDidChange()
    }

    /// Git menüsündeki sabit konumlar (Masaüstü, Belgeler …): `representedObject` hedef URL'dir.
    @objc func goToPlace(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        pane.navigate(to: url)
    }

    /// Bkz. DebugSnapshot.
    func debugPerform(_ step: String) {
        switch step {
        case "dual": toggleDualPane(nil)
        case "tab": pane.newTab()
        case "hidden": toggleHiddenFiles(nil)
        case "up": pane.goUp()
        case "switch": workspace.switchPane()
        case "cut": cut(nil)
        case "copy": copy(nil)
        case "paste": paste(nil)
        case "newfolder": newFolder(nil)
        case "rename": renameSelection(nil)
        case "trash": moveToTrash(nil)
        case "f5": copyToOtherPane(nil)
        case "enter": (window?.firstResponder as? NSTextView)?.insertNewline(nil)
        case "confirm": window?.attachedSheet?.defaultButtonCell?.performClick(nil)
        case "props": pane.showProperties()
        case "about": AboutWindowController.shared.present()
        case "save-session": (NSApp.delegate as? AppDelegate)?.saveSession()
        case "view?": print("Görünüm:", pane.viewMode.rawValue, "| çift panel:", workspace.isDualPane, "| etkin sağ:", workspace.activePane === workspace.right,
                            "| geri:", pane.tab.history.backStack.map(\.lastPathComponent), "| çerçeve:", window.map { NSStringFromRect($0.frame) } ?? "-")
        case "panes?":
            print("sol:", workspace.left.viewMode.rawValue, workspace.left.listView === workspace.left.table ? "(tablo)" : "(ızgara)",
                  "| sağ:", workspace.right.viewMode.rawValue, workspace.right.listView === workspace.right.table ? "(tablo)" : "(ızgara)",
                  "| etkin:", workspace.activePane === workspace.left ? "sol" : "sağ",
                  "| saydamlık:", workspace.left.listView.enclosingScrollView?.alphaValue ?? -1, workspace.right.listView.enclosingScrollView?.alphaValue ?? -1,
                  "| sol belge:", String(describing: type(of: workspace.left.table.enclosingScrollView?.documentView ?? workspace.left.iconView.enclosingScrollView?.documentView ?? NSView())))
        case "click-toolbar":
            // Araç çubuğunun sağ kısmına (sağ panelin üstü) sahte tıklama
            if let window, let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: window.frame.width - 120, y: window.frame.height - 20),
                                                     modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(e, atStart: false)
                if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: e.locationInWindow, modifierFlags: [], timestamp: e.timestamp,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                    NSApp.postEvent(up, atStart: false)
                }
            }
        case "click-left":
            workspace.activate(workspace.left); workspace.left.focusTable()
        case "click-right":
            workspace.activate(workspace.right); workspace.right.focusTable()
        case "connect": connectToServer(nil)
        case "click-sidebar-connect":
            if let window, let point = sidebar.debugConnectRowPoint() {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
            }
        case "connect-windows?":
            let visible = NSApp.windows.filter { $0.isVisible && !($0.windowController is BrowserWindowController) }
            print("açık diğer pencereler:", visible.count, "| sayfa:", window?.attachedSheet != nil,
                  visible.map { String(describing: type(of: $0.contentViewController as Any)).prefix(60) })
        case "server-add":
            var server = ServerBookmark(address: "smb://kullanici@nas.local/Belgeler")!
            server.name = "Test NAS"
            ServerStore.save(server)
            print("adres çözümü:", server.kind.rawValue, server.host, server.user, server.path, "→", server.url?.absoluteString ?? "-")
            print("WebDAV:", ServerBookmark(address: "https://bulut.example.com/remote.php/dav")?.url?.absoluteString ?? "-",
                  "| geçersiz:", ServerBookmark(address: "nas.local") == nil)
        case "server-clean":
            for s in ServerStore.servers where s.name == "Test NAS" { ServerStore.delete(s) }
            ServerStore.recent.removeAll { $0.name == "Test NAS" }
            print("kalan test kaydı:", ServerStore.servers.filter { $0.name == "Test NAS" }.count)
        case "keychain-test":
            let id = UUID()
            ServerKeychain.set("gizli-123", for: id, label: "MacExplorer test")
            print("Anahtar Zinciri oku:", ServerKeychain.password(for: id) == "gizli-123")
            ServerKeychain.delete(for: id)
            print("silindikten sonra:", ServerKeychain.password(for: id) == nil)
        case "menus?": print("Menüler:", NSApp.mainMenu?.items.map(\.title) ?? [])
        case "tabcopy": pane.openTabInNewWindow(pane.tab)
        case "tabwin": pane.moveTabToNewWindow(pane.tab, at: NSPoint(x: 300, y: 700))
        case "tabother":
            if let other = workspace.otherPane { other.receive(pane.tab, at: other.tabs.count, from: pane) }
        case "tabs?":
            let windows = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.filter { $0.window?.isVisible == true }
            print("Pencere sayısı:", windows.count)
            for (i, w) in windows.enumerated() {
                print("  pencere \(i + 1): sol", w.workspace.left.tabs.map(\.title), w.workspace.isDualPane ? "sağ \(w.workspace.right.tabs.map(\.title))" : "")
            }
        case "windows?":
            print("Açık pencereler:", NSApp.windows.filter(\.isVisible).map { $0.title + ($0.parent === window ? " (bağlı)" : "") })
            for (i, w) in NSApp.windows.filter({ $0.isVisible && $0 !== window }).enumerated() { DebugSnapshot.capture(w, name: "during-\(i)") }
        case "settings": SettingsWindowController.shared.showWindow(nil)
        case "bands?":
            let dark = NSAppearance(named: .darkAqua)!
            for theme in Theme.all {
                let band = theme.titleBandColor.resolved(for: dark).usingColorSpace(.sRGB)!
                let hex = String(format: "%02X%02X%02X", Int(band.redComponent * 255), Int(band.greenComponent * 255), Int(band.blueComponent * 255))
                print("Bant", theme.id, hex, String(format: "%.2f", Theme.subtitleContrast(on: band)))
            }
        case "chrome?":
            print("Pencere üstü | saydam başlık:", window?.titlebarAppearsTransparent ?? false, "| bant:", titleBand.frame.integral)
        case "aux?": print("Yardımcı pencereler | ayarlar açık:", SettingsWindowController.isOpen,
                           "| hakkında içeriği:", AboutWindowController.shared.window?.contentViewController != nil,
                           "| kısayollar içeriği:", ShortcutsWindowController.shared.window?.contentViewController != nil)
        case "close-aux": NSApp.windows.filter { $0.isVisible && !($0.windowController is BrowserWindowController) }.forEach { $0.close() }
        case "shortcuts": showShortcuts()
        case "undo": NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        case "redo": NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        case "ql": pane.toggleQuickLook()
        case "ql?": print("Hızlı Bakış açık:", QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible,
                          "öğe:", QLPreviewPanel.shared().currentPreviewItem?.previewItemURL?.lastPathComponent ?? "-",
                          "kaynak:", QLPreviewPanel.shared().dataSource.map { String(describing: type(of: $0)) } ?? "yok",
                          "sayı:", QLPreviewPanel.shared().dataSource?.numberOfPreviewItems(in: QLPreviewPanel.shared()) ?? -1)
        case "undo?": print("Geri al:", UndoCenter.shared.manager.undoMenuItemTitle, "| Yinele:", UndoCenter.shared.manager.redoMenuItemTitle,
                            "| hedef:", NSApp.target(forAction: Selector(("undo:"))).map { String(describing: type(of: $0)) } ?? "yok",
                            "| ilk yanıtlayıcı:", window?.firstResponder.map { String(describing: type(of: $0)) } ?? "yok",
                            "| grup:", UndoCenter.shared.manager.groupingLevel)
        case "zip": pane.contextMenu(row: pane.selectionIndexes.first ?? -1).items.first { $0.title == String(localized: "Gönder", bundle: .live) }?
            .submenu?.items.first.map { item in _ = item.target?.perform(item.action, with: item) }
        case "menu-item": DebugSnapshot.dump(pane.contextMenu(row: pane.selectionIndexes.first ?? -1))
        case "menu-bg": DebugSnapshot.dump(pane.contextMenu(row: -1))
        case "menu-tab": pane.debugTabMenu().map { DebugSnapshot.dump($0) }
        case "list?":
            print("Konum:", pane.tab.url.absoluteString, "| başlık:", pane.tab.title, "| öğe:", pane.shown.count)
            for item in pane.shown.prefix(12) {
                print("   ", item.isDirectory ? "[klasör]" : "[dosya] ", item.name, item.size.map { "\($0) bayt" } ?? "", item.kind, "|", item.url.absoluteString)
            }
        case "wait": break
        case "preview": togglePreviewPane(nil)
        case "makeiso": pane.makeDiskImage(.iso)
        case "makedmg": pane.makeDiskImage(.dmg)
        case "eject": pane.menuEjectVolume()
        case "constraints?":
            for c in preview.view.constraintsAffectingLayout(for: .horizontal) { print("K:", c) }
            for c in workspace.view.constraintsAffectingLayout(for: .horizontal) { print("W:", c) }
        case "preview?": print("Önizleme:", isPreviewVisible ? "açık" : "kapalı", "|", preview.debugSummary, "| genişlik:", Int(preview.view.frame.width))
        case "connect-sftp":
            ConnectServerController.present(over: window, editing: ServerBookmark(name: "Örnek", kind: .sftp, host: "sunucu.example.com", user: "ali"))
        case "sheet?":
            // Açık uyarıdaki metinler (uyarılar pencere görüntüsüne çizilmez).
            func texts(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts) }
            let sheet = window?.attachedSheet ?? NSApp.modalWindow
            print("Uyarı:", sheet?.contentView.map(texts)?.filter { !$0.isEmpty } ?? ["(yok)"])
            func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
            print("  düğmeler:", sheet?.contentView.map(buttons)?.map { "\($0.title)=\($0.keyEquivalent.unicodeScalars.map { $0.value })" } ?? [],
                  "varsayılan:", sheet?.defaultButtonCell?.title ?? "-")
        default:
            // Uzak sunucu (yalnızca geliştirme): remote:sftp://kullanıcı:parola@sunucu/yol
            // Ağ paylaşımına bağlanma: smb://10.255.255.1/paylasim (parola sorulmaz, kayıt tutulmaz)
            if step.hasPrefix("smb:"), let server = ServerBookmark(address: step) {
                ServerConnector.connect(server, password: "x", over: window) { [weak self] url in self?.pane.navigate(to: url) }
            }
            // Tuşa basma (tuş kodu, isteğe bağlı ctrl/cmd/shift): key:49, key:49:ctrl
            if step.hasPrefix("key:") {
                let parts = step.dropFirst(4).split(separator: ":")
                var flags: NSEvent.ModifierFlags = []
                if parts.contains("ctrl") { flags.insert(.control) }
                if parts.contains("cmd") { flags.insert(.command) }
                if parts.contains("shift") { flags.insert(.shift) }
                if parts.contains("num") { flags.insert(.numericPad) }
                if let code = parts.first.flatMap({ UInt16($0) }), let window,
                   let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: " ",
                                                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code) {
                    window.makeFirstResponder(pane.listView)
                    _ = handleKeyDown(event)
                }
            }
            // Ana menüden bir komut (menünün gönderdiği yoldan): menu-action:invertSelection:
            if step.hasPrefix("menu-action:") {
                window?.makeFirstResponder(pane.listView)
                let target = NSApp.target(forAction: Selector(String(step.dropFirst(12))))
                print("Hedef:", target.map { String(describing: type(of: $0)) } ?? "yok", "| ilk yanıtlayıcı:", window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-")
                NSApp.sendAction(Selector(String(step.dropFirst(12))), to: nil, from: nil)
            }
            if step == "update-check" { Updater.check(userInitiated: true) }
            if step == "update-install" { Updater.check(userInitiated: true, installWithoutAsking: true) }
            if step == "marks?" { print("Seçili:", pane.debugSelectedNames) }
            // Açık uyarıda başlığı verilen düğmeye basar: press:Zorla Çıkar
            if step.hasPrefix("press:"), let sheet = window?.attachedSheet ?? NSApp.modalWindow {
                let title = String(step.dropFirst(6))
                func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
                sheet.contentView.map(buttons)?.first { $0.title == title }?.performClick(nil)
            }
            if step.hasPrefix("remote:"), var c = URLComponents(string: String(step.dropFirst(7))) {
                let password = c.password
                c.password = nil
                if let server = ServerBookmark(address: c.string ?? "") {
                    let window = self.window
                    Task { [weak self] in
                        if let url = await RemoteSessions.open(server, password: password, window: window) { self?.pane.navigate(to: url) }
                    }
                }
            }
            if step.hasPrefix("alert-type:") {
                // Açık uyarıdaki parola kutusuna yaz (yalnızca geliştirme).
                func secure(_ v: NSView) -> NSTextField? { ((v as? NSTextField).flatMap { $0.isEditable ? $0 : nil }) ?? v.subviews.lazy.compactMap(secure).first }
                if let sheet = window?.attachedSheet, let field = sheet.contentView.flatMap(secure) { field.stringValue = String(step.dropFirst(11)) }
            }
            if step.hasPrefix("search:") { pane.debugSearch(String(step.dropFirst(7))) }
            if step == "details" { pane.setViewMode(.details) }
            if step == "status?" { print("Durum:", pane.debugStatus) }
            if step.hasPrefix("browse:") { pane.browseArchive(URL(fileURLWithPath: String(step.dropFirst(7)))) }
            if step.hasPrefix("extractall:"), let file = Archives.file(for: pane.tab.url) {
                ArchiveExtractor.extractAll(file, into: URL(fileURLWithPath: String(step.dropFirst(11))), window: window) { print("Ayıklandı:", $0.path) }
            }
            if step.hasPrefix("mount:") { pane.mountDiskImage(URL(fileURLWithPath: String(step.dropFirst(6)))) }
            if step.hasPrefix("open:") {
                pane.debugSelect([String(step.dropFirst(5))])
                pane.openSelection()
            }
            if step.hasPrefix("type:"), let editor = window?.firstResponder as? NSTextView {
                editor.insertText(String(step.dropFirst(5)), replacementRange: editor.selectedRange())
            }
            if step.hasPrefix("path:") { pane.navigate(to: URL(fileURLWithPath: String(step.dropFirst(5)))) }
            if step.hasPrefix("macrar:"), let action = MacRARAction(rawValue: String(step.dropFirst(7))) {
                pane.runMacRAR(action, on: pane.selectedURLs)
            }
            if step.hasPrefix("tabto:"), let n = Int(step.dropFirst(6)) {
                // Etkin sekmeyi n. pencerenin sol paneline bırak (sekme çubuğuna sürükle-bırak gibi)
                let windows = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.filter { $0.window?.isVisible == true }
                if windows.indices.contains(n - 1) {
                    let target = windows[n - 1].workspace.left
                    target.receive(pane.tab, at: 0, from: pane)
                }
            }
            if step.hasPrefix("lasso:") {
                // Listenin içinde (sol üstten oranla) iki nokta arası sürükleme: x1/y1/x2/y2 (0…1)
                let v = step.dropFirst(6).split(separator: "/").compactMap { Double($0) }
                let list = pane.listView
                if v.count == 4, let window, let clip = list.enclosingScrollView?.contentView {
                    let r = clip.convert(clip.bounds, to: nil)
                    func point(_ fx: Double, _ fy: Double) -> NSPoint { NSPoint(x: r.minX + r.width * fx, y: r.maxY - r.height * fy) }
                    func post(_ type: NSEvent.EventType, _ p: NSPoint) {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                    let a = point(v[0], v[1]), b = point(v[2], v[3])
                    post(.leftMouseDown, a)
                    for i in 1...8 { post(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * Double(i) / 8, y: a.y + (b.y - a.y) * Double(i) / 8)) }
                    post(.leftMouseUp, b)
                }
            }
            if step == "sel?" { print("Seçili:", pane.selectedItems.map(\.name)) }
            if step.hasPrefix("settings:"), let pane = SettingsPane(rawValue: String(step.dropFirst(9))) {
                SettingsWindowController.shared.show(pane)
            }
            if step.hasPrefix("lang:"), let language = AppLanguage(rawValue: String(step.dropFirst(5))) {
                (NSApp.delegate as? AppDelegate)?.applyLanguage(language)
            }
            // Pencere genişliği: width:700 (çubukların daralıp genişlemesini denemek için)
            if step.hasPrefix("width:"), let width = Double(step.dropFirst(6)), let window {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
            }
            if step == "fkeys?", let bar = functionBar { print("İşlev tuşları:", bar.debugFrames) }
            if step.hasPrefix("view:"), let mode = ViewMode(rawValue: String(step.dropFirst(5))) { pane.setViewMode(mode) }
            if step.hasPrefix("theme:") {
                UserDefaults.standard.set(String(step.dropFirst(6)), forKey: Preferences.Key.theme)
                NotificationCenter.default.post(name: Theme.didChange, object: nil)
            }
            if step.hasPrefix("appearance:") {
                UserDefaults.standard.set(String(step.dropFirst(11)), forKey: Preferences.Key.appearance)
                Theme.applyAppearance()
            }
            if step.hasPrefix("select:") { pane.debugSelect(step.dropFirst(7).split(separator: "+").map(String.init)) }
            if step.hasPrefix("type:"), let window {   // simge görünümünde yazarak seçme
                for ch in step.dropFirst(5) {
                    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) {
                        pane.iconView.keyDown(with: e)
                    }
                }
                print("yazılan:", step.dropFirst(5), "→ seçili:", pane.iconView.selectionIndexPaths.map(\.item).sorted())
            }
        }
    }

    /// Araç çubuğundaki düzen düğmeleri menüdeki aynı komutlarla aynı anda etkin/pasif olur.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = item.action else { return true }
        return validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    // MARK: Başlık bandı ve pencere kenarı

    /// Koyu görünümde pencerenin üstü (başlık ve araç çubuğu) temanın biraz açık bir tonunu alır: koyu masaüstünde ya da
    /// koyu bir pencerenin önünde tutulacak yer seçilsin. Açık görünümde macOS'un kendi başlık çubuğu kalır.
    /// (Pencere çevresine kenar çizgisi çizilmez: çerçeve katmanı köşe yarıçapını bildirmiyor, düz çizgi köşelerde kırılırdı.)
    private func installTitleBand() {
        titleBand.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(titleBand, positioned: .above, relativeTo: mainSplit)
        NSLayoutConstraint.activate([
            titleBand.topAnchor.constraint(equalTo: content.view.topAnchor),
            titleBand.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            titleBand.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            titleBand.bottomAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor),
        ])
        titleBand.onAppearanceChange = { [weak self] in self?.applyWindowChrome() }
        applyWindowChrome()
    }

    private func applyWindowChrome() {
        guard let window else { return }
        let dark = window.effectiveAppearance.isDark
        if window.titlebarAppearsTransparent != dark { window.titlebarAppearsTransparent = dark }
        titleBand.needsDisplay = true
    }

    // MARK: İşlev tuşu çubuğu ve Touch Bar

    private func installFunctionBar() {
        let bar = FunctionKeyBar(target: self)
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(bar)
        let height = bar.heightAnchor.constraint(equalToConstant: 26)
        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: content.view.topAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
            height,
        ])
        functionBar = bar
        functionBarHeight = height
        applyFunctionBarVisibility()
    }

    private func applyFunctionBarVisibility() {
        let shown = UIElement.functionBar.isShown
        functionBar?.isHidden = !shown
        functionBarHeight?.constant = shown ? 26 : 0
    }

    /// Touch Bar'lı MacBook'larda MacExplorer öndeyken işlev tuşları kısa adlarıyla görünür.
    /// Tuşlar kaydırılabilir bir alandadır: sistem şeridinin yanına sığmayanlara parmakla kaydırarak ulaşılır.
    override func makeTouchBar() -> NSTouchBar? {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.functionKeys]
        touchBarDualPane = workspace.isDualPane
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == .functionKeys else { return nil }
        // Dokuz düğme eşit genişlikte (fiziksel F tuşları gibi): en uzun etiket kadar, ama hepsi birlikte
        // sistem şeridinin bıraktığı alana sığacak kadar. Elle dizilir: kaydırılan alanın genişliği kesin olsun.
        let row = NSView()
        let height: CGFloat = 30, spacing: CGFloat = 3, available: CGFloat = 670
        let buttons = FunctionKey.allCases.map { key -> NSButton in
            let button = NSButton(title: "\(key.key) \(key.shortTitle(dualPane: workspace.isDualPane))", target: self, action: key.action)
            button.font = .systemFont(ofSize: 11)
            button.isEnabled = key != .move || workspace.isDualPane
            return button
        }
        let fitting = (available - spacing * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
        let buttonWidth = min(buttons.map(\.intrinsicContentSize.width).max() ?? fitting, fitting).rounded(.down)
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(i) * (buttonWidth + spacing), y: 0, width: buttonWidth, height: height)
            row.addSubview(button)
        }
        row.frame = NSRect(x: 0, y: 0, width: CGFloat(buttons.count) * (buttonWidth + spacing) - spacing, height: height)
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = row
        // Tuşların hepsinin genişliği kadar (en çok sistem şeridinin bıraktığı alan kadar); fazlası kaydırılır.
        let width = scroll.widthAnchor.constraint(equalToConstant: min(row.frame.width, available))
        width.priority = .defaultHigh
        width.isActive = true
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = scroll
        item.customizationLabel = String(localized: "İşlev tuşları", bundle: .live)
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Bir metin düzenlenirken dosya komutları kapalı: ⌘⌫ ya da F2 yanlışlıkla dosyaya uygulanmasın.
        let editingText = window?.firstResponder is NSTextView
        let hasSelection = !pane.selectedItems.isEmpty
        switch menuItem.action {
        case #selector(copy(_:)):
            return !editingText && hasSelection
        case #selector(cut(_:)), #selector(moveToTrash(_:)), #selector(deletePermanently(_:)):
            return !editingText && hasSelection && !pane.isArchive
        case #selector(paste(_:)):
            return !editingText && FileClipboard.hasFiles && !pane.isArchive
        case #selector(selectViewMode(_:)):
            menuItem.state = ViewMode.allCases.indices.contains(menuItem.tag) && ViewMode.allCases[menuItem.tag] == pane.viewMode ? .on : .off
            return true
        case #selector(functionF5(_:)):
            return !editingText && (!workspace.isDualPane || hasSelection)
        case #selector(editSelection(_:)):
            return !editingText && pane.selectedItems.contains { !$0.isDirectory }
        case #selector(quickLook(_:)), #selector(viewSelection(_:)):
            return !editingText && hasSelection && !pane.isRemote
        case #selector(showProperties(_:)):
            return !pane.isRemote
        case #selector(renameSelection(_:)):
            return !editingText && pane.selectedItems.count == 1 && !pane.isArchive
        case #selector(newFolder(_:)), #selector(newTextDocument(_:)):
            return !editingText && !pane.isArchive
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            return !editingText && hasSelection && workspace.isDualPane
        case #selector(goBack(_:)): return pane.canGoBack
        case #selector(goForward(_:)): return pane.canGoForward
        case #selector(goUp(_:)): return pane.canGoUp
        case #selector(openSelection(_:)): return !pane.selectedItems.isEmpty
        case #selector(nextFileTab(_:)), #selector(previousFileTab(_:)): return pane.tabs.count > 1
        case #selector(switchPane(_:)): return workspace.isDualPane
        case #selector(toggleDualPane(_:)):
            menuItem.state = workspace.isDualPane ? .on : .off
            return true
        case #selector(togglePreviewPane(_:)):
            menuItem.state = isPreviewVisible ? .on : .off
            return true
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = Preferences.showHidden ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: Araç çubuğu

    /// Araç çubuğundaki düğmeler Ayarlar ▸ Arayüz'den kapatılabilir.
    private var toolbarIdentifiers: [NSToolbarItem.Identifier] {
        let optional: [(UIElement, NSToolbarItem.Identifier)] = [
            (.toolbarViewMode, .viewMode), (.toolbarTerminal, .terminal), (.toolbarHidden, .hiddenFiles), (.toolbarDualPane, .dualPane),
            (.toolbarPreview, .previewPane), (.toolbarNewWindow, .newWindow),
        ]
        let edit: [NSToolbarItem.Identifier] = UIElement.toolbarEdit.isShown
            ? [.newFolderItem, .space, .cutItem, .copyItem, .pasteItem, .space, .renameItem, .deleteItem] : []
        return [.toggleSidebar, .sidebarTrackingSeparator] + edit + [.flexibleSpace] + optional.filter { $0.0.isShown }.map(\.1)
    }

    private var toolbarDisplayObservation: NSKeyValueObservation?

    private func rebuildToolbar() {
        let display = Preferences.toolbarDisplay.mode
        if let toolbar = window?.toolbar, toolbar.items.map(\.itemIdentifier) == toolbarIdentifiers {
            if toolbar.displayMode != display { toolbar.displayMode = display }
            return
        }
        let toolbar = NSToolbar(identifier: "BrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = display
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        // Araç çubuğunun sağ tık menüsünden seçilen gösterim de kalıcı olsun (Ayarlar ile aynı ayar).
        toolbarDisplayObservation = toolbar.observe(\.displayMode) { toolbar, _ in
            let mode = toolbar.displayMode
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if Preferences.toolbarDisplay.mode != mode, mode != .default { Preferences.toolbarDisplay = ToolbarDisplay(mode) }
                }
            }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .dualPane:
            configureToggle(dualPaneButton, symbol: "rectangle.split.2x1", tip: String(localized: "Çift panel (F9)", bundle: .live), action: #selector(toggleDualPane(_:)))
            item.view = dualPaneButton
            item.label = String(localized: "Çift panel", bundle: .live)
        case .previewPane:
            configureToggle(previewButton, symbol: "sidebar.right", tip: String(localized: "Önizleme bölmesi (Alt+P)", bundle: .live), action: #selector(togglePreviewPane(_:)))
            previewButton.state = isPreviewVisible ? .on : .off
            item.view = previewButton
            item.label = String(localized: "Önizleme", bundle: .live)
        case .newFolderItem, .cutItem, .copyItem, .pasteItem, .renameItem, .deleteItem:
            let (symbol, title, action): (String, String, Selector) = {
                switch id {
                case .newFolderItem: return ("folder.badge.plus", String(localized: "Yeni klasör", bundle: .live), #selector(newFolder(_:)))
                case .cutItem: return ("scissors", String(localized: "Kes", bundle: .live), #selector(cut(_:)))
                case .copyItem: return ("doc.on.doc", String(localized: "Kopyala", bundle: .live), #selector(copy(_:)))
                case .pasteItem: return ("doc.on.clipboard", String(localized: "Yapıştır", bundle: .live), #selector(paste(_:)))
                case .renameItem: return ("pencil", String(localized: "Yeniden adlandır", bundle: .live), #selector(renameSelection(_:)))
                default: return ("trash", String(localized: "Sil", bundle: .live), #selector(moveToTrash(_:)))
                }
            }()
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.label = title
            item.toolTip = title
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        case .viewMode:
            let menuItem = NSMenuToolbarItem(itemIdentifier: id)
            let menu = NSMenu()
            for (i, mode) in ViewMode.allCases.enumerated() {
                let entry = NSMenuItem(title: mode.title, action: #selector(selectViewMode(_:)), keyEquivalent: "")
                entry.tag = i
                entry.target = self
                entry.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
                menu.addItem(entry)
            }
            menuItem.menu = menu
            menuItem.showsIndicator = true
            menuItem.label = String(localized: "Görünüm", bundle: .live)
            menuItem.toolTip = String(localized: "Görünüm", bundle: .live)
            menuItem.image = NSImage(systemSymbolName: pane.viewMode.symbol, accessibilityDescription: nil)
            viewModeItem = menuItem
            return menuItem
        case .terminal:
            let button = NSButton(image: NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)!,
                                  target: self, action: #selector(openInTerminal(_:)))
            button.bezelStyle = .toolbar
            button.toolTip = String(localized: "Terminalde aç (⌥⌘T)", bundle: .live)
            item.view = button
            item.label = String(localized: "Terminalde aç", bundle: .live)
        case .newWindow:
            let button = NSButton(image: NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil)!,
                                  target: self, action: #selector(newWindowHere(_:)))
            button.bezelStyle = .toolbar
            button.toolTip = String(localized: "Yeni pencere (Ctrl+N)", bundle: .live)
            item.view = button
            item.label = String(localized: "Yeni pencere", bundle: .live)
        case .hiddenFiles:
            configureToggle(hiddenFilesButton, symbol: "eye", tip: String(localized: "Gizli öğeler", bundle: .live), action: #selector(toggleHiddenFiles(_:)))
            item.view = hiddenFilesButton
            item.label = String(localized: "Gizli öğeler", bundle: .live)
        default:
            return nil
        }
        item.toolTip = (item.view as? NSButton)?.toolTip
        return item
    }

    private func configureToggle(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .toolbar
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.toolTip = tip
        button.target = self
        button.action = action
    }
}

/// Donanım tuş kodları (klavye düzeninden bağımsız).
enum KeyCode {
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let tab: UInt16 = 48
    static let backspace: UInt16 = 51
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let home: UInt16 = 115
    static let end: UInt16 = 119
    static let pageUp: UInt16 = 116
    static let pageDown: UInt16 = 121
    static let escape: UInt16 = 53
    static let f5: UInt16 = 96
    static let d: UInt16 = 2
    static let p: UInt16 = 35
    static let forwardDelete: UInt16 = 117
    static let f1: UInt16 = 122
    static let f3: UInt16 = 99
    static let f4: UInt16 = 118
    static let f7: UInt16 = 98
    static let f8: UInt16 = 100
    static let y: UInt16 = 16
    static let space: UInt16 = 49
    /// Insert (PC klavyeleri) / Help (Apple'ın tam boy klavyeleri): aynı tuş kodu.
    static let insert: UInt16 = 114
    static let keypadPlus: UInt16 = 69
    static let keypadMinus: UInt16 = 78
    static let keypadMultiply: UInt16 = 67
    /// Üst sıradaki 1…6 rakam tuşları.
    static let digits: [UInt16] = [18, 19, 20, 21, 23, 22]
}

/// Paneller ile önizleme bölmesi arasındaki ince ayırıcı: sürüklenince bölmenin genişliği değişir.
final class PaneDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    private var lastX: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }

    /// Çizgi 1 pt; yakalama alanı iki yana 3 pt taşar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return local.y >= 0 && local.y <= bounds.height && abs(local.x - bounds.midX) <= 4 ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: -3, dy: 0), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) { lastX = event.locationInWindow.x }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX)
        lastX = x
    }

    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}

/// Başlık ve araç çubuğunun altında kalan bant (yalnızca koyu görünümde boyanır). Tıklamaları geçirir: pencere
/// buradan sürüklenir, araç çubuğu düğmeleri üstünde kalır.
@MainActor
final class TitleBandView: NSView {
    var onAppearanceChange: (() -> Void)?

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard effectiveAppearance.isDark else { return }
        Theme.current.titleBandColor.setFill()
        bounds.fill()
        // Alt kenarda ince ayırıcı: bant sekme şeridinden de ayrılsın.
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearanceChange?()
    }
}
