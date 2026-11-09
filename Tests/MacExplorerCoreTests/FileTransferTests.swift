import XCTest
@testable import MacExplorerCore

final class FileTransferTests: XCTestCase {
    private var root: URL!
    private var a: URL!   // kaynak klasör
    private var b: URL!   // hedef klasör

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacExplorerTransfer-\(UUID().uuidString)")
        a = root.appendingPathComponent("A")
        b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func names(_ dir: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    /// Çok sayıda küçük dosyalı klasör: tamamlanan bayt her dosyada sıfırlanmamalı, toplam büyüyerek ilerlemeli.
    func testFolderProgressAccumulates() throws {
        let folder = a.appendingPathComponent("Çok")
        for i in 0..<300 { try write(String(repeating: "x", count: 1000 + i), folder.appendingPathComponent("alt\(i % 7)/d\(i).txt")) }
        for i in 0..<6 { try write(String(repeating: "y", count: 2_000_000), folder.appendingPathComponent("büyük\(i).bin")) }
        let t = FileTransfer(kind: .copy, sources: [folder], destination: b)
        var seen: [Int64] = []
        var last = TransferProgress()
        t.onProgress = { seen.append($0.completedBytes); last = $0 }
        let r = t.run()
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        XCTAssertEqual(last.completedBytes, last.totalBytes)
        XCTAssertEqual(seen, seen.sorted(), "ilerleme geri gitmemeli")
        XCTAssertEqual(last.fraction, 1, accuracy: 0.001)
        var half = TransferProgress()
        half.totalBytes = 1000; half.completedBytes = 0; half.totalItems = 100; half.completedItems = 50
        XCTAssertEqual(half.fraction, 0.25, accuracy: 0.001, "küçük dosyalar da çubuğu ilerletmeli")
    }

    func testCopyFileAndFolderWithProgress() throws {
        try write("12345", a.appendingPathComponent("dosya.txt"))
        try write("abc", a.appendingPathComponent("Klasör/iç/derin.txt"))
        try FileManager.default.createSymbolicLink(atPath: a.appendingPathComponent("Klasör/bağ").path, withDestinationPath: "iç")

        let t = FileTransfer(kind: .copy, sources: [a.appendingPathComponent("dosya.txt"), a.appendingPathComponent("Klasör")], destination: b)
        var last = TransferProgress()
        t.onProgress = { last = $0 }
        let r = t.run()

        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        XCTAssertEqual(read(b.appendingPathComponent("dosya.txt")), "12345")
        XCTAssertEqual(read(b.appendingPathComponent("Klasör/iç/derin.txt")), "abc")
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: b.appendingPathComponent("Klasör/bağ").path)
        XCTAssertEqual(link, "iç", "sembolik bağlantı bağlantı olarak kopyalanmalı")
        XCTAssertEqual(read(a.appendingPathComponent("dosya.txt")), "12345", "kopyalamada kaynak kalır")
        XCTAssertEqual(last.completedBytes, last.totalBytes)
        XCTAssertEqual(last.fraction, 1, accuracy: 0.001)
        XCTAssertEqual(r.created.map(\.lastPathComponent), ["dosya.txt", "Klasör"])
    }

    func testCopyIntoSameFolderMakesCopyName() throws {
        try write("x", a.appendingPathComponent("rapor.txt"))
        try FileManager.default.createDirectory(at: a.appendingPathComponent("Proje.v2"), withIntermediateDirectories: true)
        for _ in 0..<2 {
            let t = FileTransfer(kind: .copy, sources: [a.appendingPathComponent("rapor.txt"), a.appendingPathComponent("Proje.v2")], destination: a, copySuffix: "Kopya")
            XCTAssertTrue(t.run().errors.isEmpty)
        }
        XCTAssertEqual(names(a), ["rapor.txt", "rapor - Kopya.txt", "rapor - Kopya (2).txt",
                                  "Proje.v2", "Proje.v2 - Kopya", "Proje.v2 - Kopya (2)"])
    }

    func testMergeFoldersAndResolveConflicts() throws {
        try write("yeni-1", a.appendingPathComponent("K/bir.txt"))
        try write("yeni-2", a.appendingPathComponent("K/iki.txt"))
        try write("yeni-3", a.appendingPathComponent("K/üç.txt"))
        try write("yeni-4", a.appendingPathComponent("K/dört.txt"))
        try write("eski-1", b.appendingPathComponent("K/bir.txt"))
        try write("eski-2", b.appendingPathComponent("K/iki.txt"))
        try write("eski-3", b.appendingPathComponent("K/üç.txt"))
        try write("sadece-hedef", b.appendingPathComponent("K/hedef.txt"))

        let t = FileTransfer(kind: .copy, sources: [a.appendingPathComponent("K")], destination: b)
        let trashDir = root.appendingPathComponent(".çöp")
        t.trash = { url in   // gerçek Çöp Sepeti yerine testin klasörü
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let target = trashDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        var asked: [String] = []
        t.onConflict = { c in
            asked.append(c.source.lastPathComponent)
            switch c.source.lastPathComponent {
            case "bir.txt": return .replace
            case "iki.txt": return .skip
            default: return .keepBoth
            }
        }
        let r = t.run()
        XCTAssertTrue(r.errors.isEmpty)
        XCTAssertEqual(Set(asked), ["bir.txt", "iki.txt", "üç.txt"], "klasörün kendisi sorulmaz, birleştirilir")
        let k = b.appendingPathComponent("K")
        XCTAssertEqual(read(k.appendingPathComponent("bir.txt")), "yeni-1")
        XCTAssertEqual(read(k.appendingPathComponent("iki.txt")), "eski-2")
        XCTAssertEqual(read(k.appendingPathComponent("üç.txt")), "eski-3")
        XCTAssertEqual(read(k.appendingPathComponent("üç (2).txt")), "yeni-3")
        XCTAssertEqual(read(k.appendingPathComponent("dört.txt")), "yeni-4")
        XCTAssertEqual(read(k.appendingPathComponent("hedef.txt")), "sadece-hedef")
    }

    func testMoveSameVolumeAndSkipKeepsSource() throws {
        try write("1", a.appendingPathComponent("taşı.txt"))
        try write("2", a.appendingPathComponent("K/çakışan.txt"))
        try write("3", a.appendingPathComponent("K/serbest.txt"))
        try write("hedef", b.appendingPathComponent("K/çakışan.txt"))

        let t = FileTransfer(kind: .move, sources: [a.appendingPathComponent("taşı.txt"), a.appendingPathComponent("K")], destination: b)
        t.onConflict = { _ in .skip }
        let r = t.run()
        XCTAssertTrue(r.errors.isEmpty)
        XCTAssertEqual(read(b.appendingPathComponent("taşı.txt")), "1")
        XCTAssertFalse(FileInfo.exists(a.appendingPathComponent("taşı.txt")))
        XCTAssertEqual(read(b.appendingPathComponent("K/serbest.txt")), "3")
        XCTAssertEqual(read(b.appendingPathComponent("K/çakışan.txt")), "hedef")
        XCTAssertEqual(read(a.appendingPathComponent("K/çakışan.txt")), "2", "atlanan dosya kaynakta kalır, klasör silinmez")
        XCTAssertEqual(names(a.appendingPathComponent("K")), ["çakışan.txt"])
    }

    func testMoveIntoItselfIsRefusedAndSameFolderIsNoOp() throws {
        try FileManager.default.createDirectory(at: a.appendingPathComponent("alt"), withIntermediateDirectories: true)
        let into = FileTransfer(kind: .move, sources: [a], destination: a.appendingPathComponent("alt"))
        XCTAssertEqual(into.run().errors.map(\.failure), [.destinationInsideSource])
        XCTAssertTrue(FileInfo.exists(a.appendingPathComponent("alt")))

        let same = FileTransfer(kind: .move, sources: [a.appendingPathComponent("alt")], destination: a)
        let r = same.run()
        XCTAssertTrue(r.errors.isEmpty && r.created.isEmpty)
        XCTAssertTrue(FileInfo.exists(a.appendingPathComponent("alt")))
    }

    func testCancelStopsBeforeCopying() throws {
        for i in 0..<5 { try write("\(i)", a.appendingPathComponent("f\(i).txt")) }
        let sources = (0..<5).map { a.appendingPathComponent("f\($0).txt") }
        let t = FileTransfer(kind: .copy, sources: sources, destination: b)
        t.onProgress = { [weak t] _ in t?.cancel() }   // ilk bildirimde (toplamlar hesaplanınca) iptal
        let r = t.run()
        XCTAssertTrue(r.cancelled)
        XCTAssertTrue(names(b).isEmpty)
    }

    /// Klasör kopyalanırken İptal: kopyalanan dosyalar kalır (Windows gibi), yarım dosya kalmaz, geri almak klasörü kaldırır.
    func testCancelInsideFolderKeepsCompletedFiles() throws {
        let folder = a.appendingPathComponent("K")
        for i in 0..<400 { try write(String(repeating: "z", count: 300_000), folder.appendingPathComponent("f\(i).bin")) }
        let t = FileTransfer(kind: .copy, sources: [folder], destination: b)
        t.onProgress = { [weak t] p in if p.completedItems >= 5 { t?.cancel() } }
        let r = t.run()
        XCTAssertTrue(r.cancelled)
        let copied = b.appendingPathComponent("K")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: copied.path)) ?? []
        XCTAssertGreaterThan(files.count, 0, "kopyalananlar silinmemeli")
        XCTAssertLessThan(files.count, 400)
        for name in files {
            XCTAssertEqual(FileInfo.size(copied.appendingPathComponent(name)), 300_000, "yarım dosya kalmamalı: \(name)")
        }
        guard case .trash(let undone)? = r.undo.first, r.undo.count == 1 else { return XCTFail("\(r.undo)") }
        XCTAssertEqual(undone.standardizedFileURL.path, copied.path)
    }

    func testCancelledConflictStopsWholeTransfer() throws {
        try write("1", a.appendingPathComponent("a.txt"))
        try write("2", a.appendingPathComponent("b.txt"))
        try write("x", b.appendingPathComponent("a.txt"))
        let t = FileTransfer(kind: .copy, sources: [a.appendingPathComponent("a.txt"), a.appendingPathComponent("b.txt")], destination: b)
        t.onConflict = { _ in .cancel }
        let r = t.run()
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(names(b), ["a.txt"])
    }
}

final class NamingTests: XCTestCase {
    func testRemoteCopyName() {
        XCTAssertEqual(FileNaming.copyName("rapor.pdf", isDirectory: false, existing: ["rapor.pdf"], suffix: "Kopya"), "rapor - Kopya.pdf")
        XCTAssertEqual(FileNaming.copyName("rapor.pdf", isDirectory: false, existing: ["rapor.pdf", "rapor - Kopya.pdf"], suffix: "Kopya"),
                       "rapor - Kopya (2).pdf")
        XCTAssertEqual(FileNaming.copyName("Proje.v2", isDirectory: true, existing: [], suffix: "Kopya"), "Proje.v2 - Kopya")
        XCTAssertEqual(FileNaming.copyName(".env", isDirectory: false, existing: [], suffix: "Kopya"), ".env - Kopya")
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacExplorerNaming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testNewFolderAndFileNumbering() throws {
        XCTAssertEqual(try FileCreator.newFolder(in: dir, name: "Yeni klasör").lastPathComponent, "Yeni klasör")
        XCTAssertEqual(try FileCreator.newFolder(in: dir, name: "Yeni klasör").lastPathComponent, "Yeni klasör (2)")
        XCTAssertEqual(try FileCreator.newFile(in: dir, name: "Yeni Metin Belgesi.txt").lastPathComponent, "Yeni Metin Belgesi.txt")
        XCTAssertEqual(try FileCreator.newFile(in: dir, name: "Yeni Metin Belgesi.txt").lastPathComponent, "Yeni Metin Belgesi (2).txt")
        XCTAssertEqual(try FileCreator.newFile(in: dir, name: ".gizli").lastPathComponent, ".gizli")
        XCTAssertEqual(try FileCreator.newFile(in: dir, name: ".gizli").lastPathComponent, ".gizli (2)")
    }

    func testBaseNameLength() {
        XCTAssertEqual(FileNaming.baseNameLength(of: "rapor.final.pdf", isDirectory: false), 11)
        XCTAssertEqual(FileNaming.baseNameLength(of: ".zshrc", isDirectory: false), 6)
        XCTAssertEqual(FileNaming.baseNameLength(of: "Proje.v2", isDirectory: true), 8)
        XCTAssertEqual(FileNaming.baseNameLength(of: "Özet", isDirectory: false), 4)
    }

    func testRename() throws {
        let file = try FileCreator.newFile(in: dir, name: "rapor.txt")
        _ = try FileCreator.newFile(in: dir, name: "başka.txt")
        XCTAssertThrowsError(try FileRenamer.rename(file, to: "  ")) { XCTAssertEqual($0 as? RenameError, .empty) }
        XCTAssertThrowsError(try FileRenamer.rename(file, to: "a/b")) { XCTAssertEqual($0 as? RenameError, .invalidCharacters) }
        XCTAssertThrowsError(try FileRenamer.rename(file, to: "başka.txt")) { XCTAssertEqual($0 as? RenameError, .exists) }
        let upper = try FileRenamer.rename(file, to: "Rapor.txt")   // yalnızca büyük/küçük harf
        XCTAssertEqual(upper.lastPathComponent, "Rapor.txt")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: dir.path)).contains("Rapor.txt"))
        let renamed = try FileRenamer.rename(upper, to: "Özet.md")
        XCTAssertTrue(FileInfo.exists(renamed))
        XCTAssertFalse(FileInfo.exists(upper))
    }
}

final class FileUndoTests: XCTestCase {
    private var root: URL!
    private var trashDir: URL!
    private var trash: FileUndo.Trash!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacExplorerUndo-\(UUID().uuidString)")
        trashDir = root.appendingPathComponent(".çöp")
        for d in ["A", "B", ".çöp"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        // Gerçek Çöp Sepeti yerine testin kendi klasörü
        let dir = trashDir!
        trash = { url in
            let target = FileNaming.uniqueName(for: dir.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func exists(_ path: String) -> Bool { FileInfo.exists(root.appendingPathComponent(path)) }

    func testUndoAndRedoMoveWithMergedFolder() throws {
        try write("1", "A/taşı.txt")
        try write("2", "A/K/iç.txt")
        try write("hedef", "B/K/var.txt")
        let t = FileTransfer(kind: .move, sources: [root.appendingPathComponent("A/taşı.txt"), root.appendingPathComponent("A/K")],
                             destination: root.appendingPathComponent("B"))
        let r = t.run()
        XCTAssertTrue(exists("B/K/iç.txt") && !exists("A/K"))

        let undone = FileUndo.perform(r.undo, trash: trash)
        XCTAssertTrue(undone.errors.isEmpty, "\(undone.errors)")
        XCTAssertEqual(read("A/taşı.txt"), "1")
        XCTAssertEqual(read("A/K/iç.txt"), "2", "birleştirilip silinen kaynak klasör geri oluşur")
        XCTAssertFalse(exists("B/taşı.txt"))
        XCTAssertEqual(read("B/K/var.txt"), "hedef")

        let redone = FileUndo.perform(undone.inverse, trash: trash)
        XCTAssertTrue(redone.errors.isEmpty)
        XCTAssertEqual(read("B/taşı.txt"), "1")
        XCTAssertEqual(read("B/K/iç.txt"), "2")
    }

    func testUndoCopyWithReplaceRestoresOriginal() throws {
        try write("yeni", "A/rapor.txt")
        try write("eski", "B/rapor.txt")
        try write("x", "A/diğer.txt")
        let t = FileTransfer(kind: .copy, sources: [root.appendingPathComponent("A/rapor.txt"), root.appendingPathComponent("A/diğer.txt")],
                             destination: root.appendingPathComponent("B"))
        t.trash = trash
        t.onConflict = { _ in .replace }
        let r = t.run()
        XCTAssertEqual(read("B/rapor.txt"), "yeni")

        let undone = FileUndo.perform(r.undo, trash: trash)
        XCTAssertTrue(undone.errors.isEmpty, "\(undone.errors)")
        XCTAssertEqual(read("B/rapor.txt"), "eski", "değiştirilen dosya geri gelir")
        XCTAssertFalse(exists("B/diğer.txt"), "kopya kaldırılır")
        XCTAssertEqual(read("A/rapor.txt"), "yeni", "kaynak yerinde")

        let redone = FileUndo.perform(undone.inverse, trash: trash)
        XCTAssertTrue(redone.errors.isEmpty)
        XCTAssertEqual(read("B/rapor.txt"), "yeni")
        XCTAssertEqual(read("B/diğer.txt"), "x")
    }

    func testUndoRefusesToOverwrite() throws {
        try write("taşınan", "B/a.txt")
        try write("sonradan", "A/a.txt")   // geri alınmadan önce aynı adla yeni dosya oluşmuş
        let r = FileUndo.perform([.move(from: root.appendingPathComponent("B/a.txt"), to: root.appendingPathComponent("A/a.txt"))], trash: trash)
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertTrue(r.inverse.isEmpty)
        XCTAssertEqual(read("A/a.txt"), "sonradan")
        XCTAssertEqual(read("B/a.txt"), "taşınan")
    }

    func testTrashAndRestore() throws {
        try write("veri", "A/sil.txt")
        let removed = FileUndo.perform([.trash(root.appendingPathComponent("A/sil.txt"))], trash: trash)
        XCTAssertFalse(exists("A/sil.txt"))
        let restored = FileUndo.perform(removed.inverse, trash: trash)
        XCTAssertTrue(restored.errors.isEmpty)
        XCTAssertEqual(read("A/sil.txt"), "veri")
    }
}
