import AppKit
import MacExplorerCore

/// Uzun süren dosya işlemlerini arka planda çalıştırır: ilerleme penceresi, çakışma soruları, hata raporu.
@MainActor
enum FileOperations {
    /// Kopyala / taşı. Bitince `completion` ana iş parçacığında çağrılır.
    static func transfer(_ kind: TransferKind, _ sources: [URL], to destination: URL, window: NSWindow?,
                         completion: @escaping (TransferResult) -> Void = { _ in }) {
        guard !sources.isEmpty else { return }
        let transfer = FileTransfer(kind: kind, sources: sources, destination: destination, copySuffix: String(localized: "Kopya", bundle: .live))
        let panel = TransferProgressPanel(kind: kind, count: sources.count, destination: destination)
        panel.onCancel = { transfer.cancel() }
        let answers = ConflictAnswers()

        transfer.onConflict = { conflict in
            // Soru ana kuyruk bloğu yerine run loop üzerinden sorulur: pencere açıkken ana kuyruk
            // (klasör izleme, ilerleme, diğer işlemler) çalışmaya devam eder.
            let answered = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var answer = ConflictResolution.cancel
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    // Soru açıkken ilerleme penceresi onu örtmesin.
                    panel.beginQuestion()
                    answers.resolve(conflict, window: window) { result in
                        panel.endQuestion(over: window)
                        answer = result
                        answered.signal()
                    }
                }
            }
            answered.wait()
            return answer
        }
        transfer.onProgress = { progress in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { panel.update(progress) }
            }
        }
        // Kısa işlemlerde pencere hiç görünmesin.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { panel.showIfRunning(over: window) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = transfer.run()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    panel.finish()
                    report(result.errors, window: window)
                    UndoCenter.shared.register(result.undo, name: kind == .copy ? String(localized: "Kopyala", bundle: .live) : String(localized: "Taşı", bundle: .live))
                    completion(result)
                }
            }
        }
    }

    /// Çöp Sepeti'ne taşır (Windows'taki Geri Dönüşüm Kutusu gibi onay sormadan).
    static func moveToTrash(_ urls: [URL], window: NSWindow?) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Geri almak öğeleri çöpten eski yerlerine taşır.
            let result = FileUndo.perform(urls.map { .trash($0) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    UndoCenter.shared.register(result.inverse, name: String(localized: "Sil", bundle: .live))
                    report(result.errors, window: window,
                           message: String(localized: "Bazı öğeler Çöp Sepeti’ne taşınamadı.", bundle: .live),
                           hint: String(localized: "Kalıcı olarak silmek için Shift+Delete (⌥⌘⌫) kullanabilirsiniz.", bundle: .live))
                }
            }
        }
    }

    /// Onay sorup kalıcı olarak siler (Shift+Delete).
    static func deletePermanently(_ urls: [URL], window: NSWindow?) {
        guard !urls.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? String(localized: "“\(urls[0].lastPathComponent)” kalıcı olarak silinsin mi?", bundle: .live)
            : String(localized: "Bu \(urls.count) öğe kalıcı olarak silinsin mi?", bundle: .live)
        alert.informativeText = String(localized: "Bu işlem geri alınamaz.", bundle: .live)
        let delete = alert.addButton(withTitle: String(localized: "Sil", bundle: .live))
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        alert.confirmsWithKeyboard()
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                var errors: [TransferError] = []
                for url in urls {
                    do { try FileManager.default.removeItem(at: url) }
                    catch { errors.append(TransferError(url: url, failure: .system(error.localizedDescription))) }
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { report(errors, window: window, message: String(localized: "Bazı öğeler silinemedi.", bundle: .live)) }
                }
            }
        }
    }

    static func report(_ errors: [TransferError], window: NSWindow?,
                       message: String = String(localized: "Bazı öğeler aktarılamadı.", bundle: .live), hint: String? = nil) {
        guard !errors.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        var lines = errors.prefix(6).map { error -> String in
            let reason: String
            switch error.failure {
            case .destinationInsideSource: reason = String(localized: "Hedef klasör, kaynak klasörün bir alt klasörü.", bundle: .live)
            case .system(let text): reason = text
            }
            return "“\(error.url.lastPathComponent)”: \(reason)"
        }
        if errors.count > 6 { lines.append(String(localized: "… ve \(errors.count - 6) öğe daha", bundle: .live)) }
        if let hint { lines.append("\n" + hint) }
        alert.informativeText = lines.joined(separator: "\n")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// Çakışma soruları; "Bunu kalan tüm çakışmalara uygula" seçilirse sonraki çakışmalar sorulmaz.
@MainActor
private final class ConflictAnswers {
    private var applyToAll: ConflictResolution?

    /// Soru, pencere varsa ona bağlı bir sayfa olarak (pencerenin ortasında) sorulur.
    func resolve(_ conflict: TransferConflict, window: NSWindow?, completion: @escaping (ConflictResolution) -> Void) {
        if let applyToAll { return completion(applyToAll) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSWorkspace.shared.icon(forFile: conflict.source.path)
        alert.messageText = String(localized: "Hedefte “\(conflict.destination.lastPathComponent)” adlı bir öğe zaten var.", bundle: .live)
        alert.informativeText = String(localized: "Kaynak: \(Self.describe(conflict.source))", bundle: .live) + "\n"
            + String(localized: "Hedef: \(Self.describe(conflict.destination))", bundle: .live)
        alert.addButton(withTitle: String(localized: "Atla", bundle: .live))
        alert.addButton(withTitle: String(localized: "Değiştir", bundle: .live))
        alert.addButton(withTitle: String(localized: "İkisini de koru", bundle: .live))
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live)).keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Bunu kalan tüm çakışmalara uygula", bundle: .live)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let answer: ConflictResolution
            switch response {
            case .alertFirstButtonReturn: answer = .skip
            case .alertSecondButtonReturn: answer = .replace
            case .alertThirdButtonReturn: answer = .keepBoth
            default: return completion(.cancel)
            }
            if alert.suppressionButton?.state == .on { self?.applyToAll = answer }
            completion(answer)
        }
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private static func describe(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        var parts: [String] = []
        if v?.isDirectory == true { parts.append(String(localized: "klasör", bundle: .live)) }
        else if let size = v?.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let date = v?.contentModificationDate { parts.append(Formatters.date.string(from: date)) }
        return parts.joined(separator: " · ")
    }
}

/// Windows'taki kopyalama penceresi: yüzde, çubuk, geçerli öğe, kalan süre, İptal.
@MainActor
final class TransferProgressPanel: NSWindowController {
    var onCancel: (() -> Void)?

    private let headline = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    /// Geçerli öğenin adı (kendi satırında: ad uzayıp kısaldıkça sayılar kaymasın).
    private let detail = NSTextField(labelWithString: "")
    /// Bayt, öğe sayısı ve kalan süre; rakamlar sabit genişlikte.
    private let stats = NSTextField(labelWithString: "")
    private var finished = false
    /// Çakışma sorusu açık: pencere gizli kalır, soru cevaplanınca yeniden görünür.
    private var questionOpen = false
    private let started = Date()
    private let remaining: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = 1
        f.allowedUnits = [.hour, .minute, .second]
        return f
    }()

    init(kind: TransferKind, count: Int, destination: URL) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = kind == .copy ? String(localized: "Kopyalanıyor", bundle: .live) : String(localized: "Taşınıyor", bundle: .live)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        // Klavye odağını almaz: kopyalama sürerken de pencerede çalışmaya (ve bitince Ctrl+Z'ye) devam edilebilir.
        panel.becomesKeyOnlyIfNeeded = true
        super.init(window: panel)

        let target = FileManager.default.displayName(atPath: destination.path)
        headline.stringValue = kind == .copy
            ? String(localized: "\(count) öğe “\(target)” klasörüne kopyalanıyor", bundle: .live)
            : String(localized: "\(count) öğe “\(target)” klasörüne taşınıyor", bundle: .live)
        headline.lineBreakMode = .byTruncatingMiddle
        percent.font = .systemFont(ofSize: 17, weight: .medium)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.style = .bar
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        stats.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stats.textColor = .secondaryLabelColor
        stats.lineBreakMode = .byTruncatingTail
        let cancel = NSButton(title: String(localized: "İptal", bundle: .live), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [headline, percent, bar, detail, stats, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.setCustomSpacing(3, after: detail)
        stack.setCustomSpacing(14, after: stats)
        // Sabit genişlik: uzun dosya adları pencereyi genişletip içeriği kaydırmasın.
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        headline.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40).isActive = true
        detail.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40).isActive = true
        stats.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
        update(TransferProgress())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    func update(_ p: TransferProgress) {
        guard !finished else { return }
        let fraction = p.fraction
        bar.doubleValue = fraction
        percent.stringValue = String(localized: "%\(Int((fraction * 100).rounded(.down))) tamamlandı", bundle: .live)
        detail.stringValue = p.currentName.isEmpty ? " " : String(localized: "Ad: \(p.currentName)", bundle: .live)
        var parts: [String] = []
        if p.totalBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: p.completedBytes, countStyle: .file) + " / "
                         + ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file))
        }
        if p.totalItems > 1 {
            parts.append(String(localized: "\(p.completedItems) / \(p.totalItems) öğe", bundle: .live))
        }
        let elapsed = Date().timeIntervalSince(started)
        if fraction > 0.02, elapsed > 1.5, let text = remaining.string(from: elapsed / fraction - elapsed) {
            parts.append(String(localized: "Kalan süre: yaklaşık \(text)", bundle: .live))
        }
        stats.stringValue = parts.isEmpty ? " " : parts.joined(separator: "  ·  ")
    }

    func beginQuestion() {
        questionOpen = true
        window?.hideAttached()
    }

    func endQuestion(over parent: NSWindow?) {
        questionOpen = false
        // Kısa işlerde pencere hiç görünmemişse yine gecikmeli gösterilir.
        if Date().timeIntervalSince(started) > 0.5 { showIfRunning(over: parent) }
    }

    func showIfRunning(over parent: NSWindow?) {
        guard !finished, !questionOpen else { return }
        window?.showAttached(over: parent)
    }

    func finish() {
        finished = true
        window?.hideAttached()
        close()
    }

    /// İptal: pencere hemen kapanır; kopyalama o anki veri parçasını bitirip durur, yarım dosya arka planda silinir.
    @objc private func cancelClicked() {
        onCancel?()
        finished = true
        window?.hideAttached()
    }
}
