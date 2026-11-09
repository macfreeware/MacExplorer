import Foundation

/// Bir klasördeki tek öğe: dosya, klasör, paket (.app gibi) ya da bağlantı.
public struct FileItem: Hashable, Sendable {
    public let url: URL
    /// Diskteki ad.
    public let name: String
    /// Listede gösterilen ad: klasörlerde sistemin yerelleştirdiği ad (Desktop → Masaüstü), paketlerde uzantısız ad.
    public let displayName: String
    /// İçine girilebilen klasör. Paketler (.app, .bundle) dosya gibi davranır; klasörü gösteren sembolik bağlantılar klasördür.
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    public let isSymbolicLink: Bool
    /// Bayt cinsinden boyut; klasörlerde ve paketlerde nil.
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    /// Sistemin tür açıklaması ("Klasör", "PDF belgesi" …).
    public let kind: String

    public static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .localizedNameKey, .localizedTypeDescriptionKey,
    ]

    public init(url: URL, name: String, displayName: String, isDirectory: Bool, isPackage: Bool = false,
                isHidden: Bool = false, isSymbolicLink: Bool = false, size: Int64? = nil,
                modified: Date? = nil, created: Date? = nil, kind: String = "") {
        self.url = url
        self.name = name
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modified = modified
        self.created = created
        self.kind = kind
    }

    /// Öğenin bilgilerini dosya sisteminden okur.
    public init(url: URL) {
        let v = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        let isLink = v?.isSymbolicLink ?? false
        var isDir = v?.isDirectory ?? false
        var isPackage = v?.isPackage ?? false
        if isLink, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
            isDir = target.isDirectory ?? false
            isPackage = target.isPackage ?? false
        }
        let navigable = isDir && !isPackage
        let name = url.lastPathComponent
        self.init(
            url: url,
            name: name,
            displayName: isDir ? (v?.localizedName ?? name) : name,
            isDirectory: navigable,
            isPackage: isPackage,
            isHidden: v?.isHidden ?? name.hasPrefix("."),
            isSymbolicLink: isLink,
            size: isDir ? nil : v?.fileSize.map(Int64.init),
            modified: v?.contentModificationDate,
            created: v?.creationDate,
            kind: v?.localizedTypeDescription ?? ""
        )
    }
}

extension URL {
    /// Karşılaştırma ve gezinme geçmişi için tek biçim: mutlak, `.` / `..` çözülmüş dosya yolu.
    /// Uzak adreslerde yol temizlenir, adres uzak kalır.
    public var normalizedFileURL: URL {
        if isRemote { return RemoteURL.replacingPath(self, with: RemoteURL.path(of: self)) }
        return URL(fileURLWithPath: standardizedFileURL.path)
    }
}
