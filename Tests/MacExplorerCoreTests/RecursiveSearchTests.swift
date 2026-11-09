import XCTest
@testable import MacExplorerCore

final class RecursiveSearchTests: XCTestCase {
    func testFindsInSubfoldersSkipsHiddenAndPackages() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("rs-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".gizli"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Uygulama.app/Contents"), withIntermediateDirectories: true)
        for path in ["Özet.txt", "a/özet 2.txt", "a/b/OZET-son.pdf", "a/b/diğer.txt", ".gizli/özet.txt", "Uygulama.app/Contents/ozet.txt"] {
            fm.createFile(atPath: root.appendingPathComponent(path).path, contents: Data())
        }
        defer { try? fm.removeItem(at: root) }

        func names(hidden: Bool, limit: Int = 100) -> (Set<String>, Bool) {
            var found: [FileItem] = []
            var truncated = false
            RecursiveSearch(root: root, query: "ozet", showHidden: hidden, limit: limit)
                .run(batch: { found += $0 }, finished: { truncated = $0 })
            return (Set(found.map { $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: "") }), truncated)
        }
        XCTAssertEqual(names(hidden: false).0, ["Özet.txt", "a/özet 2.txt", "a/b/OZET-son.pdf"])
        XCTAssertTrue(names(hidden: true).0.contains(".gizli/özet.txt"))
        XCTAssertFalse(names(hidden: true).0.contains("Uygulama.app/Contents/ozet.txt"))   // paket içine girilmez
        XCTAssertEqual(names(hidden: false, limit: 2).0.count, 2)
        XCTAssertTrue(names(hidden: false, limit: 2).1)
    }
}
