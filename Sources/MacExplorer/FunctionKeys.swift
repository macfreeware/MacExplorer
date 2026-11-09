import AppKit

/// İşlev tuşları: pencerenin altındaki çubukta (Total Commander / Midnight Commander gibi) ve Touch Bar'da aynı düğmeler.
/// F3 Önizle (görüntüle), F4 Düzenle (metin düzenleyicide aç).
/// F5 / F6 çift panelde diğer panele kopyalar / taşır; tek panelde F5 yeniler.
enum FunctionKey: CaseIterable {
    case help, rename, quickLook, edit, copy, move, newFolder, delete, dualPane

    var key: String {
        switch self {
        case .help: return "F1"
        case .rename: return "F2"
        case .quickLook: return "F3"
        case .edit: return "F4"
        case .copy: return "F5"
        case .move: return "F6"
        case .newFolder: return "F7"
        case .delete: return "F8"
        case .dualPane: return "F9"
        }
    }

    func title(dualPane: Bool) -> String {
        switch self {
        case .help: return String(localized: "Yardım", bundle: .live)
        case .rename: return String(localized: "Ad değiştir", bundle: .live)
        case .quickLook: return String(localized: "Önizle", bundle: .live)
        case .edit: return String(localized: "Düzenle", bundle: .live)
        case .copy: return dualPane ? String(localized: "Kopyala", bundle: .live) : String(localized: "Yenile", bundle: .live)
        case .move: return String(localized: "Taşı", bundle: .live)
        case .newFolder: return String(localized: "Yeni klasör", bundle: .live)
        case .delete: return String(localized: "Sil", bundle: .live)
        case .dualPane: return dualPane ? String(localized: "Tek panel", bundle: .live) : String(localized: "Çift panel", bundle: .live)
        }
    }

    /// Touch Bar için kısa ad: sağdaki sistem şeridinin yanında dokuz tuşun hepsi sığsın.
    func shortTitle(dualPane: Bool) -> String {
        switch self {
        case .rename: return String(localized: "Ad", bundle: .live)
        case .newFolder: return String(localized: "Klasör", bundle: .live)
        case .dualPane: return String(localized: "Panel", bundle: .live)
        default: return title(dualPane: dualPane)
        }
    }

    var action: Selector {
        switch self {
        case .help: return #selector(AppDelegate.showShortcuts(_:))
        case .rename: return #selector(BrowserWindowController.renameSelection(_:))
        case .quickLook: return #selector(BrowserWindowController.quickLook(_:))
        case .edit: return #selector(BrowserWindowController.editSelection(_:))
        case .copy: return #selector(BrowserWindowController.functionF5(_:))
        case .move: return #selector(BrowserWindowController.moveToOtherPane(_:))
        case .newFolder: return #selector(BrowserWindowController.newFolder(_:))
        case .delete: return #selector(BrowserWindowController.moveToTrash(_:))
        case .dualPane: return #selector(BrowserWindowController.toggleDualPane(_:))
        }
    }
}

/// Pencerenin altındaki işlev tuşu çubuğu: eşit genişlikte "F5 Kopyala" düğmeleri.
/// Düğmeler elle yerleştirilir: NSStackView (.fillEqually) dar pencerede adlar sığmayınca eşit genişliği bırakıyor ve
/// bazen geri dönmüyordu (düğmeler sola, ortaya ve sağa dağılmış kalıyordu). Dar pencerede adlar kısaltılır.
@MainActor
final class FunctionKeyBar: NSView {
    private var buttons: [(FunctionKey, NSButton)] = []
    private weak var target: AnyObject?
    private let inset: CGFloat = 4
    private let spacing: CGFloat = 1

    init(target: AnyObject) {
        self.target = target
        super.init(frame: .zero)
        for key in FunctionKey.allCases {
            let button = NSButton(title: "", target: target, action: key.action)
            button.isBordered = false
            button.toolTip = key.key
            button.lineBreakMode = .byTruncatingTail
            button.translatesAutoresizingMaskIntoConstraints = true
            buttons.append((key, button))
            addSubview(button)
        }
        update(dualPane: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    /// F5/F6 çift panele göre ad ve durum değiştirir.
    func update(dualPane: Bool) {
        for (key, button) in buttons {
            let title = NSMutableAttributedString(string: key.key + " ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: Theme.current.accentColor,
            ])
            title.append(NSAttributedString(string: key.title(dualPane: dualPane), attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ]))
            button.attributedTitle = title
            button.isEnabled = key != .move || dualPane
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.current.stripColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        // Düğmeler arasında hafif dikey çizgiler
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        for (_, button) in buttons.dropLast() {
            NSRect(x: button.frame.maxX.rounded(), y: 5, width: 1, height: bounds.height - 10).fill()
        }
    }

    /// Geliştirme: düğmelerin çubuktaki x konumu ve genişliği.
    var debugFrames: String {
        buttons.map { key, button in
            "\(key.key) \(Int(button.frame.minX))+\(Int(button.frame.width))"
        }.joined(separator: " ")
    }

    override func layout() {
        super.layout()
        let count = CGFloat(buttons.count)
        let width = max(0, (bounds.width - 2 * inset - spacing * (count - 1)) / count)
        let height = max(0, bounds.height - 1)   // üstteki ayırıcı çizgi
        for (i, (_, button)) in buttons.enumerated() {
            let x = inset + CGFloat(i) * (width + spacing)
            button.frame = NSRect(x: x.rounded(), y: 0, width: width.rounded(.down), height: height)
        }
        needsDisplay = true   // çizgiler düğmelerin yeni yerinde çizilsin
    }
}
