import AppKit

/// Geliştirme aracı: `MACEXPLORER_SNAPSHOT=<klasör>` ile başlatılınca öndeki pencerenin görüntüsünü
/// (ekran kaydı izni gerektirmeden, pencerenin kendi çiziminden) PNG olarak kaydeder ve uygulamayı kapatır.
/// `MACEXPLORER_SNAPSHOT_STEPS` virgülle ayrılmış adımlar alır (bkz. `BrowserWindowController.debugPerform`).
@MainActor
enum DebugSnapshot {
    static func runIfRequested(_ controller: BrowserWindowController) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MACEXPLORER_SNAPSHOT"] else { return }
        let steps = (env["MACEXPLORER_SNAPSHOT_STEPS"] ?? "").split(separator: ",").map(String.init)
        // Klasörler eşzamansız yüklendiği için adımlar arasında beklenir.
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.7) {
                // Dil değişiminden sonra eski pencere kapanır; adımlar öndeki gezgin penceresinde sürer.
                let current = (NSApp.keyWindow?.windowController as? BrowserWindowController)
                    ?? NSApp.windows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first { $0.window?.isVisible == true }
                    ?? controller
                current.debugPerform(step)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2 + Double(steps.count) * 0.7) {
            // Önde bir uyarı (sayfa ya da kalıcı pencere) varsa o da kaydedilir.
            if let alert = NSApp.modalWindow ?? controller.window?.attachedSheet {
                save(alert, to: URL(fileURLWithPath: dir).appendingPathComponent("alert.png"))
            }
            // Dil değişince pencereler yeniden kurulur: öndeki gezgin penceresi kaydedilir.
            let front = NSApp.windows.first { $0.isVisible && $0.windowController is BrowserWindowController } ?? controller.window
            if let main = front { save(main, to: URL(fileURLWithPath: dir).appendingPathComponent("window.png")) }
            for (i, other) in NSApp.windows.filter({ $0.isVisible && $0 !== controller.window && $0 !== NSApp.modalWindow }).enumerated() {
                save(other, to: URL(fileURLWithPath: dir).appendingPathComponent("other-\(i).png"))
            }
            exit(0)   // kalıcı bir uyarı açıkken de kapanabilsin
        }
    }

    /// Menüyü girintili metin olarak yazar (menüler pencere görüntüsüne çizilmez).
    static func dump(_ menu: NSMenu, depth: Int = 0) {
        for item in menu.items {
            let pad = String(repeating: "    ", count: depth)
            print(item.isSeparatorItem ? pad + "────" : pad + item.title + (item.isEnabled ? "" : "  (kapalı)") + (item.state == .on ? "  ✓" : "")
                  + (item.image.map { "  [simge \(Int($0.size.width))pt]" } ?? ""))
            if let sub = item.submenu { dump(sub, depth: depth + 1) }
        }
        print("")
    }

    /// Adımlar sırasında (örn. kopyalama sürerken) bir pencereyi kaydeder.
    static func capture(_ window: NSWindow, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MACEXPLORER_SNAPSHOT"] else { return }
        save(window, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
