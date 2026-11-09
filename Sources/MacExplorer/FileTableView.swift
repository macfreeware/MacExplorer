import AppKit
import FTPKit
import MacExplorerCore

/// Ayrıntılar görünümünün tablosu. Odaklandığında paneli etkin yapar.
@MainActor
final class FileTableView: NSTableView {
    var onBecomeFirstResponder: (() -> Void)?
    /// Sağ tık menüsü: tıklanan satır (boş alanda -1) için menüyü kurar.
    var menuProvider: ((Int) -> NSMenu?)?

    /// Windows gibi: seçili olmayan satıra sağ tıklamak yalnızca onu seçer; seçili satırda seçim korunur;
    /// boş alana sağ tıklamak seçimi kaldırır ve klasörün menüsünü açar.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        if row >= 0 {
            if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            deselectAll(nil)
        }
        return menuProvider?(row)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    /// Arkadaki pencerede ilk tıklama da seçer (Finder gibi), yalnızca pencereyi öne getirmez.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Dikdörtgen seçim (Windows Gezgini gibi)

    /// Ad (simge + yazı) üzerinden sürükleme dosyayı sürükler; boş alandan ya da diğer sütunlardan
    /// sürükleme seçim dikdörtgeni çizer. ⌘ ya da Shift ile mevcut seçime eklenir.
    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard event.clickCount == 1, !isOnName(start) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let extending = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        let base = extending ? selectedRowIndexes : IndexSet()
        let clickedRow = row(at: start)
        let band = SelectionBandView()
        var dragged = false

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            autoscroll(with: next)
            let point = convert(next.locationInWindow, from: nil)
            if !dragged {
                guard hypot(point.x - start.x, point.y - start.y) > 3 else { continue }
                dragged = true
                addSubview(band)
            }
            let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            band.frame = rect
            var selection = base
            selection.formUnion(rowsIntersecting(rect))
            if selection != selectedRowIndexes { selectRowIndexes(selection, byExtendingSelection: false) }
        }
        band.removeFromSuperview()

        // Sürüklenmeden bırakıldı: sıradan tıklama
        if !dragged {
            if clickedRow >= 0 {
                if event.modifierFlags.contains(.command) {
                    selectedRowIndexes.contains(clickedRow) ? deselectRow(clickedRow) : selectRowIndexes([clickedRow], byExtendingSelection: true)
                } else if event.modifierFlags.contains(.shift), let anchor = selectedRowIndexes.first {
                    selectRowIndexes(IndexSet(integersIn: min(anchor, clickedRow)...max(anchor, clickedRow)), byExtendingSelection: false)
                } else {
                    selectRowIndexes([clickedRow], byExtendingSelection: false)
                }
            } else if !extending {
                deselectAll(nil)
            }
        }
    }

    /// Dikdörtgenin değdiği satırlar (dikdörtgen son satırın altındaki boş alana taşsa da).
    private func rowsIntersecting(_ rect: NSRect) -> IndexSet {
        guard numberOfRows > 0 else { return [] }
        let top = max(rect.minY, 0), bottom = min(rect.maxY, self.rect(ofRow: numberOfRows - 1).maxY)
        guard bottom > top else { return [] }
        let first = row(at: NSPoint(x: 1, y: top)), last = row(at: NSPoint(x: 1, y: bottom - 0.5))
        guard first >= 0, last >= first else { return [] }
        return IndexSet(integersIn: first...last)
    }

    /// Nokta, satırın "Ad" hücresindeki simgenin ya da yazının üstünde mi?
    private func isOnName(_ point: NSPoint) -> Bool {
        let row = row(at: point)
        let nameColumn = column(withIdentifier: .init(SortColumn.name.rawValue))
        guard row >= 0, nameColumn >= 0, column(at: point) == nameColumn,
              let cell = view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? NSTableCellView else { return false }
        var hit = NSRect.zero
        if let image = cell.imageView { hit = hit.union(convert(image.frame, from: cell)) }
        if let text = cell.textField {
            var frame = convert(text.frame, from: cell)
            frame.size.width = min(frame.width, text.intrinsicContentSize.width + 4)
            hit = hit.union(frame)
        }
        return hit.insetBy(dx: -2, dy: -2).contains(point)
    }
}

/// Sürüklenirken çizilen yarı saydam seçim dikdörtgeni.
final class SelectionBandView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let accent = Theme.current.accentColor
        accent.withAlphaComponent(0.15).setFill()
        bounds.fill()
        accent.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Bir sekmenin durumu: geçmiş, sıralama, arama metni ve (sekme değişince geri yüklenen) seçim.
@MainActor
final class TabState {
    var history: NavigationHistory
    var sort = FileSort()
    var filter = ""
    var selectedURLs: [URL] = []
    var viewMode = ViewMode.saved

    init(url: URL) { history = NavigationHistory(start: url) }

    var url: URL { history.current }
    /// Sekme başlığı: klasörün sistemdeki görünen adı ("/" → "Macintosh HD"); sunucuda klasör adı, kökte sunucu adı.
    var title: String {
        if url.isRemote {
            let path = RemoteURL.path(of: url)
            if path == "/" { return Archives.isArchive(url) ? Archives.displayName(url) : (url.host ?? "/") }
            return RemotePath.name(path)
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}

/// Dosya simgeleri (16 pt), yola göre önbellekte.
@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        if url.isRemote { return RemoteIcons.icon(for: url, size: 16) }
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        cache.setObject(image, forKey: key)
        return image
    }

    static func clear() { cache.removeAllObjects() }
}

enum Formatters {
    /// Windows'taki gibi kısa tarih + saat ("03.11.2026 14:01").
    /// Liste tarihleri: bölge biçiminde ama gün ve ay iki haneli ("01.10.2023 21:45"), sütunda alt alta hizalı dursun.
    @MainActor static let date: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("ddMMyyyyjjmm")
        return f
    }()
}

/// Klavyeyle işaretlemede imlecin olduğu satırın çevresindeki ince çerçeve (tıklamaları geçirir).
final class CursorOutlineView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1.5
        layer?.zPosition = 10
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    override func updateLayer() { layer?.borderColor = NSColor.controlAccentColor.cgColor }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
