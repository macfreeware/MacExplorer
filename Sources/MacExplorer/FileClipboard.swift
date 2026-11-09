import AppKit
import MacExplorerCore

/// Dosya panosu. Dosyalar sistem panosuna dosya URL'leri olarak yazılır: Finder'da Yapıştır ile kopyalanabilir,
/// Finder'da kopyalananlar burada yapıştırılabilir. "Kes" ayrıca kendi türümüzle işaretlenir; pano başka bir
/// uygulamada değişince işaret de kaybolur ve kesilen öğeler normal görünüme döner.
@MainActor
enum FileClipboard {
    static let cutType = NSPasteboard.PasteboardType("local.macexplorer.cut")
    /// SFTP / FTP öğelerinin adresleri (sürükle-bırak ve pano). Finder bunları tanımaz; yalnızca MacExplorer panelleri.
    static let remoteType = NSPasteboard.PasteboardType("local.macexplorer.remote-url")
    static let didChange = Notification.Name("FileClipboardDidChange")

    private static let readOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    private static var cutCache: (changeCount: Int, paths: Set<String>) = (-1, [])

    static func write(_ urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { url -> NSPasteboardWriting in url.isRemote ? remoteItem(url) : url as NSURL })
        if cut { pb.setData(Data(), forType: cutType) }
        notify()
    }

    static func read() -> (urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        return (urls(from: pb), pb.types?.contains(cutType) == true)
    }

    static var hasFiles: Bool {
        let pb = NSPasteboard.general
        return pb.canReadObject(forClasses: [NSURL.self], options: readOptions) || pb.types?.contains(remoteType) == true
    }

    /// Panodaki (ya da sürüklenen) dosyalar: yerel dosya adresleri ve uzak öğe adresleri.
    static func urls(from pb: NSPasteboard) -> [URL] {
        let local = pb.readObjects(forClasses: [NSURL.self], options: readOptions) as? [URL] ?? []
        let remote = (pb.pasteboardItems ?? []).compactMap { $0.string(forType: remoteType).flatMap(URL.init(string:)) }
        return local + remote
    }

    /// Uzak öğe: kendi türümüz ve düz metin olarak adresi.
    static func remoteItem(_ url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: remoteType)
        item.setString(url.absoluteString, forType: .string)
        return item
    }

    /// Kesilmiş (yapıştırılmayı bekleyen) öğelerin yolları; listede soluk çizilir.
    static var cutPaths: Set<String> {
        let pb = NSPasteboard.general
        if cutCache.changeCount != pb.changeCount {
            let (urls, cut) = read()
            cutCache = (pb.changeCount, cut ? Set(urls.map(\.locationKey)) : [])
        }
        return cutCache.paths
    }

    /// Kesilenler yapıştırılınca pano boşaltılır (Windows gibi).
    static func clear() {
        NSPasteboard.general.clearContents()
        notify()
    }

    static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
