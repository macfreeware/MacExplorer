import XCTest
@testable import MacExplorerCore

final class UpdateInfoTests: XCTestCase {
    func testParseRelease() throws {
        let json = """
        {"tag_name":"v1.3.0","description":"Notlar","_links":{"self":"https://gitlab.com/freeware2/macexplorer/-/releases/v1.3.0"},
         "assets":{"links":[
           {"name":"MacExplorer.zip","url":"https://gitlab.com/a","direct_asset_url":"https://gitlab.com/d/MacExplorer.zip"},
           {"name":"MacExplorer.zip.sha256","url":"https://gitlab.com/b"}]}}
        """
        let r = try UpdateInfo.parse(Data(json.utf8))
        XCTAssertEqual(r.version, "1.3.0")
        XCTAssertEqual(r.notes, "Notlar")
        XCTAssertEqual(r.archive?.absoluteString, "https://gitlab.com/d/MacExplorer.zip")
        XCTAssertEqual(r.checksum?.absoluteString, "https://gitlab.com/b")
        XCTAssertEqual(r.page?.lastPathComponent, "v1.3.0")
    }

    func testParseReleaseWithoutAssets() throws {
        let r = try UpdateInfo.parse(Data(#"{"tag_name":"1.2.1"}"#.utf8))
        XCTAssertEqual(r.version, "1.2.1")
        XCTAssertNil(r.archive)
    }

    func testOnlyGitLabLinksAreAccepted() throws {
        let json = """
        {"tag_name":"v2.0.0","_links":{"self":"https://evil.example/page"},"assets":{"links":[
          {"name":"MacExplorer.zip","url":"https://gitlab.com/ok","direct_asset_url":"https://evil.example/MacExplorer.zip"},
          {"name":"MacExplorer.zip.sha256","url":"http://gitlab.com/plain"}]}}
        """
        let r = try UpdateInfo.parse(Data(json.utf8))
        XCTAssertNil(r.archive)
        XCTAssertNil(r.checksum)
        XCTAssertNil(r.page)
        XCTAssertNotNil(try UpdateInfo.parse(Data(json.utf8), allowAnyHost: true).archive)
        XCTAssertFalse(UpdateInfo.isTrusted(URL(string: "https://gitlab.com.evil.example/a")!))
        XCTAssertTrue(UpdateInfo.isTrusted(URL(string: "https://gitlab.com/freeware2/a")!))
    }

    func testCanReplaceNeedsWritableAppAndFolder() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("MacExplorerUpdate-\(UUID().uuidString)", isDirectory: true)
        let app = folder.appendingPathComponent("Deneme.app", isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
            try? fm.removeItem(at: folder)
        }
        XCTAssertTrue(UpdateInfo.canReplace(app: app))
        XCTAssertFalse(UpdateInfo.canReplace(app: folder), "uzantısı .app olmayan")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.path)
        XCTAssertFalse(UpdateInfo.canReplace(app: app), "paket salt okunur")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertFalse(UpdateInfo.canReplace(app: app), "klasör salt okunur")
    }

    func testVersionCompare() {
        XCTAssertTrue(UpdateInfo.isNewer("1.2.2", than: "1.2.1"))
        XCTAssertTrue(UpdateInfo.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(UpdateInfo.isNewer("1.2.1", than: "1.2"))
        XCTAssertFalse(UpdateInfo.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateInfo.isNewer("1.2.1", than: "1.2.1"))
        XCTAssertFalse(UpdateInfo.isNewer("1.2.0", than: "1.3"))
    }

    func testCheckDue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdateInfo.isCheckDue(lastCheck: Date(timeIntervalSince1970: 0), now: now))      // hiç denetlenmedi
        XCTAssertTrue(UpdateInfo.isCheckDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertFalse(UpdateInfo.isCheckDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertFalse(UpdateInfo.isCheckDue(lastCheck: now, now: now))
        XCTAssertTrue(UpdateInfo.isCheckDue(lastCheck: now.addingTimeInterval(3600), now: now))       // saat geri alındı
    }

    func testChecksum() {
        let hex = String(repeating: "aB", count: 32)
        XCTAssertEqual(UpdateInfo.parseChecksum("\(hex)  MacExplorer.zip\n"), hex.lowercased())
        XCTAssertEqual(UpdateInfo.parseChecksum(hex), hex.lowercased())
        XCTAssertNil(UpdateInfo.parseChecksum("xyz  MacExplorer.zip"))
        XCTAssertNil(UpdateInfo.parseChecksum(""))
    }
}
