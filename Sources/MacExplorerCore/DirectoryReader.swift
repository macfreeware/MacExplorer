import Foundation

/// Klasör içeriğini okur.
public enum DirectoryReader {
    public static func read(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return urls.map(FileItem.init(url:))
    }
}

/// Ada göre süzme (Ara kutusu): büyük/küçük harf ve aksan duyarsız ("ozet" → "Özet").
public enum NameFilter {
    /// Desene göre seçim (mc'deki + / −): `*` ve `?` joker; birden çok desen `;`, `,` ya da boşlukla ayrılır.
    /// Büyük/küçük harf ve Türkçe karakter farkı gözetilmez ("*.PDF" "rapor.pdf"yi de seçer).
    public static func matchesPattern(_ name: String, pattern: String) -> Bool {
        let patterns = pattern.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).map(String.init)
        guard !patterns.isEmpty else { return false }
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return patterns.contains { wildcard(folded, $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
    }

    private static func wildcard(_ text: String, _ pattern: String) -> Bool {
        let t = Array(text), p = Array(pattern)
        var ti = 0, pi = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] { ti += 1; pi += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    public static func matches(_ name: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
