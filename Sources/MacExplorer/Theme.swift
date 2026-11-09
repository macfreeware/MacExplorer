import AppKit

/// Aydınlık / karanlık görünüm (Ayarlar ▸ Görünüm).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Renk teması. Her renk aydınlık ve karanlık görünümde ayrı tanımlıdır; görünüm değişince kendiliğinden uyar.
/// `system` teması macOS'un kendi renklerini kullanır (nil renkler).
struct Theme: Identifiable, Equatable {
    let id: String
    /// Vurgu: etkin panel çizgisi, seçili satır, adres çubuğu odağı.
    let accent: NSColor?
    /// Sekme çubuğunun zemini.
    let strip: NSColor?
    /// Seçili sekme ve gezinme çubuğu.
    let chrome: NSColor?
    /// Dosya listesinin zemini.
    let content: NSColor?
    /// Kenar çubuğuna hafif renk tonu.
    let sidebarTint: NSColor?

    static func == (a: Theme, b: Theme) -> Bool { a.id == b.id }

    var title: String {
        switch id {
        case "ocean": return String(localized: "Okyanus", bundle: .live)
        case "forest": return String(localized: "Orman", bundle: .live)
        case "sunset": return String(localized: "Gün Batımı", bundle: .live)
        case "lavender": return String(localized: "Lavanta", bundle: .live)
        case "graphite": return String(localized: "Grafit", bundle: .live)
        case "midnight": return String(localized: "Gece Yarısı", bundle: .live)
        case "cherry": return String(localized: "Kiraz", bundle: .live)
        case "sand": return String(localized: "Kum", bundle: .live)
        case "mint": return String(localized: "Nane", bundle: .live)
        case "amber": return String(localized: "Kehribar", bundle: .live)
        case "aubergine": return String(localized: "Patlıcan", bundle: .live)
        case "olive": return String(localized: "Zeytin", bundle: .live)
        case "contrast": return String(localized: "Yüksek Karşıtlık", bundle: .live)
        default: return String(localized: "Sistem", bundle: .live)
        }
    }

    // Kullanılan renkler (temada yoksa sistem rengi)
    var accentColor: NSColor { accent ?? .controlAccentColor }
    var stripColor: NSColor { strip ?? .underPageBackgroundColor }
    var chromeColor: NSColor { chrome ?? .controlBackgroundColor }
    var contentColor: NSColor { content ?? .controlBackgroundColor }

    static let system = Theme(id: "system", accent: nil, strip: nil, chrome: nil, content: nil, sidebarTint: nil)

    static let all: [Theme] = [
        system,
        make("ocean", accent: (0x1E88E5, 0x4FA3F7), strip: (0xDCEAF7, 0x0F1E2E), chrome: (0xF3F8FD, 0x172A3D), content: (0xFFFFFF, 0x101B27)),
        make("forest", accent: (0x2E7D32, 0x5CBF63), strip: (0xDCEADB, 0x0F1F18), chrome: (0xF3F9F2, 0x18291F), content: (0xFFFFFF, 0x0F1913)),
        make("sunset", accent: (0xE8590C, 0xFF8A4C), strip: (0xF7E3D6, 0x2A1711), chrome: (0xFDF5EF, 0x33211A), content: (0xFFFEFC, 0x1D130F)),
        make("lavender", accent: (0x7E57C2, 0xA98BE8), strip: (0xE7E0F4, 0x1C1628), chrome: (0xF7F4FC, 0x262036), content: (0xFFFFFF, 0x16121F)),
        make("graphite", accent: (0x5F6B7A, 0x9AA7B8), strip: (0xE3E5E8, 0x191B1E), chrome: (0xF5F6F7, 0x232629), content: (0xFFFFFF, 0x151719)),
        make("midnight", accent: (0x3949AB, 0x7C8CF0), strip: (0xDDE1F2, 0x0E1226), chrome: (0xF4F5FB, 0x171B33), content: (0xFFFFFF, 0x0D1020)),
        make("cherry", accent: (0xC2185B, 0xF06292), strip: (0xF6DCE5, 0x2A0F18), chrome: (0xFDF3F6, 0x331720), content: (0xFFFFFF, 0x1C0B11)),
        make("sand", accent: (0x9C6B3E, 0xD7A86E), strip: (0xEFE6D8, 0x231C14), chrome: (0xFBF7F0, 0x2C241A), content: (0xFFFDF9, 0x18130D)),
        make("mint", accent: (0x00897B, 0x4DD0C4), strip: (0xD7EFEC, 0x0C1F1D), chrome: (0xF2FAF9, 0x142B28), content: (0xFFFFFF, 0x0B1715)),
        make("amber", accent: (0xE67E00, 0xFFB74D), strip: (0xFBE9CC, 0x261A08), chrome: (0xFFF8EC, 0x302210), content: (0xFFFFFF, 0x1A1206)),
        make("aubergine", accent: (0x8E24AA, 0xCE93D8), strip: (0xEADCF0, 0x1E0F24), chrome: (0xFAF4FC, 0x29162F), content: (0xFFFFFF, 0x150A19)),
        make("olive", accent: (0x6B7F1A, 0xB5C95A), strip: (0xE7EBD6, 0x191C0E), chrome: (0xF8FAF1, 0x222615), content: (0xFFFFFF, 0x12140A)),
        // Görme kolaylığı: saf siyah / beyaz zemin, güçlü mavi vurgu
        make("contrast", accent: (0x0040DD, 0x409CFF), strip: (0xE0E0E0, 0x000000), chrome: (0xFFFFFF, 0x0A0A0A), content: (0xFFFFFF, 0x000000)),
    ]

    private static func make(_ id: String, accent: (Int, Int), strip: (Int, Int), chrome: (Int, Int), content: (Int, Int)) -> Theme {
        let a = dynamic(accent)
        return Theme(id: id, accent: a, strip: dynamic(strip), chrome: dynamic(chrome), content: dynamic(content),
                     sidebarTint: NSColor(name: nil) { appearance in
                         a.resolved(for: appearance).withAlphaComponent(appearance.isDark ? 0.10 : 0.07)
                     })
    }

    private static func dynamic(_ hex: (light: Int, dark: Int)) -> NSColor {
        NSColor(name: nil) { $0.isDark ? NSColor(hex: hex.dark) : NSColor(hex: hex.light) }
    }

    // MARK: Seçili tema

    static let didChange = Notification.Name("ThemeDidChange")

    static var current: Theme {
        let id = UserDefaults.standard.string(forKey: Preferences.Key.theme) ?? "system"
        return all.first { $0.id == id } ?? .system
    }

    /// Kayıtlı görünümü uygulama geneline uygular (açılışta ve Ayarlar'da değişince).
    @MainActor
    static func applyAppearance() {
        let mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Preferences.Key.appearance) ?? "") ?? .system
        NSApp.appearance = mode.appearance
    }
}

extension NSWindow {
    /// Pencereyi başka bir pencerenin ortasına yerleştirir (o yoksa ekranın ortasına); ekran dışına taşmaz.
    func center(over parent: NSWindow?) {
        layoutIfNeeded()
        guard let parent, parent.isVisible, let screen = parent.screen ?? NSScreen.main else { return center() }
        let size = frame.size, p = parent.frame, visible = screen.visibleFrame
        var origin = NSPoint(x: p.midX - size.width / 2, y: p.midY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        setFrameOrigin(origin)
    }

    /// İlerleme pencereleri: ana pencerenin üstüne bağlanır. Ana pencereye tıklanınca arkasına düşmez, onunla birlikte
    /// taşınır; başka uygulamaların önüne çıkmaz. Pencere menüsünde de listelenir.
    func showAttached(over owner: NSWindow?) {
        if isVisible, owner == nil || self.parent === owner { return orderFront(nil) }
        center(over: owner)
        isExcludedFromWindowsMenu = false
        if let owner, owner.isVisible {
            self.parent?.removeChildWindow(self)
            owner.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func hideAttached() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Dinamik rengin belirli görünümdeki karşılığı.
    func resolved(for appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance { result = self.usingColorSpace(.sRGB) ?? self }
        return result
    }
}

/// Temanın seçim rengiyle çizilen satır (Sistem temasında macOS'un kendi seçimi kullanılır).
final class ThemedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // Sistem temasında macOS'un vurgu rengi
        let accent = Theme.current.accent ?? .controlAccentColor
        let color = isEmphasized ? accent : accent.withAlphaComponent(effectiveAppearance.isDark ? 0.35 : 0.22)
        color.setFill()
        let rect = bounds.insetBy(dx: 4, dy: 1)
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    /// Vurgulu seçimde yazılar beyaz; soluk seçimde normal renkte kalsın.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }

    /// Bölüm başlıkları (Hızlı erişim, Bu Mac) zeminsiz.
    override func drawBackground(in dirtyRect: NSRect) {
        if !isGroupRowStyle { super.drawBackground(in: dirtyRect) }
    }
}

extension NSAlert {
    /// Silme soruları klavyeyle de yanıtlanabilsin (Windows gibi): Return ilk düğme (Sil), Esc ikinci (İptal).
    /// macOS, tehlikeli işlem düğmesine Return'ü kendiliğinden bağlamaz.
    func confirmsWithKeyboard() {
        guard buttons.count >= 2 else { return }
        // NSAlert, gösterilirken tehlikeli düğmenin tuşunu siler: atama gösterildikten hemen sonra yapılır.
        let apply = { [weak self] in
            guard let self, self.buttons.count >= 2 else { return }
            self.buttons[0].keyEquivalent = "\r"
            self.buttons[1].keyEquivalent = "\u{1b}"
            self.window.makeFirstResponder(self.buttons[0])
        }
        apply()
        DispatchQueue.main.async { MainActor.assumeIsolated { apply() } }
    }
}
