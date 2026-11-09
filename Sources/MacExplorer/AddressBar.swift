import AppKit
import FTPKit
import MacExplorerCore

/// Windows Gezgini'nin adres çubuğu: klasör yolu tam adlarla, tıklanabilir adımlar halinde ("Macintosh HD › Kullanıcılar › ali").
/// Yer yetmezse baştaki adımlar "«" menüsüne geçer; her adımın "›" düğmesi o klasörün alt klasörlerini listeler.
/// Boş alana tıklayınca (ya da ⌘L / Ctrl+L / Alt+D) yol yazılabilir hale gelir. Enter gider, Esc vazgeçer.
@MainActor
final class AddressBar: NSView, NSTextFieldDelegate {
    /// Yol adımına ya da menüden bir klasöre tıklandı.
    var onSelectURL: ((URL) -> Void)?
    /// Yazılan metinle Enter'a basıldı.
    var onSubmit: ((String) -> Void)?
    /// Düzenleme Esc ya da Enter ile bitti (odak listeye dönsün).
    var onFinishEditing: (() -> Void)?

    var url: URL = FileManager.default.homeDirectoryForCurrentUser {
        didSet { rebuildSegments() }
    }

    var isEditing: Bool { !field.isHidden }

    private struct Segment {
        let url: URL
        let button: NSButton
        let chevron: NSButton
    }

    private let field = NSTextField()
    private var segments: [Segment] = []
    private lazy var overflow: NSButton = {
        let b = NSButton(title: "«", target: self, action: #selector(overflowClicked(_:)))
        b.isBordered = false
        b.font = .systemFont(ofSize: 13, weight: .semibold)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = String(localized: "Önceki klasörler", bundle: .live)
        addSubview(b)
        return b
    }()
    /// Görünmeyen (taşan) baştaki adımlar.
    private var hiddenSegments: [Segment] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.isHidden = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        // Yazma moduna her zaman: sağdaki boş alan (yol ne kadar uzun olursa olsun ayrılır) ya da kısayol.
        toolTip = String(localized: "Yolu yazmak için sağdaki boş alana tıklayın ya da ⌘L / Ctrl+L / Alt+D'ye basın.", bundle: .live)
        rebuildSegments()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        (isEditing ? Theme.current.accentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isEditing ? 1.5 : 1
        path.stroke()
    }

    // MARK: Adımlar

    /// Kökten (diskin kendisi) bu klasöre kadar adımlar. Başka disklerde yol o diskin adıyla başlar.
    private func rebuildSegments() {
        segments.forEach { $0.button.removeFromSuperview(); $0.chevron.removeFromSuperview() }
        if url.isRemote { return rebuildRemoteSegments() }
        let urls = Self.localChain(url)
        segments = urls.enumerated().map { index, url in
            makeSegment(index: index, count: urls.count, url: url, title: FileManager.default.displayName(atPath: url.path))
        }
        showSegments(!isEditing)
        needsLayout = true
    }

    /// Diskin kökünden bu klasöre kadar (başka disklerde o diskin adıyla başlar).
    private static func localChain(_ url: URL) -> [URL] {
        let target = url.standardizedFileURL
        let volume = (try? target.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL ?? URL(fileURLWithPath: "/")
        var urls: [URL] = []
        var current = target
        while true {
            urls.insert(current, at: 0)
            if current.path == volume.path || current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        return urls
    }

    /// Sunucuda: ilk adım sunucu (kullanıcı@sunucu, kök klasör), sonra yolun klasörleri.
    private func rebuildRemoteSegments() {
        let paths = RemotePath.ancestors(RemoteURL.path(of: url))
        let user = URLComponents(url: url, resolvingAgainstBaseURL: false)?.user
        let server = Archives.isArchive(url) ? Archives.displayName(url) : [user, url.host].compactMap { $0 }.joined(separator: "@")
        // Arşivin içi: önce arşivin bulunduğu yerel klasörler.
        let local = Archives.file(for: url).map { Self.localChain($0.deletingLastPathComponent()) } ?? []
        let count = local.count + paths.count
        segments = local.enumerated().map { index, folder in
            makeSegment(index: index, count: count, url: folder, title: FileManager.default.displayName(atPath: folder.path))
        } + paths.enumerated().map { offset, path in
            let target = RemoteURL.replacingPath(url, with: path)
            return makeSegment(index: local.count + offset, count: count, url: target, title: offset == 0 ? server : RemotePath.name(path))
        }
        showSegments(!isEditing)
        needsLayout = true
    }

    private func makeSegment(index: Int, count: Int, url: URL, title: String) -> Segment {
        let button = NSButton(title: title, target: self, action: #selector(segmentClicked(_:)))
        button.isBordered = true
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.font = .systemFont(ofSize: 12, weight: index == count - 1 ? .semibold : .regular)
        button.lineBreakMode = .byTruncatingMiddle
        button.toolTip = url.isRemote ? url.absoluteString.removingPercentEncoding : url.path
        let archiveRoot = Archives.isArchive(url) && RemoteURL.path(of: url) == "/"
        if index == 0 || archiveRoot {
            let icon = archiveRoot ? (Archives.file(for: url).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                : url.isRemote
                ? (NSImage(systemSymbolName: url.scheme == "sftp" ? "terminal" : "server.rack", accessibilityDescription: nil) ?? NSImage())
                : NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 14, height: 14)
            button.image = icon
            button.imagePosition = .imageLeading
        }
        let chevron = NSButton(title: "›", target: self, action: #selector(chevronClicked(_:)))
        chevron.font = .systemFont(ofSize: 14, weight: .medium)
        chevron.isBordered = true
        chevron.bezelStyle = .accessoryBarAction
        chevron.showsBorderOnlyWhileMouseInside = true
        chevron.contentTintColor = .secondaryLabelColor
        chevron.toolTip = String(localized: "Alt klasörler", bundle: .live)
        button.tag = index
        chevron.tag = index
        addSubview(button)
        addSubview(chevron)
        return Segment(url: url, button: button, chevron: chevron)
    }

    private func showSegments(_ show: Bool) {
        segments.forEach { $0.button.isHidden = !show; $0.chevron.isHidden = !show }
        overflow.isHidden = !show || hiddenSegments.isEmpty
    }

    /// Sondan başa doğru sığan adımlar gösterilir; sığmayanlar "«" menüsüne gider. Sağda yazma için boşluk kalır.
    override func layout() {
        super.layout()
        guard !isEditing else { return }
        let height: CGFloat = 22, y = (bounds.height - height) / 2
        let chevronWidth: CGFloat = 16, overflowWidth: CGFloat = 20, editRoom: CGFloat = 44
        let available = bounds.width - 6 - editRoom
        let widths = segments.map { ceil($0.button.fittingSize.width) + 2 }

        var first = segments.count - 1
        var used = widths.last.map { $0 + chevronWidth } ?? 0
        while first > 0 {
            let next = widths[first - 1] + chevronWidth
            let needsOverflow = first - 1 > 0
            if used + next + (needsOverflow ? overflowWidth : 0) > available { break }
            used += next
            first -= 1
        }
        hiddenSegments = Array(segments[..<first])
        overflow.isHidden = hiddenSegments.isEmpty

        var x: CGFloat = 4
        if !hiddenSegments.isEmpty {
            overflow.frame = NSRect(x: x, y: y, width: overflowWidth, height: height)
            x += overflowWidth
        }
        for (i, segment) in segments.enumerated() {
            let visible = i >= first
            segment.button.isHidden = !visible
            segment.chevron.isHidden = !visible
            guard visible else { continue }
            // Tek başına bile sığmayan son adım kısaltılır.
            let width = min(widths[i], max(40, available - (x - 4) - chevronWidth))
            segment.button.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width
            segment.chevron.frame = NSRect(x: x, y: y, width: chevronWidth, height: height)
            x += chevronWidth
        }
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard segments.indices.contains(sender.tag) else { return }
        onSelectURL?(segments[sender.tag].url)
    }

    /// "›": o klasörün alt klasörleri (Windows gibi); seçilen klasöre gidilir.
    @objc private func chevronClicked(_ sender: NSButton) {
        guard segments.indices.contains(sender.tag) else { return }
        let parent = segments[sender.tag].url
        if parent.isRemote { return remoteChevronClicked(sender, parent: parent) }
        let menu = NSMenu()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let options: FileManager.DirectoryEnumerationOptions = Preferences.showHidden ? [] : [.skipsHiddenFiles]
        let children = ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: keys, options: options)) ?? [])
            .filter { let v = try? $0.resourceValues(forKeys: Set(keys)); return v?.isDirectory == true && v?.isPackage != true }
            .sorted { FileManager.default.displayName(atPath: $0.path).localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending }
        let next = segments.indices.contains(sender.tag + 1) ? segments[sender.tag + 1].url.path : nil
        for child in children.prefix(80) {
            let item = ClosureMenuItem(title: FileManager.default.displayName(atPath: child.path)) { [weak self] in self?.onSelectURL?(child) }
            let icon = NSWorkspace.shared.icon(forFile: child.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if child.standardizedFileURL.path == next { item.state = .on }   // yoldaki bir sonraki klasör işaretli
            menu.addItem(item)
        }
        if children.isEmpty {
            let empty = NSMenuItem(title: String(localized: "Alt klasör yok", bundle: .live), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else if children.count > 80 {
            let more = NSMenuItem(title: String(localized: "… ve \(children.count - 80) klasör daha", bundle: .live), action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 3), in: sender)
    }

    /// Sunucudaki alt klasörler: listelenir, sonra menü açılır.
    private func remoteChevronClicked(_ sender: NSButton, parent: URL) {
        guard let connection = RemoteSessions.existing(for: parent) else { return }
        let path = RemoteURL.path(of: parent)
        let next = segments.indices.contains(sender.tag + 1) ? RemoteURL.path(of: segments[sender.tag + 1].url) : nil
        let showHidden = Preferences.showHidden
        Task { [weak self] in
            let files = (try? await connection.run { try await $0.list(path).files }) ?? []
            guard let self else { return }
            let folders = files.filter { $0.isDirectory && (showHidden || !$0.name.hasPrefix(".")) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let menu = NSMenu()
            for folder in folders.prefix(80) {
                let child = parent.appendingPathComponent(folder.name, isDirectory: true)
                let item = ClosureMenuItem(title: folder.name) { [weak self] in self?.onSelectURL?(child) }
                item.image = RemoteIcons.icon(for: child, size: 16)
                if RemotePath.join(path, folder.name) == next { item.state = .on }
                menu.addItem(item)
            }
            if folders.isEmpty {
                let empty = NSMenuItem(title: String(localized: "Alt klasör yok", bundle: .live), action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 3), in: sender)
        }
    }

    /// "«": görünmeyen baştaki klasörler.
    @objc private func overflowClicked(_ sender: NSButton) {
        let menu = NSMenu()
        for segment in hiddenSegments.reversed() {
            let url = segment.url
            let item = ClosureMenuItem(title: segment.button.title) { [weak self] in self?.onSelectURL?(url) }
            if url.isRemote {
                item.image = RemoteIcons.icon(for: URL(string: url.absoluteString + "/") ?? url, size: 16)
            } else {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 3), in: sender)
    }

    // MARK: Yazma

    /// Yolun sağındaki boş alana tıklama: yazma moduna geç.
    override func mouseDown(with event: NSEvent) {
        if !isEditing { beginEditing() }
    }

    func beginEditing() {
        field.stringValue = url.isRemote
            ? (RemoteURL.replacingPath(url, with: RemoteURL.path(of: url)).absoluteString.removingPercentEncoding ?? url.absoluteString)
            : url.path
        field.isHidden = false
        showSegments(false)
        needsDisplay = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        guard isEditing else { return }
        field.isHidden = true
        showSegments(true)
        needsLayout = true
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue
            endEditing()
            onFinishEditing?()
            onSubmit?(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            onFinishEditing?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing() }
}
