import AppKit
import MacExplorerCore

/// Disk görüntüleri (ISO, DMG, IMG, CDR): Windows'taki "Bağla" gibi bağlanır, disk "Bu Mac" altında görünür ve
/// MacExplorer'da açılır. Klasörden ISO ya da DMG oluşturulabilir. Hepsi macOS'un kendi `hdiutil` aracıyla.
@MainActor
enum DiskImage {
    static let extensions: Set<String> = ["iso", "dmg", "img", "cdr", "toast", "sparseimage"]

    static func isDiskImage(_ url: URL) -> Bool {
        !url.isRemote && extensions.contains(url.pathExtension.lowercased())
    }

    // MARK: Bağla

    /// Bağlar; bağlanan diskin kök klasörüyle `completion` çağrılır. Parolalı ya da lisans sözleşmeli görüntülerde
    /// macOS'un kendi Disk Görüntüsü Bağlayıcısı açılır (parolayı o sorar); bağlanınca yine `completion` çağrılır.
    static func mount(_ url: URL, window: NSWindow?, completion: @escaping (URL) -> Void) {
        Task {
            let result = await Task.detached { attach(url) }.value
            switch result {
            case .mounted(let point):
                completion(point)
            case .needsUI:
                openWithSystemMounter(url, completion: completion)
            case .failed(let message):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "“\(url.lastPathComponent)” bağlanamadı.", bundle: .live)
                alert.informativeText = message
                await RemoteSessions.present(alert, window: window)
            }
        }
    }

    private enum AttachResult: Sendable { case mounted(URL), needsUI, failed(String) }

    nonisolated private static func attach(_ url: URL) -> AttachResult {
        // -nobrowse yok: disk Finder'da da görünsün. -noautoopen: Finder kendi penceresini açmasın.
        guard let result = Shell.runWithError("/usr/bin/hdiutil", ["attach", "-plist", "-noverify", "-noautoopen", url.path]) else {
            return .failed(String(localized: "hdiutil çalıştırılamadı.", bundle: .live))
        }
        if result.status == 0,
           let plist = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]],
           let point = entities.compactMap({ $0["mount-point"] as? String }).first {
            return .mounted(URL(fileURLWithPath: point, isDirectory: true))
        }
        let error = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        // Parola (şifreli DMG) ya da lisans sözleşmesi: terminalsiz hdiutil soramaz.
        let lower = error.lowercased()
        if lower.contains("authentication") || lower.contains("password") || lower.contains("passphrase") || lower.contains("license") || lower.contains("agreement") {
            return .needsUI
        }
        if result.status == 0 { return .failed(String(localized: "Görüntüde bağlanabilecek bir bölüm yok.", bundle: .live)) }
        return .failed(error.isEmpty ? String(localized: "Bilinmeyen hata (\(result.status)).", bundle: .live) : error)
    }

    private static func openWithSystemMounter(_ url: URL, completion: @escaping (URL) -> Void) {
        var observer: NSObjectProtocol?
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            MainActor.assumeIsolated { completion(volume) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        }
        let mounter = URL(fileURLWithPath: "/System/Library/CoreServices/DiskImageMounter.app")
        NSWorkspace.shared.open([url], withApplicationAt: mounter, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Çıkar

    /// Klasör bir diskin kökü mü ve çıkarılabilir mi (bağlı disk görüntüsü, USB bellek, ağ diski …)?
    static func ejectableVolume(_ url: URL) -> Bool {
        guard !url.isRemote, url.path != "/",
              let v = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey]),
              v.volume?.standardizedFileURL.path == url.standardizedFileURL.path else { return false }
        return v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsInternal == false || v.volumeIsLocal == false
    }

    // MARK: Oluştur

    enum Format { case iso, dmg }

    /// Klasörden disk görüntüsü: ISO (Windows, Linux ve Mac'te açılır; UDF ile 4 GB'tan büyük dosyalar da) ya da
    /// DMG (Mac'e özgü, sıkıştırılmış). Görüntü klasörün yanına oluşturulur.
    static func create(_ format: Format, from folder: URL, window: NSWindow?, completion: @escaping (URL) -> Void) {
        let name = folder.lastPathComponent
        let ext = format == .iso ? "iso" : "dmg"
        let target = FileNaming.uniqueName(for: folder.deletingLastPathComponent().appendingPathComponent("\(name).\(ext)"))
        // Birim adı: ISO'da en çok 32 karakter.
        let volumeName = String(name.prefix(32))
        let args: [String] = format == .iso
            ? ["makehybrid", "-iso", "-joliet", "-udf", "-default-volume-name", volumeName, "-o", target.path, folder.path]
            : ["create", "-puppetstrings", "-srcfolder", folder.path, "-volname", volumeName, "-format", "UDZO", target.path]

        let panel = ProgressPanel(title: format == .iso ? String(localized: "ISO oluşturuluyor", bundle: .live) : String(localized: "DMG oluşturuluyor", bundle: .live),
                                  message: String(localized: "“\(name)” → \(target.lastPathComponent)", bundle: .live))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        panel.onCancel = { process.terminate() }
        out.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            // -puppetstrings (yalnızca create; makehybrid yüzde vermez, çubuk belirsiz kalır): "PERCENT:42.5"
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("PERCENT:") {
                if let value = Double(line.dropFirst(8)), value >= 0 {
                    DispatchQueue.main.async { MainActor.assumeIsolated { panel.update(value / 100) } }
                }
            }
        }
        process.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = p.terminationStatus, cancelled = p.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    panel.close()
                    if status == 0 {
                        UndoCenter.shared.register([.trash(target)], name: String(localized: "Disk Görüntüsü Oluştur", bundle: .live))
                        completion(target)
                    } else {
                        try? FileManager.default.removeItem(at: target)
                        guard !cancelled else { return }
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = String(localized: "Disk görüntüsü oluşturulamadı.", bundle: .live)
                        alert.informativeText = error.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await RemoteSessions.present(alert, window: window) }
                    }
                }
            }
        }
        do { try process.run() } catch {
            panel.close()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if process.isRunning { panel.show(over: window) } }
    }
}

/// Uzun süren tek bir iş için küçük ilerleme penceresi (yüzde çubuğu ve İptal).
@MainActor
final class ProgressPanel: NSObject {
    var onCancel: (() -> Void)?
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
    private let bar = NSProgressIndicator()
    private var closed = false

    init(title: String, message: String) {
        super.init()
        panel.title = title
        let label = NSTextField(labelWithString: message)
        label.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        let cancel = NSButton(title: String(localized: "İptal", bundle: .live), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 340).isActive = true
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        panel.contentView = stack
    }

    func update(_ fraction: Double) {
        if bar.isIndeterminate { bar.isIndeterminate = false }
        bar.doubleValue = fraction
    }

    func show(over window: NSWindow?) {
        guard !closed else { return }
        panel.showAttached(over: window)
    }

    func close() {
        closed = true
        panel.hideAttached()
    }

    @objc private func cancelClicked() { onCancel?() }
}
