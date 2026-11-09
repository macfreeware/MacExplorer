import AppKit
import FTPKit
import MacExplorerCore

/// Arşivin içinde klasör gibi gezinme (Windows'ta ZIP'e çift tıklamak gibi), salt okunur.
/// Okuma macOS'un kendi `bsdtar` (libarchive) aracıyla: ZIP, RAR, 7Z, TAR (gz/bz2/xz/zst), CAB, XAR, CPIO, LHA.
/// Arşiv, uzak klasör altyapısına bir "sunucu" olarak bağlanır (`archive://arşiv-adı@kimlik/iç/yol`):
/// gezinme, adres çubuğu, önizleme, sürükleyip dışarı bırakarak ve kopyala-yapıştırla çıkarma oradan gelir.
/// Arşivi düzenlemek (ekleme, silme) MacRAR'ın işidir.
@MainActor
enum Archives {
    static let scheme = "archive"

    /// Gezinilebilen arşivler. Tek dosyalık sıkıştırmalar (.gz, .xz tek başına) ve disk görüntüleri (bağlanır) hariç.
    static let browsable: Set<String> = ["zip", "rar", "7z", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "cab", "xar", "cpio", "lha", "lzh", "jar"]

    static func isBrowsable(_ url: URL) -> Bool {
        guard !url.isRemote else { return false }
        let name = url.lastPathComponent.lowercased()
        if browsable.contains(url.pathExtension.lowercased()) { return true }
        return [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"].contains { name.hasSuffix($0) }
    }

    /// Çift tıklayınca içine girilen türler (Windows'taki gibi ZIP); diğerleri varsayılan uygulamayla (MacRAR) açılır.
    static func opensInPlace(_ url: URL) -> Bool { !url.isRemote && url.pathExtension.lowercased() == "zip" }

    /// Açık arşivler: kimlik → arşiv dosyası.
    private static var files: [String: URL] = [:]

    /// Arşivin kök adresi; oturum ilk kez burada kurulur.
    static func open(_ file: URL) -> URL? {
        let id = identifier(for: file)
        files[id] = file
        let base = RemoteURL.make(scheme: scheme, user: file.lastPathComponent, host: id, port: nil, path: "/")
        if let base { RemoteSessions.register(archive: file, base: base) }
        return base
    }

    static func file(for url: URL) -> URL? {
        guard url.scheme == scheme, let host = url.host else { return nil }
        return files[host.lowercased()]
    }

    nonisolated static func isArchive(_ url: URL) -> Bool { url.scheme == "archive" }

    /// Yoldan türetilen kısa kimlik: aynı arşiv yeniden açılınca aynı adres.
    private static func identifier(for file: URL) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in file.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "a" + String(hash, radix: 36)
    }

    /// Arşivin adı (adres çubuğu, sekme başlığı).
    nonisolated static func displayName(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.user ?? url.host ?? ""
    }
}

/// Arşivi okuyan "istemci": içindekiler bir kez listelenir (önbellekte), dosyalar tek tek `bsdtar -xO` ile çıkarılır.
final class ArchiveClient: RemoteClient, @unchecked Sendable {
    let file: URL
    let config: FTPConfig
    private let lock = NSLock()
    private var index: ArchiveIndex?

    init(file: URL) {
        self.file = file
        config = FTPConfig(host: "archive", serverProtocol: .ftp)
    }

    var isConnected: Bool { lock.withLock { index != nil } }
    var homeDirectory: String { "/" }

    func connect() async throws {
        for attempt in 0..<4 {
            do {
                let built = try await Task.detached { [file] in try ArchiveIndex.load(file) }.value
                lock.withLock { index = built }
                return
            } catch ArchivePassword.Needed.password {
                guard attempt < 3, await ArchivePassword.ask(for: file, failed: attempt > 0) else {
                    throw FTPError.local(String(localized: "Arşiv parolalı; parola girilmedi.", bundle: .live))
                }
            }
        }
    }

    func disconnect() async { lock.withLock { index = nil } }

    func list(_ path: String) async throws -> (path: String, files: [RemoteFile]) {
        guard let index = lock.withLock({ index }) else { throw FTPError.notConnected }
        let clean = RemoteURL.clean(path)
        guard let children = index.children[clean] else {
            throw FTPError.local(String(localized: "Arşivde böyle bir klasör yok.", bundle: .live))
        }
        return (clean, children)
    }

    func size(_ path: String) async throws -> Int64? {
        lock.withLock { index?.entries[RemoteURL.clean(path)]?.size }
    }

    func modified(_ path: String) async throws -> Date? {
        lock.withLock { index?.entries[RemoteURL.clean(path)]?.modified }
    }

    func download(_ remotePath: String, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let entry = lock.withLock({ index?.entries[RemoteURL.clean(remotePath)] }) else {
            throw FTPError.local(String(localized: "Arşivde bu dosya yok.", bundle: .live))
        }
        for attempt in 0..<4 {
            do {
                return try await extract(entry, to: localURL, progress: progress)
            } catch ArchivePassword.Needed.password {
                // Parolalı arşiv: sorulur, bu oturumda hatırlanır.
                guard attempt < 3, await ArchivePassword.ask(for: file, failed: attempt > 0) else {
                    throw FTPError.local(String(localized: "Arşiv parolalı; parola girilmedi.", bundle: .live))
                }
            }
        }
    }

    private func extract(_ entry: ArchiveIndex.Entry, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: localURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        // Ad desen olarak eşleştirilir: * ? [ ] \ kaçışlanır. Parola her zaman verilir: verilmezse bsdtar
        // terminalden sormaya çalışır ve sonsuza dek bekler.
        process.arguments = ArchivePassword.arguments(for: file) + ["-xOf", file.path, ArchiveIndex.escape(entry.member)]
        process.environment = ArchiveIndex.environment
        process.standardOutput = output
        let err = Pipe()
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { process.waitUntilExit(); cont.resume() }
            }
        } onCancel: {
            process.terminate()
        }
        if Task.isCancelled { try? FileManager.default.removeItem(at: localURL) }
        try Task.checkCancellation()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0, !ArchivePassword.isPasswordError(message) else {
            try? FileManager.default.removeItem(at: localURL)   // yarım dosya kalmasın
            throw ArchivePassword.isPasswordError(message) ? ArchivePassword.Needed.password : ArchiveIndex.error(message)
        }
        progress(entry.size)
        if let date = entry.modified { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: localURL.path) }
    }

    // Salt okunur: düzenleme MacRAR ile.
    private func readOnly() -> FTPError {
        FTPError.local(String(localized: "Arşiv salt okunur. Arşive eklemek ya da arşivden silmek için MacRAR ile açın.", bundle: .live))
    }
    func makeDirectory(_ path: String) async throws { throw readOnly() }
    func deleteFile(_ path: String) async throws { throw readOnly() }
    func removeDirectory(_ path: String, recursive: Bool) async throws { throw readOnly() }
    func rename(_ from: String, to: String) async throws { throw readOnly() }
    func chmod(_ path: String, mode: String) async throws { throw readOnly() }
    func setModified(_ path: String, to date: Date) async throws -> Bool { false }
    func noop() async throws {}
    func upload(_ localURL: URL, to remotePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws { throw readOnly() }
}

/// Arşivin içindekiler: `bsdtar -tv` çıktısından klasör ağacı (klasör kayıtları olmayan arşivlerde klasörler yollardan türetilir).
struct ArchiveIndex: Sendable {
    struct Entry: Sendable {
        let member: String     // arşivdeki adı (çıkarırken)
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
    }

    var entries: [String: Entry] = [:]
    var children: [String: [RemoteFile]] = [:]

    /// Ay adları İngilizce, adlar UTF-8 gelsin.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }()

    static func escape(_ name: String) -> String {
        var out = ""
        for ch in name {
            if "*?[]\\".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func error(_ message: String) -> FTPError {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("passphrase") || lower.contains("encrypt") || lower.contains("password") {
            return .local(String(localized: "Arşiv parolalı. İçindekileri çıkarmak için MacRAR ile açın.", bundle: .live))
        }
        return .local(text.isEmpty ? String(localized: "Arşiv okunamadı.", bundle: .live) : text.replacingOccurrences(of: "bsdtar: ", with: ""))
    }

    static func load(_ file: URL) throws -> ArchiveIndex {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        p.arguments = ArchivePassword.arguments(for: file) + ["-tvf", file.path]
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        nonisolated(unsafe) var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errorData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let message = String(decoding: errorData, as: UTF8.self)
        if text.isEmpty && ArchivePassword.isPasswordError(message) { throw ArchivePassword.Needed.password }
        if p.terminationStatus != 0 && text.isEmpty { throw error(message) }
        return build(text)
    }

    static func build(_ listing: String) -> ArchiveIndex {
        var index = ArchiveIndex()
        var dirs: Set<String> = ["/"]
        var files: [(String, Entry)] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            guard let (member, entry) = parse(String(line)) else { continue }
            var path = member
            while path.hasPrefix("./") { path.removeFirst(2) }
            path = RemoteURL.clean(path.precomposedStringWithCanonicalMapping)
            guard path != "/" else { continue }
            if entry.isDirectory { dirs.insert(path) } else { files.append((path, entry)) }
            index.entries[path] = entry
            // Ara klasörler (kaydı olmayanlar dahil)
            var parent = RemotePath.parent(path)
            while parent != "/" && dirs.insert(parent).inserted { parent = RemotePath.parent(parent) }
        }
        // Önce tüm klasörler boş liste alır: `dirs` sırasızdır, tek döngüde bir üst klasör sonradan sıfırlanıp altındakileri
        // silebilirdi (arşiv rastgele boş görünürdü).
        for dir in dirs { index.children[dir] = [] }
        for dir in dirs where dir != "/" {
            let entry = index.entries[dir]
            index.children[RemotePath.parent(dir), default: []].append(
                RemoteFile(name: RemotePath.name(dir), isDirectory: true, modified: entry?.modified ?? .distantPast))
        }
        for (path, entry) in files {
            index.children[RemotePath.parent(path), default: []].append(
                RemoteFile(name: RemotePath.name(path), isDirectory: false, size: entry.size, modified: entry.modified ?? .distantPast))
        }
        return index
    }

    /// "-rw-r--r--  0 501  0   36249 Nov  4 12:17 alt klasör/resim.jpg"
    static func parse(_ line: String) -> (String, Entry)? {
        var fields: [Substring] = []
        var rest = Substring(line)
        for _ in 0..<8 {
            rest = rest.drop(while: { $0 == " " })
            guard let end = rest.firstIndex(of: " ") else { return nil }
            fields.append(rest[..<end])
            rest = rest[end...]
        }
        // Ad: tarih/saat alanından sonraki tek boşluktan itibaren (adın başındaki boşluklar korunur).
        guard rest.first == " " else { return nil }
        var name = String(rest.dropFirst())
        let perms = fields[0]
        guard let kind = perms.first, let size = Int64(fields[4]) else { return nil }
        if kind == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        if kind == "h", let link = name.range(of: " link to ") { name = String(name[..<link.lowerBound]) }
        let isDirectory = kind == "d" || name.hasSuffix("/")
        let date = parseDate(month: String(fields[5]), day: String(fields[6]), timeOrYear: String(fields[7]))
        return (name, Entry(member: name, isDirectory: isDirectory, size: isDirectory ? 0 : size, modified: date))
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func parseDate(month: String, day: String, timeOrYear: String) -> Date? {
        guard let m = months.firstIndex(of: month.lowercased()), let d = Int(day) else { return nil }
        var c = DateComponents()
        c.month = m + 1
        c.day = d
        let cal = Calendar(identifier: .gregorian)
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":")
            c.hour = Int(hm[0])
            c.minute = hm.count > 1 ? Int(hm[1]) : 0
            c.year = cal.component(.year, from: Date())
            if let date = cal.date(from: c), date > Date().addingTimeInterval(86400) { c.year! -= 1 }
        } else {
            c.year = Int(timeOrYear)
        }
        return cal.date(from: c)
    }
}

/// Tümünü ayıkla: arşivin adını taşıyan yeni bir klasöre (`bsdtar -xf`), ilerleme penceresiyle.
@MainActor
enum ArchiveExtractor {
    static func extractAll(_ file: URL, into folder: URL, window: NSWindow?, completion: @escaping (URL) -> Void) {
        var base = file.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"] where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        if base == file.lastPathComponent { base = file.deletingPathExtension().lastPathComponent }
        let target = FileNaming.uniqueName(for: folder.appendingPathComponent(base, isDirectory: true))
        do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) } catch {
            return show(error.localizedDescription, window: window)
        }
        let panel = ProgressPanel(title: String(localized: "Ayıklanıyor", bundle: .live),
                                  message: String(localized: "“\(file.lastPathComponent)” → \(target.lastPathComponent)", bundle: .live))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ArchivePassword.arguments(for: file) + ["-xf", file.path, "-C", target.path]
        process.environment = ArchiveIndex.environment
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        panel.onCancel = { process.terminate() }
        process.terminationHandler = { p in
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = p.terminationStatus, cancelled = p.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    panel.close()
                    if status == 0 {
                        UndoCenter.shared.register([.trash(target)], name: String(localized: "Tümünü Ayıkla", bundle: .live))
                        completion(target)
                    } else if !cancelled, ArchivePassword.isPasswordError(message) {
                        // Parola sorulur, yeniden denenir (boş kalan klasör silinir).
                        try? FileManager.default.removeItem(at: target)
                        Task {
                            if await ArchivePassword.ask(for: file, failed: ArchivePassword.has(file)) {
                                extractAll(file, into: folder, window: window, completion: completion)
                            }
                        }
                    } else if !cancelled {
                        show(ArchiveIndex.error(message).localizedDescription, window: window)
                        completion(target)   // kısmen ayıklananlar görünsün
                    }
                }
            }
        }
        do { try process.run() } catch { panel.close(); return show(error.localizedDescription, window: window) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if process.isRunning { panel.show(over: window) } }
    }

    private static func show(_ message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Arşiv ayıklanamadı.", bundle: .live)
        alert.informativeText = message
        Task { await RemoteSessions.present(alert, window: window) }
    }
}

/// Parolalı arşivlerin parolası: sorulur, uygulama açık kaldıkça bellekte tutulur (diske yazılmaz).
enum ArchivePassword {
    enum Needed: Error { case password }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var passwords: [String: String] = [:]

    static func has(_ file: URL) -> Bool { lock.withLock { passwords[file.path] != nil } }

    /// Her bsdtar çağrısına: bilinen parola, yoksa geçersiz bir yer tutucu (terminalden sormasın diye).
    static func arguments(for file: URL) -> [String] {
        ["--passphrase", lock.withLock { passwords[file.path] } ?? "\u{1}"]
    }

    static func isPasswordError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("passphrase") || lower.contains("encrypted") && lower.contains("password")
    }

    /// Parolayı sorar; girildiyse true.
    static func ask(for file: URL, failed: Bool) async -> Bool {
        let answer = await prompt(file, failed: failed)
        guard let answer, !answer.isEmpty else { return false }
        lock.withLock { passwords[file.path] = answer }
        return true
    }

    @MainActor
    private static func prompt(_ file: URL, failed: Bool) async -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(file.lastPathComponent)” parolalı", bundle: .live)
        alert.informativeText = failed ? String(localized: "Parola yanlış. Yeniden girin.", bundle: .live)
            : String(localized: "Arşivdeki dosyaları açmak için parolayı girin.", bundle: .live)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Tamam", bundle: .live))
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        alert.window.initialFirstResponder = field
        guard await RemoteSessions.present(alert, window: NSApp.keyWindow) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
