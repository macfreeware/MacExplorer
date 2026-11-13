import Foundation

/// GitLab'daki son sürümün bilgileri (`/api/v4/projects/<yol>/releases/permalink/latest`).
public struct UpdateRelease: Sendable, Equatable {
    public let version: String
    public let notes: String
    public let page: URL?
    /// Uygulamanın zip'i (sabit ad: `MacExplorer.zip`).
    public let archive: URL?
    /// Zip'in SHA-256 özeti dosyası (`MacExplorer.zip.sha256`).
    public let checksum: URL?

    public init(version: String, notes: String, page: URL?, archive: URL?, checksum: URL?) {
        self.version = version
        self.notes = notes
        self.page = page
        self.archive = archive
        self.checksum = checksum
    }
}

public enum UpdateInfo {
    public static let archiveName = "MacExplorer.zip"
    public static let checksumName = "MacExplorer.zip.sha256"

    /// Dosya ve sayfa bağlantıları yalnızca `https://gitlab.com` üzerinde olabilir.
    public static func isTrusted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "gitlab.com"
    }

    /// GitLab sürüm yanıtını çözer. Sürüm etiketi "v1.2.3" ya da "1.2.3". `gitlab.com` dışındaki bağlantılar yok sayılır;
    /// `allowAnyHost` yalnızca geliştirme denemeleri içindir (yerel sahte sürüm).
    public static func parse(_ data: Data, allowAnyHost: Bool = false) throws -> UpdateRelease {
        struct Payload: Decodable {
            let tag_name: String
            let description: String?
            let _links: Links?
            let assets: Assets?
            struct Links: Decodable { let `self`: String? }
            struct Assets: Decodable { let links: [Link]? }
            struct Link: Decodable { let name: String; let url: String; let direct_asset_url: String? }
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        func allowed(_ text: String?) -> URL? {
            guard let url = text.flatMap(URL.init(string:)), allowAnyHost || isTrusted(url) else { return nil }
            return url
        }
        func asset(_ name: String) -> URL? {
            guard let link = p.assets?.links?.first(where: { $0.name == name }) else { return nil }
            return allowed(link.direct_asset_url ?? link.url)
        }
        return UpdateRelease(version: version, notes: p.description ?? "",
                             page: allowed(p._links?.`self`),
                             archive: asset(archiveName), checksum: asset(checksumName))
    }

    /// Uygulama yerinde değiştirilebilir mi: .app paketi olmalı, paket ve bulunduğu klasör yazılabilir olmalı.
    /// Değilse (ör. başka kullanıcının kurduğu kopya, salt okunur disk) indirmeden önce indirme sayfası önerilir.
    public static func canReplace(app: URL, fileManager: FileManager = .default) -> Bool {
        app.pathExtension == "app"
            && fileManager.isWritableFile(atPath: app.path)
            && fileManager.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Otomatik denetleme zamanı geldi mi: son başarılı denetimden bu yana `interval` geçtiyse. Saat geri alınmışsa
    /// (son denetim gelecekte görünüyorsa) da denetlenir; yoksa saat düzelene kadar hiç bakılmazdı.
    public static func isCheckDue(lastCheck: Date, now: Date = Date(), interval: TimeInterval = 24 * 3600) -> Bool {
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed > interval || elapsed < 0
    }

    /// Güncelleme penceresinde gösterilecek kısım: sürüm notundan yalnızca yenilikler.
    /// Notlar "Türkçe bölümler --- English paragraph" biçimindedir. Türkçede baştaki gereksinim satırı ile "Kurulum",
    /// "Denenecekler" bölümleri atılır, kalan "## …" bölümleri döner. İngilizcede paragraftaki "New since …" cümlesinden
    /// başlanır. Beklenen biçim bulunmazsa notun ilgili dili olduğu gibi döner.
    public static func highlights(from notes: String, english: Bool) -> String {
        let parts = notes.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n---\n")
        let turkish = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let englishPart = parts.count > 1 ? parts[1...].joined(separator: "\n---\n").trimmingCharacters(in: .whitespacesAndNewlines) : ""

        if english, !englishPart.isEmpty {
            if let range = englishPart.range(of: "New since") { return String(englishPart[range.lowerBound...]) }
            return englishPart
        }

        let skipped: Set<String> = ["kurulum", "denenecekler", "installation"]
        var kept: [String] = []
        var current: [String]?
        func flush() {
            guard let section = current, let title = section.first else { return }
            let name = title.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
            if !skipped.contains(name) { kept.append(section.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        for line in turkish.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                current = [line]
            } else {
                current?.append(line)
            }
        }
        flush()
        return kept.isEmpty ? turkish : kept.joined(separator: "\n\n")
    }

    /// Noktalı sürümlerin sayısal karşılaştırması: 1.10 > 1.9, 1.2.1 > 1.2.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// `shasum -a 256` çıktısından özet: "abc…  MacExplorer.zip" ya da yalnızca "abc…". Küçük harfe çevrilir.
    public static func parseChecksum(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return nil }
        let hex = first.lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }
}
