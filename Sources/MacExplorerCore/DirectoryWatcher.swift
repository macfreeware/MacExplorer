import Foundation

/// Bir klasöre öğe eklenince, silinince ya da yeniden adlandırılınca haber verir.
/// Art arda gelen olaylar `latency` süresince birleştirilir; işleyici bir kez çağrılır.
public final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    public init?(url: URL, queue: DispatchQueue = .main, latency: TimeInterval = 0.2, handler: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link, .attrib], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let item = DispatchWorkItem(block: handler)
            self.pending = item
            queue.asyncAfter(deadline: .now() + latency, execute: item)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        pending?.cancel()
        source.cancel()
    }
}
