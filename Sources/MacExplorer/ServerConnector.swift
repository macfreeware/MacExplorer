import AppKit
import NetFS

/// Ağ paylaşımlarını (SMB, WebDAV, AFP, NFS) macOS'un kendi sistemiyle (Finder'ın ⌘K'sı ile aynı) disk gibi bağlar.
/// Bağlanan disk "Bu Mac" altında görünür; MacExplorer'ın tüm özellikleri onunla çalışır.
/// Parola verilmezse macOS kendi giriş penceresini açar (orada "Anahtar Zinciri'nde hatırla" da seçilebilir);
/// paylaşım adı verilmezse macOS paylaşım listesini gösterir.
@MainActor
enum ServerConnector {
    /// Bağlanır; başarılı olursa bağlanan klasörle `completion` çağrılır.
    static func connect(_ server: ServerBookmark, password: String?, over window: NSWindow?, completion: @escaping (URL) -> Void) {
        // SFTP / FTP disk olarak bağlanmaz: panelde uzak klasör olarak açılır.
        if server.kind.isRemote {
            Task { if let url = await RemoteSessions.open(server, password: password, window: window) { completion(url) } }
            return
        }
        guard let url = server.url else {
            return show(String(localized: "Sunucu adresi geçersiz.", bundle: .live), detail: nil, over: window)
        }
        let panel = ConnectingPanel(server: server)
        let openOptions = NSMutableDictionary(dictionary: [kNAUIOptionKey: kNAUIOptionAllowUI])
        let mountOptions = NSMutableDictionary()
        var request: AsyncRequestID?
        var timedOut = false
        let user = server.kind.usesCredentials && !server.user.isEmpty ? server.user as CFString : nil
        let pass = server.kind.usesCredentials ? password.map { $0 as CFString } : nil
        let status = NetFSMountURLAsync(url as CFURL, nil, user, pass, openOptions, mountOptions, &request, DispatchQueue.main) { status, _, mountpoints in
            MainActor.assumeIsolated {
                panel.close()
                guard !timedOut else { return }   // süre doldu: kullanıcıya zaten soruldu
                let paths = (mountpoints as? [String]) ?? []
                // Zaten bağlıysa (EEXIST) macOS bağlı yeri yine döndürür.
                if let first = paths.first, status == 0 || status == EEXIST {
                    ServerStore.noteConnected(server)
                    completion(URL(fileURLWithPath: first))
                } else if status != 0 {
                    report(status, server: server, over: window)
                }
            }
        }
        if status != 0 {
            report(status, server: server, over: window)
            return
        }
        panel.onCancel = { if let request { NetFSMountURLCancel(request) } }
        // Kapalı bilgisayarda macOS uzun süre hata vermeden bekler: 30 saniyede vazgeçilir, Tekrar Dene sunulur.
        panel.timeout = connectTimeout
        panel.onTimeout = {
            timedOut = true
            if let request { NetFSMountURLCancel(request) }
            panel.close()
            askRetry(server, password: password, over: window, completion: completion)
        }
        panel.show(over: window)
    }

    static let connectTimeout = 30

    /// Süre doldu: kullanıcıya nedenini söyler, isterse yeniden dener.
    private static func askRetry(_ server: ServerBookmark, password: String?, over window: NSWindow?, completion: @escaping (URL) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(server.displayName)” sunucusuna bağlanılamadı.", bundle: .live)
        alert.informativeText = String(localized: "Sunucu \(connectTimeout) saniye içinde yanıt vermedi. Bilgisayarın açık ve ağa bağlı olduğundan, adresin doğru olduğundan emin olun.", bundle: .live)
        alert.addButton(withTitle: String(localized: "Tekrar Dene", bundle: .live))
        alert.addButton(withTitle: String(localized: "Tamam", bundle: .live))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            // Sayfa kapanma animasyonu bitsin, sonra yeni bağlanma sayfası açılsın.
            DispatchQueue.main.async { connect(server, password: password, over: window, completion: completion) }
        }
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    /// Bağlı ağ diskini çıkarır.
    /// Diski çıkarır. Yerel disklerde (disk görüntüsü, USB) `hdiutil detach`: APFS biçimli DMG'lerde
    /// NSWorkspace yalnızca birimi ayırır, görüntü bağlı kalırdı. Olmazsa NSWorkspace ile denenir.
    static func eject(_ volume: URL, over window: NSWindow?) {
        let isLocal = (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? false
        Task {
            // Çıkarma beklerken (ör. kapanmış sunucu) arayüz donmasın: hepsi arka planda.
            let error = await Task.detached { () -> NSError? in
                if isLocal, let result = Shell.runWithError("/usr/bin/hdiutil", ["detach", volume.path]), result.status == 0 { return nil }
                if let error = unmount(volume) {
                    // Sunucu kapanınca macOS ağ diskini ilk denemede ayıramayıp "meşgul" der; ikincisinde ayırır.
                    guard !isLocal else { return error }
                    try? await Task.sleep(for: .seconds(1))
                    return unmount(volume)
                }
                return nil
            }.value
            guard let error else { return }
            askForceEject(volume, error: error, over: window)
        }
    }

    nonisolated private static func unmount(_ volume: URL) -> NSError? {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume); return nil } catch { return error as NSError }
    }

    /// Finder gibi: disk kullanılıyorsa (ya da sunucu yanıt vermiyorsa) zorla çıkarmayı önerir.
    private static func askForceEject(_ volume: URL, error: NSError, over window: NSWindow?) {
        let busy = error.code == Int(fBsyErr) || error.code == Int(EBUSY)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(volume.lastPathComponent)” çıkarılamadı.", bundle: .live)
        alert.informativeText = busy
            ? String(localized: "Bir uygulama bu diski kullanıyor ya da sunucu yanıt vermiyor. Zorla çıkarırsanız açık dosyalardaki kaydedilmemiş değişiklikler kaybolabilir.", bundle: .live)
            : error.localizedDescription
        alert.addButton(withTitle: String(localized: "Zorla Çıkar", bundle: .live))
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        alert.buttons.first?.hasDestructiveAction = true
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                let failure = await Task.detached { () -> String? in
                    if let r = Shell.runWithError("/usr/sbin/diskutil", ["unmount", "force", volume.path]), r.status == 0 { return nil }
                    if let r = Shell.runWithError("/sbin/umount", ["-f", volume.path]), r.status == 0 { return nil }
                    return String(localized: "Disk zorla da çıkarılamadı.", bundle: .live)
                }.value
                if let failure { show(String(localized: "“\(volume.lastPathComponent)” çıkarılamadı.", bundle: .live), detail: failure, over: window) }
            }
        }
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    // MARK: Hatalar

    private static func report(_ status: Int32, server: ServerBookmark, over window: NSWindow?) {
        let userCancelled: Int32 = -128
        guard status != userCancelled, status != ECANCELED else { return }
        let detail: String
        switch status {
        case EAUTH, EACCES, EPERM: detail = String(localized: "Kullanıcı adı ya da parola yanlış.", bundle: .live)
        case ECONNREFUSED: detail = String(localized: "Sunucu bağlantıyı reddetti. Sunucuda bu paylaşım türünün açık olduğundan emin olun.", bundle: .live)
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN: detail = String(localized: "Sunucuya ulaşılamıyor. Adı ya da adresi ve ağ bağlantınızı kontrol edin.", bundle: .live)
        case ETIMEDOUT: detail = String(localized: "Sunucu yanıt vermedi (zaman aşımı).", bundle: .live)
        case ENOENT: detail = String(localized: "Sunucuda böyle bir paylaşım ya da klasör yok.", bundle: .live)
        case -5998: detail = String(localized: "Sunucuda bağlanılabilecek paylaşım yok.", bundle: .live)
        case -5999: detail = String(localized: "Hesabın bağlanma yetkisi yok.", bundle: .live)
        case -5045: detail = String(localized: "Parolanın değiştirilmesi gerekiyor.", bundle: .live)
        default: detail = NSError(domain: NSPOSIXErrorDomain, code: Int(status)).localizedDescription + " (\(status))"
        }
        show(String(localized: "“\(server.displayName)” sunucusuna bağlanılamadı.", bundle: .live), detail: detail, over: window)
    }

    private static func show(_ message: String, detail: String?, over window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail ?? ""
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// Bağlanırken gösterilen küçük sayfa: dönen gösterge, geçen süre ve İptal. `timeout` verilirse o kadar saniye
/// sonra `onTimeout` çağrılır; macOS'un kendi giriş penceresi açıkken (uygulama arka plandayken) süre işlemez.
@MainActor
final class ConnectingPanel: NSObject {
    var onCancel: (() -> Void)?
    var timeout: Int?
    var onTimeout: (() -> Void)?
    private let elapsedLabel = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var elapsed = 0
    private var activeElapsed = 0
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 90), styleMask: [.titled], backing: .buffered, defer: true)
    private weak var parent: NSWindow?

    init(server: ServerBookmark) {
        super.init()
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: String(localized: "“\(server.displayName)” sunucusuna bağlanılıyor…", bundle: .live))
        label.lineBreakMode = .byTruncatingMiddle
        let cancel = NSButton(title: String(localized: "İptal", bundle: .live), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        // Standart macOS sayfası düzeni: yazı üstte, İptal sağ altta; kenar boşlukları eşit (20 pt).
        let content = NSView()
        for view in [spinner, label, elapsedLabel, cancel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 380),
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            spinner.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            cancel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            elapsedLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            elapsedLabel.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
        ])
        panel.contentView = content
    }

    func show(over window: NSWindow?) {
        parent = window
        if let window, window.attachedSheet == nil { window.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
        updateElapsed()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        elapsed += 1
        if NSApp.isActive || RemoteSessions.isDebugRun { activeElapsed += 1 }
        updateElapsed()
        if let timeout, activeElapsed >= timeout {
            stopTimer()
            onTimeout?()
        }
    }

    private func updateElapsed() {
        elapsedLabel.stringValue = String(localized: "Geçen süre: \(elapsed) sn", bundle: .live)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func close() {
        stopTimer()
        if let parent, panel.sheetParent === parent { parent.endSheet(panel) } else { panel.orderOut(nil) }
    }

    @objc private func cancelClicked() {
        onCancel?()
        close()
    }
}
