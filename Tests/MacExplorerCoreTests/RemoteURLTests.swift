import XCTest
@testable import MacExplorerCore

final class RemoteURLTests: XCTestCase {
    func testMakeAndPath() {
        let url = RemoteURL.make(scheme: "sftp", user: "ali", host: "sunucu", port: 2222, path: "/var/www/site dosyaları/")!
        XCTAssertTrue(url.isRemote)
        XCTAssertEqual(RemoteURL.path(of: url), "/var/www/site dosyaları")
        XCTAssertEqual(RemoteURL.serverKey(url), "sftp://ali@sunucu:2222")
        XCTAssertEqual(RemoteURL.path(of: URL(string: "ftp://sunucu")!), "/")
    }

    func testClean() {
        XCTAssertEqual(RemoteURL.clean("//a/./b/../c/"), "/a/c")
        XCTAssertEqual(RemoteURL.clean(""), "/")
        XCTAssertEqual(RemoteURL.clean("/.."), "/")
    }

    func testLocationKeyAndNormalize() {
        let a = URL(string: "sftp://ali@Sunucu/a/b/")!
        let b = URL(string: "sftp://ali@sunucu/a/b")!
        XCTAssertEqual(a.locationKey, b.locationKey)
        XCTAssertNotEqual(a.locationKey, URL(string: "ftp://ali@sunucu/a/b")!.locationKey)
        XCTAssertTrue(a.normalizedFileURL.isRemote)
        XCTAssertEqual(RemoteURL.path(of: a.normalizedFileURL), "/a/b")
        XCTAssertFalse(URL(fileURLWithPath: "/tmp").isRemote)
    }

    func testHistoryWithRemote() {
        var history = NavigationHistory(start: URL(fileURLWithPath: "/tmp"))
        history.visit(URL(string: "sftp://ali@sunucu/home/ali/")!)
        history.visit(URL(string: "sftp://ali@sunucu/home/ali")!)   // aynı konum: geçmişe eklenmez
        XCTAssertEqual(history.backStack.count, 1)
        XCTAssertTrue(history.current.isRemote)
        XCTAssertEqual(history.goBack()?.path, "/tmp")
        let restored = NavigationHistory(current: URL(string: "ftp://sunucu/a")!, back: [URL(string: "ftp://sunucu/")!], forward: [])
        XCTAssertEqual(restored.backStack.count, 1)
    }
}
