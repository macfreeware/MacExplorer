import Foundation
import Darwin

public enum TransferKind: Sendable {
    case copy, move
}

/// Hedefte aynı adlı öğe varken yapılacak iş (Windows'taki "Dosyaları Değiştir veya Atla").
public enum ConflictResolution: Sendable {
    case replace, skip, keepBoth, cancel
}

public struct TransferConflict: Sendable {
    public let source: URL
    public let destination: URL
}

public struct TransferProgress: Sendable {
    public var totalBytes: Int64 = 0
    public var completedBytes: Int64 = 0
    public var totalItems = 0
    public var completedItems = 0
    public var currentName = ""

    public init() {}

    /// 0…1. Bayt ve öğe oranlarının ortalaması: ağ disklerinde her küçük dosya, boyutundan bağımsız sabit bir süre
    /// aldığından yalnızca bayta bakan çubuk çok sayıda küçük dosyada %0'da takılı kalır, kalan süre de tutmaz.
    /// Bayt bilinmiyorsa (aynı diskte taşıma) yalnızca öğe sayısına göre.
    public var fraction: Double {
        let items = totalItems > 0 ? min(1, Double(completedItems) / Double(totalItems)) : 0
        guard totalBytes > 0 else { return items }
        let bytes = min(1, Double(completedBytes) / Double(totalBytes))
        return totalItems > 0 ? (bytes + items) / 2 : bytes
    }
}

public enum TransferFailure: Sendable, Equatable {
    /// Klasör kendi içine (ya da bir alt klasörüne) kopyalanmak / taşınmak istendi.
    case destinationInsideSource
    case system(String)
}

public struct TransferError: Sendable {
    public let url: URL
    public let failure: TransferFailure

    public init(url: URL, failure: TransferFailure) {
        self.url = url
        self.failure = failure
    }
}

public struct TransferResult: Sendable {
    /// Hedefte oluşan (ya da içine birleştirilen) en üst düzey öğeler; listede seçili gösterilir.
    public var created: [URL] = []
    public var errors: [TransferError] = []
    public var cancelled = false
    /// İşlemi geri almanın adımları, uygulanacak sırada (bkz. `FileUndo`).
    public var undo: [FileUndoOp] = []

    public init(created: [URL] = [], cancelled: Bool = false) {
        self.created = created
        self.cancelled = cancelled
    }
}

/// Dosya ve klasörleri bir klasöre kopyalar ya da taşır.
///
/// - Aynı adlı klasörler Windows'taki gibi birleştirilir; yalnızca dosya çakışmaları `onConflict` ile sorulur.
/// - Aynı diskte taşıma yeniden adlandırmadır (anında); diskler arasında kopyalanıp kaynak silinir.
/// - Kopyalama `copyfile(3)` ile yapılır: izinler, genişletilmiş öznitelikler korunur, APFS'te dosyalar klonlanır.
/// - Aynı klasöre kopyalamak "ad - Kopya.uzantı" üretir.
///
/// `run()` eşzamanlıdır ve ana iş parçacığı dışında çağrılmalıdır; `onConflict` ve `onProgress` o iş parçacığında çağrılır.
public final class FileTransfer: @unchecked Sendable {
    public let kind: TransferKind
    public let sources: [URL]
    public let destination: URL
    /// Aynı klasöre kopyalarken ada eklenen sözcük ("Kopya" / "Copy").
    public let copySuffix: String

    public var onConflict: (TransferConflict) -> ConflictResolution = { _ in .skip }
    public var onProgress: (TransferProgress) -> Void = { _ in }
    /// "Değiştir" seçilince eski öğenin gittiği yer (testlerde değiştirilir).
    public var trash: FileUndo.Trash = FileUndo.systemTrash

    private let lock = NSLock()
    private var cancelled = false
    private var progress = TransferProgress()
    private var currentFileBytes: Int64 = 0
    /// Klasör kopyalanırken yazılmakta olan dosya: İptal edilirse yalnızca bu (yarım) dosya silinir.
    private var partialFile: String?
    private var lastReport = Date.distantPast
    private var result = TransferResult()

    public init(kind: TransferKind, sources: [URL], destination: URL, copySuffix: String = "Kopya") {
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.copySuffix = copySuffix
    }

    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Yapılanların tersi, yapıldıkları sırada (sonunda ters çevrilir).
    private var undoLog: [FileUndoOp] = []

    public func run() -> TransferResult {
        let dest = destination.normalizedFileURL
        var work: [URL] = []
        for src in sources.map(\.normalizedFileURL) {
            if src.path == dest.path || dest.path.hasPrefix(src.path + "/") {
                result.errors.append(TransferError(url: src, failure: .destinationInsideSource))
                continue
            }
            // Bulunduğu klasöre taşımak bir şey değiştirmez.
            if kind == .move && src.deletingLastPathComponent().path == dest.path { continue }
            work.append(src)
        }
        for src in work {
            if kind == .move && FileInfo.sameVolume(src, dest) {
                progress.totalItems += 1
            } else {
                let (bytes, items) = FileInfo.measure(src)
                progress.totalBytes += bytes
                progress.totalItems += items
            }
        }
        report(force: true)
        for src in work {
            if isCancelled { break }
            if let created = transfer(src, into: dest) { result.created.append(created) }
        }
        result.cancelled = isCancelled
        result.undo = undoLog.reversed()
        report(force: true)
        return result
    }

    // MARK: Aktarım

    private func transfer(_ src: URL, into dir: URL) -> URL? {
        guard !isCancelled else { return nil }
        let fm = FileManager.default
        var dst = dir.appendingPathComponent(src.lastPathComponent)
        if kind == .copy && src.deletingLastPathComponent().path == dir.path {
            dst = FileNaming.copyName(for: src, in: dir, suffix: copySuffix)
        } else if FileInfo.exists(dst) {
            if FileInfo.isMergeableDirectory(src) && FileInfo.isMergeableDirectory(dst) {
                let children = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
                for child in children { _ = transfer(child, into: dst) }
                if kind == .move { rmdir(src.path) }   // yalnızca boşaldıysa silinir (atlanan öğeler kaynakta kalır)
                return dst
            }
            switch onConflict(TransferConflict(source: src, destination: dst)) {
            case .skip:
                skip(src)
                return nil
            case .cancel:
                cancel()
                return nil
            case .keepBoth:
                dst = FileNaming.uniqueName(for: dst)
            case .replace:
                // Eski öğe Çöp Sepeti'ne gider: değiştirme de geri alınabilir. Çöpü olmayan disklerde silinir.
                if let trashed = try? trash(dst) {
                    undoLog.append(.move(from: trashed, to: dst))
                } else {
                    do { try fm.removeItem(at: dst) } catch {
                        fail(src, error.localizedDescription)
                        skip(src)
                        return nil
                    }
                }
            }
        }
        return perform(src, to: dst) ? dst : nil
    }

    private func perform(_ src: URL, to dst: URL) -> Bool {
        progress.currentName = src.lastPathComponent
        report()
        if kind == .move {
            if Darwin.rename(src.path, dst.path) == 0 {
                undoLog.append(.move(from: dst, to: src))
                progress.completedItems += 1
                report()
                return true
            }
            let err = errno
            guard err == EXDEV else {
                fail(src, FileInfo.posixMessage(err))
                return false
            }
            // Başka disk: kopyala, sonra kaynağı sil.
        }
        guard copy(src, to: dst) else { return false }
        if kind == .move {
            do {
                try FileManager.default.removeItem(at: src)
                undoLog.append(.move(from: dst, to: src))
            } catch {
                fail(src, error.localizedDescription)
                undoLog.append(.trash(dst))   // kaynak silinemedi: geri almak kopyayı kaldırır
            }
        } else {
            undoLog.append(.trash(dst))
        }
        return true
    }

    private func copy(_ src: URL, to dst: URL) -> Bool {
        guard let state = copyfile_state_alloc() else { return false }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, source, destination, context in
            guard let context else { return COPYFILE_CONTINUE }
            return Unmanaged<FileTransfer>.fromOpaque(context).takeUnretainedValue()
                .copyStatus(what: what, stage: stage, state: state, source: source, destination: destination)
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())

        let directory = FileInfo.isRealDirectory(src)
        var flags = CopyFlags.all | CopyFlags.nofollowSource
        flags |= directory ? CopyFlags.recursive : (CopyFlags.clone | CopyFlags.exclusive)
        currentFileBytes = 0
        let rc = copyfile(src.path, dst.path, state, copyfile_flags_t(flags))
        let err = errno
        currentFileBytes = 0
        let partial = partialFile
        partialFile = nil
        if rc != 0 {
            if isCancelled && directory {
                // Windows gibi: İptal'de o ana dek kopyalananlar kalır (geri almak hepsini kaldırır); yalnızca yarım
                // kalan dosya silinir. Bütün klasörü silmek ağ disklerinde uzun sürer ve yapılan işi boşa çıkarır.
                if let partial { unlink(partial) }
                undoLog.append(.trash(dst))
            } else if err != EEXIST {
                try? FileManager.default.removeItem(at: dst)   // yarım kalan kopyayı temizle
            }
            if !isCancelled { fail(src, FileInfo.posixMessage(err)) }
            return false
        }
        if !directory {
            progress.completedBytes += FileInfo.size(src)
            progress.completedItems += 1
        }
        report()
        return true
    }

    /// `copyfile` ilerleme bildirimi (aynı iş parçacığında, kopyalama sürerken çağrılır).
    fileprivate func copyStatus(what: Int32, stage: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?,
                                destination: UnsafePointer<CChar>?) -> Int32 {
        if isCancelled { return COPYFILE_QUIT }
        switch (what, stage) {
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 { currentFileBytes = Int64(copied) }
            report()
        case (COPYFILE_RECURSE_FILE, COPYFILE_START):
            if let source { progress.currentName = (String(cString: source) as NSString).lastPathComponent }
            partialFile = destination.map { String(cString: $0) }
            currentFileBytes = 0
            report()
        case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
            if let source {
                var st = stat()
                if lstat(source, &st) == 0 { progress.completedBytes += Int64(st.st_size) }
            }
            progress.completedItems += 1
            partialFile = nil
            currentFileBytes = 0
            report()
        case (COPYFILE_RECURSE_DIR, COPYFILE_START):
            progress.completedItems += 1
        case (_, COPYFILE_ERR):
            return COPYFILE_QUIT
        default:
            break
        }
        return COPYFILE_CONTINUE
    }

    // MARK: Yardımcılar

    private func skip(_ src: URL) {
        let (bytes, items) = FileInfo.measure(src)
        if progress.totalBytes > 0 { progress.completedBytes += bytes }
        progress.completedItems += items
        report()
    }

    private func fail(_ src: URL, _ message: String) {
        result.errors.append(TransferError(url: src, failure: .system(message)))
    }

    private func report(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.05 else { return }
        lastReport = now
        var snapshot = progress
        snapshot.completedBytes += currentFileBytes
        onProgress(snapshot)
    }
}

/// copyfile.h bayrakları (bileşik makrolar Swift'e aktarılmadığından açıkça).
private enum CopyFlags {
    static let all: UInt32 = 1 << 0 | 1 << 1 | 1 << 2 | 1 << 3   // ACL | STAT | XATTR | DATA
    static let recursive: UInt32 = 1 << 15
    static let exclusive: UInt32 = 1 << 17
    static let nofollowSource: UInt32 = 1 << 18
    static let clone: UInt32 = 1 << 24
}

/// Dosya sistemi sorguları (sembolik bağlantılar izlenmez).
public enum FileInfo {
    public static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    public static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Birleştirilebilir klasör: gerçek klasör, paket (.app) değil.
    public static func isMergeableDirectory(_ url: URL) -> Bool {
        isRealDirectory(url) && (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    public static func size(_ url: URL) -> Int64 {
        var st = stat()
        return lstat(url.path, &st) == 0 ? Int64(st.st_size) : 0
    }

    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        return lstat(a.path, &sa) == 0 && lstat(b.path, &sb) == 0 && sa.st_dev == sb.st_dev
    }

    public static func sameFile(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        return lstat(a.path, &sa) == 0 && lstat(b.path, &sb) == 0 && sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// Toplam bayt ve öğe sayısı (klasörün kendisi dahil, içindekilerle birlikte).
    public static func measure(_ url: URL) -> (bytes: Int64, items: Int) {
        guard isRealDirectory(url) else { return (size(url), 1) }
        var bytes: Int64 = 0, items = 1
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let child as URL in e {
                items += 1
                let v = try? child.resourceValues(forKeys: Set(keys))
                if v?.isDirectory != true { bytes += Int64(v?.fileSize ?? 0) }
            }
        }
        return (bytes, items)
    }

    public static func posixMessage(_ code: Int32) -> String {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
    }
}
