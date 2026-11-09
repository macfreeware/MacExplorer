import Foundation
import Darwin

/// Geri almanın yapı taşı. Her dosya işlemi geri alınırken bunlardan bir listeye indirgenir:
/// yeniden adlandırma ve taşıma `move`, Çöp Sepeti'nden geri yükleme de `move` (çöpteki yerinden eski yerine),
/// kopyalamayı ve yeni öğeyi geri almak `trash`. Bir adımı uygulamak tersini üretir; yineleme böyle çalışır.
public enum FileUndoOp: Sendable, Equatable {
    case move(from: URL, to: URL)
    case trash(URL)
}

public struct FileUndoResult: Sendable {
    /// Uygulanan adımların tersi, uygulanacak sırada (yineleme için).
    public var inverse: [FileUndoOp] = []
    public var errors: [TransferError] = []
}

public enum FileUndo {
    /// Öğeyi Çöp Sepeti'ne taşır, çöpteki yerini döndürür. Testler kendi klasörlerine taşıyan bir sürüm verir.
    public typealias Trash = @Sendable (URL) throws -> URL

    public static let systemTrash: Trash = { url in
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let trashed = trashed as URL? else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        return trashed
    }

    /// Adımları sırayla uygular. Başarısız adım atlanır, tersi kaydedilmez.
    public static func perform(_ ops: [FileUndoOp], trash: Trash = systemTrash) -> FileUndoResult {
        var result = FileUndoResult()
        var inverse: [FileUndoOp] = []
        for op in ops {
            switch op {
            case let .move(from, to):
                do {
                    try move(from, to)
                    inverse.append(.move(from: to, to: from))
                } catch {
                    result.errors.append(TransferError(url: from, failure: .system(error.localizedDescription)))
                }
            case let .trash(url):
                do {
                    inverse.append(.move(from: try trash(url), to: url))
                } catch {
                    result.errors.append(TransferError(url: url, failure: .system(error.localizedDescription)))
                }
            }
        }
        result.inverse = inverse.reversed()
        return result
    }

    /// Öğeyi tam olarak `to` yoluna taşır; gerekirse üst klasörleri oluşturur. Hedef doluysa üstüne yazmaz.
    static func move(_ from: URL, _ to: URL) throws {
        let fm = FileManager.default
        guard FileInfo.exists(from) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: from.path])
        }
        if FileInfo.exists(to) && !FileInfo.sameFile(from, to) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to.path])
        }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Darwin.rename(from.path, to.path) == 0 { return }
        guard errno == EXDEV else { throw RenameError.system(FileInfo.posixMessage(errno)) }
        // Başka disk: copyfile ile kopyala, sonra kaynağı sil (FileTransfer ile aynı yol, tek öğe).
        try fm.copyItem(at: from, to: to)
        try fm.removeItem(at: from)
    }
}
