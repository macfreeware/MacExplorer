import AppKit
import MacExplorerCore

/// Dosya işlemlerinin geri alma geçmişi: Windows Gezgini gibi tüm pencereler için tek geçmiş.
/// Düzen ▸ Geri Al (⌘Z / Ctrl+Z) ve Yinele (⇧⌘Z / Ctrl+Y) bunu kullanır; bir metin düzenlenirken pencere
/// kendi metin geçmişini verir (bkz. BrowserWindowController.windowWillReturnUndoManager).
@MainActor
final class UndoCenter {
    static let shared = UndoCenter()
    let manager = UndoManager()

    private init() {
        manager.levelsOfUndo = 50
    }

    /// İşlemi geçmişe ekler; `name` menüde "Geri Al <ad>" olarak görünür.
    func register(_ ops: [FileUndoOp], name: String) {
        guard !ops.isEmpty else { return }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.run(ops, name: name) }
        }
        manager.setActionName(name)
    }

    /// Geri alırken uygulanan adımların tersi kaydedilir: UndoManager bunu "Yinele" olarak saklar.
    private func run(_ ops: [FileUndoOp], name: String) {
        let result = FileUndo.perform(ops)
        register(result.inverse, name: name)
        FileOperations.report(result.errors, window: NSApp.keyWindow,
                              message: String(localized: "Bazı öğeler geri alınamadı.", bundle: .live),
                              hint: String(localized: "Öğe bu arada taşınmış, silinmiş ya da yerinde aynı adlı başka bir öğe oluşmuş olabilir.", bundle: .live))
    }
}
