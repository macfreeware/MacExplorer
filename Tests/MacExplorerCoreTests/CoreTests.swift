import XCTest
@testable import MacExplorerCore

final class FileSortTests: XCTestCase {
    private func file(_ name: String, size: Int64 = 0, date: TimeInterval = 0, kind: String = "Belge") -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, displayName: name, isDirectory: false,
                 size: size, modified: Date(timeIntervalSince1970: date), kind: kind)
    }

    private func folder(_ name: String) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, displayName: name, isDirectory: true, kind: "Klasör")
    }

    func testFoldersFirstAndNaturalOrder() {
        let items = [file("Dosya 10"), folder("b"), file("Dosya 2"), folder("A")]
        XCTAssertEqual(FileSort().sorted(items).map(\.name), ["A", "b", "Dosya 2", "Dosya 10"])
    }

    func testDescendingKeepsFoldersFirst() {
        let items = [file("a"), folder("x"), file("c"), folder("y")]
        XCTAssertEqual(FileSort(column: .name, ascending: false).sorted(items).map(\.name), ["y", "x", "c", "a"])
    }

    func testSizeAndDateWithNameTieBreak() {
        let items = [file("b", size: 10), file("a", size: 10), file("c", size: 5)]
        XCTAssertEqual(FileSort(column: .size).sorted(items).map(\.name), ["c", "a", "b"])
        XCTAssertEqual(FileSort(column: .size, ascending: false).sorted(items).map(\.name), ["a", "b", "c"])
        let dated = [file("x", date: 30), file("y", date: 10), file("z", date: 20)]
        XCTAssertEqual(FileSort(column: .modified).sorted(dated).map(\.name), ["y", "z", "x"])
    }
}

final class SizeFormatTests: XCTestCase {
    func testWindowsStyleKilobytes() {
        let tr = Locale(identifier: "tr_TR"), en = Locale(identifier: "en_US")
        XCTAssertEqual(SizeFormat.kilobytes(0, locale: tr), "0 KB")
        XCTAssertEqual(SizeFormat.kilobytes(1, locale: tr), "1 KB")
        XCTAssertEqual(SizeFormat.kilobytes(1024, locale: tr), "1 KB")
        XCTAssertEqual(SizeFormat.kilobytes(1025, locale: tr), "2 KB")
        XCTAssertEqual(SizeFormat.kilobytes(1234 * 1024, locale: tr), "1.234 KB")
        XCTAssertEqual(SizeFormat.kilobytes(1234 * 1024, locale: en), "1,234 KB")
    }
}

final class NavigationHistoryTests: XCTestCase {
    func testBackForward() {
        var h = NavigationHistory(start: URL(fileURLWithPath: "/a"))
        h.visit(URL(fileURLWithPath: "/a/b"))
        h.visit(URL(fileURLWithPath: "/a/b/"))   // aynı konum: eklenmez
        h.visit(URL(fileURLWithPath: "/c"))
        XCTAssertEqual(h.backStack.map(\.path), ["/a", "/a/b"])
        XCTAssertEqual(h.goBack()?.path, "/a/b")
        XCTAssertTrue(h.canGoForward)
        XCTAssertEqual(h.goForward()?.path, "/c")
        h.goBack()
        h.visit(URL(fileURLWithPath: "/d"))       // yeni konum ileri geçmişi siler
        XCTAssertFalse(h.canGoForward)
        XCTAssertEqual(h.current.path, "/d")
    }
}

final class DirectoryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacExplorerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Klasör"), withIntermediateDirectories: true)
        try Data("merhaba".utf8).write(to: dir.appendingPathComponent("Özet.txt"))
        try Data().write(to: dir.appendingPathComponent(".gizli"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("bağlantı"),
                                                   withDestinationURL: dir.appendingPathComponent("Klasör"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReadAndHidden() throws {
        let visible = try DirectoryReader.read(dir, showHidden: false)
        XCTAssertEqual(Set(visible.map(\.name)), ["Klasör", "Özet.txt", "bağlantı"])
        let all = try DirectoryReader.read(dir, showHidden: true)
        XCTAssertTrue(all.contains { $0.name == ".gizli" && $0.isHidden })

        let text = try XCTUnwrap(visible.first { $0.name == "Özet.txt" })
        XCTAssertFalse(text.isDirectory)
        XCTAssertEqual(text.size, 7)
        let link = try XCTUnwrap(visible.first { $0.name == "bağlantı" })
        XCTAssertTrue(link.isDirectory, "klasörü gösteren bağlantı klasör gibi açılmalı")
        XCTAssertTrue(link.isSymbolicLink)
    }

    func testFilter() {
        XCTAssertTrue(NameFilter.matches("Özet.txt", query: "ozet"))
        XCTAssertTrue(NameFilter.matches("Rapor", query: "  "))
        XCTAssertFalse(NameFilter.matches("Rapor", query: "x"))
    }

    func testWatcherFiresOnChange() throws {
        let fired = expectation(description: "değişiklik bildirildi")
        let watcher = DirectoryWatcher(url: dir, queue: .main, latency: 0.05) { fired.fulfill() }
        XCTAssertNotNil(watcher)
        try Data().write(to: dir.appendingPathComponent("yeni.txt"))
        wait(for: [fired], timeout: 3)
        _ = watcher
    }
}

final class ShellQuoteTests: XCTestCase {
    func testQuote() {
        XCTAssertEqual(ShellQuote.quote("/Users/ali/Belgeler/özet.txt"), "/Users/ali/Belgeler/özet.txt")
        XCTAssertEqual(ShellQuote.quote("/Volumes/My Disk/a b"), "'/Volumes/My Disk/a b'")
        XCTAssertEqual(ShellQuote.quote("/tmp/it's"), "'/tmp/it'\\''s'")
        XCTAssertEqual(ShellQuote.quote("/tmp/$HOME(1)"), "'/tmp/$HOME(1)'")
    }
}

final class SavedHistoryTests: XCTestCase {
    func testRestoreSkipsMissingFolders() {
        let existing: Set<String> = ["/a", "/c"]
        var h = NavigationHistory(current: URL(fileURLWithPath: "/b"),
                                  back: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/silindi")],
                                  forward: [URL(fileURLWithPath: "/c")], exists: { existing.contains($0.path) })
        XCTAssertEqual(h.backStack.map(\.path), ["/a"])
        XCTAssertEqual(h.goForward()?.path, "/c")
        XCTAssertEqual(h.goBack()?.path, "/b")
        XCTAssertEqual(h.goBack()?.path, "/a")
    }
}

final class PatternTests: XCTestCase {
    func testWildcards() {
        XCTAssertTrue(NameFilter.matchesPattern("rapor.pdf", pattern: "*.pdf"))
        XCTAssertTrue(NameFilter.matchesPattern("RAPOR.PDF", pattern: "*.pdf"))
        XCTAssertTrue(NameFilter.matchesPattern("Şubat.txt", pattern: "s*.TXT"))
        XCTAssertFalse(NameFilter.matchesPattern("rapor.pdf.zip", pattern: "*.pdf"))
        XCTAssertTrue(NameFilter.matchesPattern("a1.jpg", pattern: "*.png; a?.jpg"))
        XCTAssertTrue(NameFilter.matchesPattern("foto.jpeg", pattern: "*.jpg,*.jpeg"))
        XCTAssertTrue(NameFilter.matchesPattern("x", pattern: "*"))
        XCTAssertFalse(NameFilter.matchesPattern("x", pattern: "  "))
    }
}
