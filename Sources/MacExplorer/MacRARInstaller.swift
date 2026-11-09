import AppKit
import MacExplorerCore

/// MacRAR kurulu değilse: GitLab sayfası ya da en son kurulum paketini indirip macOS Yükleyici'sinde açma.
@MainActor
enum MacRARInstaller {
    static let page = URL(string: "https://gitlab.com/freeware2/macrar")!
    /// MacRAR README'sindeki "en son sürüm" bağlantısı; GitLab en yeni sürümün paketine yönlendirir.
    static let latestPackage = URL(string: "https://gitlab.com/freeware2/macrar/-/releases/permalink/latest/downloads/MacRAR.pkg")!

    static var isInstalled: Bool {
        // Geliştirme: MACEXPLORER_NO_MACRAR=1 ile "kurulu değil" görünümü denenir.
        if ProcessInfo.processInfo.environment["MACEXPLORER_NO_MACRAR"] == "1" { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacRARBridge.bundleIdentifier) != nil
    }

    static func openPage() { NSWorkspace.shared.open(page) }

    /// Paketi İndirilenler klasörüne indirir ve Yükleyici'de açar; kurulumu kullanıcı Yükleyici'de onaylar.
    static func downloadAndInstall(over parent: NSWindow?) {
        let sheet = DownloadSheet()
        let task = URLSession.shared.downloadTask(with: latestPackage) { temp, response, error in
            let outcome: Result<URL, Error>
            if let temp, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false {
                let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                let name = response?.suggestedFilename ?? "MacRAR.pkg"
                let target = FileNaming.uniqueName(for: downloads.appendingPathComponent(name))
                outcome = Result { try FileManager.default.moveItem(at: temp, to: target); return target }
            } else {
                outcome = .failure(error ?? URLError(.badServerResponse))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    sheet.close()
                    switch outcome {
                    case .success(let pkg):
                        NSWorkspace.shared.open(pkg)
                    case .failure(let error as URLError) where error.code == .cancelled:
                        break
                    case .failure(let error):
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = String(localized: "MacRAR indirilemedi.", bundle: .live)
                        alert.informativeText = error.localizedDescription
                        alert.addButton(withTitle: String(localized: "GitLab sayfasını aç", bundle: .live))
                        alert.addButton(withTitle: String(localized: "Kapat", bundle: .live))
                        if alert.runModal() == .alertFirstButtonReturn { openPage() }
                    }
                }
            }
        }
        sheet.show(task: task, over: parent)
        task.resume()
    }
}

/// İndirme sırasında gösterilen küçük pencere: ilerleme çubuğu ve İptal.
@MainActor
private final class DownloadSheet: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110), styleMask: [.titled], backing: .buffered, defer: true)
    private let bar = NSProgressIndicator()
    private var observation: NSKeyValueObservation?
    private weak var parent: NSWindow?

    func show(task: URLSessionDownloadTask, over parent: NSWindow?) {
        self.parent = parent
        let label = NSTextField(labelWithString: String(localized: "MacRAR’ın en son sürümü indiriliyor…", bundle: .live))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let cancel = NSButton(title: String(localized: "İptal", bundle: .live), target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
        self.task = task
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.bar.doubleValue = value } }
        }
        if let parent, parent.isVisible { parent.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }

    private var task: URLSessionDownloadTask?

    @objc private func cancelClicked() { task?.cancel() }

    func close() {
        observation = nil
        if let parent, panel.sheetParent === parent { parent.endSheet(panel) } else { panel.orderOut(nil) }
    }
}
