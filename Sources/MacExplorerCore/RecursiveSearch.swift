import Foundation

/// Alt klasörlerde ada göre arama (Windows Gezgini'nin arama kutusu gibi). Arka planda yürür, sonuçlar
/// gruplar halinde bildirilir; durdurulabilir. Paketlerin (.app) içine girilmez; gizli öğeler ayara göre.
public final class RecursiveSearch: @unchecked Sendable {
    public let root: URL
    public let query: String
    private let showHidden: Bool
    private let limit: Int
    private let lock = NSLock()
    private var cancelled = false

    public init(root: URL, query: String, showHidden: Bool, limit: Int = 5000) {
        self.root = root
        self.query = query
        self.showHidden = showHidden
        self.limit = limit
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }

    /// Aramayı yürütür (çağıran iş parçacığında; arka planda çağrılmalı). `batch` en çok ~4 kez/sn çağrılır;
    /// `finished` en sonda bir kez, sonuç sınırına ulaşıldıysa `true` ile.
    public func run(batch: ([FileItem]) -> Void, finished: (Bool) -> Void) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: FileItem.resourceKeys,
                                                               options: options, errorHandler: { _, _ in true }) else {
            return finished(false)
        }
        var pending: [FileItem] = []
        var count = 0
        var lastFlush = Date()
        for case let url as URL in enumerator {
            if isCancelled { return }
            // Önce ad (ucuz), eşleşirse öğenin bilgileri okunur.
            guard NameFilter.matches(url.lastPathComponent, query: query) else { continue }
            pending.append(FileItem(url: url))
            count += 1
            if count >= limit {
                batch(pending)
                return finished(true)
            }
            if Date().timeIntervalSince(lastFlush) > 0.25 {
                batch(pending)
                pending = []
                lastFlush = Date()
            }
        }
        if isCancelled { return }
        if !pending.isEmpty { batch(pending) }
        finished(false)
    }
}
