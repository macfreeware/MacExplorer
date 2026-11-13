import AppKit

/// Sağ tık menülerindeki simgeler (SF Symbols). Uygulama simgesi taşıyan öğeler (Birlikte aç, Düzenle, MacRAR) kendi simgelerini korur.
enum MenuSymbol {
    static func image(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Komuta göre simge adı.
    static let byAction: [String: String] = [
        "menuOpen": "arrow.up.forward.square",
        "menuOpenItemLocation": "folder",
        "menuMount": "externaldrive.badge.plus",
        "menuBrowseArchive": "archivebox",
        "menuOpenInNewTab": "plus.square.on.square",
        "menuOpenInNewWindow": "macwindow.badge.plus",
        "menuQuickLook": "eye",
        "menuEdit": "pencil",
        "menuShare": "square.and.arrow.up",
        "menuCut": "scissors",
        "menuCopy": "doc.on.doc",
        "menuCopyAsPath": "text.quote",
        "menuCopyAddress": "link",
        "menuCopyFolderAddress": "link",
        "menuCopyFolderPath": "text.quote",
        "menuCreateShortcut": "arrowshape.turn.up.right",
        "menuPasteShortcut": "arrowshape.turn.up.right",
        "menuDelete": "trash",
        "menuRename": "character.cursor.ibeam",
        "menuShowInFinder": "macwindow.on.rectangle",
        "menuOpenSelectionInTerminal": "apple.terminal",
        "menuOpenInTerminal": "apple.terminal",
        "menuProperties": "info.circle",
        "menuDownload": "arrow.down.circle",
        "menuUpload": "arrow.up.circle",
        "menuRefresh": "arrow.clockwise",
        "menuToggleHidden": "eye.slash",
        "menuPaste": "doc.on.clipboard",
        "menuDisconnect": "xmark.circle",
        "menuExtractAll": "arrow.up.bin",
        "menuOpenArchiveInMacRAR": "archivebox",
        "menuCloseArchive": "xmark.circle",
        "menuOpenWithOther": "ellipsis.circle",
        "menuSendToZip": "doc.zipper",
        "menuSendToDesktop": "menubar.dock.rectangle",
        "menuEjectVolume": "eject",
    ]

    /// macOS 27 menülerdeki SF Symbol simgelerini varsayılan olarak gizler; görünür kalmalarını açıkça isteriz.
    /// (Uygulama simgeleri gibi sembol olmayan resimler zaten gösterilir.)
    /// Özellik (`preferredImageVisibility`, macOS 27) bu derleyicinin AppKit arayüzünde görünmediği için çalışma anında,
    /// varsa ayarlanır; eski macOS sürümlerinde yoktur ve simgeler zaten gösterilir. 1 = `.visible`.
    static func show(_ item: NSMenuItem) {
        guard item.responds(to: Selector(("setPreferredImageVisibility:"))) else { return }
        item.setValue(1, forKey: "preferredImageVisibility")
    }

    /// Menüdeki ve alt menülerdeki simgeli tüm öğeleri görünür kılar.
    static func showAll(in menu: NSMenu) {
        for item in menu.items {
            if item.image != nil { show(item) }
            if let sub = item.submenu { showAll(in: sub) }
        }
    }

    static func image(for action: Selector?) -> NSImage? {
        guard let action else { return nil }
        let name = NSStringFromSelector(action).replacingOccurrences(of: ":", with: "")
        return byAction[name].flatMap(image)
    }
}

extension NSMenuItem {
    /// Sağ tık menüsü simgesi: SF Symbol adını verip macOS 27'de de görünür kılar.
    func setSymbol(_ name: String) {
        image = MenuSymbol.image(name)
        MenuSymbol.show(self)
    }
}
