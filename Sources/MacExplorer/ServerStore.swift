import Foundation
import MacExplorerCore
import Security

/// Bağlanılabilen sunucu türleri. Ağ paylaşımları (SMB, WebDAV, AFP, NFS) macOS'un kendi sistemiyle disk gibi
/// bağlanır; SFTP / FTP türleri MacZilla'nın FTPKit'iyle uzak klasör sekmesinde açılır (bkz. RemoteSessions).
enum ServerKind: String, Codable, CaseIterable, Identifiable {
    case smb, webdav, webdavs, afp, nfs
    case sftp, ftp, ftpes, ftps
    var id: String { rawValue }

    /// Sunucuya Bağlan penceresinde sunulan türler.
    static let available: [ServerKind] = [.smb, .sftp, .ftp, .ftpes, .ftps, .webdavs, .webdav, .afp, .nfs]

    /// SFTP / FTP: disk olarak bağlanmaz, panelde uzak klasör olarak açılır.
    var isRemote: Bool { [.sftp, .ftp, .ftpes, .ftps].contains(self) }

    var title: String {
        switch self {
        case .smb: return String(localized: "SMB – Windows / NAS paylaşımı", bundle: .live)
        case .webdav: return String(localized: "WebDAV (http)", bundle: .live)
        case .webdavs: return String(localized: "WebDAV (https, şifreli)", bundle: .live)
        case .afp: return String(localized: "AFP – eski Mac sunucuları", bundle: .live)
        case .nfs: return String(localized: "NFS – Unix / Linux paylaşımı", bundle: .live)
        case .sftp: return String(localized: "SFTP – SSH dosya aktarımı", bundle: .live)
        case .ftp: return String(localized: "FTP – şifrelenmemiş", bundle: .live)
        case .ftpes: return String(localized: "FTPES – açık TLS (AUTH TLS)", bundle: .live)
        case .ftps: return String(localized: "FTPS – örtük TLS", bundle: .live)
        }
    }

    var scheme: String {
        switch self {
        case .webdav: return "http"
        case .webdavs: return "https"
        default: return rawValue
        }
    }

    var symbol: String {
        switch self {
        case .smb: return "server.rack"
        case .webdav, .webdavs: return "globe"
        case .afp: return "externaldrive.connected.to.line.below"
        case .nfs: return "network"
        case .sftp: return "terminal"
        case .ftp, .ftpes, .ftps: return "arrow.up.arrow.down.circle"
        }
    }

    /// NFS'te kullanıcı / parola yoktur.
    var usesCredentials: Bool { self != .nfs }

    init?(scheme: String) {
        switch scheme.lowercased() {
        case "smb", "cifs": self = .smb
        case "http": self = .webdav
        case "https": self = .webdavs
        case "afp": self = .afp
        case "nfs": self = .nfs
        case "sftp", "ssh": self = .sftp
        case "ftp": self = .ftp
        case "ftpes": self = .ftpes
        case "ftps": self = .ftps
        default: return nil
        }
    }
}

/// Kayıtlı sunucu. Parola burada değil, macOS Anahtar Zinciri'nde (bkz. ServerKeychain).
struct ServerBookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: ServerKind
    var host: String
    var port: Int?
    var user: String
    /// Paylaşım adı ya da başlangıç klasörü ("Belgeler", "/var/www").
    var path: String
    /// SFTP: özel anahtar dosyası (boşsa ssh'in kendi anahtarları / ssh-agent).
    var keyFile: String = ""

    var displayName: String { name.isEmpty ? host : name }

    /// SFTP / FTP: sunucudaki bir klasörün adresi (sftp://kullanıcı@sunucu:port/yol).
    func remoteURL(path: String) -> URL? {
        RemoteURL.make(scheme: kind.rawValue, user: user.trimmingCharacters(in: .whitespaces),
                       host: host.trimmingCharacters(in: .whitespaces), port: port, path: path)
    }

    /// Parolasız adres (son bağlantılar ve görüntü için): smb://kullanıcı@sunucu:port/paylaşım
    var url: URL? {
        var c = URLComponents()
        c.scheme = kind.scheme
        c.host = host.trimmingCharacters(in: .whitespaces)
        c.port = port
        if kind.usesCredentials, !user.isEmpty { c.user = user }
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        c.path = trimmed.isEmpty ? "" : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
        return c.url
    }

    /// Yapıştırılan adresten ("smb://nas.local/Paylaşım", "https://site/dav") doldurur.
    init?(address: String) {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: text), let scheme = c.scheme, let kind = ServerKind(scheme: scheme),
              let host = c.host, !host.isEmpty else { return nil }
        self.init(name: "", kind: kind, host: host, port: c.port, user: c.user ?? "",
                  path: c.path.removingPercentEncoding ?? c.path)
    }

    init(name: String, kind: ServerKind, host: String, port: Int? = nil, user: String = "", path: String = "", keyFile: String = "") {
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
        self.path = path
        self.keyFile = keyFile
    }
}

/// Kayıtlı sunucular ve son bağlantılar (parolasız), kullanıcı ayarlarında JSON olarak.
@MainActor
enum ServerStore {
    static let didChange = Notification.Name("ServerStoreDidChange")
    private static let serversKey = "servers"
    private static let recentKey = "recentServers"
    private static let recentLimit = 8

    static var servers: [ServerBookmark] {
        get { decode(serversKey) }
        set { encode(newValue, serversKey) }
    }

    /// Son bağlanılanlar (kaydedilmemiş olanlar da), en yenisi başta.
    static var recent: [ServerBookmark] {
        get { decode(recentKey) }
        set { encode(Array(newValue.prefix(recentLimit)), recentKey) }
    }

    static func save(_ server: ServerBookmark) {
        var list = servers
        if let i = list.firstIndex(where: { $0.id == server.id }) { list[i] = server } else { list.append(server) }
        servers = list
    }

    /// Kaydı, Anahtar Zinciri'ndeki parolasını ve son bağlantılardaki izini birlikte siler.
    static func delete(_ server: ServerBookmark) {
        servers.removeAll { $0.id == server.id }
        recent.removeAll { $0.id == server.id }
        ServerKeychain.delete(for: server.id)
    }

    /// Tüm kayıtlı bağlantılar ve parolaları.
    static func deleteAll() {
        for server in servers { ServerKeychain.delete(for: server.id) }
        servers = []
        recent = []
    }

    static func noteConnected(_ server: ServerBookmark) {
        var list = recent.filter { $0.id != server.id && $0.url != server.url }
        list.insert(server, at: 0)
        recent = list
    }

    static func clearRecent() { recent = [] }

    private static func decode(_ key: String) -> [ServerBookmark] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ServerBookmark].self, from: data) else { return [] }
        return list
    }

    private static func encode(_ list: [ServerBookmark], _ key: String) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// Sunucu parolaları macOS Anahtar Zinciri'nde (genel parola; hesap = kaydın kimliği). Düz dosyada asla tutulmaz.
enum ServerKeychain {
    private static let service = "local.macexplorer.server"

    static func password(for id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ password: String, for id: UUID, label: String) -> Bool {
        delete(for: id)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: id.uuidString, kSecAttrLabel as String: "MacExplorer – \(label)",
                                   kSecValueData as String: Data(password.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(for id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}
