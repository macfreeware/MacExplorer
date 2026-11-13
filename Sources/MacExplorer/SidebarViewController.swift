import AppKit
import MacExplorerCore

@MainActor
final class SidebarNode: NSObject {
    let title: String
    let url: URL?
    /// Temanın vurgu renginde çizilen SF Symbol adı (MacRAR'ın kenar çubuğu gibi).
    let symbol: String?
    var children: [SidebarNode]
    /// Kayıtlı sunucu satırı (tıklayınca bağlanır).
    var server: ServerBookmark?
    /// "Sunucuya Bağlan…" satırı.
    var isConnectAction = false
    /// Bağlı ağ diski ya da çıkarılabilir disk (sağ tık ▸ Çıkar).
    var isEjectable = false

    init(title: String, url: URL? = nil, symbol: String? = nil, children: [SidebarNode] = []) {
        self.title = title
        self.url = url
        self.symbol = symbol
        self.children = children
    }

    var isSection: Bool { url == nil && server == nil && !isConnectAction }
}

/// Sol bölme: üstte uygulama başlığı (simge, ad, sürüm, temanın renklerinde şerit), altında Hızlı erişim
/// (kullanıcı klasörleri) ve Bu Mac (diskler, harici sürücüler). Simgeler temanın vurgu rengindedir.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onNavigate: ((URL) -> Void)?
    var onConnect: ((ServerBookmark) -> Void)?
    var onShowConnect: (() -> Void)?
    var onEditServer: ((ServerBookmark) -> Void)?
    var onDeleteServer: ((ServerBookmark) -> Void)?
    var onEject: ((URL) -> Void)?

    private let outline = SidebarOutlineView()
    private let header = SidebarHeaderView()
    private let scroll = NSScrollView()
    private var sections: [SidebarNode] = []
    private var suppressSelection = false
    private var highlighted: URL?

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        // Düz stil: seçimi tema çizer (source list stilinde sistem kendi rengini dayatır, açık zeminde yazı kayboluyordu).
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .custom
        outline.rowHeight = 30
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.menuProvider = { [weak self] row in self?.contextMenu(row: row) }

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        // Temanın kenar çubuğu tonu (Sistem temasında saydam: macOS'un kenar çubuğu zemini görünür)
        let root = BackgroundView { Theme.current.sidebarTint ?? .clear }
        for v in [header, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild()
        NotificationCenter.default.addObserver(forName: ServerStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
    }

    func rebuild() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let places: [(String, URL, String)] = [
            (String(localized: "Ana Klasör", bundle: .live), home, "house"),
            (String(localized: "Masaüstü", bundle: .live), home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            (String(localized: "Belgeler", bundle: .live), home.appendingPathComponent("Documents"), "doc"),
            (String(localized: "İndirilenler", bundle: .live), home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            (String(localized: "Resimler", bundle: .live), home.appendingPathComponent("Pictures"), "photo"),
            (String(localized: "Müzik", bundle: .live), home.appendingPathComponent("Music"), "music.note"),
            (String(localized: "Filmler", bundle: .live), home.appendingPathComponent("Movies"), "film"),
            (String(localized: "Uygulamalar", bundle: .live), URL(fileURLWithPath: "/Applications"), "square.grid.2x2"),
        ]
        let quick = places
            .filter { fm.fileExists(atPath: $0.1.path) }
            .map { SidebarNode(title: $0.0, url: $0.1, symbol: $0.2) }

        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsEjectableKey]
        let volumeURLs = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes = volumeURLs.map { url -> SidebarNode in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let name = v?.volumeLocalizedName ?? url.lastPathComponent
            let symbol = v?.volumeIsLocal == false ? "server.rack"
                : (v?.volumeIsInternal == false || v?.volumeIsEjectable == true) ? "externaldrive" : "internaldrive"
            let node = SidebarNode(title: name, url: url, symbol: symbol)
            node.isEjectable = url.path != "/"
            return node
        }

        // Kayıtlı sunucular ve en altta "Sunucuya Bağlan…"
        var servers = ServerStore.servers.map { server -> SidebarNode in
            let node = SidebarNode(title: server.displayName, symbol: server.kind.symbol)
            node.server = server
            return node
        }
        let connect = SidebarNode(title: String(localized: "Yeni bağlantı…", bundle: .live), symbol: "plus.circle")
        connect.isConnectAction = true
        servers.append(connect)

        sections = [
            SidebarNode(title: String(localized: "Hızlı erişim", bundle: .live), children: quick),
            SidebarNode(title: String(localized: "Bu Mac", bundle: .live), children: volumes),
            SidebarNode(title: String(localized: "Sunucular", bundle: .live), children: servers),
        ]
        outline.reloadData()
        sections.forEach { outline.expandItem($0) }
        if let highlighted { highlight(highlighted) }
    }

    /// Etkin sekmenin klasörü kenar çubuğunda varsa onu seçili gösterir.
    func highlight(_ url: URL) {
        highlighted = url
        let path = url.standardizedFileURL.path
        let serverKey = url.isRemote ? RemoteURL.serverKey(url) : nil
        suppressSelection = true
        defer { suppressSelection = false }
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? SidebarNode else { continue }
            // Sunucu sekmesinde kayıtlı sunucusu seçili görünür.
            let matches = serverKey != nil
                ? node.server.flatMap { $0.kind.isRemote ? $0.remoteURL(path: "/") : nil }.map(RemoteURL.serverKey) == serverKey
                : node.url?.standardizedFileURL.path == path
            if matches {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outline.deselectAll(nil)
    }

    /// Tema değişti: zemin tonu, simgelerin ve başlık şeridinin vurgu rengi yenilenir.
    func applyTheme() {
        guard isViewLoaded else { return }
        rebuild()
        view.redrawSubtree()
    }

    // MARK: Veri kaynağı

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? sections.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.isSection ?? false
    }

    // MARK: Görünüm

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ThemedRowView() }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSection ?? false
    }

    /// Yalnızca yerler (klasör, disk) seçilir; sunucu ve "Yeni bağlantı…" satırları yalnızca tıklamaya tepki verir
    /// (seçilebilselerdi seçim ve tıklama aynı komutu iki kez çalıştırırdı).
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.url != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let id = NSUserInterfaceItemIdentifier(node.isSection ? "HeaderCell" : "DataCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id, withIcon: !node.isSection)
        cell.textField?.stringValue = node.title
        if let symbol = node.symbol {
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: node.title)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            cell.imageView?.contentTintColor = Theme.current.accentColor
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, withIcon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        if withIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            cell.addSubview(image)
            cell.imageView = image
            text.font = .systemFont(ofSize: 14)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 22),
                image.heightAnchor.constraint(equalToConstant: 20),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            ])
        } else {
            text.font = .systemFont(ofSize: 12, weight: .semibold)
            text.textColor = .secondaryLabelColor
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Seçim

    /// Klavyeyle seçim de klasöre gider (yalnızca yerler seçilebilir).
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, outline.selectedRow >= 0,
              let url = (outline.item(atRow: outline.selectedRow) as? SidebarNode)?.url else { return }
        onNavigate?(url)
    }

    /// Zaten seçili öğeye yeniden tıklama da (başka klasöre gidildiyse) o klasöre döndürür.
    @objc private func clicked() { navigate(row: outline.clickedRow) }

    private func navigate(row: Int) {
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return }
        if let url = node.url {
            onNavigate?(url)
        } else if let server = node.server {
            onConnect?(server)
        } else if node.isConnectAction {
            onShowConnect?()
        }
    }

    /// Bkz. DebugSnapshot: "Yeni bağlantı…" satırının pencere koordinatlarındaki ortası.
    func debugConnectRowPoint() -> NSPoint? {
        for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? SidebarNode)?.isConnectAction == true {
            let rect = outline.rect(ofRow: row)
            return outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        }
        return nil
    }

    // MARK: Sağ tık

    private func contextMenu(row: Int) -> NSMenu? {
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return nil }
        let menu = NSMenu()
        defer { MenuSymbol.showAll(in: menu) }
        if let server = node.server {
            menu.addItem(ClosureMenuItem(title: String(localized: "Bağlan", bundle: .live), symbol: "network") { [weak self] in self?.onConnect?(server) })
            menu.addItem(ClosureMenuItem(title: String(localized: "Düzenle…", bundle: .live), symbol: "pencil") { [weak self] in self?.onEditServer?(server) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: String(localized: "Bağlantıyı Sil…", bundle: .live), symbol: "trash") { [weak self] in self?.onDeleteServer?(server) })
        } else if node.isConnectAction {
            menu.addItem(ClosureMenuItem(title: String(localized: "Sunucuya Bağlan…", bundle: .live), symbol: "plus.circle") { [weak self] in self?.onShowConnect?() })
        } else if let url = node.url {
            menu.addItem(ClosureMenuItem(title: String(localized: "Aç", bundle: .live), symbol: "folder") { [weak self] in self?.onNavigate?(url) })
            if node.isEjectable {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: String(localized: "Çıkar", bundle: .live), symbol: "eject") { [weak self] in self?.onEject?(url) })
            }
        } else {
            return nil
        }
        return menu
    }
}

/// Kenar çubuğunun üstü: uygulama simgesi, ad, sürüm ve temanın vurgu renginin üç tonunda ince şerit
/// (MacRAR'ın kenar çubuğundaki gibi).
@MainActor
final class SidebarHeaderView: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "MacExplorer")
    private let version = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 17, weight: .bold)
        name.lineBreakMode = .byTruncatingTail
        version.font = .systemFont(ofSize: 12, weight: .medium)
        version.textColor = .secondaryLabelColor
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        version.stringValue = short.map { "v\($0)" } ?? ""
        for v in [icon, name, version] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            name.topAnchor.constraint(equalTo: icon.topAnchor, constant: 1),
            version.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            version.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            heightAnchor.constraint(equalToConstant: 54),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    override func draw(_ dirtyRect: NSRect) {
        // Alt kenarda üç parçalı şerit: vurgu rengi, açık ve koyu tonu.
        let accent = Theme.current.accentColor.usingColorSpace(.sRGB) ?? Theme.current.accentColor
        let colors = [accent, accent.blended(withFraction: 0.45, of: .white) ?? accent, accent.blended(withFraction: 0.35, of: .black) ?? accent]
        let width = bounds.width / CGFloat(colors.count)
        for (i, color) in colors.enumerated() {
            color.setFill()
            NSRect(x: CGFloat(i) * width, y: 0, width: width + 0.5, height: 3).fill()
        }
    }
}

/// Kenar çubuğunun tablosu: sağ tıklanan satır için menü.
@MainActor
final class SidebarOutlineView: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }
}
