import AppKit
import FTPKit
import MacExplorerCore
import UniformTypeIdentifiers

/// Bir SFTP / FTP sunucusuyla açık oturum. Gezinme (listeleme, yeniden adlandırma, silme) bu bağlantıdan yapılır;
/// dosya aktarımları gezinmeyi bekletmesin diye kendi bağlantılarını açar (bkz. `makeClient`).
@MainActor
final class RemoteConnection {
    let server: ServerBookmark
    var password: String
    private(set) var client: any RemoteClient
    private var connecting: Task<Void, Error>?
    private(set) var home = "/"
    /// Kök adres (sftp://kullanıcı@sunucu/ ya da archive://ad@kimlik/).
    let base: URL
    /// Sunucu dışı kaynaklar (arşiv) kendi istemcisini verir.
    private let factory: (() -> any RemoteClient)?

    init(server: ServerBookmark, password: String) {
        self.server = server
        self.password = password
        base = server.remoteURL(path: "/") ?? URL(string: "sftp://\(server.host)/")!
        factory = nil
        client = Self.makeClient(server, password: password)
    }

    /// Arşiv gibi parolasız, kendi istemcisi olan kaynak.
    init(base: URL, name: String, factory: @escaping () -> any RemoteClient) {
        server = ServerBookmark(name: name, kind: .ftp, host: base.host ?? "")
        password = ""
        self.base = base
        self.factory = factory
        client = factory()
    }

    var key: String { RemoteURL.serverKey(base) }
    var rootURL: URL? { base }
    var isArchive: Bool { base.scheme == Archives.scheme }

    func url(for path: String) -> URL? { RemoteURL.replacingPath(base, with: path) }

    /// Aynı sunucuya yeni, bağımsız bir bağlantı (aktarımlar için).
    func makeClient() -> any RemoteClient { factory?() ?? Self.makeClient(server, password: password) }

    private static func makeClient(_ server: ServerBookmark, password: String) -> any RemoteClient {
        let proto = ServerProtocol(rawValue: server.kind.rawValue) ?? .sftp
        var options: [String] = []
        // Parola verilmediyse yalnızca anahtar / ssh-agent denenir; olmazsa parola sorulur.
        if proto == .sftp && password.isEmpty {
            options = ["-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no"]
        }
        options += RemoteSessions.debugSSHOptions
        let config = FTPConfig(host: server.host, port: server.port.map { UInt16(clamping: $0) },
                               user: server.user, password: password, serverProtocol: proto,
                               keyFile: server.keyFile, sshOptions: options)
        let verbose = RemoteSessions.isDebugRun && ProcessInfo.processInfo.environment["MACEXPLORER_FTP_LOG"] != nil
        let log: @Sendable (LogKind, String) -> Void = { kind, text in if verbose { print("[\(kind)] \(text)") } }
        return makeRemoteClient(config: config, log: log, trust: { info in await CertificateTrust.ask(info) })
    }

    func ensureConnected() async throws {
        if client.isConnected { return }
        if let connecting { return try await connecting.value }
        let client = self.client
        let task = Task { try await client.connect() }
        connecting = task
        defer { connecting = nil }
        try await task.value
        home = client.homeDirectory
    }

    /// İşlemi çalıştırır; bağlantı kopmuşsa bir kez yeniden bağlanıp tekrar dener.
    func run<T>(_ operation: (any RemoteClient) async throws -> T) async throws -> T {
        try await ensureConnected()
        do {
            return try await operation(client)
        } catch let error as FTPError where error.isConnectionError {
            await client.disconnect()
            client = makeClient()
            try await ensureConnected()
            return try await operation(client)
        }
    }

    func disconnect() async { await client.disconnect() }

    /// Parola değişti (sorulup girildi): bağlantı yeniden kurulur.
    func reset(password: String) {
        self.password = password
        client = makeClient()
    }
}

/// Açık SFTP / FTP oturumları (sunucu başına bir tane) ve bağlanma akışı: sunucu kimliği onayı, parola sorma.
@MainActor
enum RemoteSessions {
    /// Sunucuda içerik değişti; nesne: değişen klasörün (ya da öğenin) adresi.
    static let didChange = Notification.Name("RemoteSessionsDidChange")
    private static var connections: [String: RemoteConnection] = [:]
    private static var opening: [String: Task<RemoteConnection?, Never>] = [:]

    /// Bu adresin oturumu; yoksa (adres yazıldı, oturum geri yüklendi) kayıtlı sunucudan ya da adresten bağlanır.
    static func connection(for url: URL, window: NSWindow?) async -> RemoteConnection? {
        let key = RemoteURL.serverKey(url)
        if let existing = connections[key] { return existing }
        if let task = opening[key] { return await task.value }
        if url.scheme == Archives.scheme {
            // Oturum geri yüklendi ya da arşiv kapatıldı: arşiv dosyası biliniyorsa yeniden açılır.
            guard let file = Archives.file(for: url), Archives.open(file) != nil else { return nil }
            return connections[key]
        }
        let server = savedServer(matching: url) ?? ServerBookmark(address: url.absoluteString)
        guard let server else { return nil }
        let task = Task { await connect(server, password: ServerKeychain.password(for: server.id), window: window, showsErrors: false) }
        opening[key] = task
        defer { opening[key] = nil }
        return await task.value
    }

    /// Bağlantı varsa (bağlanmadan) döndürür.
    static func existing(for url: URL) -> RemoteConnection? { connections[RemoteURL.serverKey(url)] }

    /// Sunucuya bağlanır ve başlangıç klasörünün adresini döndürür (kayıttaki klasör; yoksa kullanıcının ana dizini).
    static func open(_ server: ServerBookmark, password: String?, window: NSWindow?) async -> URL? {
        guard let connection = await connect(server, password: password, window: window, showsErrors: true) else { return nil }
        let start = server.path.trimmingCharacters(in: .whitespaces)
        let path = start.isEmpty ? connection.home : (start.hasPrefix("/") ? start : RemotePath.join(connection.home, start))
        return connection.url(for: path)
    }

    static func disconnect(_ url: URL) {
        let key = RemoteURL.serverKey(url)
        guard let connection = connections.removeValue(forKey: key) else { return }
        Task { await connection.disconnect() }
    }

    static var openConnections: [RemoteConnection] { Array(connections.values) }

    /// Arşiv oturumu (bkz. Archives): içindekiler ilk listelemede okunur.
    static func register(archive file: URL, base: URL) {
        let key = RemoteURL.serverKey(base)
        guard connections[key] == nil else { return }
        connections[key] = RemoteConnection(base: base, name: file.lastPathComponent) { ArchiveClient(file: file) }
    }

    // MARK: Bağlanma

    private static func connect(_ original: ServerBookmark, password: String?, window: NSWindow?, showsErrors: Bool) async -> RemoteConnection? {
        var server = original
        if server.kind == .sftp {
            let resolved = await SSHConfig.resolve(host: server.host, user: server.user, port: server.port)
            if server.user.isEmpty { server.user = resolved.user }
            if server.port == nil, resolved.port != 22 { server.port = resolved.port }
            guard await HostKeyCheck.confirm(alias: server.host, resolved: resolved, window: window) else { return nil }
        }
        if let existing = server.remoteURL(path: "/").flatMap({ connections[RemoteURL.serverKey($0)] }) { return existing }

        let connection = RemoteConnection(server: server, password: password ?? "")
        let panel = ConnectingPanel(server: server)
        var attempt = 0
        while true {
            attempt += 1
            let task = Task { try await connection.ensureConnected() }
            panel.onCancel = { task.cancel(); Task { await connection.disconnect() } }
            panel.show(over: window)
            let result = await task.result
            panel.close()
            if task.isCancelled { return nil }
            switch result {
            case .success:
                connections[connection.key] = connection
                if !isDebugRun { ServerStore.noteConnected(original) }
                return connection
            case .failure(let error):
                if isAuthenticationError(error), attempt <= 3,
                   let answer = await PasswordPrompt.ask(server: server, failed: !connection.password.isEmpty, window: window) {
                    if answer.save, ServerStore.servers.contains(where: { $0.id == original.id }) {
                        ServerKeychain.set(answer.password, for: original.id, label: original.displayName)
                    }
                    connection.reset(password: answer.password)
                    continue
                }
                if isAuthenticationError(error) && attempt > 1 { return nil }   // vazgeçildi
                if showsErrors || !isAuthenticationError(error) {
                    await showError(String(localized: "“\(server.displayName)” sunucusuna bağlanılamadı.", bundle: .live),
                                    detail: error.localizedDescription, window: window)
                }
                return nil
            }
        }
    }

    /// Geliştirme denemeleri son bağlantılara ve kullanıcının known_hosts dosyasına dokunmaz (bkz. DebugSnapshot).
    nonisolated static var isDebugRun: Bool { ProcessInfo.processInfo.environment["MACEXPLORER_SNAPSHOT"] != nil }

    /// Geliştirme: ssh'e eklenen seçenekler (örn. "-o UserKnownHostsFile=/tmp/x").
    nonisolated static var debugSSHOptions: [String] {
        guard isDebugRun, let text = ProcessInfo.processInfo.environment["MACEXPLORER_SSH_OPTIONS"] else { return [] }
        return text.split(separator: " ").map(String.init)
    }

    static func isAuthenticationError(_ error: Error) -> Bool {
        if case FTPError.server(let code, _) = error, code == 530 { return true }
        let text = error.localizedDescription.lowercased()
        return text.contains("permission denied") || text.contains("authentication failed") || text.contains("too many authentication")
    }

    /// Kayıtlı sunuculardan bu adresle eşleşen (parolası Anahtar Zinciri'nde olabilir).
    private static func savedServer(matching url: URL) -> ServerBookmark? {
        let key = RemoteURL.serverKey(url)
        let all = ServerStore.servers + ServerStore.recent
        return all.first { $0.kind.isRemote && $0.remoteURL(path: "/").map(RemoteURL.serverKey) == key }
            ?? all.first { server in
                // Kullanıcı adı kayıtta boş (ssh varsayılanı) olabilir.
                guard server.kind.isRemote, server.user.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
                c.user = nil
                c.path = "/"
                return server.remoteURL(path: "/").map(RemoteURL.serverKey) == c.url.map(RemoteURL.serverKey)
            }
    }

    static func showError(_ message: String, detail: String, window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        await present(alert, window: window)
    }

    @discardableResult
    static func present(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.attachedSheet == nil {
            return await withCheckedContinuation { cont in alert.beginSheetModal(for: window) { cont.resume(returning: $0) } }
        }
        return alert.runModal()
    }
}

// MARK: - Parola

@MainActor
enum PasswordPrompt {
    static func ask(server: ServerBookmark, failed: Bool, window: NSWindow?) async -> (password: String, save: Bool)? {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(server.displayName)” için parola", bundle: .live)
        let who = server.user.isEmpty ? server.host : "\(server.user)@\(server.host)"
        alert.informativeText = failed
            ? String(localized: "Parola kabul edilmedi. \(who) için yeniden girin.", bundle: .live)
            : (server.kind == .sftp
               ? String(localized: "\(who) parolayla giriş istiyor. SSH anahtarınız parolalıysa anahtarın parolasını da girebilirsiniz.", bundle: .live)
               : String(localized: "\(who) parolayla giriş istiyor.", bundle: .live))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let save = NSButton(checkboxWithTitle: String(localized: "Parolayı Anahtar Zinciri'nde sakla", bundle: .live), target: nil, action: nil)
        save.state = .on
        let canSave = ServerStore.servers.contains { $0.id == server.id }
        let stack = NSStackView(views: canSave ? [field, save] : [field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: canSave ? 52 : 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Bağlan", bundle: .live))
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        alert.window.initialFirstResponder = field
        let response = await RemoteSessions.present(alert, window: window)
        guard response == .alertFirstButtonReturn else { return nil }
        return (field.stringValue, canSave && save.state == .on)
    }
}

// MARK: - FTPS sertifikası

/// macOS'un güvenmediği FTPS sertifikası: kullanıcıya parmak iziyle sorulur; kabul edilen parmak izi hatırlanır.
enum CertificateTrust {
    private static let key = "trustedCertificates"

    static func ask(_ info: CertificateInfo) async -> Bool {
        let trusted = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if trusted[info.host.lowercased()] == info.fingerprint { return true }
        return await askUser(info)
    }

    @MainActor
    private static func askUser(_ info: CertificateInfo) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(info.host)” sunucusunun sertifikası doğrulanamadı.", bundle: .live)
        alert.informativeText = [info.problem, String(localized: "Sertifika: \(info.subject)", bundle: .live),
                                 String(localized: "Parmak izi (SHA-256): \(info.fingerprint)", bundle: .live),
                                 String(localized: "Sunucunun sahibi olduğunu bildiğiniz bir sertifikaysa devam edin.", bundle: .live)]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "Güven ve Bağlan", bundle: .live))
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        guard await RemoteSessions.present(alert, window: NSApp.keyWindow) == .alertFirstButtonReturn else { return false }
        var trusted = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        trusted[info.host.lowercased()] = info.fingerprint
        UserDefaults.standard.set(trusted, forKey: key)
        return true
    }
}

// MARK: - SSH

/// `~/.ssh/config` ile birlikte ssh'in bir sunucu için kullanacağı ayarlar (`ssh -G`).
enum SSHConfig {
    struct Resolved: Sendable {
        var hostname: String
        var user: String
        var port: Int
        var knownHosts: [String]
    }

    static func resolve(host: String, user: String, port: Int?) async -> Resolved {
        await Task.detached {
            var args = ["-G"] + RemoteSessions.debugSSHOptions
            if let port { args += ["-p", String(port)] }
            if !user.isEmpty { args += ["-l", user] }
            args += ["--", host]
            var r = Resolved(hostname: host, user: user.isEmpty ? NSUserName() : user, port: port ?? 22,
                             knownHosts: ["~/.ssh/known_hosts"])
            guard !host.hasPrefix("-"), let output = Shell.run("/usr/bin/ssh", args)?.output else { return r }
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "hostname": r.hostname = parts[1]
                case "user": r.user = parts[1]
                case "port": r.port = Int(parts[1]) ?? r.port
                case "userknownhostsfile": r.knownHosts = parts[1].split(separator: " ").map(String.init)
                default: break
                }
            }
            return r
        }.value
    }

    /// `~/.ssh/config` içindeki sunucu adları (joker karakterli kalıplar hariç), Include'lar dahil.
    static func hosts() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var seen = Set<String>(), result: [String] = [], visited = Set<String>()
        func read(_ url: URL) {
            guard visited.insert(url.path).inserted, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#") else { continue }
                let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0].lowercased() {
                case "host":
                    for name in parts[1].split(separator: " ").map(String.init)
                    where !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") && seen.insert(name).inserted {
                        result.append(name)
                    }
                case "include":
                    for pattern in parts[1].split(separator: " ") {
                        var path = (String(pattern) as NSString).expandingTildeInPath
                        if !path.hasPrefix("/") { path = home.appendingPathComponent(".ssh/" + path).path }
                        for match in glob(path) { read(URL(fileURLWithPath: match)) }
                    }
                default: break
                }
            }
        }
        read(home.appendingPathComponent(".ssh/config"))
        return result
    }

    private static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }

    /// "Terminalde aç": sunucuya ssh ile bağlanıp o klasöre geçen bir Terminal penceresi.
    @MainActor
    static func openTerminal(_ server: ServerBookmark, path: String) {
        var args = ["ssh", "-t"]
        if let port = server.port { args += ["-p", String(port)] }
        if !server.keyFile.isEmpty { args += ["-i", (server.keyFile as NSString).expandingTildeInPath] }
        if !server.user.isEmpty { args += ["-l", server.user] }
        args += ["--", server.host]
        // Sunucuda: klasöre geç, kullanıcının kabuğunu oturum kabuğu olarak başlat.
        let remote = "cd \(ShellQuote.quote(path)) 2>/dev/null; exec \"$SHELL\" -l"
        args.append(remote)
        let command = args.map { ShellQuote.quote($0) }.joined(separator: " ")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacExplorer-ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("\(server.host)-\(UUID().uuidString.prefix(8)).command")
        let text = "#!/bin/sh\n# MacExplorer: SSH oturumu\nrm -f \"$0\"\nclear\nexec \(command)\n"
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch { return NSSound.beep() }
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// SFTP'de sunucunun kimliği: `known_hosts`'ta yoksa parmak izi gösterilip onay istenir (Terminal'deki ssh gibi).
/// Onaylanınca ssh anahtarı kendisi kaydeder (StrictHostKeyChecking=accept-new); değişmiş anahtarı ssh reddeder.
@MainActor
enum HostKeyCheck {
    static func confirm(alias: String, resolved: SSHConfig.Resolved, window: NSWindow?) async -> Bool {
        let status = await Task.detached { lookup(resolved) }.value
        guard case .unknown(let fingerprints) = status else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(alias)” sunucusu tanınmıyor.", bundle: .live)
        var lines = [String(localized: "Bu sunucuya ilk kez bağlanıyorsunuz. Sunucunun kimliği (anahtar parmak izi):", bundle: .live)]
        lines += fingerprints.prefix(4).map { "  " + $0 }
        lines.append(String(localized: "Parmak izi sunucunun yöneticisinin verdiğiyle aynıysa bağlanın. Onaylarsanız ~/.ssh/known_hosts dosyasına eklenir ve bir dahaki sefere sorulmaz.", bundle: .live))
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Bağlan", bundle: .live))
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        return await RemoteSessions.present(alert, window: window) == .alertFirstButtonReturn
    }

    enum Status: Sendable { case known, unknown([String]), unreachable }

    nonisolated static func lookup(_ r: SSHConfig.Resolved) -> Status {
        let name = r.port == 22 ? r.hostname : "[\(r.hostname)]:\(r.port)"
        for file in r.knownHosts + ["/etc/ssh/ssh_known_hosts"] {
            let path = (file as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let result = Shell.run("/usr/bin/ssh-keygen", ["-F", name, "-f", path]), result.status == 0, !result.output.isEmpty {
                return .known
            }
        }
        guard !r.hostname.hasPrefix("-"),
              let scan = Shell.run("/usr/bin/ssh-keyscan", ["-T", "8", "-p", String(r.port), "--", r.hostname]),
              !scan.output.isEmpty,
              let prints = Shell.run("/usr/bin/ssh-keygen", ["-l", "-f", "-"], input: scan.output) else { return .unreachable }
        // "256 SHA256:abc… sunucu (ED25519)" → "ED25519  SHA256:abc…"
        let list = prints.output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ")
            guard parts.count >= 3 else { return nil }
            let type = parts.last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")) } ?? ""
            return "\(type)  \(parts[1])"
        }
        return list.isEmpty ? .unreachable : .unknown(list)
    }
}

/// Kısa süren komut satırı araçları (ssh -G, ssh-keygen, ssh-keyscan, hdiutil).
enum Shell {
    /// Çıktı ve hata metniyle birlikte.
    static func runWithError(_ tool: String, _ args: [String]) -> (status: Int32, output: String, error: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // İki boru da okunur: biri dolarsa süreç beklemede kalmasın.
        nonisolated(unsafe) var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errorData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
    }

    static func run(_ tool: String, _ args: [String], input: String? = nil) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return nil }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Uzak dosya öğeleri

extension FileItem {
    /// Sunucudaki bir öğe. Klasör adresleri "/" ile biter: simge ve tür adresten anlaşılsın.
    init(remote file: RemoteFile, in directory: URL) {
        let url = directory.appendingPathComponent(file.name, isDirectory: file.isDirectory)
        self.init(url: url, name: file.name, displayName: file.name, isDirectory: file.isDirectory,
                  isHidden: file.name.hasPrefix("."), isSymbolicLink: file.isLink,
                  size: file.isDirectory ? nil : file.size,
                  modified: file.modified == .distantPast ? nil : file.modified,
                  kind: RemoteIcons.kind(for: url))
    }
}

/// Uzak öğelerin simgesi ve tür adı uzantıdan (dosya bilgisayarda olmadığı için).
@MainActor
enum RemoteIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL, size: CGFloat) -> NSImage {
        let type = url.hasDirectoryPath ? UTType.folder : (UTType(filenameExtension: url.pathExtension) ?? .data)
        let key = "\(type.identifier)|\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = (NSWorkspace.shared.icon(for: type).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: size, height: size)
        cache.setObject(image, forKey: key)
        return image
    }

    nonisolated static func kind(for url: URL) -> String {
        let text = url.hasDirectoryPath ? (UTType.folder.localizedDescription ?? "")
            : (UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? String(localized: "Belge", bundle: .live))
        return text.prefix(1).uppercased() + text.dropFirst()   // "klasör" → "Klasör" (yerel listedeki gibi)
    }
}
