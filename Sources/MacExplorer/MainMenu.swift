import AppKit

/// Menü çubuğu. Hedefi boş (nil) olan komutlar yanıtlayıcı zinciriyle öndeki pencereye gider.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static func functionKey(_ code: Int) -> String {
        String(Character(UnicodeScalar(UInt32(code))!))
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "MacExplorer")
        menu.addItem(item(String(localized: "MacExplorer Hakkında", bundle: .live), #selector(AppDelegate.showAbout(_:))))
        menu.addItem(item(String(localized: "Güncellemeleri Denetle…", bundle: .live), #selector(AppDelegate.checkForUpdates(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Ayarlar…", bundle: .live), #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "MacExplorer’ı Gizle", bundle: .live), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(String(localized: "Diğerlerini Gizle", bundle: .live), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(String(localized: "Tümünü Göster", bundle: .live), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "MacExplorer’dan Çık", bundle: .live), #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Dosya", bundle: .live))
        menu.addItem(item(String(localized: "Yeni Pencere", bundle: .live), #selector(AppDelegate.newWindowHere(_:)), "n"))
        menu.addItem(item(String(localized: "Yeni Sekme", bundle: .live), #selector(BrowserWindowController.newFileTab(_:)), "t"))
        menu.addItem(item(String(localized: "Yeni Klasör", bundle: .live), #selector(BrowserWindowController.newFolder(_:)), "n", [.command, .shift]))
        menu.addItem(item(String(localized: "Yeni Metin Belgesi", bundle: .live), #selector(BrowserWindowController.newTextDocument(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Aç", bundle: .live), #selector(BrowserWindowController.openSelection(_:)), functionKey(NSDownArrowFunctionKey)))
        menu.addItem(item(String(localized: "Hızlı Bakış", bundle: .live), #selector(BrowserWindowController.quickLook(_:)), "y"))
        menu.addItem(item(String(localized: "Yeniden Adlandır", bundle: .live), #selector(BrowserWindowController.renameSelection(_:)), functionKey(NSF2FunctionKey), []))
        menu.addItem(item(String(localized: "Sil", bundle: .live), #selector(BrowserWindowController.moveToTrash(_:)), "\u{8}"))
        menu.addItem(item(String(localized: "Kalıcı Olarak Sil", bundle: .live), #selector(BrowserWindowController.deletePermanently(_:)), "\u{8}", [.command, .option]))
        menu.addItem(item(String(localized: "Özellikler", bundle: .live), #selector(BrowserWindowController.showProperties(_:)), "i"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Yolu Kopyala", bundle: .live), #selector(BrowserWindowController.copyFolderPath(_:)), "c", [.command, .option]))
        menu.addItem(item(String(localized: "Terminalde Aç", bundle: .live), #selector(BrowserWindowController.openInTerminal(_:)), "t", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Diğer Panele Kopyala", bundle: .live), #selector(BrowserWindowController.copyToOtherPane(_:)), functionKey(NSF5FunctionKey), []))
        menu.addItem(item(String(localized: "Diğer Panele Taşı", bundle: .live), #selector(BrowserWindowController.moveToOtherPane(_:)), functionKey(NSF6FunctionKey), []))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Sekmeyi Kapat", bundle: .live), #selector(BrowserWindowController.closeFileTab(_:)), "w"))
        menu.addItem(item(String(localized: "Pencereyi Kapat", bundle: .live), #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Düzen", bundle: .live))
        menu.addItem(item(String(localized: "Geri Al", bundle: .live), Selector(("undo:")), "z"))
        menu.addItem(item(String(localized: "Yinele", bundle: .live), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Kes", bundle: .live), #selector(NSText.cut(_:)), "x"))
        menu.addItem(item(String(localized: "Kopyala", bundle: .live), #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(String(localized: "Yapıştır", bundle: .live), #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Tümünü Seç", bundle: .live), #selector(NSText.selectAll(_:)), "a"))
        // mc gibi sayısal tuş takımından da: + / − / * (bkz. BrowserWindowController.handleKeyDown)
        menu.addItem(item(String(localized: "Seç… (Num +)", bundle: .live), #selector(BrowserWindowController.selectMatchingItems(_:))))
        menu.addItem(item(String(localized: "Seçimi Kaldır… (Num −)", bundle: .live), #selector(BrowserWindowController.deselectMatchingItems(_:))))
        menu.addItem(item(String(localized: "Seçimi Tersine Çevir (Num *)", bundle: .live), #selector(BrowserWindowController.invertItemSelection(_:))))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Görünüm", bundle: .live))
        for (i, mode) in ViewMode.allCases.enumerated() {
            let entry = item(mode.title, #selector(BrowserWindowController.selectViewMode(_:)), "\(i + 1)")
            entry.tag = i
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Çift Panel", bundle: .live), #selector(BrowserWindowController.toggleDualPane(_:)), functionKey(NSF9FunctionKey), []))
        menu.addItem(item(String(localized: "Kenar Çubuğu", bundle: .live), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item(String(localized: "Önizleme Bölmesi", bundle: .live), #selector(BrowserWindowController.togglePreviewPane(_:)), "p", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Gizli Öğeleri Göster", bundle: .live), #selector(BrowserWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Yenile", bundle: .live), #selector(BrowserWindowController.refresh(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Tam Ekran", bundle: .live), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Git", bundle: .live))
        menu.addItem(item(String(localized: "Geri", bundle: .live), #selector(BrowserWindowController.goBack(_:)), "["))
        menu.addItem(item(String(localized: "İleri", bundle: .live), #selector(BrowserWindowController.goForward(_:)), "]"))
        menu.addItem(item(String(localized: "Üst Klasör", bundle: .live), #selector(BrowserWindowController.goUp(_:)), functionKey(NSUpArrowFunctionKey)))
        menu.addItem(.separator())
        let home = FileManager.default.homeDirectoryForCurrentUser
        let places: [(String, URL, String, NSEvent.ModifierFlags)] = [
            (String(localized: "Masaüstü", bundle: .live), home.appendingPathComponent("Desktop"), "d", [.command, .shift]),
            (String(localized: "Belgeler", bundle: .live), home.appendingPathComponent("Documents"), "o", [.command, .shift]),
            (String(localized: "İndirilenler", bundle: .live), home.appendingPathComponent("Downloads"), "l", [.command, .option]),
            (String(localized: "Ana Klasör", bundle: .live), home, "h", [.command, .shift]),
            (String(localized: "Uygulamalar", bundle: .live), URL(fileURLWithPath: "/Applications"), "a", [.command, .shift]),
        ]
        for (title, url, key, modifiers) in places {
            let entry = item(title, #selector(BrowserWindowController.goToPlace(_:)), key, modifiers)
            entry.representedObject = url
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Sunucuya Bağlan…", bundle: .live), #selector(BrowserWindowController.connectToServer(_:)), "k"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Adres Çubuğu", bundle: .live), #selector(BrowserWindowController.focusAddressBar(_:)), "l"))
        menu.addItem(item(String(localized: "Ara", bundle: .live), #selector(BrowserWindowController.focusSearch(_:)), "f"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Sonraki Sekme", bundle: .live), #selector(BrowserWindowController.nextFileTab(_:)), "]", [.command, .shift]))
        menu.addItem(item(String(localized: "Önceki Sekme", bundle: .live), #selector(BrowserWindowController.previousFileTab(_:)), "[", [.command, .shift]))
        menu.addItem(item(String(localized: "Diğer Panel", bundle: .live), #selector(BrowserWindowController.switchPane(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Yardım", bundle: .live))
        menu.addItem(item(String(localized: "Klavye Kısayolları", bundle: .live), #selector(AppDelegate.showShortcuts(_:)), functionKey(NSF1FunctionKey), []))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "MacRAR Sayfası", bundle: .live), #selector(AppDelegate.openMacRARPage(_:))))
        menu.addItem(item(String(localized: "MacExplorer Kaynak Kodu", bundle: .live), #selector(AppDelegate.openSourcePage(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Pencere", bundle: .live))
        menu.addItem(item(String(localized: "Küçült", bundle: .live), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Büyüt", bundle: .live), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Tümünü Öne Getir", bundle: .live), #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
