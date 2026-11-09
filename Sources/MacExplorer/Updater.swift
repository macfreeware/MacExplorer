import AppKit
import CryptoKit
import MacExplorerCore

/// GitLab'dan kendi kendini güncelleme. Son sürüm `freeware2/macexplorer` projesinin "en son sürüm" adresinden okunur
/// (proje yolu, kimliği değil: depo yeniden kurulsa da adres değişmez). Yeni sürüm varsa notları gösterilir; kabul
/// edilirse `MacExplorer.zip` indirilir, SHA-256 özeti (`MacExplorer.zip.sha256`) ve içindeki uygulamanın kimliği ile
/// sürümü doğrulanır, uygulama yerine konur ve yeniden başlatılır.
/// Depo private iken GitLab "bulunamadı" der: otomatik denetleme sessiz kalır.
@MainActor
enum Updater {
    #if DEBUG
    // Yalnızca geliştirme derlemesinde (scripts/build_app.sh debug): yayımlanan uygulama bu ayarları okumaz.
    // MACEXPLORER_UPDATE_URL başka bir sürüm bilgisi (ör. file:// ile sahte sürüm), MACEXPLORER_UPDATE_PROJECT başka bir
    // GitLab projesi, MACEXPLORER_UPDATE_NO_RELAUNCH kurduktan sonra yeniden başlatmama.
    private static let testURL = ProcessInfo.processInfo.environment["MACEXPLORER_UPDATE_URL"].flatMap(URL.init(string:))
    private static let testProject = ProcessInfo.processInfo.environment["MACEXPLORER_UPDATE_PROJECT"]
    private static let skipsRelaunch = ProcessInfo.processInfo.environment["MACEXPLORER_UPDATE_NO_RELAUNCH"] != nil
    #else
    private static let testURL: URL? = nil
    private static let testProject: String? = nil
    private static let skipsRelaunch = false
    #endif

    private static let project = testProject ?? "freeware2/macexplorer"

    static var apiURL: URL {
        testURL ?? URL(string: "https://gitlab.com/api/v4/projects/\(project.replacingOccurrences(of: "/", with: "%2F"))/releases/permalink/latest")!
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    private static var isRunning = false

    // MARK: Denetleme

    /// Açılışta: ayar açıksa ve son denetlemeden bu yana bir gün geçtiyse sessizce bakar (yalnızca yeni sürüm varsa sorar).
    static func checkAutomatically() {
        guard Preferences.updateAutoCheck, !RemoteSessions.isDebugRun else { return }
        let last = Date(timeIntervalSince1970: Preferences.updateLastCheck)
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { check(userInitiated: false) }
    }

    enum Outcome {
        case upToDate, newer(UpdateRelease), failed(String)
    }

    /// Soru sormadan bakar (Hakkında penceresi sonucu kendi içinde yazar).
    static func checkNow() async -> Outcome {
        switch await fetch() {
        case .failure(let message): return .failed(message)
        case .success(let release):
            if !RemoteSessions.isDebugRun { Preferences.updateLastCheck = Date().timeIntervalSince1970 }
            return UpdateInfo.isNewer(release.version, than: currentVersion) ? .newer(release) : .upToDate
        }
    }

    /// Menü / Ayarlar: sonuç her durumda söylenir. Otomatik denetlemede yalnızca yeni sürüm sorulur.
    static func check(userInitiated: Bool, installWithoutAsking: Bool = false) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            let outcome = await checkNow()
            isRunning = false
            switch outcome {
            case .upToDate:
                if userInitiated {
                    inform(String(localized: "MacExplorer güncel.", bundle: .live),
                           String(localized: "Kullandığınız sürüm (\(currentVersion)) en son sürüm.", bundle: .live))
                }
            case .newer(let release):
                if installWithoutAsking { return install(release) }
                if !userInitiated, Preferences.updateSkippedVersion == release.version { return }
                offer(release)
            case .failed(let message):
                if userInitiated { inform(String(localized: "Güncellemeler denetlenemedi.", bundle: .live), message) }
            }
        }
    }

    private enum FetchResult { case success(UpdateRelease), failure(String) }

    private static func fetch() async -> FetchResult {
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failure(http.statusCode == 404
                    ? String(localized: "Sürüm bilgisine ulaşılamadı. Depo henüz herkese açık değilse bu beklenen bir durumdur.", bundle: .live)
                    : httpFailure(http.statusCode))
            }
            return .success(try UpdateInfo.parse(data, allowAnyHost: testURL != nil))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Sorma

    static func offer(_ release: UpdateRelease) {
        if RemoteSessions.isDebugRun { return FileHandle.standardError.write(Data("Güncelleme sunuluyor: \(release.version)\n".utf8)) }
        let alert = NSAlert()
        alert.messageText = String(localized: "MacExplorer \(release.version) hazır", bundle: .live)
        alert.informativeText = String(localized: "Kullandığınız sürüm: \(currentVersion). Güncelleme indirilir, doğrulanır ve MacExplorer yeniden başlatılır; açık pencereler geri gelir.", bundle: .live)
        if !release.notes.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.contentView.bounds)
            text.isEditable = false
            text.autoresizingMask = [.width]
            text.textContainerInset = NSSize(width: 6, height: 6)
            text.font = .systemFont(ofSize: 12)
            text.string = release.notes
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        let writable = UpdateInfo.canReplace(app: Bundle.main.bundleURL)
        let canInstall = release.archive != nil && release.checksum != nil && writable
        if !writable {
            alert.informativeText = String(localized: "Kullandığınız sürüm: \(currentVersion). Bu kopya bulunduğu yerde güncellenemiyor (yazma izni yok); yeni sürümü indirme sayfasından kurabilirsiniz.", bundle: .live)
        }
        alert.addButton(withTitle: canInstall ? String(localized: "Şimdi Güncelle", bundle: .live) : String(localized: "İndirme Sayfasını Aç", bundle: .live))
        alert.addButton(withTitle: String(localized: "Sonra", bundle: .live))
        alert.addButton(withTitle: String(localized: "Bu Sürümü Atla", bundle: .live))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canInstall { install(release) } else if let page = release.page { NSWorkspace.shared.open(page) }
        case .alertThirdButtonReturn:
            Preferences.updateSkippedVersion = release.version
        default:
            break
        }
    }

    private static func inform(_ title: String, _ detail: String, page: URL? = nil) {
        // Deneme çalıştırmalarında ekranda kalıcı uyarı açılmaz; sonuç yalnızca yazılır.
        if RemoteSessions.isDebugRun { return FileHandle.standardError.write(Data("Güncelleme: \(title) | \(detail)\n".utf8)) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "Tamam", bundle: .live))
        if page != nil { alert.addButton(withTitle: String(localized: "İndirme Sayfasını Aç", bundle: .live)) }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn, let page { NSWorkspace.shared.open(page) }
    }

    // MARK: Kurma

    private struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func install(_ release: UpdateRelease) {
        let panel = ProgressPanel(title: String(localized: "MacExplorer güncelleniyor", bundle: .live),
                                  message: String(localized: "Sürüm \(release.version) indiriliyor ve doğrulanıyor…", bundle: .live))
        let work = Task {
            do {
                guard UpdateInfo.canReplace(app: Bundle.main.bundleURL) else {
                    throw UpdateError(message: String(localized: "Bu kopya bulunduğu yerde güncellenemiyor (yazma izni yok).", bundle: .live))
                }
                let (app, work) = try await prepare(release)
                do { try replaceRunningApp(with: app) } catch {
                    try? FileManager.default.removeItem(at: work)
                    throw error
                }
                try? FileManager.default.removeItem(at: work)   // yeniden başlamadan önce: terminate geri dönmez
                panel.close()
                relaunch()
            } catch is CancellationError {
                panel.close()
            } catch {
                panel.close()
                inform(String(localized: "Güncelleme kurulamadı.", bundle: .live),
                       error.localizedDescription + "\n\n" + String(localized: "İsterseniz yeni sürümü indirme sayfasından elle kurabilirsiniz.", bundle: .live),
                       page: release.page)
            }
        }
        panel.onCancel = { work.cancel() }
        panel.show(over: NSApp.keyWindow)
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError(message: httpFailure(http.statusCode))
        }
    }

    /// GitLab, giriş yapılmamış istekleri IP başına sınırlar (429); bu kalıcı bir hata değildir.
    private static func httpFailure(_ code: Int) -> String {
        code == 429
            ? String(localized: "GitLab şu an çok fazla istek aldığı için yanıt vermedi. Bir saat içinde yeniden deneyin.", bundle: .live)
            : String(localized: "GitLab yanıtı: HTTP \(code)", bundle: .live)
    }

    /// İndirir, özeti doğrular, açar ve içindeki uygulamayı denetler; kurulmaya hazır uygulamayı ve geçici klasörü döndürür.
    private static func prepare(_ release: UpdateRelease) async throws -> (app: URL, work: URL) {
        guard let archiveURL = release.archive, let checksumURL = release.checksum else {
            throw UpdateError(message: String(localized: "Sürümde \(UpdateInfo.archiveName) ya da özet dosyası yok.", bundle: .live))
        }
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: checksumURL)
        try requireSuccess(checksumResponse)
        guard let expected = UpdateInfo.parseChecksum(String(decoding: checksumData, as: UTF8.self)) else {
            throw UpdateError(message: String(localized: "Özet dosyası okunamadı.", bundle: .live))
        }
        let (downloaded, archiveResponse) = try await URLSession.shared.download(from: archiveURL)
        try requireSuccess(archiveResponse)
        try Task.checkCancellation()

        // Geçici klasör uygulamayla aynı diskte: değiştirme kopyalama değil yeniden adlandırma olur, yarıda kalamaz.
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: Bundle.main.bundleURL, create: true)
        let zip = work.appendingPathComponent(UpdateInfo.archiveName)
        do { try FileManager.default.moveItem(at: downloaded, to: zip) } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }

        let verified = Task.detached { () throws -> URL in
            // SHA-256: indirilen dosya sürümdeki özetle aynı mı (yarım ya da değiştirilmiş indirme kurulmaz)?
            let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw UpdateError(message: String(localized: "İndirilen dosyanın özeti tutmuyor; dosya bozuk ya da değiştirilmiş olabilir.", bundle: .live))
            }
            let unpacked = work.appendingPathComponent("app", isDirectory: true)
            guard let unzip = Shell.runWithError("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]), unzip.status == 0 else {
                throw UpdateError(message: String(localized: "Arşiv açılamadı.", bundle: .live))
            }
            let app = unpacked.appendingPathComponent("MacExplorer.app", isDirectory: true)
            guard let bundle = Bundle(url: app),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                  version == release.version else {
                throw UpdateError(message: String(localized: "Arşivdeki uygulama beklenen MacExplorer sürümü değil.", bundle: .live))
            }
            guard let verify = Shell.runWithError("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]), verify.status == 0 else {
                throw UpdateError(message: String(localized: "Uygulamanın imzası doğrulanamadı.", bundle: .live))
            }
            // İndirilen uygulama "internetten indirildi" işaretini taşımasın (kullanıcı güncellemeyi zaten onayladı).
            _ = Shell.runWithError("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            return app
        }
        do {
            return (try await verified.value, work)
        } catch {
            try? FileManager.default.removeItem(at: work)   // reddedilen indirme geride kalmasın
            throw error
        }
    }

    /// Çalışan uygulamanın paketini yenisiyle değiştirir (macOS çalışan bir paketin yerine yenisini koymaya izin verir).
    private static func replaceRunningApp(with app: URL) throws {
        let current = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: app, backupItemName: nil, options: [])
        } catch {
            throw UpdateError(message: String(localized: "“\(current.deletingLastPathComponent().path)” klasörüne yazılamadı: \(error.localizedDescription)", bundle: .live))
        }
    }

    /// Uygulama kapanınca yenisini açan küçük bir kabuk komutu bırakır, sonra kapanır (oturum kaydedilir).
    private static func relaunch() {
        if skipsRelaunch {
            print("Güncelleme kuruldu:", Bundle.main.bundleURL.path)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
