import Foundation
import Darwin

/// Windows tarzı ad üretimi.
public enum FileNaming {
    /// Ad boştaysa olduğu gibi; doluysa "ad (2).uzantı", "ad (3).uzantı" … ("Her ikisini de koru", "Yeni klasör (2)").
    public static func uniqueName(for url: URL) -> URL {
        guard FileInfo.exists(url) else { return url }
        let dir = url.deletingLastPathComponent()
        let (base, ext) = split(url)
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(join("\(base) (\(n))", ext))
            if !FileInfo.exists(candidate) { return candidate }
            n += 1
        }
    }

    /// Aynı klasöre kopya: "ad - Kopya.uzantı", doluysa "ad - Kopya (2).uzantı".
    public static func copyName(for source: URL, in dir: URL, suffix: String) -> URL {
        let (base, ext) = split(source)
        return uniqueName(for: dir.appendingPathComponent(join("\(base) - \(suffix)", ext)))
    }

    /// Sunucuda aynı klasöre kopya için ad (yerel `copyName` ile aynı kural): "ad - Kopya.uzantı", doluysa
    /// "ad - Kopya (2).uzantı". `existing`: klasördeki adlar.
    public static func copyName(_ name: String, isDirectory: Bool, existing: Set<String>, suffix: String) -> String {
        let ext = isDirectory || name.hasPrefix(".") && !name.dropFirst().contains(".") ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = join("\(base) - \(suffix)", ext)
        var n = 2
        while existing.contains(candidate) {
            candidate = join("\(base) - \(suffix) (\(n))", ext)
            n += 1
        }
        return candidate
    }

    /// Ad ve uzantı. Klasörlerde (paketler hariç) ve "." ile başlayan adlarda uzantı yoktur.
    public static func split(_ url: URL) -> (base: String, ext: String) {
        let name = url.lastPathComponent
        let ext = (name as NSString).pathExtension
        if ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".") || FileInfo.isMergeableDirectory(url) {
            return (name, "")
        }
        return ((name as NSString).deletingPathExtension, ext)
    }

    private static func join(_ base: String, _ ext: String) -> String {
        ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Yeniden adlandırırken seçilecek kısım: uzantı hariç ad (Windows gibi). Klasörlerde adın tamamı.
    public static func baseNameLength(of name: String, isDirectory: Bool) -> Int {
        guard !isDirectory else { return (name as NSString).length }
        let ext = (name as NSString).pathExtension
        if ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".") { return (name as NSString).length }
        return ((name as NSString).deletingPathExtension as NSString).length
    }
}

public enum RenameError: Error, Equatable {
    case empty
    case invalidCharacters
    case exists
    case system(String)
}

public enum FileRenamer {
    /// Öğeyi aynı klasörde yeniden adlandırır; yeni URL'yi döndürür. Yalnızca büyük/küçük harf değişikliği de yapılabilir.
    public static func rename(_ url: URL, to newName: String) throws -> URL {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { throw RenameError.empty }
        guard !name.contains("/"), !name.contains(":") else { throw RenameError.invalidCharacters }
        guard name != url.lastPathComponent else { return url }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        // Büyük/küçük harf duyarsız diskte "rapor" → "Rapor" aynı dosyadır; başka bir dosyanın üstüne yazılmaz.
        if FileInfo.exists(target) && !FileInfo.sameFile(url, target) { throw RenameError.exists }
        guard Darwin.rename(url.path, target.path) == 0 else { throw RenameError.system(FileInfo.posixMessage(errno)) }
        return target
    }
}

public enum FileCreator {
    /// "Yeni klasör", doluysa "Yeni klasör (2)" …
    public static func newFolder(in dir: URL, name: String) throws -> URL {
        let url = FileNaming.uniqueName(for: dir.appendingPathComponent(name))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Boş dosya ("Yeni Metin Belgesi.txt").
    public static func newFile(in dir: URL, name: String) throws -> URL {
        let url = FileNaming.uniqueName(for: dir.appendingPathComponent(name))
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }
}

/// Terminale yapıştırılabilir yol: gerekmiyorsa olduğu gibi, boşluk ya da kabuk karakteri varsa tek tırnak içinde.
public enum ShellQuote {
    private static let special = CharacterSet(charactersIn: " \t\n'\"\\$`!*?[](){}&;<>|#~^")

    public static func quote(_ path: String) -> String {
        guard path.isEmpty || path.unicodeScalars.contains(where: special.contains) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
