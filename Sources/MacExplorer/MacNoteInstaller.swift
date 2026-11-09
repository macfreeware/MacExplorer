import AppKit
import CryptoKit

/// MacNote++ (ücretsiz metin düzenleyici) ile bağlantı: F4 ve sağ tık düzenleme, F3 salt okunur görüntüleme, indirip kurma.
enum MacNoteInstaller {
    static let bundleIdentifier = "com.macnotepp.editor"
    static let page = URL(string: "https://gitlab.com/freeware2/macnotepp")!
    /// Sürümsüz adresler: GitLab en yeni sürümün dosyalarına yönlendirir.
    private static let latestArchive = URL(string: "https://gitlab.com/freeware2/macnotepp/-/releases/permalink/latest/downloads/MacNotePP.zip")!
    private static let latestChecksum = URL(string: "https://gitlab.com/freeware2/macnotepp/-/releases/permalink/latest/downloads/MacNotePP.zip.sha256")!

    /// Kurulu MacNote++. Geliştirme: MACEXPLORER_NO_MACNOTE=1 ile "kurulu değil" görünümü denenir.
    static var app: URL? {
        if ProcessInfo.processInfo.environment["MACEXPLORER_NO_MACNOTE"] == "1" { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static var isInstalled: Bool { app != nil }

    static func openPage() { NSWorkspace.shared.open(page) }

    /// Dosyaları MacNote++'ta düzenlemeye kapalı açar (F3).
    static func view(_ files: [URL]) {
        guard let app else { return NSSound.beep() }
        var link = URLComponents()
        link.scheme = "macnotepp"
        link.host = "view"
        link.queryItems = files.map { URLQueryItem(name: "path", value: $0.path) }
        guard let url = link.url else { return NSSound.beep() }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Zip'i ve özetini indirir, doğrular, uygulamayı Uygulamalar klasörüne koyar ve açar.
    @MainActor
    static func downloadAndInstall(over parent: NSWindow?) {
        let sheet = DownloadSheet()
        let task = URLSession.shared.downloadTask(with: latestArchive) { temp, response, error in
            // Geçici dosya yalnızca bu kapanış süresince vardır; önce taşınır.
            var kept: URL?
            if let temp, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("MacNotePP-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: temp, to: copy)) != nil { kept = copy }
            }
            Task { @MainActor in
                do {
                    guard let kept else { throw error ?? URLError(.badServerResponse) }
                    defer { try? FileManager.default.removeItem(at: kept) }
                    let installed = try await install(archive: kept)
                    sheet.close()
                    NSWorkspace.shared.openApplication(at: installed, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                } catch let failure as URLError where failure.code == .cancelled {
                    sheet.close()
                } catch {
                    sheet.close()
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = String(localized: "MacNote++ kurulamadı.", bundle: .live)
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: String(localized: "GitLab sayfasını aç", bundle: .live))
                    alert.addButton(withTitle: String(localized: "Kapat", bundle: .live))
                    if alert.runModal() == .alertFirstButtonReturn { openPage() }
                }
            }
        }
        sheet.show(task: task, over: parent, message: String(localized: "MacNote++’ın en son sürümü indiriliyor…", bundle: .live))
        task.resume()
    }

    private static func install(archive: URL) async throws -> URL {
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: latestChecksum)
        guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = String(decoding: checksumData, as: UTF8.self).split(whereSeparator: \.isWhitespace).first?.lowercased() else {
            throw InstallError(message: String(localized: "Özet dosyası okunamadı.", bundle: .live))
        }
        return try await Task.detached { () throws -> URL in
            let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
            guard digest.map({ String(format: "%02x", $0) }).joined() == expected else {
                throw InstallError(message: String(localized: "İndirilen dosyanın özeti tutmuyor; dosya bozuk ya da değiştirilmiş olabilir.", bundle: .live))
            }
            let fileManager = FileManager.default
            let work = fileManager.temporaryDirectory.appendingPathComponent("MacNotePP-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: work) }
            guard let unzip = Shell.runWithError("/usr/bin/ditto", ["-x", "-k", archive.path, work.path]), unzip.status == 0 else {
                throw InstallError(message: String(localized: "Arşiv açılamadı.", bundle: .live))
            }
            let unpacked = work.appendingPathComponent("MacNote++/MacNote++.app", isDirectory: true)
            guard Bundle(url: unpacked)?.bundleIdentifier == bundleIdentifier,
                  let verify = Shell.runWithError("/usr/bin/codesign", ["--verify", "--deep", "--strict", unpacked.path]), verify.status == 0 else {
                throw InstallError(message: String(localized: "Uygulamanın imzası doğrulanamadı.", bundle: .live))
            }
            // Kullanıcı kurulumu kendisi başlattı; macOS yeniden sormasın.
            _ = Shell.runWithError("/usr/bin/xattr", ["-dr", "com.apple.quarantine", unpacked.path])
            let target = URL(fileURLWithPath: "/Applications/MacNote++.app", isDirectory: true)
            do {
                try fileManager.moveItem(at: unpacked, to: target)
            } catch {
                throw InstallError(message: String(localized: "“\(target.deletingLastPathComponent().path)” klasörüne yazılamadı: \(error.localizedDescription)", bundle: .live))
            }
            return target
        }.value
    }
}
