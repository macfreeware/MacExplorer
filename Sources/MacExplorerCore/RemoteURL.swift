import Foundation

/// Uzak klasör adresleri: `sftp://kullanıcı@sunucu:port/yol` (ftp, ftpes, ftps de; arşivin içi: `archive://ad@kimlik/yol`). Sekme geçmişi, adres çubuğu ve
/// seçim bu adreslerle çalışır; sunucuyla konuşan katman MacExplorer'daki RemoteSessions'tır.
public enum RemoteURL {
    public static let schemes: Set<String> = ["sftp", "ftp", "ftpes", "ftps", "archive"]

    public static func make(scheme: String, user: String, host: String, port: Int?, path: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = port
        if !user.isEmpty { c.user = user }
        c.path = clean(path)
        return c.url
    }

    /// Uzak yol ("/var/www"); kökte "/".
    public static func path(of url: URL) -> String {
        let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        return clean(p.isEmpty ? "/" : p)
    }

    /// Aynı sunucuda başka bir yol.
    public static func replacingPath(_ url: URL, with path: String) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.path = clean(path)
        return c.url ?? url
    }

    /// Bağlantının kimliği: tür, kullanıcı, sunucu, port (yol hariç).
    public static func serverKey(_ url: URL) -> String {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let user = c?.user.map { $0 + "@" } ?? ""
        let port = c?.port.map { ":\($0)" } ?? ""
        return "\(url.scheme?.lowercased() ?? "")://\(user)\(c?.host?.lowercased() ?? "")\(port)"
    }

    /// Fazladan ve sondaki eğik çizgiler atılır; "." ve ".." çözülür.
    public static func clean(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}

extension URL {
    /// SFTP / FTP adresi mi?
    public var isRemote: Bool { RemoteURL.schemes.contains(scheme?.lowercased() ?? "") }

    /// Konum karşılaştırması için anahtar: yerelde yol, uzakta tam adres.
    public var locationKey: String {
        isRemote ? RemoteURL.serverKey(self) + RemoteURL.path(of: self) : standardizedFileURL.path
    }
}
