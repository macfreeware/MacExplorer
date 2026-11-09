import Foundation

/// Bir sekmenin Geri / İleri geçmişi.
public struct NavigationHistory: Sendable {
    public private(set) var current: URL
    public private(set) var backStack: [URL] = []
    public private(set) var forwardStack: [URL] = []

    public init(start: URL) { current = start.normalizedFileURL }

    /// Kaydedilmiş geçmişten (oturumu geri yükleme): artık var olmayan klasörler atlanır.
    public init(current: URL, back: [URL], forward: [URL], exists: (URL) -> Bool = { $0.isRemote || FileInfo.isRealDirectory($0) }) {
        self.current = current.normalizedFileURL
        backStack = back.map(\.normalizedFileURL).filter(exists)
        forwardStack = forward.map(\.normalizedFileURL).filter(exists)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Yeni konuma gider; ileri geçmişi silinir. Aynı konuma gitmek geçmişe eklenmez.
    public mutating func visit(_ url: URL) {
        let target = url.normalizedFileURL
        guard target.locationKey != current.locationKey else { return }
        backStack.append(current)
        current = target
        forwardStack.removeAll()
    }

    @discardableResult
    public mutating func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = previous
        return previous
    }

    @discardableResult
    public mutating func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return next
    }
}
