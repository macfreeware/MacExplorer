import Foundation

/// Windows "Kısayol oluştur" karşılığı: macOS takma adı (Finder alias). Açılınca hedefi açılır; hedef taşınsa da bulunur.
public enum ShortcutMaker {
    /// `dir` içinde "ad - Kısayol" adlı takma ad oluşturur (doluysa "ad - Kısayol (2)").
    public static func createAlias(to target: URL, in dir: URL, suffix: String) throws -> URL {
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        let alias = FileNaming.uniqueName(for: dir.appendingPathComponent("\(target.lastPathComponent) - \(suffix)"))
        try URL.writeBookmarkData(bookmark, to: alias)
        return alias
    }
}

public enum ZipError: Error, Equatable {
    case failed(String)
}

/// Windows "Gönder ▸ Sıkıştırılmış (zip) klasör": macOS'un yerleşik araçlarıyla zip oluşturur.
public enum ZipMaker {
    /// Tek öğede "ad.zip", birden çokta `name` (sağ tıklanan öğenin adı) ile; ad doluysa "ad (2).zip".
    /// Eşzamanlıdır; ana iş parçacığı dışında çağrılmalıdır.
    public static func zip(_ sources: [URL], in dir: URL, name: String) throws -> URL {
        let base = sources.count == 1 ? FileNaming.split(sources[0]).base : name
        let target = FileNaming.uniqueName(for: dir.appendingPathComponent("\(base).zip"))
        // bsdtar, adları UTF-8 işaretiyle yazar: Windows'ta "Klasör" bozulmadan açılır. (Finder'ın kullandığı ditto bu
        // işareti koymaz ve __MACOSX klasörü ekler.) Kaynaklar aynı klasördedir; arşive göreli adlarla girerler.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.currentDirectoryURL = sources[0].deletingLastPathComponent()
        process.arguments = ["--format", "zip", "--options", "zip:hdrcharset=UTF-8", "-cf", target.path, "--"]
            + sources.map(\.lastPathComponent)
        // Dock'tan açılan uygulamada yerel ayar tanımsız olabilir; bsdtar adları UTF-8 okusun.
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { _, new in new }
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: target)
            throw ZipError.failed(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return target
    }
}
