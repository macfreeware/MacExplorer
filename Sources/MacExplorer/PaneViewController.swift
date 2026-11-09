import AppKit
import FTPKit
import Quartz
import MacExplorerCore

@MainActor
protocol PaneViewControllerDelegate: AnyObject {
    func paneDidBecomeActive(_ pane: PaneViewController)
    func paneDidChangeLocation(_ pane: PaneViewController)
    /// Panelin son sekmesi kapatılmak istendi.
    func paneWantsCloseLastTab(_ pane: PaneViewController)
    /// Çift paneldeki diğer panel (tek panelde nil).
    func otherPane(of pane: PaneViewController) -> PaneViewController?
}

/// Tek bir dosya paneli: sekme çubuğu, gezinme çubuğu (Geri / İleri / Yukarı / Yenile, adres, Ara),
/// Ayrıntılar listesi ve durum çubuğu. Çift panel modunda iki tane yan yana durur.
@MainActor
final class PaneViewController: NSViewController {
    weak var delegate: PaneViewControllerDelegate?

    private(set) var tabs: [TabState]
    private(set) var selectedTab = 0
    var tab: TabState { tabs[selectedTab] }

    let table = FileTableView()
    /// Simge görünümleri ve Liste (Ayrıntılar'da tablo kullanılır).
    let iconView = FileIconView()
    private let scrollView = NSScrollView()
    private let tabBar = TabBarView()
    private let addressBar = AddressBar()
    private let searchField = NSSearchField()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let refreshButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    /// Durum çubuğunun sağındaki görünüm düğmeleri (Windows Gezgini'nin sağ alt köşesi gibi).
    private let viewButtons = NSSegmentedControl()
    private let bottomSeparator = NSBox()
    private var statusBarHeight: NSLayoutConstraint?
    private let placeholder = NSTextField(wrappingLabelWithString: "")

    private var items: [FileItem] = []
    /// Alt klasörlerde aramanın sonuçları ve durumu (bkz. restartSearch).
    private var searchResults: [FileItem]?
    private var search: RecursiveSearch?
    private var searchDelay: DispatchWorkItem?
    private var searchTruncated = false
    private var searchRoot: URL?
    private(set) var shown: [FileItem] = []
    private var errorMessage: String?
    private var watcher: DirectoryWatcher?
    private var watchedPath: String?
    private var loadGeneration = 0
    private var applyingSort = false
    private var lastShowHidden = Preferences.showHidden
    /// Satır içinde yeniden adlandırılan öğe (bu sürede liste yenilenmez).
    private var renamingURL: URL?
    private var renameOriginal = ""
    private var renameCancelled = false
    private var reloadWhileRenaming = false
    /// Liste yüklenince yeniden adlandırması başlatılacak öğe (Yeni klasör).
    private var pendingRenamePath: String?
    nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?

    /// Çift panelde etkin panel (seçili sekmede vurgu çizgisi).
    var isActive = false {
        didSet { applyActiveState() }
    }

    /// Çift paneldeyken etkin panel sekmesinin vurgu çizgisiyle gösterilir, diğeri hafifçe soluklaşır.
    var isInDualPane = false {
        didSet { applyActiveState() }
    }

    private func applyActiveState() {
        tabBar.isActive = isActive
        guard isViewLoaded else { return }
        let dim = isInDualPane && !isActive && Preferences.dimInactivePane
        for (v, dimmed) in [(scrollView, 0.62), (statusLabel, 0.62), (viewButtons, 0.62), (addressBar.superview ?? addressBar, 0.75), (tabBar, 0.75)] as [(NSView, CGFloat)] {
            v.alphaValue = dim ? dimmed : 1
        }
    }

    init(url: URL) {
        tabs = [TabState(url: url)]
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    // MARK: Görünüm

    override func loadView() {
        let root = BackgroundView { Theme.current.chromeColor }

        configure(backButton, symbol: "chevron.left", tip: String(localized: "Geri", bundle: .live), action: #selector(backClicked))
        configure(forwardButton, symbol: "chevron.right", tip: String(localized: "İleri", bundle: .live), action: #selector(forwardClicked))
        configure(upButton, symbol: "arrow.up", tip: String(localized: "Üst klasör", bundle: .live), action: #selector(upClicked))
        configure(refreshButton, symbol: "arrow.clockwise", tip: String(localized: "Yenile", bundle: .live), action: #selector(refreshClicked))

        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.searchMenuTemplate = searchMenu()
        searchField.controlSize = .regular
        searchField.font = .systemFont(ofSize: 12)

        let nav = NSStackView(views: [backButton, forwardButton, upButton, refreshButton, addressBar, searchField])
        nav.orientation = .horizontal
        nav.spacing = 2
        nav.setCustomSpacing(8, after: refreshButton)
        nav.setCustomSpacing(8, after: addressBar)
        nav.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        addressBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureTable()
        configureIconView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.isHidden = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        bottomSeparator.boxType = .separator

        viewButtons.segmentCount = ViewMode.allCases.count
        viewButtons.trackingMode = .selectOne
        viewButtons.controlSize = .small
        viewButtons.segmentStyle = .separated
        for (i, mode) in ViewMode.allCases.enumerated() {
            viewButtons.setImage(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular)), forSegment: i)
            viewButtons.setToolTip(mode.title, forSegment: i)
            viewButtons.setWidth(24, forSegment: i)
        }
        viewButtons.target = self
        viewButtons.action = #selector(viewButtonClicked)

        let statusHeight = bottomSeparator.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        statusBarHeight = statusHeight

        for v in [tabBar, nav, topSeparator, scrollView, placeholder, bottomSeparator, statusLabel, viewButtons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 34),

            nav.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            nav.heightAnchor.constraint(equalToConstant: 38),
            // Ara kutusu dar panellerde (çift panel) küçülür, adres çubuğuna yer kalsın.
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            {
                let preferred = searchField.widthAnchor.constraint(equalToConstant: 180)
                preferred.priority = .defaultLow
                return preferred
            }(),
            addressBar.widthAnchor.constraint(greaterThanOrEqualTo: searchField.widthAnchor, multiplier: 1.6),

            topSeparator.topAnchor.constraint(equalTo: nav.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            placeholder.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 60),
            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),

            bottomSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusHeight,

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: viewButtons.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            viewButtons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            viewButtons.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.onSelect = { [weak self] in self?.selectTab($0) }
        tabBar.onClose = { [weak self] in self?.closeTab(at: $0) }
        tabBar.onNew = { [weak self] in self?.newTab() }
        tabBar.onBeginDrag = { [weak self] index in self?.beginTabDrag(index) ?? false }
        tabBar.onDropTab = { [weak self] index in self?.acceptDroppedTab(at: index) }
        tabBar.onDragOut = { [weak self] point in self?.moveDraggedTabToNewWindow(at: point) }
        tabBar.menuProvider = { [weak self] index in self?.tabMenu(for: index) }
        addressBar.onSelectURL = { [weak self] in self?.navigate(to: $0) }
        addressBar.onSubmit = { [weak self] in self?.goToTyped($0) }
        addressBar.onFinishEditing = { [weak self] in self?.focusTable() }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        // Kaydırma çubuğu belirip kaybolunca görünür genişlik değişir.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewResized), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipboardChanged), name: FileClipboard.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(remoteChanged(_:)), name: RemoteSessions.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeUnmounted(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        applyInterfaceOptions()
        applyActiveState()
        showCurrentTab()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitNameColumn()
    }

    @objc private func clipViewResized() { fitNameColumn() }

    /// "Ad" sütunu: kullanıcı genişlik verdiyse o, vermediyse kalan alan (en çok `defaultNameWidth`); panel daralınca
    /// diğer sütunlar görünür kalsın diye önce o daralır. Geniş pencerede sağda boşluk kalır (Windows Gezgini gibi).
    private func fitNameColumn() {
        guard let name = table.tableColumn(withIdentifier: .init(SortColumn.name.rawValue)) else { return }
        let others = table.tableColumns.filter { $0 !== name && !$0.isHidden }.reduce(0) { $0 + $1.width }
        let spacing = table.intercellSpacing.width * CGFloat(table.tableColumns.count)
        let available = max(120, scrollView.contentView.bounds.width - others - spacing - 16)   // 16: dikey kaydırma çubuğu payı
        let preferred = Preferences.columnWidths[SortColumn.name.rawValue].map { CGFloat($0) } ?? Preferences.defaultNameWidth
        let width = min(available, max(name.minWidth, preferred))
        guard abs(name.width - width) > 0.5 else { return }
        fittingColumns = true
        name.width = width
        fittingColumns = false
    }

    /// Kayıtlı sütun genişlikleri (Ad dışındakiler) uygulanır.
    private func applySavedColumnWidths() {
        let saved = Preferences.columnWidths
        fittingColumns = true
        for column in table.tableColumns where column.identifier.rawValue != SortColumn.name.rawValue {
            if let width = saved[column.identifier.rawValue], abs(column.width - CGFloat(width)) > 0.5 { column.width = CGFloat(width) }
        }
        fittingColumns = false
        fitNameColumn()
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.toolTip = tip
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func configureTable() {
        let columns: [(SortColumn, String, CGFloat)] = [
            (.name, String(localized: "Ad", bundle: .live), 300),
            (.modified, String(localized: "Değiştirme tarihi", bundle: .live), 125),
            (.kind, String(localized: "Tür", bundle: .live), 120),
            (.size, String(localized: "Boyut", bundle: .live), 80),
        ]
        for (column, title, width) in columns {
            let c = NSTableColumn(identifier: .init(column.rawValue))
            c.title = title
            c.width = width
            c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            if column == .size { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        // Alt klasörlerde aramada sonucun bulunduğu klasör (yalnızca arama sürerken görünür).
        let location = NSTableColumn(identifier: Self.locationColumn)
        location.title = String(localized: "Klasör", bundle: .live)
        location.width = 220
        location.minWidth = 60
        location.isHidden = true
        table.addTableColumn(location)
        table.style = .fullWidth
        table.backgroundColor = Theme.current.contentColor
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        // "Ad" sütunu kalan genişliği doldurur (bkz. fitNameColumn); diğer sütunlar kullanıcının verdiği genişlikte kalır.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        applySavedColumnWidths()
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([.fileURL, FileClipboard.remoteType])
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        table.menuProvider = { [weak self] row in self?.contextMenu(row: row) }
        table.onBecomeFirstResponder = { [weak self] in
            guard let self else { return }
            self.delegate?.paneDidBecomeActive(self)
        }
    }

    /// Tema değişti: zemin ve seçim renkleri yeniden çizilir.
    func applyTheme() {
        table.backgroundColor = Theme.current.contentColor
        iconView.backgroundColors = [Theme.current.contentColor]
        iconView.visibleItems().forEach { $0.view.needsDisplay = true }
        table.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        view.redrawSubtree()
    }

    // MARK: Görünümler

    private func configureIconView() {
        iconView.collectionViewLayout = NSCollectionViewFlowLayout()
        iconView.isSelectable = true
        iconView.allowsMultipleSelection = true
        iconView.allowsEmptySelection = true
        iconView.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.identifier)
        iconView.dataSource = self
        iconView.delegate = self
        iconView.backgroundColors = [Theme.current.contentColor]
        iconView.registerForDraggedTypes([.fileURL, FileClipboard.remoteType])
        iconView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        iconView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        iconView.onBecomeFirstResponder = { [weak self] in
            guard let self else { return }
            self.delegate?.paneDidBecomeActive(self)
        }
        iconView.onDoubleClick = { [weak self] index in
            guard let self, index < self.shown.count else { return }
            self.open([self.shown[index]])
        }
        iconView.menuProvider = { [weak self] index in self?.contextMenu(row: index) }
        iconView.nameProvider = { [weak self] index in
            guard let self, index < self.shown.count else { return nil }
            return self.shown[index].displayName
        }
        iconView.onTypeSelect = { [weak self] index in self?.setSelection(IndexSet(integer: index)) }
        iconView.validateDrop = { [weak self] info, index in
            guard let self else { return [] }
            return self.dropOperation(info, target: self.iconDropTarget(index))
        }
        iconView.acceptDrop = { [weak self] info, index in
            guard let self else { return false }
            return self.performDrop(info, target: self.iconDropTarget(index))
        }
    }

    /// Boş alan: bu klasör; klasör öğesi: o klasör; dosya: bırakılamaz (görünüm klasörün kendisine düşer).
    private func iconDropTarget(_ index: Int?) -> URL? {
        guard let index else { return tab.url }
        return index < shown.count && shown[index].isDirectory ? shown[index].url : nil
    }

    var viewMode: ViewMode { tab.viewMode }

    /// Görünüm menüsü / araç çubuğu / Ctrl+Shift+1…6: seçim ve odak korunarak görünüm değişir.
    func setViewMode(_ mode: ViewMode) {
        guard mode != tab.viewMode else { return }
        let selection = selectedURLs
        let hadFocus = isListFocused(view.window?.firstResponder)
        tab.viewMode = mode
        ViewMode.saved = mode
        applyViewMode()
        reloadList()
        let paths = Set(selection.map { $0.standardizedFileURL.path })
        setSelection(IndexSet(shown.indices.filter { paths.contains(shown[$0].url.standardizedFileURL.path) }))
        if hadFocus { focusTable() }
        delegate?.paneDidChangeLocation(self)
    }

    private func applyViewMode() {
        let mode = tab.viewMode
        viewButtons.selectedSegment = ViewMode.allCases.firstIndex(of: mode) ?? 0
        if mode == .details {
            if scrollView.documentView !== table { scrollView.documentView = table }
        } else {
            let layout = iconView.collectionViewLayout as? NSCollectionViewFlowLayout ?? NSCollectionViewFlowLayout()
            layout.itemSize = mode.itemSize
            layout.scrollDirection = mode == .list ? .horizontal : .vertical
            layout.minimumInteritemSpacing = mode.isRowLayout ? 0 : 8
            layout.minimumLineSpacing = mode == .list ? 16 : (mode.isRowLayout ? 0 : 8)
            layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            iconView.collectionViewLayout = layout
            if scrollView.documentView !== iconView {
                iconView.frame = scrollView.contentView.bounds
                iconView.autoresizingMask = [.width]
                scrollView.documentView = iconView
            }
            layout.invalidateLayout()
        }
        scrollView.hasHorizontalScroller = mode == .details || mode == .list
    }

    /// Görünen liste: Ayrıntılar'da tablo, diğerlerinde ızgara.
    var listView: NSView { tab.viewMode == .details ? table : iconView }

    func isListFocused(_ responder: NSResponder?) -> Bool { responder === table || responder === iconView }

    var selectionIndexes: IndexSet {
        tab.viewMode == .details ? table.selectedRowIndexes : IndexSet(iconView.selectionIndexPaths.map(\.item))
    }

    private func reloadList() {
        if tab.viewMode == .details { table.reloadData() } else { iconView.reloadData() }
        if markCursor != nil { showMarkCursor(scroll: false) }   // liste yenilendi: imleç yerinde kalsın
    }

    // MARK: Desene göre seçim (mc'deki + / − / *)

    private static var lastPattern = "*"

    /// Desene göre seçim ve tersine çevirmede sayılan öğeler: dosyalar (uygulamalar ve paketler dahil), ayar açıksa klasörler de.
    /// Gizli öğeler yalnızca gösteriliyorsa listededir (`shown`).
    private func countsForSelection(_ item: FileItem) -> Bool {
        !item.isDirectory || item.isPackage || Preferences.selectIncludesFolders
    }

    /// Num + (Seç…) / Num − (Seçimi kaldır…): "*.pdf; rapor*" gibi desene uyan öğeler seçime eklenir ya da çıkarılır.
    func selectByPattern(adding: Bool) {
        guard !shown.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = adding ? String(localized: "Seç", bundle: .live) : String(localized: "Seçimi kaldır", bundle: .live)
        var info = String(localized: "Desen: * herhangi bir ad, ? tek karakter. Birden çok desen ; ile ayrılır (ör. *.jpg; *.png).", bundle: .live)
        if !Preferences.selectIncludesFolders {
            info += "\n" + String(localized: "Klasörler dahil değil (Ayarlar ▸ Genel).", bundle: .live)
        }
        alert.informativeText = info
        let field = NSTextField(string: Self.lastPattern)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Tamam", bundle: .live))
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        alert.window.initialFirstResponder = field
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            Self.lastPattern = field.stringValue
            var rows = self.selectionIndexes
            for (i, item) in self.shown.enumerated() where self.countsForSelection(item)
                && NameFilter.matchesPattern(item.displayName, pattern: field.stringValue) {
                if adding { rows.insert(i) } else { rows.remove(i) }
            }
            self.applyKeyboardSelection(rows)
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: apply) } else { apply(alert.runModal()) }
    }

    /// Num * : seçimi tersine çevirir (Windows'taki "Seçimi tersine çevir"). Ayar kapalıyken yalnızca dosyalar: seçili
    /// klasörlerin seçimi de kalkar.
    func invertSelection() {
        guard !shown.isEmpty else { return }
        let current = selectionIndexes
        let rows = IndexSet(shown.indices.filter { countsForSelection(shown[$0]) && !current.contains($0) })
        applyKeyboardSelection(rows)
    }

    /// Klavyeyle yapılan seçim: işaretleme sürüyorsa bozulmaz.
    private func applyKeyboardSelection(_ rows: IndexSet) {
        settingMarks = true
        setSelection(rows, scroll: false)
        settingMarks = false
        updateStatus()
        focusTable()
    }

    // MARK: Klavyeyle işaretleme (mc / Total Commander gibi)

    /// İşaretleme imleci: seçimden ayrı, satırın çevresinde ince çerçeve. nil: işaretleme yok (oklar her zamanki gibi seçer).
    private var markCursor: Int?
    /// Seçim kodla değiştiriliyor (işaretleme sürer).
    private var settingMarks = false
    private let cursorOutline = CursorOutlineView()

    var isMarking: Bool { markCursor != nil }

    /// Boşluk / Insert: imleçteki öğenin işaretini değiştirir; `advance` ise imleç bir alta geçer.
    /// İlk basışta tek seçili öğe imleç sayılır (oklarla gelinen yer); fareyle yapılmış çoklu seçim korunur.
    func toggleMark(advance: Bool) {
        guard !shown.isEmpty else { return }
        var rows = selectionIndexes
        let cursor: Int
        if let markCursor {
            cursor = min(markCursor, shown.count - 1)
        } else {
            cursor = leadRow ?? 0
            if rows.count <= 1 { rows = [] }
        }
        if rows.contains(cursor) { rows.remove(cursor) } else { rows.insert(cursor) }
        settingMarks = true
        setSelection(rows, scroll: false)
        settingMarks = false
        markCursor = advance ? min(cursor + 1, shown.count - 1) : cursor
        showMarkCursor(scroll: true)
        updateStatus()
    }

    /// İşaretleme sürerken oklar yalnızca imleci gezdirir.
    func moveMarkCursor(_ key: UInt16) {
        guard let cursor = markCursor, !shown.isEmpty else { return }
        let step: Int
        switch key {
        case KeyCode.upArrow: step = -verticalStep
        case KeyCode.downArrow: step = verticalStep
        case KeyCode.leftArrow: step = tab.viewMode == .details ? 0 : -1
        case KeyCode.rightArrow: step = tab.viewMode == .details ? 0 : 1
        default: step = jump(key, from: cursor) - cursor
        }
        markCursor = max(0, min(shown.count - 1, cursor + step))
        showMarkCursor(scroll: true)
    }

    /// Home, End, Page Up, Page Down ile varılan satır.
    private func jump(_ key: UInt16, from row: Int) -> Int {
        let last = shown.count - 1
        switch key {
        case KeyCode.home: return 0
        case KeyCode.end: return last
        case KeyCode.pageUp: return max(0, row - pageStep)
        case KeyCode.pageDown: return min(last, row + pageStep)
        default: return row
        }
    }

    /// Bir sayfada kaç öğe atlanır: görünen satırlar, bağlam kalsın diye biri eksik.
    private var pageStep: Int {
        if tab.viewMode == .details {
            let rowHeight = table.rowHeight + table.intercellSpacing.height
            return max(1, Int(table.visibleRect.height / rowHeight) - 1)
        }
        let step = verticalStep
        guard shown.count > step,
              let first = iconView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
              let below = iconView.layoutAttributesForItem(at: IndexPath(item: step, section: 0))?.frame,
              below.minY > first.minY else { return step }
        return max(1, Int(iconView.visibleRect.height / (below.minY - first.minY)) - 1) * step
    }

    /// Shift ile genişletilen aralık. Seçim başka yoldan değişince geçersiz sayılır.
    private var extendedRange: (anchor: Int, cursor: Int)?

    /// Home, End, Page Up, Page Down: seçim o satıra geçer; `extending` (Shift) ise başlangıç satırından oraya kadar seçilir.
    func moveSelection(_ key: UInt16, extending: Bool) {
        guard !shown.isEmpty else { return }
        let rows = selectionIndexes
        let lead = min(leadRow ?? 0, shown.count - 1)
        var anchor = lead, cursor = lead
        if let range = extendedRange,
           rows == IndexSet(integersIn: min(range.anchor, range.cursor)...max(range.anchor, range.cursor)) {
            (anchor, cursor) = range
        } else if extending, let first = rows.first, let last = rows.last, rows.count == last - first + 1 {
            // Shift+oklarla başlamış aralık: bağlantı noktası son satırın karşı ucu.
            anchor = lead == first ? last : first
        }
        let target = jump(key, from: cursor)
        extendedRange = extending ? (anchor, target) : nil
        setSelection(extending ? IndexSet(integersIn: min(anchor, target)...max(anchor, target)) : [target], scroll: false)
        scrollToRow(target)
    }

    private func scrollToRow(_ row: Int) {
        if tab.viewMode == .details {
            table.scrollRowToVisible(row)
        } else {
            iconView.scrollToItems(at: [IndexPath(item: row, section: 0)],
                                   scrollPosition: tab.viewMode == .list ? .nearestVerticalEdge : .nearestHorizontalEdge)
        }
    }

    /// Esc: işaretler kaldırılır.
    func clearMarks() {
        settingMarks = true
        setSelection([], scroll: false)
        settingMarks = false
        endMarking()
        updateStatus()
    }

    func endMarking() {
        guard markCursor != nil else { return }
        markCursor = nil
        cursorOutline.removeFromSuperview()
    }

    /// Klavye odağının olduğu satır: tabloda son seçilen, ızgarada ilk seçili öğe.
    private var leadRow: Int? {
        if tab.viewMode == .details { return table.selectedRow >= 0 ? table.selectedRow : nil }
        return iconView.selectionIndexPaths.map(\.item).min()
    }

    /// ↑/↓ kaç öğe atlar: tabloda 1, simge ızgarasında bir satırdaki öğe sayısı.
    private var verticalStep: Int {
        guard tab.viewMode != .details, shown.count > 1,
              let first = iconView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame else { return 1 }
        var columns = 1
        while columns < shown.count,
              let frame = iconView.layoutAttributesForItem(at: IndexPath(item: columns, section: 0))?.frame,
              abs(frame.minY - first.minY) < 1 { columns += 1 }
        return columns
    }

    private func showMarkCursor(scroll: Bool) {
        guard let cursor = markCursor, cursor < shown.count else { return endMarking() }
        let host: NSView = tab.viewMode == .details ? table : iconView
        let frame: NSRect
        if tab.viewMode == .details {
            frame = table.rect(ofRow: cursor).insetBy(dx: 2, dy: 0.5)
            if scroll { table.scrollRowToVisible(cursor) }
        } else {
            let path = IndexPath(item: cursor, section: 0)
            frame = iconView.layoutAttributesForItem(at: path)?.frame ?? .zero
            if scroll { iconView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge) }
        }
        cursorOutline.frame = frame
        // Satır görünümleri sonradan eklense de çerçeve üstte kalsın.
        host.addSubview(cursorOutline, positioned: .above, relativeTo: nil)
    }

    private func setSelection(_ rows: IndexSet, scroll: Bool = true) {
        if tab.viewMode == .details {
            table.selectRowIndexes(rows, byExtendingSelection: false)
            if scroll { table.scrollRowToVisible(rows.first ?? 0) }
        } else {
            iconView.selectionIndexPaths = Set(rows.filter { $0 < shown.count }.map { IndexPath(item: $0, section: 0) })
            if scroll, !shown.isEmpty {
                iconView.scrollToItems(at: [IndexPath(item: rows.first ?? 0, section: 0)],
                                       scrollPosition: tab.viewMode == .list ? .nearestVerticalEdge : .nearestHorizontalEdge)
            }
            updateStatus()
            refreshQuickLook()
        }
    }

    /// Satırın ad alanı ve onu taşıyan görünüm (yeniden adlandırmak için).
    private func nameField(forRow row: Int) -> (NSView, NSTextField)? {
        if tab.viewMode == .details {
            let column = table.column(withIdentifier: .init(SortColumn.name.rawValue))
            guard column >= 0, let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return nil }
            return (cell, field)
        }
        iconView.layoutSubtreeIfNeeded()
        guard let item = iconView.item(at: IndexPath(item: row, section: 0)), let field = item.textField else { return nil }
        return (item.view, field)
    }

    /// Paylaş menüsü gibi öğenin yanında açılan şeyler için öğenin çerçevesi.
    func frame(forRow row: Int) -> (NSRect, NSView) {
        if tab.viewMode == .details { return (table.rect(ofRow: row), table) }
        return (iconView.frameForItem(at: row), iconView)
    }

    // MARK: Hızlı Bakış

    /// F3: Ayarlardaki seçime göre MacNote++'ta salt okunur açar ya da Hızlı Bakış gösterir.
    /// Uzak dosyalar ve klasörler her zaman Hızlı Bakış'a gider.
    func viewSelection() {
        let items = selectedItems
        if Preferences.f3OpensMacNote, MacNoteInstaller.isInstalled, !isRemote, !items.isEmpty, items.allSatisfy({ !$0.isDirectory }) {
            MacNoteInstaller.view(items.map(\.url))
        } else {
            toggleQuickLook()
        }
    }

    /// Boşluk / ⌘Y: seçili öğelerin önizlemesini açar ya da kapatır.
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if isRemote && !(QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible) { return NSSound.beep() }   // önizleme yerel dosyalarda
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !selectedItems.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    /// Panel bu paneldeyse seçim değişince önizleme de değişir.
    private func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, panel.dataSource === self else { return }
        panel.reloadData()
    }

    // MARK: Gezinme

    func navigate(to url: URL, selecting: [URL] = []) {
        let target = url.normalizedFileURL
        guard target.locationKey != tab.url.locationKey else { return }
        tab.selectedURLs = selectedURLs
        tab.history.visit(target)
        tab.filter = ""
        showCurrentTab(selecting: selecting)
    }

    func goBack() {
        let from = tab.url
        guard tab.history.goBack() != nil else { return }
        tab.filter = ""
        showCurrentTab(selecting: [from])
    }

    func goForward() {
        let from = tab.url
        guard tab.history.goForward() != nil else { return }
        tab.filter = ""
        showCurrentTab(selecting: [from])
    }

    /// Üst klasöre çıkar ve çıkılan klasörü seçili gösterir (Windows gibi).
    func goUp() {
        let from = tab.url
        // Arşivin kökünden: arşivin bulunduğu klasöre, arşiv seçili.
        if isArchive, RemoteURL.path(of: from) == "/" {
            if let file = Archives.file(for: from) { navigate(to: file.deletingLastPathComponent(), selecting: [file]) }
            return
        }
        guard from.path != "/" else { return }
        navigate(to: from.deletingLastPathComponent(), selecting: [from])
    }

    func refresh() {
        IconCache.clear()
        Thumbnails.clear()
        reload()
    }

    var canGoBack: Bool { tab.history.canGoBack }
    var canGoForward: Bool { tab.history.canGoForward }
    var canGoUp: Bool { tab.url.path != "/" || (isArchive && Archives.file(for: tab.url) != nil) }

    /// Adres çubuğuna yazılan yol: klasöre gider, dosyayı açar; yoksa uyarır.
    private func goToTyped(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Sunucu adresi: sftp:// ftp:// panelde açılır; smb:// afp:// … disk olarak bağlanır.
        if trimmed.contains("://"), let url = URL(string: trimmed) ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") {
            if url.isRemote {
                navigate(to: RemoteURL.replacingPath(url, with: RemoteURL.path(of: url)))
            } else if let server = ServerBookmark(address: trimmed) {
                ServerConnector.connect(server, password: nil, over: view.window) { [weak self] in self?.navigate(to: $0) }
            }
            return
        }
        if isRemote {
            let current = RemoteURL.path(of: tab.url)
            navigate(to: RemoteURL.replacingPath(tab.url, with: trimmed.hasPrefix("/") ? trimmed : RemotePath.join(current, trimmed)))
            return
        }
        let path = (trimmed as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : tab.url.appendingPathComponent(path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path) {
                navigate(to: url)
            } else {
                NSWorkspace.shared.open(url)
            }
        } else if let window = view.window {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "“\(trimmed)” bulunamadı.", bundle: .live)
            alert.informativeText = String(localized: "Adı doğru yazdığınızdan emin olun ve yeniden deneyin.", bundle: .live)
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: Sekmeler

    /// Yeni sekme; klasör verilmezse Windows 11 Gezgini gibi başlangıç yeri (Ana Klasör) açılır.
    func newTab(url: URL? = nil, activate: Bool = true) {
        tab.selectedURLs = selectedURLs
        let newTab = TabState(url: url ?? FileManager.default.homeDirectoryForCurrentUser)
        newTab.viewMode = tab.viewMode
        tabs.insert(newTab, at: selectedTab + 1)
        if activate {
            selectedTab += 1
            showCurrentTab()
        } else {
            tabBar.update(titles: tabs.map(\.title), selected: selectedTab)
        }
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard tabs.count > 1 else {
            delegate?.paneWantsCloseLastTab(self)
            return
        }
        tabs.remove(at: index)
        if index < selectedTab {
            selectedTab -= 1
            tabBar.update(titles: tabs.map(\.title), selected: selectedTab)
        } else if index == selectedTab {
            selectedTab = min(index, tabs.count - 1)
            showCurrentTab()
        } else {
            tabBar.update(titles: tabs.map(\.title), selected: selectedTab)
        }
    }

    func closeCurrentTab() { closeTab(at: selectedTab) }

    func selectTab(_ index: Int) {
        guard index != selectedTab, tabs.indices.contains(index) else { return }
        tab.selectedURLs = selectedURLs
        selectedTab = index
        showCurrentTab()
    }

    // MARK: Sekme taşıma (sürükle-bırak ve sekme menüsü)

    private func beginTabDrag(_ index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        tab.selectedURLs = selectedURLs
        TabDrag.current = (self, tabs[index])
        return true
    }

    /// Sürüklenen sekme bu panelin sekme çubuğuna bırakıldı: aynı paneldeyse sıra değişir,
    /// başka panel ya da penceredense geçmişi, görünümü ve seçimiyle buraya taşınır.
    private func acceptDroppedTab(at index: Int) {
        guard let (source, moved) = TabDrag.current else { return }
        TabDrag.current = nil
        if source === self {
            guard let from = tabs.firstIndex(where: { $0 === moved }) else { return }
            let to = from < index ? index - 1 : index
            guard to != from else { return }
            let selected = tab
            tabs.remove(at: from)
            tabs.insert(moved, at: min(to, tabs.count))
            selectedTab = tabs.firstIndex(where: { $0 === selected }) ?? 0
            tabBar.update(titles: tabs.map(\.title), selected: selectedTab)
            return
        }
        receive(moved, at: index, from: source)
    }

    /// Sekmeyi başka bir panelden alır ve seçili yapar; kaynak panelden çıkarılır.
    func receive(_ moved: TabState, at index: Int, from source: PaneViewController) {
        guard source !== self, !tabs.contains(where: { $0 === moved }) else { return }
        tab.selectedURLs = selectedURLs
        let at = min(max(index, 0), tabs.count)
        tabs.insert(moved, at: at)
        selectedTab = at
        showCurrentTab()
        view.window?.makeKeyAndOrderFront(nil)
        focusTable()
        delegate?.paneDidBecomeActive(self)
        source.removeTab(moved)
    }

    /// Sekmeyi bu panelden çıkarır (başka yere taşındı). Son sekmeyse panel/pencere kapanır.
    func removeTab(_ removed: TabState) {
        guard let index = tabs.firstIndex(where: { $0 === removed }) else { return }
        closeTab(at: index)
    }

    /// Sekme pencerelerin dışına bırakıldı: yeni pencereye taşınır.
    private func moveDraggedTabToNewWindow(at point: NSPoint?) {
        guard let (source, moved) = TabDrag.current, source === self else { return }
        TabDrag.current = nil
        moveTabToNewWindow(moved, at: point)
    }

    func moveTabToNewWindow(_ moved: TabState, at point: NSPoint?) {
        if moved === tab { moved.selectedURLs = selectedURLs }
        (NSApp.delegate as? AppDelegate)?.newWindow(with: moved, at: point)
        removeTab(moved)
    }

    /// Sekmenin kopyası (geçmiş, sıralama, görünüm ve seçimle) yeni pencerede açılır; asıl sekme yerinde kalır.
    /// Sekmeyi pencerenin dışına sürüklemek ise taşır (bkz. `moveTabToNewWindow`).
    func openTabInNewWindow(_ source: TabState) {
        let copy = TabState(url: source.url)
        copy.history = source.history
        copy.sort = source.sort
        copy.viewMode = source.viewMode
        copy.selectedURLs = source === tab ? selectedURLs : source.selectedURLs
        (NSApp.delegate as? AppDelegate)?.newWindow(with: copy, at: nil)
    }

    /// Sekmeye sağ tık (Firefox / Windows Gezgini sekmeleri gibi).
    private func tabMenu(for index: Int) -> NSMenu? {
        guard tabs.indices.contains(index) else { return nil }
        let target = tabs[index]
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add(String(localized: "Yeni sekme", bundle: .live)) { [weak self] in self?.newTab() }
        add(String(localized: "Sekmeyi çoğalt", bundle: .live)) { [weak self] in
            guard let self, let i = self.tabs.firstIndex(where: { $0 === target }) else { return }
            self.selectTab(i)
            self.newTab(url: target.url)
        }
        menu.addItem(.separator())
        add(String(localized: "Sekmeyi yeni pencerede aç", bundle: .live)) { [weak self] in
            self?.openTabInNewWindow(target)
        }
        let other = delegate?.otherPane(of: self)
        add(String(localized: "Sekmeyi diğer panele taşı", bundle: .live), enabled: other != nil) { [weak self] in
            guard let self, let other else { return }
            if target === self.tab { target.selectedURLs = self.selectedURLs }
            other.receive(target, at: other.tabs.count, from: self)
        }
        menu.addItem(.separator())
        // Bu Mac'teki klasörde Terminal, SFTP'de ssh açılır; FTP'de kabuk, arşivin içinde gerçek klasör yoktur.
        let isSFTP = target.url.scheme == "sftp"
        let isLocalFolder = !target.url.isRemote && Archives.file(for: target.url) == nil
        add(isSFTP ? String(localized: "Terminalde aç (SSH)", bundle: .live) : String(localized: "Terminalde aç", bundle: .live),
            enabled: isSFTP || isLocalFolder) { [weak self] in self?.openInTerminal(target.url) }
        menu.addItem(.separator())
        add(String(localized: "Sekmeyi kapat", bundle: .live)) { [weak self] in self?.removeTab(target) }
        add(String(localized: "Diğer sekmeleri kapat", bundle: .live), enabled: tabs.count > 1) { [weak self] in
            guard let self else { return }
            self.tabs = [target]
            self.selectedTab = 0
            self.showCurrentTab()
        }
        return menu
    }

    /// Geliştirme denemesi: etkin sekmenin sağ tık menüsü.
    func debugTabMenu() -> NSMenu? { tabMenu(for: selectedTab) }

    /// Yeni pencere bu sekmelerle açılır.
    func setTabs(_ newTabs: [TabState], selected: Int = 0) {
        guard !newTabs.isEmpty else { return }
        tabs = newTabs
        selectedTab = min(selected, newTabs.count - 1)
        if isViewLoaded { showCurrentTab() }
    }

    func selectNextTab() { selectTab((selectedTab + 1) % tabs.count) }
    func selectPreviousTab() { selectTab((selectedTab - 1 + tabs.count) % tabs.count) }

    /// Tüm sekmeleri tek bir sekmeyle değiştirir (çift panel ilk açılışı).
    func resetTabs(to url: URL, like template: TabState? = nil) {
        let tab = TabState(url: url)
        if let template {
            tab.viewMode = template.viewMode
            tab.sort = template.sort
        }
        tabs = [tab]
        selectedTab = 0
        if isViewLoaded { showCurrentTab() }
    }

    /// Diğer panelin sekmelerini devralır (çift panelden çıkarken sol panelin son sekmesi kapatıldığında).
    func adoptTabs(from other: PaneViewController) {
        other.tab.selectedURLs = other.selectedURLs
        tabs = other.tabs
        selectedTab = other.selectedTab
        showCurrentTab()
    }

    // MARK: Odak

    func focusTable() { view.window?.makeFirstResponder(listView) }

    func focusAddressBar() {
        delegate?.paneDidBecomeActive(self)
        addressBar.beginEditing()
    }

    func focusSearch() {
        delegate?.paneDidBecomeActive(self)
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: Açma

    var selectedItems: [FileItem] {
        selectionIndexes.filter { $0 < shown.count }.map { shown[$0] }
    }

    var selectedURLs: [URL] { selectedItems.map(\.url) }

    /// Enter / ⌘↓ / Aç: tek klasöre girer; birden çok klasör yeni sekmelerde açılır; dosyalar varsayılan uygulamayla açılır.
    func openSelection() {
        open(selectedItems)
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < shown.count else { return }
        open([shown[row]])
    }

    private func open(_ list: [FileItem]) {
        guard !list.isEmpty else { return }
        let inNewTabs = list.count > 1
        if isRemote {
            // Uzak klasörlere girilir; dosyalar geçici klasöre indirilip açılır.
            for folder in list where folder.isDirectory {
                if inNewTabs { newTab(url: folder.url, activate: false) } else { navigate(to: folder.url) }
            }
            let files = list.filter { !$0.isDirectory }.map(\.url)
            if !files.isEmpty { RemoteTransfers.open(files, window: view.window) }
            return
        }
        for item in list {
            var url = item.url
            var isDirectory = item.isDirectory
            if !isDirectory,
               (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true,
               let resolved = try? URL(resolvingAliasFileAt: url) {
                url = resolved
                let v = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                isDirectory = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            }
            if isDirectory {
                if inNewTabs { newTab(url: url, activate: false) } else { navigate(to: url) }
            } else if Archives.opensInPlace(url) {
                browseArchive(url)   // ZIP: Windows'taki gibi klasör gibi açılır
            } else if DiskImage.isDiskImage(url) {
                mountDiskImage(url)   // ISO / DMG: bağlanır ve burada açılır
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Yükleme

    private func showCurrentTab(selecting: [URL]? = nil) {
        searchField.stringValue = tab.filter
        applyingSort = true
        table.sortDescriptors = [NSSortDescriptor(key: tab.sort.column.rawValue, ascending: tab.sort.ascending)]
        applyingSort = false
        applyViewMode()
        locationChanged()
        if !tab.filter.isEmpty { restartSearch() }   // aranmış bir sekmeye dönüldü
        load(selecting: selecting ?? tab.selectedURLs)
    }

    private func locationChanged() {
        endSearch()
        addressBar.endEditing()
        addressBar.url = tab.url
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        upButton.isEnabled = canGoUp
        searchField.placeholderString = String(localized: "Ara: \(tab.title)", bundle: .live)
        tabBar.update(titles: tabs.map(\.title), selected: selectedTab)
        delegate?.paneDidChangeLocation(self)
    }

    private enum LoadOutcome: Sendable {
        case items([FileItem])
        case failure(String)
    }

    private func load(selecting: [URL]?) {
        let url = tab.url
        if url.isRemote { return loadRemote(url, selecting: selecting) }
        if watchedPath != url.path {
            watchedPath = url.path
            watcher = DirectoryWatcher(url: url) { [weak self] in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        loadGeneration += 1
        let generation = loadGeneration
        let showHidden = Preferences.showHidden
        Task.detached(priority: .userInitiated) {
            let outcome: LoadOutcome
            do { outcome = .items(try DirectoryReader.read(url, showHidden: showHidden)) }
            catch { outcome = .failure(error.localizedDescription) }
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.loadedLocation = url.locationKey
                self.apply(outcome, selecting: selecting)
            }
        }
    }

    /// Sunucudaki klasör: oturum yoksa önce bağlanılır (parola gerekirse sorulur).
    private func loadRemote(_ url: URL, selecting: [URL]?) {
        watcher = nil
        watchedPath = nil
        loadGeneration += 1
        let generation = loadGeneration
        let showHidden = Preferences.showHidden
        // Başka klasöre geçildiyse eski liste sunucu yanıt verene kadar ekranda kalmasın.
        if loadedLocation != url.locationKey {
            items = []
            shown = []
            reloadList()
            placeholder.stringValue = RemoteSessions.existing(for: url) == nil
                ? String(localized: "“\(url.host ?? "")” sunucusuna bağlanılıyor…", bundle: .live)
                : String(localized: "Yükleniyor…", bundle: .live)
            placeholder.isHidden = false
            updateStatus()
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome: LoadOutcome
            if let connection = await RemoteSessions.connection(for: url, window: self.view.window) {
                let path = RemoteURL.path(of: url)
                do {
                    let files = try await connection.run { try await $0.list(path).files }
                    outcome = .items(files.filter { showHidden || !$0.name.hasPrefix(".") }.map { FileItem(remote: $0, in: url) })
                } catch {
                    outcome = .failure(error.localizedDescription)
                }
            } else {
                outcome = .failure(String(localized: "Sunucuya bağlanılamadı. Yenile (F5) ile yeniden deneyebilirsiniz.", bundle: .live))
            }
            guard generation == self.loadGeneration else { return }
            self.loadedLocation = url.locationKey
            self.apply(outcome, selecting: selecting)
        }
    }

    /// Listesi ekranda olan klasör (uzak klasöre geçerken eski listeyi temizlemek için).
    private var loadedLocation = ""

    /// Sunucuda bir şey değişti (yükleme, silme, taşıma): aynı sunucuyu gösteren paneller yenilenir.
    @objc private func remoteChanged(_ note: Notification) {
        guard isRemote, let url = note.object as? URL, RemoteURL.serverKey(url) == RemoteURL.serverKey(tab.url) else { return }
        reload()
    }

    var isRemote: Bool { tab.url.isRemote }
    /// Arşivin içi (salt okunur).
    var isArchive: Bool { Archives.isArchive(tab.url) }

    /// Arşivde değişiklik istendi: kısa uyarı (arşivi düzenlemek MacRAR'ın işi).
    func readOnlyArchive() {
        NSSound.beep()
        showError(String(localized: "Arşiv salt okunur. Arşive eklemek ya da arşivden silmek için MacRAR ile açın.", bundle: .live))
    }

    /// Arşivin içine girer (klasör gibi, salt okunur).
    func browseArchive(_ file: URL) {
        if let root = Archives.open(file) { navigate(to: root) }
    }

    /// Bir disk çıkarıldı (disk görüntüsü, USB, ağ diski): o diskte kalan sekmeler ana klasöre döner.
    /// Geri ile eski konum yine görülebilir (disk yeniden bağlanırsa açılır).
    @objc private func volumeUnmounted(_ note: Notification) {
        guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        let root = volume.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
        func onVolume(_ url: URL) -> Bool {
            guard !url.isRemote else { return false }
            let path = url.standardizedFileURL.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        for (index, state) in tabs.enumerated() where onVolume(state.url) {
            if index == selectedTab {
                navigate(to: home)
            } else {
                state.history.visit(home)
                state.selectedURLs = []
            }
        }
        tabBar.update(titles: tabs.map(\.title), selected: selectedTab)
    }

    /// Seçim ya da liste değişti (önizleme bölmesi için).
    static let selectionDidChange = Notification.Name("PaneSelectionDidChange")

    func reload() {
        guard renamingURL == nil else { reloadWhileRenaming = true; return }
        load(selecting: selectedURLs)
    }

    private func apply(_ outcome: LoadOutcome, selecting: [URL]?) {
        switch outcome {
        case .items(let list):
            items = list
            errorMessage = nil
        case .failure(let message):
            items = []
            errorMessage = String(localized: "Bu klasöre erişilemiyor.", bundle: .live) + "\n" + message
        }
        rebuild(selecting: selecting)
    }

    private func rebuild(selecting: [URL]?) {
        var filtered = tab.filter.isEmpty ? items : items.filter { NameFilter.matches($0.displayName, query: tab.filter) }
        if let results = searchResults, !tab.filter.isEmpty {
            // Bu klasördeki eşleşmeler hemen, alt klasörlerdekiler bulundukça.
            let here = Set(filtered.map(\.url.standardizedFileURL.path))
            filtered += results.filter { !here.contains($0.url.standardizedFileURL.path) }
        }
        shown = tab.sort.sorted(filtered)
        reloadList()

        if let errorMessage {
            placeholder.stringValue = errorMessage
        } else if shown.isEmpty, search != nil {
            placeholder.stringValue = String(localized: "Aranıyor…", bundle: .live)
        } else if shown.isEmpty {
            placeholder.stringValue = tab.filter.isEmpty
                ? String(localized: "Bu klasör boş.", bundle: .live)
                : String(localized: "Arama ölçütlerinizle eşleşen öğe yok.", bundle: .live)
        }
        placeholder.isHidden = errorMessage == nil && !shown.isEmpty

        if let selecting {
            let paths = Set(selecting.map { $0.standardizedFileURL.path })
            let rows = IndexSet(shown.indices.filter { paths.contains(shown[$0].url.standardizedFileURL.path) })
            setSelection(rows)
        }
        updateStatus()
        if let path = pendingRenamePath, let row = shown.firstIndex(where: { $0.url.standardizedFileURL.path == path }) {
            pendingRenamePath = nil
            beginRename(row: row)
        }
    }

    private func updateStatus() {
        var text = String(localized: "\(shown.count) öğe", bundle: .live)
        if searchResults != nil {
            text = search != nil ? String(localized: "Aranıyor… \(shown.count) sonuç", bundle: .live)
                : searchTruncated ? String(localized: "İlk \(shown.count) sonuç gösteriliyor", bundle: .live)
                : String(localized: "\(shown.count) sonuç", bundle: .live)
        }
        let selection = selectedItems
        if !selection.isEmpty {
            text += "     " + String(localized: "\(selection.count) öğe seçili", bundle: .live)
            let sizes = selection.compactMap(\.size)
            if !sizes.isEmpty {
                text += "  " + ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
            }
        }
        statusLabel.stringValue = text
        NotificationCenter.default.post(name: Self.selectionDidChange, object: self)
        // Araç çubuğundaki Kes / Kopyala / Sil … seçim değişir değişmez etkinleşsin.
        view.window?.toolbar?.validateVisibleItems()
    }

    /// Durum çubuğu ve görünüm düğmeleri Ayarlar ▸ Arayüz'den kapatılabilir.
    private func applyInterfaceOptions() {
        let statusBar = UIElement.statusBar.isShown
        statusLabel.isHidden = !statusBar
        bottomSeparator.isHidden = !statusBar
        viewButtons.isHidden = !statusBar || !UIElement.viewButtons.isShown
        statusBarHeight?.constant = statusBar ? -24 : 0
    }

    @objc private func viewButtonClicked() {
        let index = viewButtons.selectedSegment
        guard ViewMode.allCases.indices.contains(index) else { return }
        setViewMode(ViewMode.allCases[index])
    }

    private var sizeDisplay = Preferences.sizeDisplay
    /// Sütun genişliği kod tarafından değiştiriliyor (kullanıcı boyutlandırması sayılmaz).
    private var fittingColumns = false
    /// Ayırıcıya çift tıklanan sütun: sonraki boyut değişikliği kullanıcınınki sayılır.
    private var sizingToFit: NSUserInterfaceItemIdentifier?
    /// Çift tıklamayla içeriğe sığdırmadan önceki genişlik (tekrar çift tıklanınca geri döner).
    private var widthBeforeFit: [NSUserInterfaceItemIdentifier: CGFloat] = [:]

    private func preferencesChanged() {
        applyInterfaceOptions()
        applyActiveState()
        // Başka pencerede değiştirilen sütun genişlikleri (sürükleme sürerken değil).
        if !fittingColumns, (table.headerView?.resizedColumn ?? -1) < 0 { applySavedColumnWidths() }
        let size = Preferences.sizeDisplay
        if size != sizeDisplay {
            sizeDisplay = size
            if let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == SortColumn.size.rawValue }) {
                table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: column))
            }
        }
        let showHidden = Preferences.showHidden
        guard showHidden != lastShowHidden else { return }
        lastShowHidden = showHidden
        reload()
    }

    // MARK: Dosya işlemleri

    /// Kes / Kopyala: seçili öğeleri panoya yazar.
    func copySelection(cut: Bool) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        if cut && isArchive { return readOnlyArchive() }   // arşivden kesilmez, kopyalanıp çıkarılır
        FileClipboard.write(urls, cut: cut)
    }

    /// Yapıştır: panodaki dosyaları bu klasöre kopyalar; kesildilerse taşır ve panoyu boşaltır.
    func paste() {
        let (urls, cut) = FileClipboard.read()
        guard !urls.isEmpty else { return }
        if isArchive { return readOnlyArchive() }
        transfer(cut ? .move : .copy, urls, to: tab.url) { result in
            if cut && !result.cancelled { FileClipboard.clear() }
        }
    }

    func transfer(_ kind: TransferKind, _ urls: [URL], to destination: URL, completion: @escaping (TransferResult) -> Void = { _ in }) {
        if Archives.isArchive(destination) { return readOnlyArchive() }
        // Arşivden taşınmaz: çıkarılır (kopyalanır), arşiv olduğu gibi kalır.
        let kind = urls.contains(where: Archives.isArchive) ? TransferKind.copy : kind
        let remote = urls.filter(\.isRemote), local = urls.filter { !$0.isRemote }
        if destination.isRemote || !remote.isEmpty {
            let window = view.window
            let done: ([URL]) -> Void = { [weak self] created in
                self?.reveal(created, in: destination)
                NotificationCenter.default.post(name: RemoteSessions.didChange, object: destination.isRemote ? destination : remote.first)
                completion(TransferResult(created: created))
            }
            if destination.isRemote {
                if !local.isEmpty { RemoteTransfers.upload(local, to: destination, move: kind == .move, window: window, completion: done) }
                if !remote.isEmpty {
                    let key = RemoteURL.serverKey(destination)
                    if kind == .move, remote.allSatisfy({ RemoteURL.serverKey($0) == key }) {
                        moveOnServer(remote, to: destination, completion: done)   // aynı sunucuda taşıma: yeniden adlandırma
                    } else {
                        RemoteTransfers.copyBetween(remote, to: destination, move: kind == .move, window: window, completion: done)
                    }
                }
            } else {
                RemoteTransfers.download(remote, to: destination, move: kind == .move, window: window, completion: done)
                if !local.isEmpty { FileOperations.transfer(kind, local, to: destination, window: window) { completion($0) } }
            }
            return
        }
        FileOperations.transfer(kind, urls, to: destination, window: view.window) { [weak self] result in
            self?.reveal(result.created, in: destination)
            completion(result)
        }
    }

    /// Aynı sunucuda başka klasöre taşıma (yeniden adlandırma). Kopyalama ve sunucular arası taşıma: `RemoteTransfers.copyBetween`.
    private func moveOnServer(_ urls: [URL], to destination: URL, completion: @escaping ([URL]) -> Void) {
        Task { [weak self] in
            guard let connection = await RemoteSessions.connection(for: destination, window: self?.view.window) else { return }
            var created: [URL] = [], errors: [String] = []
            let base = RemoteURL.path(of: destination)
            for url in urls {
                let target = RemotePath.join(base, url.lastPathComponent)
                do {
                    try await connection.run { try await $0.rename(RemoteURL.path(of: url), to: target) }
                    if let made = RemoteURL.make(destination, path: target, isDirectory: url.hasDirectoryPath) { created.append(made) }
                } catch { errors.append("“\(url.lastPathComponent)”: \(error.localizedDescription)") }
            }
            completion(created)
            if !errors.isEmpty { self?.showError(errors.prefix(6).joined(separator: "\n")) }
        }
    }

    /// Yeni oluşan öğeyi seçer ve adını düzenlemeye açar (Yeni klasör, zip, kısayol).
    func revealAndRename(_ url: URL) {
        tab.filter = ""
        searchField.stringValue = ""
        pendingRenamePath = url.standardizedFileURL.path
        load(selecting: [url])
        focusTable()
    }

    /// "Finder'da göster": öğelerin klasörüne gider ve onları seçili gösterir.
    func show(_ urls: [URL], in directory: URL) {
        tab.filter = ""
        searchField.stringValue = ""
        if tab.url.locationKey != directory.normalizedFileURL.locationKey { navigate(to: directory) }
        tab.selectedURLs = urls   // pencere ilk açılırken başlayan yükleme de bu seçimi kullansın
        load(selecting: urls)
        focusTable()
    }

    /// Bu panel o klasördeyse yeni öğeleri seçili gösterir.
    func reveal(_ urls: [URL], in directory: URL) {
        guard !urls.isEmpty, tab.url.locationKey == directory.normalizedFileURL.locationKey else { return }
        load(selecting: urls)
    }

    /// Sil: Çöp Sepeti'ne; `permanently` ise onay sorup kalıcı olarak.
    func deleteSelection(permanently: Bool) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        if isArchive { return readOnlyArchive() }
        if isRemote {
            let directory = tab.url
            RemoteTransfers.delete(urls, window: view.window) { NotificationCenter.default.post(name: RemoteSessions.didChange, object: directory) }
            return
        }
        if permanently {
            FileOperations.deletePermanently(urls, window: view.window)
        } else {
            // Arama sonuçlarından hemen düşer.
            if searchResults != nil {
                let gone = Set(urls.map { $0.standardizedFileURL.path })
                searchResults?.removeAll { gone.contains($0.url.standardizedFileURL.path) }
            }
            // Silinenden sonraki öğe seçili kalsın (Windows gibi).
            if let last = selectionIndexes.last, last + 1 < shown.count {
                tab.selectedURLs = [shown[last + 1].url]
            }
            FileOperations.moveToTrash(urls, window: view.window)
        }
    }

    func createNewFolder() {
        if isArchive { return readOnlyArchive() }
        if isRemote { return createRemote(String(localized: "Yeni klasör", bundle: .live), folder: true) }
        create(String(localized: "Yeni Klasör", bundle: .live)) { try FileCreator.newFolder(in: $0, name: String(localized: "Yeni klasör", bundle: .live)) }
    }

    func createNewTextDocument() {
        if isArchive { return readOnlyArchive() }
        if isRemote { return createRemote(String(localized: "Yeni Metin Belgesi.txt", bundle: .live), folder: false) }
        create(String(localized: "Yeni Metin Belgesi", bundle: .live)) { try FileCreator.newFile(in: $0, name: String(localized: "Yeni Metin Belgesi.txt", bundle: .live)) }
    }

    /// Yeni öğe oluşturur, geri alma geçmişine ekler (geri almak onu Çöp Sepeti'ne taşır) ve adını düzenlemeye açar.
    func create(_ undoName: String, _ make: (URL) throws -> URL) {
        do {
            let url = try make(tab.url)
            UndoCenter.shared.register([.trash(url)], name: undoName)
            revealAndRename(url)
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Sunucuda yeni klasör ya da boş metin belgesi ("Yeni klasör (2)" …), sonra adı düzenlemeye açılır.
    private func createRemote(_ name: String, folder: Bool) {
        let taken = Set(items.map { $0.name.lowercased() })
        let ext = folder ? "" : (name as NSString).pathExtension
        let stem = folder || ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name, n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty || folder ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            n += 1
        }
        let directory = tab.url
        let path = RemotePath.join(RemoteURL.path(of: directory), candidate)
        Task { [weak self] in
            guard let connection = await RemoteSessions.connection(for: directory, window: self?.view.window) else { return }
            do {
                if folder {
                    try await connection.run { try await $0.makeDirectory(path) }
                } else {
                    let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    FileManager.default.createFile(atPath: empty.path, contents: Data())
                    defer { try? FileManager.default.removeItem(at: empty) }
                    try await connection.run { try await $0.upload(empty, to: path) { _ in } }
                }
                if let url = RemoteURL.make(directory, path: path, isDirectory: folder) { self?.revealAndRename(url) }
            } catch {
                self?.showError(error.localizedDescription)
            }
        }
    }

    // MARK: Yeniden adlandırma

    var isRenaming: Bool { renamingURL != nil }

    /// F2 (Windows) / Enter (Mac): seçili tek öğenin adını satır içinde düzenler; uzantı seçilmez.
    func beginRename() {
        if isArchive { return readOnlyArchive() }
        let rows = selectionIndexes
        guard rows.count == 1, let row = rows.first else { return }
        beginRename(row: row)
    }

    private func beginRename(row: Int) {
        guard row < shown.count else { return }
        setSelection([row])
        guard let (container, field) = nameField(forRow: row) else { return }
        let item = shown[row]
        renamingURL = item.url
        renameOriginal = item.name
        renameCancelled = false
        container.alphaValue = 1
        field.maximumNumberOfLines = 1
        field.stringValue = item.name
        field.textColor = .labelColor
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.delegate = self
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: FileNaming.baseNameLength(of: item.name, isDirectory: item.isDirectory))
    }

    private func finishRename(_ field: NSTextField) {
        guard let url = renamingURL else { return }
        renamingURL = nil
        let newName = field.stringValue
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = nil
        let window = view.window
        if window?.firstResponder === window || window?.firstResponder == nil { focusTable() }

        guard !renameCancelled, newName != renameOriginal else {
            reloadWhileRenaming = false
            load(selecting: [url])
            return
        }
        reloadWhileRenaming = false
        if url.isRemote { return renameRemote(url, to: newName) }
        do {
            let renamed = try FileRenamer.rename(url, to: newName)
            replaceItem(url, with: FileItem(url: renamed))   // hemen Enter'a basılırsa yeni ad açılsın
            if let i = searchResults?.firstIndex(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
                searchResults?[i] = FileItem(url: renamed)
            }
            UndoCenter.shared.register([.move(from: renamed, to: url)], name: String(localized: "Yeniden Adlandır", bundle: .live))
            load(selecting: [renamed])
        } catch let error as RenameError {
            load(selecting: [url])
            switch error {
            case .empty: showError(String(localized: "Bir dosya adı yazmalısınız.", bundle: .live))
            case .invalidCharacters: showError(String(localized: "Dosya adı şu karakterleri içeremez: / :", bundle: .live))
            case .exists: showError(String(localized: "Bu konumda “\(newName)” adlı bir öğe zaten var.", bundle: .live))
            case .system(let message): showError(message)
            }
        } catch {
            load(selecting: [url])
            showError(error.localizedDescription)
        }
    }

    private func renameRemote(_ url: URL, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { load(selecting: [url]); return showError(String(localized: "Bir dosya adı yazmalısınız.", bundle: .live)) }
        guard !name.contains("/") else { load(selecting: [url]); return showError(String(localized: "Dosya adı şu karakteri içeremez: /", bundle: .live)) }
        guard !items.contains(where: { $0.name == name && $0.url != url }) else {
            load(selecting: [url])
            return showError(String(localized: "Bu konumda “\(name)” adlı bir öğe zaten var.", bundle: .live))
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
        // Sunucu yanıt verene kadar da listede yeni ad ve adres dursun: hızlıca Enter'a basılırsa eski (artık olmayan)
        // adres açılmasın. Sunucu reddederse eski haline döner.
        let original = items.first { $0.url.locationKey == url.locationKey }
        if let original {
            replaceItem(url, with: FileItem(url: target, name: name, displayName: name, isDirectory: original.isDirectory,
                                            isPackage: original.isPackage, isHidden: name.hasPrefix("."),
                                            isSymbolicLink: original.isSymbolicLink, size: original.size,
                                            modified: original.modified, created: original.created, kind: original.kind))
        }
        Task { [weak self] in
            guard let connection = await RemoteSessions.connection(for: url, window: self?.view.window) else { return }
            do {
                try await connection.run { try await $0.rename(RemoteURL.path(of: url), to: RemoteURL.path(of: target)) }
                self?.load(selecting: [target])
            } catch {
                if let original { self?.replaceItem(target, with: original) }
                self?.load(selecting: [url])
                self?.showError(error.localizedDescription)
            }
        }
    }

    /// Listede bir öğeyi yerinde değiştirir (seçim korunur); yeniden adlandırmadan hemen sonra.
    private func replaceItem(_ old: URL, with item: FileItem) {
        let key = old.locationKey
        if let i = items.firstIndex(where: { $0.url.locationKey == key }) { items[i] = item }
        guard let row = shown.firstIndex(where: { $0.url.locationKey == key }) else { return }
        shown[row] = item
        if tab.viewMode == .details {
            table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        } else {
            iconView.reloadItems(at: [IndexPath(item: row, section: 0)])
            iconView.selectionIndexPaths.insert(IndexPath(item: row, section: 0))
        }
    }

    func showError(_ message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    @objc private func clipboardChanged() {
        guard !isRenaming else { return }
        let selection = selectionIndexes
        reloadList()
        setSelection(selection, scroll: false)
    }

    /// Bkz. DebugSnapshot: adlarıyla öğeleri seçer ve listeye odaklanır.
    var debugSelectedNames: [String] { selectionIndexes.filter { $0 < shown.count }.map { shown[$0].displayName } + (markCursor.map { ["| imleç: \($0)"] } ?? []) }

    func debugSelect(_ names: [String]) {
        let rows = IndexSet(shown.indices.filter { names.contains(shown[$0].name) })
        focusTable()
        setSelection(rows)
    }

    // MARK: Düğmeler

    @objc private func backClicked() { goBack() }
    @objc private func forwardClicked() { goForward() }
    @objc private func upClicked() { goUp() }
    @objc private func refreshClicked() { refresh() }

    @objc private func searchChanged() {
        tab.filter = searchField.stringValue
        restartSearch()
        rebuild(selecting: selectedURLs)
    }

    // MARK: Alt klasörlerde arama

    static let locationColumn = NSUserInterfaceItemIdentifier("location")

    /// Arama sürüyor mu / bitti mi: sonuçlar (nil: alt klasör araması yok).
    var isSearchingSubfolders: Bool { searchResults != nil }

    /// Yazdıkça yeniden başlar (kısa bir beklemeyle); yalnızca bu Mac'teki klasörlerde.
    private func restartSearch() {
        search?.cancel()
        search = nil
        searchDelay?.cancel()
        let query = tab.filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, Preferences.searchSubfolders, !tab.url.isRemote else {
            if searchResults != nil {
                searchResults = nil
                searchTruncated = false
                showLocationColumn(false)
            }
            return
        }
        searchResults = searchResults ?? []
        showLocationColumn(true)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.startSearch(query) }
        }
        searchDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func startSearch(_ query: String) {
        let job = RecursiveSearch(root: tab.url, query: query, showHidden: Preferences.showHidden)
        search = job
        searchResults = []
        searchTruncated = false
        searchRoot = tab.url
        rebuild(selecting: selectedURLs)
        DispatchQueue.global(qos: .userInitiated).async {
            job.run(batch: { found in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in
                        guard let self, self.search === job else { return }
                        self.searchResults?.append(contentsOf: found)
                        self.rebuild(selecting: self.selectedURLs)
                    }
                }
            }, finished: { truncated in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in
                        guard let self, self.search === job else { return }
                        self.search = nil
                        self.searchTruncated = truncated
                        self.rebuild(selecting: self.selectedURLs)
                    }
                }
            })
        }
    }

    /// Başka klasöre geçildi: arama biter.
    func endSearch() {
        search?.cancel()
        search = nil
        searchDelay?.cancel()
        guard searchResults != nil else { return }
        searchResults = nil
        searchTruncated = false
        showLocationColumn(false)
    }

    private func showLocationColumn(_ show: Bool) {
        table.tableColumn(withIdentifier: Self.locationColumn)?.isHidden = !show
        fitNameColumn()
    }

    /// Sonucun bulunduğu klasör, aramanın başladığı klasöre göre ("Belgeler/Faturalar"); kendisi ise o klasörün adı.
    func locationText(_ item: FileItem) -> String {
        let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
        let root = (searchRoot ?? tab.url).standardizedFileURL.path
        if parent == root { return FileManager.default.displayName(atPath: root) }
        if parent.hasPrefix(root + "/") { return String(parent.dropFirst(root.count + 1)) }
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    /// Geliştirme: arama kutusuna yazmak gibi.
    func debugSearch(_ text: String) {
        searchField.stringValue = text
        searchChanged()
    }

    /// Geliştirme: durum çubuğu metni.
    var debugStatus: String { statusLabel.stringValue }

    /// Arama kutusunun büyüteç menüsü.
    private func searchMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: String(localized: "Alt klasörlerde ara", bundle: .live), action: #selector(toggleSearchSubfolders(_:)), keyEquivalent: "")
        item.target = self
        item.state = Preferences.searchSubfolders ? .on : .off
        menu.addItem(item)
        return menu
    }

    @objc private func toggleSearchSubfolders(_ sender: NSMenuItem) {
        Preferences.searchSubfolders.toggle()
        searchField.searchMenuTemplate = searchMenu()
        restartSearch()
        rebuild(selecting: selectedURLs)
    }

    /// Dosya konumunu aç (Windows'taki gibi): sonucun bulunduğu klasöre gider, öğe seçili.
    func openItemLocation(_ url: URL) {
        tab.filter = ""
        searchField.stringValue = ""
        endSearch()
        navigate(to: url.deletingLastPathComponent(), selecting: [url])
    }
}

// MARK: - Tablo

extension PaneViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < shown.count else { return nil }
        let item = shown[row]
        if tableColumn.identifier == Self.locationColumn {
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView
                ?? makeCell(tableColumn.identifier, withIcon: false, alignment: .left)
            cell.textField?.stringValue = locationText(item)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.lineBreakMode = .byTruncatingHead
            cell.toolTip = item.url.deletingLastPathComponent().path
            return cell
        }
        guard let column = SortColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView
            ?? makeCell(tableColumn.identifier, withIcon: column == .name, alignment: column == .size ? .right : .left)
        let text: String
        switch column {
        case .name:
            text = item.displayName
            cell.imageView?.image = IconCache.icon(for: item.url)
            cell.imageView?.alphaValue = item.isHidden ? 0.5 : 1
        case .modified:
            text = item.modified.map { Formatters.date.string(from: $0) } ?? ""
        case .kind:
            text = item.kind
        case .size:
            text = item.size.map { sizeDisplay.string($0) } ?? ""
        }
        cell.textField?.stringValue = text
        // Kesilen (yapıştırılmayı bekleyen) öğeler Windows'taki gibi soluk
        cell.alphaValue = FileClipboard.cutPaths.contains(item.url.locationKey) ? 0.45 : 1
        // Gizli öğeler Windows'taki gibi soluk
        cell.textField?.textColor = column == .name
            ? (item.isHidden ? .secondaryLabelColor : .labelColor)
            : .secondaryLabelColor
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, withIcon: Bool, alignment: NSTextAlignment) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.alignment = alignment
        // Tarih ve boyut: rakamlar eşit genişlikte, satırlar alt alta hizalı.
        let numeric = id.rawValue == SortColumn.modified.rawValue || id.rawValue == SortColumn.size.rawValue
        text.font = numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var constraints = [
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]
        if withIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applyingSort, let d = tableView.sortDescriptors.first, let key = d.key, let column = SortColumn(rawValue: key) else { return }
        tab.sort = FileSort(column: column, ascending: d.ascending)
        rebuild(selecting: selectedURLs)
    }

    /// Kullanıcı bir sütunu sürükleyerek ya da ayırıcıya çift tıklayarak boyutlandırdı: genişlik hatırlanır (tüm pencereler).
    func tableViewColumnDidResize(_ notification: Notification) {
        guard !fittingColumns, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        let byUser = (table.headerView?.resizedColumn ?? -1) >= 0 || sizingToFit == column.identifier
        guard byUser else { return }
        sizingToFit = nil
        var widths = Preferences.columnWidths
        widths[column.identifier.rawValue] = Double(column.width)
        Preferences.columnWidths = widths
        if column.identifier.rawValue != SortColumn.name.rawValue { fitNameColumn() }
    }

    /// Sütun ayırıcısına çift tıklama: sütun en uzun içeriğe göre ayarlanır (Windows Gezgini gibi); bir daha çift
    /// tıklanınca önceki genişliğine döner.
    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn columnIndex: Int) -> CGFloat {
        let column = table.tableColumns[columnIndex]
        let font = NSFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var texts: [String] = [column.title]
        switch SortColumn(rawValue: column.identifier.rawValue) {
        case .name: texts += shown.map(\.displayName)
        case .modified: texts += shown.compactMap { $0.modified.map { Formatters.date.string(from: $0) } }
        case .kind: texts += shown.map(\.kind)
        case .size: texts += shown.compactMap { $0.size.map { sizeDisplay.string($0) } }
        case nil: texts += shown.map(locationText)
        }
        let widest = texts.reduce(0) { max($0, ($1 as NSString).size(withAttributes: attributes).width) }
        let extra: CGFloat = column.identifier.rawValue == SortColumn.name.rawValue ? 16 + 6 + 2 + 12 : 12
        sizingToFit = column.identifier
        let fit = min(1200, max(column.minWidth, ceil(widest + extra)))
        // İkinci çift tıklama: sütun zaten içeriğe göreyse önceki genişliğine döner.
        if abs(column.width - fit) < 1, let previous = widthBeforeFit[column.identifier] {
            widthBeforeFit[column.identifier] = nil
            return previous
        }
        widthBeforeFit[column.identifier] = column.width
        return fit
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !settingMarks { endMarking() }   // tıklama ya da başka bir seçim: işaretleme biter
        updateStatus()
        refreshQuickLook()
    }

    // MARK: Sürükle-bırak

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        row < shown.count ? pasteboardWriter(for: shown[row]) : nil
    }

    /// Yerel öğeler dosya adresi olarak (Finder'a da sürüklenir), uzak öğeler kendi türümüzle.
    func pasteboardWriter(for item: FileItem) -> NSPasteboardWriting {
        item.url.isRemote ? FileClipboard.remoteItem(item.url) : item.url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let target: URL
        if dropOperation == .on, row >= 0, row < shown.count, shown[row].isDirectory {
            target = shown[row].url
        } else {
            tableView.setDropRow(-1, dropOperation: .on)   // klasörün kendisine bırak
            target = tab.url
        }
        return self.dropOperation(info, target: target)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        performDrop(info, target: row >= 0 && row < shown.count && shown[row].isDirectory ? shown[row].url : tab.url)
    }

    /// Bırakılabilir mi, nasıl (taşı / kopyala)? Kendi üstüne ya da zaten bulunduğu klasöre taşıma yok.
    func dropOperation(_ info: NSDraggingInfo, target: URL?) -> NSDragOperation {
        guard let target, !Archives.isArchive(target) else { return [] }   // arşive bırakılmaz (salt okunur)
        let urls = Self.draggedURLs(info)
        let targetKey = target.locationKey
        guard !urls.isEmpty, !urls.contains(where: { $0.locationKey == targetKey }) else { return [] }
        let operation = Self.dragOperation(info, urls: urls, target: target)
        if operation == .move && urls.allSatisfy({ $0.deletingLastPathComponent().locationKey == targetKey }) {
            return []
        }
        return operation
    }

    func performDrop(_ info: NSDraggingInfo, target: URL?) -> Bool {
        let operation = dropOperation(info, target: target)
        guard let target, !operation.isEmpty else { return false }
        transfer(operation == .move ? .move : .copy, Self.draggedURLs(info), to: target)
        return true
    }

    private static func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        FileClipboard.urls(from: info.draggingPasteboard)
    }

    /// Aynı diskte taşır, başka diske kopyalar; ⌥ basılıysa kopyalar, ⌘ basılıysa taşır (Finder gibi).
    private static func dragOperation(_ info: NSDraggingInfo, urls: [URL], target: URL) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        // Sunucuyla bilgisayar arasında: kopyala (indir / yükle). Aynı sunucuda: taşı. Sunucular arası: yok.
        let allRemote = urls.allSatisfy(\.isRemote), allLocal = !urls.contains(where: \.isRemote)
        if !allLocal || target.isRemote {
            if (allLocal && target.isRemote) || (allRemote && !target.isRemote) {
                return mask.contains(.copy) || mask.contains(.generic) ? .copy : []
            }
            let key = RemoteURL.serverKey(target)
            return allRemote && urls.allSatisfy({ RemoteURL.serverKey($0) == key }) ? .move : []
        }
        if mask == .copy { return .copy }
        if mask == .generic || mask == .move { return .move }
        let sameVolume = urls.allSatisfy { FileInfo.sameVolume($0, target) }
        if sameVolume && (mask.contains(.move) || mask.contains(.generic)) { return .move }
        return mask.contains(.copy) ? .copy : []
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemedRowView() }

    /// Yazarak seçme ad üzerinden yapılır.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        row < shown.count ? shown[row].displayName : nil
    }
}

/// Zemin rengini (açık/koyu görünüme uyarak) çizen düz görünüm.
final class BackgroundView: NSView {
    private let color: () -> NSColor

    /// Renk her çizimde sorulur: tema değişince yeniden çizmek yeter.
    init(color: @escaping () -> NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    override func draw(_ dirtyRect: NSRect) {
        color().setFill()
        dirtyRect.intersection(bounds).fill()   // macOS 14+ görünümler sınırına kırpılmaz
    }
}

// MARK: - Satır içi yeniden adlandırma

extension PaneViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, renamingURL != nil else { return }
        finishRename(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard renamingURL != nil else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            view.window?.makeFirstResponder(listView)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(listView)
            return true
        }
        return false
    }
}

// MARK: - Hızlı Bakış veri kaynağı

extension PaneViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = selectedItems
        return index < items.count ? items[index].url as NSURL : nil
    }

    /// Panel öndeyken ok tuşları listede gezinir; Boşluk paneli kapatır.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        if event.keyCode == KeyCode.space {
            panel.orderOut(nil)
        } else {
            listView.keyDown(with: event)
        }
        return true
    }

    /// Önizleme satırın simgesinden büyüyerek açılır.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item?.previewItemURL, let row = shown.firstIndex(where: { $0.url == url }),
              let window = view.window else { return .zero }
        let image: NSImageView?
        if tab.viewMode == .details {
            let column = table.column(withIdentifier: .init(SortColumn.name.rawValue))
            guard column >= 0, table.visibleRect.intersects(table.rect(ofRow: row)) else { return .zero }
            image = (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.imageView
        } else {
            image = iconView.item(at: IndexPath(item: row, section: 0))?.imageView
        }
        guard let image else { return .zero }
        return window.convertToScreen(image.convert(image.bounds, to: nil))
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        item?.previewItemURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

extension NSView {
    /// Görünümü ve tüm alt görünümlerini yeniden çizer (tema değişince).
    func redrawSubtree() {
        needsDisplay = true
        subviews.forEach { $0.redrawSubtree() }
    }
}

// MARK: - Simge görünümü veri kaynağı

extension PaneViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileIconItem.identifier, for: indexPath)
        if let item = item as? FileIconItem, indexPath.item < shown.count {
            let file = shown[indexPath.item]
            item.configure(file, mode: tab.viewMode, cut: FileClipboard.cutPaths.contains(file.url.locationKey))
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if !settingMarks { endMarking() }
        updateStatus()
        refreshQuickLook()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if !settingMarks { endMarking() }
        updateStatus()
        refreshQuickLook()
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        indexPath.item < shown.count ? pasteboardWriter(for: shown[indexPath.item]) : nil
    }
}

/// Kapanışla çalışan menü öğesi (sekme menüsü gibi küçük, bağlama özgü menüler için).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    @objc private func run() { handler() }
}
