import Foundation

/// MacRAR'a gönderilebilen komutlar. Ham değerler MacRAR'ın `FinderAction` adlarıdır (`macrar://<ad>?…`).
public enum MacRARAction: String, CaseIterable, Sendable {
    case add                // Arşive ekle… (MacRAR'ın Ekle penceresi)
    case compress           // "ad.rar" olarak sıkıştır
    case compressStamped    // zaman damgalı RAR
    case open               // arşivi MacRAR'da aç
    case extractDialog      // Dosyaları çıkart…
    case extractHere        // Buraya çıkart
    case extractFolder      // "ad/" klasörüne çıkart
    case compressZip        // "ad.zip" olarak sıkıştır
    case compressZipStamped // zaman damgalı ZIP
}

/// MacRAR ile bağlantı. MacRAR'ın Finder eklentisinin kullandığı yolu kullanır: `macrar://<eylem>?t=<anahtar>&p=<yol>…`
/// adresini açmak MacRAR'ı (kapalıysa başlatarak) tetikler; iş arka planda, küçük bir ilerleme paneliyle yapılır.
/// Anahtar MacRAR'ın ilk açılışta ürettiği, yalnızca kullanıcının okuyabildiği dosyadadır; MacRAR'da değişiklik gerekmez.
public enum MacRARBridge {
    public static let bundleIdentifier = "local.macrar.app"
    public static let scheme = "macrar"

    public static func supportDirectory(home: URL = realHome()) -> URL {
        home.appendingPathComponent("Library/Application Support/MacRAR", isDirectory: true)
    }

    /// MacRAR'ın anahtarı; MacRAR hiç açılmadıysa ya da dosya bozuksa nil.
    public static func token(home: URL = realHome()) -> String? {
        guard let data = try? Data(contentsOf: supportDirectory(home: home).appendingPathComponent("finder.token")) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = token.count == 64 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        return valid ? token : nil
    }

    /// RAR oluşturulabilir mi: MacRAR'ın yazdığı durum "rar=1" diyorsa ya da bilinen bir konumda `rar` varsa.
    public static func canCompressRAR(home: URL = realHome(),
                                      exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        let state = (try? String(contentsOf: supportDirectory(home: home).appendingPathComponent("finder.state"), encoding: .utf8)) ?? ""
        let lines = state.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("rar=1") { return true }
        if lines.contains("rar=0") { return false }
        let candidates = ["/opt/homebrew/bin/rar", "/usr/local/bin/rar", "/opt/local/bin/rar",
                          supportDirectory(home: home).appendingPathComponent("tools/rar/rar").path]
        return candidates.contains(where: exists)
    }

    /// MacRAR'ın arşiv saydığı uzantılar (MacRAR `ArchiveTypes` ile aynı).
    public static let archiveExtensions: Set<String> = [
        "rar", "zip", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lz", "lzma", "zst",
        "cab", "iso", "cpio", "xar", "lha", "lzh", "cbr", "cbz", "jar", "war",
    ]

    public static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) { return true }
        // RAR'ın eski çok parçalı adları: .r00, .r01 …
        return ext.count == 3 && ext.hasPrefix("r") && ext.dropFirst().allSatisfy(\.isNumber)
    }

    /// Seçime uygun komutlar: hepsi arşivse açma/çıkarma, değilse sıkıştırma (rar yoksa RAR girdileri olmadan).
    public static func actions(for urls: [URL], canCompressRAR: Bool) -> [MacRARAction] {
        guard !urls.isEmpty else { return [] }
        if urls.allSatisfy(isArchive) {
            return [.open, .extractDialog, .extractHere, .extractFolder]
        }
        return [.add] + (canCompressRAR ? [.compress, .compressStamped] : []) + [.compressZip, .compressZipStamped]
    }

    public static func commandURL(action: MacRARAction, paths: [String], token: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = action.rawValue
        c.queryItems = [URLQueryItem(name: "t", value: token)] + paths.map { URLQueryItem(name: "p", value: $0) }
        return c.url
    }

    /// Gerçek ev dizini (korumalı süreçlerde de kapsayıcı değil, kullanıcının dizini).
    public static func realHome() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
