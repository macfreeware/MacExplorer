import XCTest
@testable import MacExplorerCore

final class MacRARBridgeTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("MacExplorerHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: MacRARBridge.supportDirectory(home: home), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeSupport(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: MacRARBridge.supportDirectory(home: home).appendingPathComponent(name))
    }

    func testToken() throws {
        XCTAssertNil(MacRARBridge.token(home: home))
        try writeSupport("finder.token", String(repeating: "ab", count: 32) + "\n")
        XCTAssertEqual(MacRARBridge.token(home: home), String(repeating: "ab", count: 32))
        try writeSupport("finder.token", "kısa")
        XCTAssertNil(MacRARBridge.token(home: home))
        try writeSupport("finder.token", String(repeating: "AB", count: 32))
        XCTAssertNil(MacRARBridge.token(home: home), "MacRAR yalnızca küçük harf onaltılık kabul eder")
    }

    func testCanCompressRAR() throws {
        XCTAssertFalse(MacRARBridge.canCompressRAR(home: home, exists: { _ in false }))
        XCTAssertTrue(MacRARBridge.canCompressRAR(home: home, exists: { $0 == "/opt/homebrew/bin/rar" }))
        try writeSupport("finder.state", "rar=0\nlang=tr\n")
        XCTAssertFalse(MacRARBridge.canCompressRAR(home: home, exists: { _ in true }))
        try writeSupport("finder.state", "rar=1\n")
        XCTAssertTrue(MacRARBridge.canCompressRAR(home: home, exists: { _ in false }))
    }

    func testActionsForSelection() {
        let rar = URL(fileURLWithPath: "/x/a.rar"), part = URL(fileURLWithPath: "/x/a.r01"), doc = URL(fileURLWithPath: "/x/b.txt")
        XCTAssertEqual(MacRARBridge.actions(for: [rar, part], canCompressRAR: true), [.open, .extractDialog, .extractHere, .extractFolder])
        XCTAssertEqual(MacRARBridge.actions(for: [rar, doc], canCompressRAR: true), [.add, .compress, .compressStamped, .compressZip, .compressZipStamped])
        XCTAssertEqual(MacRARBridge.actions(for: [doc], canCompressRAR: false), [.add, .compressZip, .compressZipStamped])
        XCTAssertEqual(MacRARBridge.actions(for: [], canCompressRAR: true), [])
    }

    func testCommandURLMatchesMacRARFormat() throws {
        let token = String(repeating: "0f", count: 32)
        let url = try XCTUnwrap(MacRARBridge.commandURL(action: .extractHere, paths: ["/a b/ç.rar", "/x&y.zip"], token: token))
        XCTAssertEqual(url.scheme, "macrar")
        XCTAssertEqual(url.host, "extractHere")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "t" }?.value, token)
        XCTAssertEqual(items.filter { $0.name == "p" }.map(\.value), ["/a b/ç.rar", "/x&y.zip"])
    }
}

final class ShortcutAndZipTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacExplorerZip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Klasör"), withIntermediateDirectories: true)
        try Data("içerik".utf8).write(to: dir.appendingPathComponent("Klasör/iç.txt"))
        try Data("rapor".utf8).write(to: dir.appendingPathComponent("rapor.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAliasResolvesToTarget() throws {
        let target = dir.appendingPathComponent("rapor.txt")
        let alias = try ShortcutMaker.createAlias(to: target, in: dir, suffix: "Kısayol")
        XCTAssertEqual(alias.lastPathComponent, "rapor.txt - Kısayol")
        XCTAssertEqual(try URL(resolvingAliasFileAt: alias).standardizedFileURL.path, target.standardizedFileURL.path)
        let second = try ShortcutMaker.createAlias(to: target, in: dir, suffix: "Kısayol")
        XCTAssertEqual(second.lastPathComponent, "rapor.txt - Kısayol (2)")
    }

    func testZipSingleAndMultiple() throws {
        let single = try ZipMaker.zip([dir.appendingPathComponent("Klasör")], in: dir, name: "x")
        XCTAssertEqual(single.lastPathComponent, "Klasör.zip")
        let multi = try ZipMaker.zip([dir.appendingPathComponent("rapor.txt"), dir.appendingPathComponent("Klasör")], in: dir, name: "rapor")
        XCTAssertEqual(multi.lastPathComponent, "rapor.zip")
        let again = try ZipMaker.zip([dir.appendingPathComponent("rapor.txt")], in: dir, name: "rapor")
        XCTAssertEqual(again.lastPathComponent, "rapor (2).zip")

        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        list.arguments = ["-tf", multi.path]
        list.environment = ["LC_ALL": "en_US.UTF-8"]
        let out = Pipe()
        list.standardOutput = out
        try list.run()
        let names = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).precomposedStringWithCanonicalMapping
        list.waitUntilExit()
        XCTAssertTrue(names.contains("rapor.txt"))
        XCTAssertTrue(names.contains("Klasör/iç.txt"))
        XCTAssertFalse(names.contains("__MACOSX"))
        // Ad alanında UTF-8 işareti (genel amaçlı bayrak 0x800): Windows Türkçe adları doğru gösterir.
        let data = try Data(contentsOf: single)
        let flags = UInt16(data[6]) | UInt16(data[7]) << 8
        XCTAssertEqual(flags & 0x800, 0x800)
    }
}
