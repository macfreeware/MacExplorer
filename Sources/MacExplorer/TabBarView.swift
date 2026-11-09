import AppKit

/// Sürüklenen sekme. Sürükleme aynı uygulama içinde kaldığından sekmenin kendisi burada tutulur;
/// panoya yalnızca türü yazılır (Finder'a bırakılınca dosya işlemi olmasın diye dosya URL'si yazılmaz).
@MainActor
enum TabDrag {
    static let type = NSPasteboard.PasteboardType("local.macexplorer.tab")
    static var current: (pane: PaneViewController, tab: TabState)?
}

/// Bir panelin sekme çubuğu. Seçili sekme alttaki gezinme çubuğuyla aynı zemindedir (tarayıcı sekmeleri gibi);
/// çift panelde etkin panelin seçili sekmesinin üstünde vurgu rengi çizgisi vardır.
@MainActor
final class TabBarView: NSView, NSDraggingSource {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    /// Sekme sürüklenmeye başladı (sekmeyi `TabDrag.current`'a koyar); nil dönerse sürüklenmez.
    var onBeginDrag: ((Int) -> Bool)?
    /// Sürüklenen sekme bu çubuğa, verilen sıraya bırakıldı.
    var onDropTab: ((Int) -> Void)?
    /// Sekme hiçbir pencerenin üstüne bırakılmadı: ekran noktasında yeni pencere.
    var onDragOut: ((NSPoint) -> Void)?
    /// Sekmeye sağ tık.
    var menuProvider: ((Int) -> NSMenu?)?

    /// Bırakılacak yer (sekmeler arasındaki çizgi).
    private var dropIndex: Int? {
        didSet { if oldValue != dropIndex { needsDisplay = true } }
    }

    /// Çift panelde bu panel etkin mi (vurgu çizgisi).
    var isActive = false {
        didSet { tabViews.forEach { $0.paneActive = isActive } }
    }

    private var tabViews: [TabItemView] = []
    private lazy var addButton: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Yeni sekme", bundle: .live))!,
                         target: self, action: #selector(addClicked))
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = String(localized: "Yeni sekme", bundle: .live)
        return b
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(addButton)
        registerForDraggedTypes([TabDrag.type])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    override var isFlipped: Bool { true }

    func update(titles: [String], selected: Int) {
        while tabViews.count > titles.count { tabViews.removeLast().removeFromSuperview() }
        while tabViews.count < titles.count {
            let v = TabItemView()
            v.onSelect = { [weak self, weak v] in
                guard let self, let v, let i = self.tabViews.firstIndex(of: v) else { return }
                self.onSelect?(i)
            }
            v.onClose = { [weak self, weak v] in
                guard let self, let v, let i = self.tabViews.firstIndex(of: v) else { return }
                self.onClose?(i)
            }
            v.onDrag = { [weak self, weak v] event in
                guard let self, let v else { return }
                self.beginDrag(v, event: event)
            }
            v.onMenu = { [weak self, weak v] in
                guard let self, let v, let i = self.tabViews.firstIndex(of: v) else { return nil }
                return self.menuProvider?(i)
            }
            addSubview(v)
            tabViews.append(v)
        }
        for (i, v) in tabViews.enumerated() {
            v.title = titles[i]
            v.isSelected = i == selected
            v.paneActive = isActive
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let addWidth: CGFloat = 28, inset: CGFloat = 6, top: CGFloat = 5
        let available = bounds.width - addWidth - inset * 2
        let width = tabViews.isEmpty ? 0 : min(220, max(70, available / CGFloat(tabViews.count)))
        var x = inset
        for v in tabViews {
            v.frame = NSRect(x: x, y: top, width: width, height: bounds.height - top)
            x += width
        }
        addButton.frame = NSRect(x: min(x + 2, bounds.width - addWidth), y: top + 2, width: addWidth - 4, height: bounds.height - top - 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.current.stripColor.setFill()
        bounds.fill()
        if let dropIndex {
            let x = dropIndex < tabViews.count ? tabViews[dropIndex].frame.minX : (tabViews.last?.frame.maxX ?? 6)
            Theme.current.accentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: 6, width: 3, height: bounds.height - 8), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    // MARK: Sekme sürükleme (Firefox gibi: başka pencerenin sekme çubuğuna ya da dışarıya, yeni pencereye)

    private func beginDrag(_ tabView: TabItemView, event: NSEvent) {
        guard let index = tabViews.firstIndex(of: tabView), onBeginDrag?(index) == true else { return }
        let item = NSPasteboardItem()
        item.setString("tab", forType: TabDrag.type)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(tabView.frame, contents: tabView.snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { TabDrag.current = nil }
        guard operation.isEmpty else { return }
        // Bir MacExplorer penceresinin üstüne (ama sekme çubuğu dışına) bırakıldıysa bir şey yapma.
        let overWindow = NSApp.windows.contains { $0.isVisible && $0.windowController is BrowserWindowController && $0.frame.contains(screenPoint) }
        if !overWindow { onDragOut?(screenPoint) }
    }

    /// Bırakma çizgisinin yeri: imlecin hangi sekmenin solunda / sağında olduğuna göre.
    private func insertionIndex(_ sender: NSDraggingInfo) -> Int {
        let x = convert(sender.draggingLocation, from: nil).x
        for (i, v) in tabViews.enumerated() where x < v.frame.midX { return i }
        return tabViews.count
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard TabDrag.current != nil, sender.draggingPasteboard.types?.contains(TabDrag.type) == true else { return [] }
        dropIndex = insertionIndex(sender)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropIndex = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let index = insertionIndex(sender)
        dropIndex = nil
        guard TabDrag.current != nil else { return false }
        onDropTab?(index)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dropIndex = nil }

    override func mouseDown(with event: NSEvent) {
        // Boş alana çift tık: yeni sekme
        if event.clickCount == 2 { onNew?() }
    }

    @objc private func addClicked() { onNew?() }
}

@MainActor
final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onMenu: (() -> NSMenu?)?
    private var mouseDownPoint: NSPoint?

    var title = "" {
        didSet { label.stringValue = title; toolTip = title }
    }
    var isSelected = false {
        didSet { needsDisplay = true; updateCloseButton() }
    }
    var paneActive = false {
        didSet { needsDisplay = true }
    }
    private var hovering = false {
        didSet { needsDisplay = true; updateCloseButton() }
    }

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Sekmeyi kapat", bundle: .live))?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = String(localized: "Sekmeyi kapat", bundle: .live)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(label)
        addSubview(closeButton)
        updateCloseButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        closeButton.frame = NSRect(x: b.width - 24, y: (b.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 12, y: (b.height - 16) / 2, width: max(0, b.width - 40), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        if isSelected {
            // Alt köşeler sınırın dışında kalır: sekme alttaki gezinme çubuğuyla birleşik görünür.
            Theme.current.chromeColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 8), xRadius: 7, yRadius: 7).fill()
            if paneActive {
                Theme.current.accentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX + 8, y: r.minY, width: r.width - 16, height: 2.5), xRadius: 1.25, yRadius: 1.25).fill()
            }
        } else if hovering {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 3), xRadius: 6, yRadius: 6).fill()
        } else {
            NSColor.separatorColor.setFill()
            NSRect(x: r.maxX - 1, y: r.minY + 8, width: 1, height: r.height - 14).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        onSelect?()
    }

    /// Birkaç nokta sürüklenince sekme sürüklemesi başlar.
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > 4 {
            mouseDownPoint = nil
            onDrag?(event)
        }
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }

    /// Sürüklenirken imlecin altında görünen sekme resmi.
    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    /// Orta tık sekmeyi kapatır (tarayıcılardaki gibi).
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } else { super.otherMouseDown(with: event) }
    }

    private func updateCloseButton() {
        closeButton.isHidden = !(isSelected || hovering)
    }

    @objc private func closeClicked() { onClose?() }
}
