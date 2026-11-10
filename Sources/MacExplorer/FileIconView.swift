import AppKit
import QuickLookThumbnailing
import MacExplorerCore

/// Windows Gezgini'nin görünümleri (Görünüm menüsü ve araç çubuğu).
enum ViewMode: String, CaseIterable {
    case extraLargeIcons, largeIcons, mediumIcons, smallIcons, list, details

    var title: String {
        switch self {
        case .extraLargeIcons: return String(localized: "Çok büyük simgeler", bundle: .live)
        case .largeIcons: return String(localized: "Büyük simgeler", bundle: .live)
        case .mediumIcons: return String(localized: "Orta boyutlu simgeler", bundle: .live)
        case .smallIcons: return String(localized: "Küçük simgeler", bundle: .live)
        case .list: return String(localized: "Liste", bundle: .live)
        case .details: return String(localized: "Ayrıntılar", bundle: .live)
        }
    }

    var symbol: String {
        switch self {
        case .extraLargeIcons: return "square.grid.2x2"
        case .largeIcons: return "square.grid.3x2"
        case .mediumIcons: return "square.grid.3x3"
        case .smallIcons: return "square.grid.4x3.fill"
        case .list: return "list.bullet.indent"
        case .details: return "list.bullet.rectangle"
        }
    }

    /// Simge boyutu (pt). Küçük simgeler ve Liste satır düzenindedir (simge solda, ad sağda).
    var iconSize: CGFloat {
        switch self {
        case .extraLargeIcons: return 160
        case .largeIcons: return 80
        case .mediumIcons: return 48
        case .smallIcons, .list, .details: return 16
        }
    }

    var isRowLayout: Bool { self == .smallIcons || self == .list || self == .details }

    var itemSize: NSSize {
        switch self {
        case .extraLargeIcons: return NSSize(width: 210, height: 214)
        case .largeIcons: return NSSize(width: 124, height: 128)
        case .mediumIcons: return NSSize(width: 96, height: 92)
        case .smallIcons: return NSSize(width: 210, height: 22)
        case .list, .details: return NSSize(width: 240, height: 22)
        }
    }

    /// Yeni pencerelerin görünümü: en son seçilen.
    static var saved: ViewMode {
        get { ViewMode(rawValue: UserDefaults.standard.string(forKey: Preferences.Key.viewMode) ?? "") ?? .details }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Preferences.Key.viewMode) }
    }
}

/// Simge görünümleri ve Liste için ızgara. Sağ tık, çift tık ve bırakma hedefi panele bildirilir.
@MainActor
final class FileIconView: NSCollectionView {
    var onBecomeFirstResponder: (() -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    /// Bırakma: sürüklenen bilgisi ve üzerine bırakılan öğe (boş alanda nil) → işlem.
    var validateDrop: ((NSDraggingInfo, Int?) -> NSDragOperation)?
    var acceptDrop: ((NSDraggingInfo, Int?) -> Bool)?
    /// Yazarak seçme: öğenin görünen adı ve bulunan öğeye gitme.
    var nameProvider: ((Int) -> String?)?
    var onTypeSelect: ((Int) -> Void)?
    private var typed = ""
    private var lastTyped = Date.distantPast
    /// Bırakma hedefi olarak vurgulanan öğe.
    private var dropTarget: Int? {
        didSet {
            guard oldValue != dropTarget else { return }
            for index in [oldValue, dropTarget].compactMap({ $0 }) {
                (item(at: IndexPath(item: index, section: 0)) as? FileIconItem)?.isDropTarget = index == dropTarget
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    /// Arkadaki pencerede ilk tıklama da seçer (Finder gibi).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func index(at event: NSEvent) -> Int? {
        indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item
    }

    // MARK: Yazarak seçme (Windows gibi: adın başı yazılır; aynı harfe tekrar basmak sıradakine geçer)

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .function])
        guard mods.isEmpty, let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else {
            return super.keyDown(with: event)
        }
        if Date().timeIntervalSince(lastTyped) > 1 { typed = "" }
        // Boşluk yalnızca bir adın ortasında yazıya katılır; tek başına Hızlı Bakış'tır.
        if typed.isEmpty, chars == " " { return super.keyDown(with: event) }
        lastTyped = Date()
        typed += chars
        if let match = typeSelectMatch() { onTypeSelect?(match) } else { NSSound.beep() }
    }

    private func typeSelectMatch() -> Int? {
        let count = numberOfItems(inSection: 0)
        guard count > 0 else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        let current = selectionIndexPaths.map(\.item).min()
        // Aynı harf tekrarlanıyorsa o harfle başlayan bir sonraki öğe.
        let repeated = typed.count > 1 && Set(typed.lowercased()).count == 1
        let prefix = repeated ? String(typed.prefix(1)) : typed
        let start = repeated || typed.count == 1 ? ((current ?? -1) + 1) : (current ?? 0)
        for offset in 0..<count {
            let i = (start + offset) % count
            if let name = nameProvider?(i), name.range(of: prefix, options: options) != nil { return i }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let clicked = index(at: event)
        super.mouseDown(with: event)
        if event.clickCount == 2, let clicked { onDoubleClick?(clicked) }
    }

    /// Windows gibi: seçili olmayan öğeye sağ tık yalnızca onu seçer; boş alanda seçim kalkar.
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        if let index = index(at: event) {
            let path = IndexPath(item: index, section: 0)
            if !selectionIndexPaths.contains(path) {
                deselectAll(nil)
                selectItems(at: [path], scrollPosition: [])
                delegate?.collectionView?(self, didSelectItemsAt: [path])
            }
            return menuProvider?(index)
        }
        deselectAll(nil)
        delegate?.collectionView?(self, didDeselectItemsAt: [])
        return menuProvider?(-1)
    }

    // MARK: Bırakma hedefi (klasör öğesinin üstüne ya da boş alana)

    private func target(_ sender: NSDraggingInfo) -> Int? {
        indexPathForItem(at: convert(sender.draggingLocation, from: nil))?.item
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        var index = target(sender)
        var operation = validateDrop?(sender, index) ?? []
        if index != nil, operation.isEmpty {   // dosyanın üstü: klasörün kendisine bırak
            index = nil
            operation = validateDrop?(sender, nil) ?? []
        }
        dropTarget = index
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropTarget = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let index = dropTarget
        dropTarget = nil
        return acceptDrop?(sender, index) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dropTarget = nil }
}

/// Izgaradaki tek öğe: simge (ya da küçük resim) ve ad.
@MainActor
final class FileIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconItem")

    private(set) var url: URL?
    var mode: ViewMode = .mediumIcons {
        didSet { (view as? FileIconItemView)?.mode = mode; view.needsLayout = true }
    }
    var isDropTarget = false {
        didSet { (view as? FileIconItemView)?.isDropTarget = isDropTarget }
    }

    override var isSelected: Bool {
        didSet { (view as? FileIconItemView)?.isSelectedItem = isSelected }
    }

    override func loadView() {
        let itemView = FileIconItemView()
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(wrappingLabelWithString: "")
        text.font = .systemFont(ofSize: 12)
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.isBordered = false
        itemView.addSubview(image)
        itemView.addSubview(text)
        itemView.imageView = image
        itemView.textField = text
        imageView = image
        textField = text
        view = itemView
    }

    func configure(_ item: FileItem, mode: ViewMode, cut: Bool) {
        url = item.url
        self.mode = mode
        textField?.stringValue = item.displayName
        textField?.toolTip = item.displayName
        textField?.textColor = item.isHidden ? .secondaryLabelColor : .labelColor
        view.alphaValue = cut ? 0.45 : 1
        imageView?.alphaValue = item.isHidden ? 0.5 : 1
        imageView?.image = Thumbnails.icon(for: item.url, size: mode.iconSize)
        if mode.iconSize >= 48 && !item.isDirectory {
            Thumbnails.thumbnail(for: item.url, size: mode.iconSize) { [weak self] image in
                guard let self, self.url == item.url, self.mode == mode else { return }
                self.imageView?.image = image
            }
        }
    }
}

/// Öğenin görünümü: düzen (satır ya da simge altında ad) ve seçim/bırakma vurgusu.
@MainActor
final class FileIconItemView: NSView {
    weak var imageView: NSImageView?
    weak var textField: NSTextField?
    var mode: ViewMode = .mediumIcons
    var isSelectedItem = false { didSet { needsDisplay = true } }
    var isDropTarget = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        guard let imageView, let textField else { return }
        if mode.isRowLayout {
            imageView.frame = NSRect(x: 4, y: (b.height - 16) / 2, width: 16, height: 16)
            textField.maximumNumberOfLines = 1
            textField.alignment = .left
            textField.lineBreakMode = .byTruncatingTail
            textField.frame = NSRect(x: 24, y: (b.height - 16) / 2, width: b.width - 28, height: 16)
        } else {
            let size = mode.iconSize
            imageView.frame = NSRect(x: (b.width - size) / 2, y: 6, width: size, height: size)
            textField.maximumNumberOfLines = 2
            textField.alignment = .center
            textField.lineBreakMode = .byTruncatingMiddle
            textField.frame = NSRect(x: 4, y: size + 10, width: b.width - 8, height: b.height - size - 12)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelectedItem || isDropTarget else { return }
        let accent = Theme.current.accentColor
        let focused = (enclosingScrollView?.documentView).map { window?.firstResponder === $0 } ?? false
        (isDropTarget ? accent.withAlphaComponent(0.35) : accent.withAlphaComponent(focused ? 0.30 : 0.15)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// Simgeler ve küçük resimler (Quick Look ile), boyuta göre önbellekte.
@MainActor
enum Thumbnails {
    /// Üst sınır: fotoğraf klasörlerinde her küçük resim ~1 MB tutar; sınır dolunca en eskiler atılır, gerekirse yeniden üretilir.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Görüntünün bellekteki yaklaşık boyutu (bayt): en büyük temsilinin pikselleri × 4.
    private static func cost(of image: NSImage, fallbackSize: CGFloat) -> Int {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        let side = Int(fallbackSize * (NSScreen.main?.backingScaleFactor ?? 2))
        return max(pixels, side * side) * 4
    }

    static func icon(for url: URL, size: CGFloat) -> NSImage {
        if url.isRemote { return RemoteIcons.icon(for: url, size: size) }
        let key = "icon|\(Int(size))|\(url.path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: size, height: size)
        // Sistem simgesi 2048 px'e kadar temsil taşır ama yalnızca çizildiği boyutta yer tutar; maliyet o boyuttan.
        let side = Int(size * (NSScreen.main?.backingScaleFactor ?? 2))
        cache.setObject(image, forKey: key, cost: side * side * 4)
        return image
    }

    /// Dosyanın içeriğinden küçük resim (resim, PDF, video …); yoksa çağrılmaz, simge kalır.
    static func thumbnail(for url: URL, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        guard !url.isRemote else { return }   // sunucudaki dosyanın içeriği indirilmeden okunamaz
        let key = "thumb|\(Int(size))|\(url.path)"
        if let cached = cache.object(forKey: key as NSString) { return completion(cached) }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    cache.setObject(image, forKey: key as NSString, cost: cost(of: image, fallbackSize: size))
                    completion(image)
                }
            }
        }
    }

    static func clear() { cache.removeAllObjects() }
}
