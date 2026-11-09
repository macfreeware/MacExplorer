import AppKit
import FTPKit
import MacExplorerCore

/// Sunucuyla bilgisayar arasında dosya aktarımı (indirme / yükleme), klasörler alt öğeleriyle birlikte.
/// Her iş kendi bağlantısını açar: büyük bir aktarım sürerken panelde gezinmek beklemez.
@MainActor
enum RemoteTransfers {
    /// İndir: uzak öğeleri yerel klasöre. `move` ise başarıyla inenler sunucudan silinir.
    static func download(_ sources: [URL], to destination: URL, move: Bool = false, overwrite: Bool = false,
                         window: NSWindow?, completion: @escaping ([URL]) -> Void = { _ in }) {
        guard let first = sources.first else { return }
        Task {
            guard let connection = await RemoteSessions.connection(for: first, window: window) else { return }
            let job = Job(kind: move ? .move : .copy, count: sources.count, destination: destination, window: window)
            let created = await job.run(connection) { client in
                try await job.download(sources, to: destination, overwrite: overwrite, client: client)
            }
            if move { await job.deleteRemote(sources.filter { job.succeeded($0) }, connection: connection) }
            job.finish()
            completion(created)
        }
    }

    /// Yükle: yerel öğeleri uzak klasöre. `move` ise başarıyla yüklenenler Çöp Sepeti'ne taşınır.
    static func upload(_ sources: [URL], to destination: URL, move: Bool = false,
                       window: NSWindow?, completion: @escaping ([URL]) -> Void = { _ in }) {
        guard !sources.isEmpty else { return }
        Task {
            guard let connection = await RemoteSessions.connection(for: destination, window: window) else { return }
            let job = Job(kind: move ? .move : .copy, count: sources.count, destination: destination, window: window)
            let created = await job.run(connection) { client in
                try await job.upload(sources, to: destination, client: client)
            }
            if move {
                for url in sources where job.succeeded(url) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            }
            job.finish()
            completion(created)
        }
    }

    /// Dosyayı geçici klasöre indirip açar (ya da verilen uygulamayla).
    static func open(_ files: [URL], with app: URL? = nil, window: NSWindow?) {
        var groups: [URL: [URL]] = [:]
        for file in files { groups[cacheFolder(for: file.deletingLastPathComponent()), default: []].append(file) }
        for (folder, list) in groups {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            download(list, to: folder, overwrite: true, window: window) { local in
                guard !local.isEmpty else { return }
                if let app {
                    NSWorkspace.shared.open(local, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    local.forEach { NSWorkspace.shared.open($0) }
                }
            }
        }
    }

    /// ~/Library/Caches/MacExplorer/Uzak/<sunucu>/<yol>
    private static func cacheFolder(for remoteDirectory: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let server = RemoteURL.serverKey(remoteDirectory).replacingOccurrences(of: "://", with: "_")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return caches.appendingPathComponent("MacExplorer/Remote/\(server)" + RemoteURL.path(of: remoteDirectory), isDirectory: true)
    }

    /// Sunucudaki öğeleri siler (klasörler içindekilerle birlikte); önce onay sorar.
    static func delete(_ urls: [URL], window: NSWindow?, completion: @escaping () -> Void) {
        guard let first = urls.first else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? String(localized: "“\(urls[0].lastPathComponent)” sunucudan kalıcı olarak silinsin mi?", bundle: .live)
            : String(localized: "Bu \(urls.count) öğe sunucudan kalıcı olarak silinsin mi?", bundle: .live)
        alert.informativeText = String(localized: "Sunucuda Çöp Sepeti yoktur; bu işlem geri alınamaz.", bundle: .live)
        alert.addButton(withTitle: String(localized: "Sil", bundle: .live)).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        alert.confirmsWithKeyboard()
        Task {
            guard await RemoteSessions.present(alert, window: window) == .alertFirstButtonReturn,
                  let connection = await RemoteSessions.connection(for: first, window: window) else { return }
            var errors: [String] = []
            for url in urls {
                let path = RemoteURL.path(of: url)
                do {
                    try await connection.run { client in
                        if url.hasDirectoryPath { try await client.removeDirectory(path, recursive: true) } else { try await client.deleteFile(path) }
                    }
                } catch {
                    errors.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
            completion()
            if !errors.isEmpty {
                await RemoteSessions.showError(String(localized: "Bazı öğeler silinemedi.", bundle: .live), detail: errors.prefix(6).joined(separator: "\n"), window: window)
            }
        }
    }

    // MARK: İş

    @MainActor
    final class Job {
        private let panel: TransferProgressPanel
        private let window: NSWindow?
        private var progress = TransferProgress()
        private var errors: [String] = []
        private var failedRoots = Set<String>()
        private var cancelled = false
        private var task: Task<[URL], Never>?
        private var applyToAll: Resolution?
        private var client: (any RemoteClient)?
        /// Sunucudan sunucuya kopyada kaynak bağlantısı (İptal ikisini de kapatır).
        private var extraClient: (any RemoteClient)?
        private var currentRoot = ""

        enum Resolution { case skip, replace, cancel }

        init(kind: TransferKind, count: Int, destination: URL, window: NSWindow?) {
            self.window = window
            panel = TransferProgressPanel(kind: kind, count: count, destination: destination)
            panel.onCancel = { [weak self] in self?.cancel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self.map { $0.panel.showIfRunning(over: $0.window) } }
            }
        }

        func succeeded(_ url: URL) -> Bool { !cancelled && !failedRoots.contains(url.absoluteString) }

        private func cancel() {
            cancelled = true
            task?.cancel()
            if let client { Task { await client.disconnect() } }
            if let extraClient { Task { await extraClient.disconnect() } }
        }

        /// Ayrı bir bağlantı açar, işi çalıştırır, bağlantıyı kapatır. Oluşan üst öğelerin adresleri döner.
        func run(_ connection: RemoteConnection, _ body: @escaping (any RemoteClient) async throws -> [URL]) async -> [URL] {
            let client = connection.makeClient()
            self.client = client
            let task = Task<[URL], Never> {
                do {
                    try await client.connect()
                    let created = try await body(client)
                    await client.disconnect()
                    return created
                } catch {
                    await client.disconnect()
                    if !cancelled && !(error is CancellationError) { errors.append(error.localizedDescription) }
                    return []
                }
            }
            self.task = task
            return await task.value
        }

        func finish() {
            panel.finish()
            guard !errors.isEmpty, !cancelled else { return }
            var lines = Array(errors.prefix(6))
            if errors.count > 6 { lines.append(String(localized: "… ve \(errors.count - 6) öğe daha", bundle: .live)) }
            let window = self.window
            Task { await RemoteSessions.showError(String(localized: "Bazı öğeler aktarılamadı.", bundle: .live), detail: lines.joined(separator: "\n"), window: window) }
        }

        private func fail(_ name: String, _ error: Error) {
            if error is CancellationError || cancelled { return }
            errors.append("“\(name)”: \(error.localizedDescription)")
            failedRoots.insert(currentRoot)
        }

        private func update() { panel.update(progress) }

        private func checkCancelled() throws { if cancelled || Task.isCancelled { throw CancellationError() } }

        // MARK: İndirme

        private struct RemoteEntry { let path: String; let local: URL; let isDirectory: Bool; let size: Int64 }

        func download(_ sources: [URL], to destination: URL, overwrite: Bool, client: any RemoteClient) async throws -> [URL] {
            var created: [URL] = []
            for source in sources {
                try checkCancelled()
                currentRoot = source.absoluteString
                let path = RemoteURL.path(of: source)
                let local = destination.appendingPathComponent(source.lastPathComponent, isDirectory: source.hasDirectoryPath)
                // Klasörün içindekiler önce listelenir: toplam boyut ilerleme çubuğu için bilinsin.
                var entries: [RemoteEntry] = []
                do {
                    if source.hasDirectoryPath {
                        try await collect(path, local: local, client: client, into: &entries)
                    } else {
                        let size = (try? await client.size(path)) ?? 0
                        entries.append(RemoteEntry(path: path, local: local, isDirectory: false, size: size))
                    }
                } catch { fail(source.lastPathComponent, error); continue }
                progress.totalBytes += entries.reduce(0) { $0 + $1.size }
                progress.totalItems += entries.count

                var rootDone = false
                for entry in entries {
                    try checkCancelled()
                    progress.currentName = entry.local.lastPathComponent
                    update()
                    do {
                        if entry.isDirectory {
                            try FileManager.default.createDirectory(at: entry.local, withIntermediateDirectories: true)
                        } else {
                            if FileManager.default.fileExists(atPath: entry.local.path), !overwrite {
                                switch await resolve(entry.local.lastPathComponent) {
                                case .skip: progress.completedBytes += entry.size; continue
                                case .cancel: cancel(); throw CancellationError()
                                case .replace: try? FileManager.default.removeItem(at: entry.local)
                                }
                            } else if overwrite {
                                try? FileManager.default.removeItem(at: entry.local)
                            }
                            let base = progress.completedBytes
                            try await client.download(entry.path, to: entry.local) { [weak self] bytes in
                                DispatchQueue.main.async { MainActor.assumeIsolated {
                                    guard let self else { return }
                                    self.progress.completedBytes = base + bytes
                                    self.update()
                                } }
                            }
                            progress.completedBytes = base + entry.size
                        }
                        progress.completedItems += 1
                        rootDone = true
                    } catch {
                        fail(entry.local.lastPathComponent, error)
                        if error is CancellationError || cancelled { throw CancellationError() }
                    }
                }
                if rootDone || entries.isEmpty { created.append(local) }
            }
            return created
        }

        private func collect(_ path: String, local: URL, client: any RemoteClient, into entries: inout [RemoteEntry]) async throws {
            try checkCancelled()
            entries.append(RemoteEntry(path: path, local: local, isDirectory: true, size: 0))
            for file in try await client.list(path).files {
                let child = RemotePath.join(path, file.name)
                let childLocal = local.appendingPathComponent(file.name, isDirectory: file.isDirectory)
                if file.isDirectory {
                    try await collect(child, local: childLocal, client: client, into: &entries)
                } else {
                    entries.append(RemoteEntry(path: child, local: childLocal, isDirectory: false, size: file.size))
                }
            }
        }

        // MARK: Yükleme

        private struct LocalEntry { let url: URL; let path: String; let isDirectory: Bool; let size: Int64 }

        func upload(_ sources: [URL], to destination: URL, client: any RemoteClient) async throws -> [URL] {
            var created: [URL] = []
            let base = RemoteURL.path(of: destination)
            for source in sources {
                try checkCancelled()
                currentRoot = source.absoluteString
                var entries: [LocalEntry] = []
                collect(source, remote: RemotePath.join(base, source.lastPathComponent), into: &entries)
                progress.totalBytes += entries.reduce(0) { $0 + $1.size }
                progress.totalItems += entries.count
                var rootDone = false
                for entry in entries {
                    try checkCancelled()
                    progress.currentName = entry.url.lastPathComponent
                    update()
                    do {
                        if entry.isDirectory {
                            do { try await client.makeDirectory(entry.path) } catch {
                                // Zaten varsa sorun değil.
                                if (try? await client.list(entry.path)) == nil { throw error }
                            }
                        } else {
                            if (try? await client.size(entry.path)) != nil {
                                switch await resolve(entry.url.lastPathComponent) {
                                case .skip: progress.completedBytes += entry.size; continue
                                case .cancel: cancel(); throw CancellationError()
                                case .replace: break
                                }
                            }
                            let start = progress.completedBytes
                            try await client.upload(entry.url, to: entry.path) { [weak self] bytes in
                                DispatchQueue.main.async { MainActor.assumeIsolated {
                                    guard let self else { return }
                                    self.progress.completedBytes = start + bytes
                                    self.update()
                                } }
                            }
                            progress.completedBytes = start + entry.size
                            if let date = (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                                _ = try? await client.setModified(entry.path, to: date)
                            }
                        }
                        progress.completedItems += 1
                        rootDone = true
                    } catch {
                        fail(entry.url.lastPathComponent, error)
                        if error is CancellationError || cancelled { throw CancellationError() }
                    }
                }
                if rootDone, let url = RemoteURL.make(destination, path: RemotePath.join(base, source.lastPathComponent), isDirectory: entries.first?.isDirectory ?? false) {
                    created.append(url)
                }
            }
            return created
        }

        private func collect(_ url: URL, remote: String, into entries: inout [LocalEntry]) {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .isSymbolicLinkKey])
            if v?.isDirectory == true {
                entries.append(LocalEntry(url: url, path: remote, isDirectory: true, size: 0))
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    collect(child, remote: RemotePath.join(remote, child.lastPathComponent), into: &entries)
                }
            } else {
                entries.append(LocalEntry(url: url, path: remote, isDirectory: false, size: Int64(v?.fileSize ?? 0)))
            }
        }

        // MARK: Taşıma sonrası

        func deleteRemote(_ urls: [URL], connection: RemoteConnection) async {
            for url in urls {
                let path = RemoteURL.path(of: url)
                do {
                    try await connection.run { client in
                        if url.hasDirectoryPath { try await client.removeDirectory(path, recursive: true) } else { try await client.deleteFile(path) }
                    }
                } catch {
                    errors.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
        }

        // MARK: Çakışma

        private func resolve(_ name: String) async -> Resolution {
            if let applyToAll { return applyToAll }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Hedefte “\(name)” adlı bir öğe zaten var.", bundle: .live)
            alert.addButton(withTitle: String(localized: "Atla", bundle: .live))
            alert.addButton(withTitle: String(localized: "Değiştir", bundle: .live))
            alert.addButton(withTitle: String(localized: "İptal", bundle: .live)).keyEquivalent = "\u{1b}"
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Bunu kalan tüm çakışmalara uygula", bundle: .live)
            panel.beginQuestion()
            let response = await RemoteSessions.present(alert, window: window)
            panel.endQuestion(over: window)
            let answer: Resolution
            switch response {
            case .alertFirstButtonReturn: answer = .skip
            case .alertSecondButtonReturn: answer = .replace
            default: return .cancel
            }
            if alert.suppressionButton?.state == .on { applyToAll = answer }
            return answer
        }
    }
}

extension RemoteURL {
    /// Aynı sunucuda başka bir öğenin adresi; klasörse "/" ile biter.
    static func make(_ base: URL, path: String, isDirectory: Bool) -> URL? {
        let url = replacingPath(base, with: path)
        return isDirectory ? URL(string: url.absoluteString + "/") : url
    }
}

// MARK: - Sunucudan sunucuya

extension RemoteTransfers {
    /// Sunucudaki (ya da arşivdeki) öğeleri bir sunucu klasörüne kopyalar / taşır.
    /// - Aynı SFTP sunucusunda kopya sunucunun kendisinde yapılır (`cp -Rp`): veri Mac'e inip geri yüklenmez.
    ///   Kabuk vermeyen (yalnızca SFTP) ya da Unix olmayan sunucularda Mac üzerinden aktarılır.
    /// - FTP'de (sunucuda kopyalama komutu yok) ve farklı sunucular arasında Mac üzerinden: indir, yükle, geçici dosyaları sil.
    /// - Aynı klasöre kopya Windows gibi "ad - Kopya" adını alır. Taşımada kaynak, kopya başarılıysa silinir.
    static func copyBetween(_ sources: [URL], to destination: URL, move: Bool, window: NSWindow?,
                            completion: @escaping ([URL]) -> Void) {
        guard let first = sources.first else { return }
        Task {
            guard let target = await RemoteSessions.connection(for: destination, window: window),
                  let origin = await RemoteSessions.connection(for: first, window: window) else { return }
            let job = Job(kind: move ? .move : .copy, count: sources.count, destination: destination, window: window)
            let created = await job.copyBetween(sources, origin: origin, target: target, destination: destination)
            if move { await job.deleteRemote(sources.filter { job.succeeded($0) }, connection: origin) }
            job.finish()
            completion(created)
        }
    }
}

extension RemoteTransfers.Job {
    func copyBetween(_ sources: [URL], origin: RemoteConnection, target: RemoteConnection, destination: URL) async -> [URL] {
        let sourceClient = origin.makeClient(), targetClient = target.makeClient()
        client = targetClient
        extraClient = sourceClient
        let work = Task<[URL], Never> {
            do {
                try await targetClient.connect()
                try await sourceClient.connect()
                let sameServer = origin.key == target.key
                let shell = sameServer && target.server.kind == .sftp ? await RemoteShell(config: targetClient.config) : nil
                let base = RemoteURL.path(of: destination)
                var existing = Set(try await targetClient.list(base).files.map(\.name))
                var created: [URL] = []
                for source in sources {
                    try checkCancelled()
                    currentRoot = source.absoluteString
                    let path = RemoteURL.path(of: source)
                    let isDirectory = source.hasDirectoryPath
                    var name = source.lastPathComponent
                    // Aynı klasöre kopya: "ad - Kopya"; başka klasörde aynı ad varsa sorulur.
                    if sameServer && RemotePath.parent(path) == base {
                        name = FileNaming.copyName(name, isDirectory: isDirectory, existing: existing,
                                                   suffix: String(localized: "Kopya", bundle: .live))
                    } else if existing.contains(name) {
                        switch await resolve(name) {
                        case .skip: continue
                        case .cancel: cancel(); throw CancellationError()
                        case .replace:
                            let old = RemotePath.join(base, name)
                            do {
                                if (try? await targetClient.list(old)) != nil { try await targetClient.removeDirectory(old, recursive: true) }
                                else { try await targetClient.deleteFile(old) }
                            } catch { fail(name, error); continue }
                        }
                    }
                    let targetPath = RemotePath.join(base, name)
                    progress.currentName = name
                    update()
                    let copied: Bool
                    if let shell, await shell.copy(path, to: targetPath, onCancel: { [weak self] in self?.cancelled ?? true }) {
                        progress.completedItems += 1
                        progress.totalItems += 1
                        update()
                        copied = true
                    } else {
                        copied = try await relay(path, isDirectory: isDirectory, to: targetPath, from: sourceClient, into: targetClient)
                    }
                    if copied, let url = RemoteURL.make(destination, path: targetPath, isDirectory: isDirectory) {
                        created.append(url)
                        existing.insert(name)
                    }
                }
                await sourceClient.disconnect()
                await targetClient.disconnect()
                return created
            } catch {
                await sourceClient.disconnect()
                await targetClient.disconnect()
                if !cancelled && !(error is CancellationError) { errors.append(error.localizedDescription) }
                return []
            }
        }
        task = work
        return await work.value
    }

    /// Mac üzerinden: geçici klasöre indirir, hedefe yükler, geçici dosyaları siler.
    private func relay(_ path: String, isDirectory: Bool, to targetPath: String,
                       from source: any RemoteClient, into target: any RemoteClient) async throws -> Bool {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MacExplorer-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let local = temp.appendingPathComponent(RemotePath.name(targetPath), isDirectory: isDirectory)
        // İndirme ve yükleme aynı iş: önce indirilenler sayılır, sonra yüklenenler (çubuk ikisinin toplamı).
        let failuresBefore = errors.count
        var entries: [RemoteEntry] = []
        if isDirectory {
            try await collect(path, local: local, client: source, into: &entries)
        } else {
            entries.append(RemoteEntry(path: path, local: local, isDirectory: false, size: (try? await source.size(path)) ?? 0))
        }
        progress.totalBytes += 2 * entries.reduce(0) { $0 + $1.size }
        progress.totalItems += 2 * entries.count
        for entry in entries {
            try checkCancelled()
            progress.currentName = entry.local.lastPathComponent
            update()
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: entry.local, withIntermediateDirectories: true)
            } else {
                let start = progress.completedBytes
                do {
                    try await source.download(entry.path, to: entry.local) { [weak self] bytes in
                        DispatchQueue.main.async { MainActor.assumeIsolated {
                            guard let self else { return }
                            self.progress.completedBytes = start + bytes
                            self.update()
                        } }
                    }
                } catch {
                    fail(entry.local.lastPathComponent, error)
                    if error is CancellationError || cancelled { throw CancellationError() }
                }
                progress.completedBytes = start + entry.size
            }
            progress.completedItems += 1
        }
        guard errors.count == failuresBefore else { return false }
        // Yükleme: yerel geçici kopyadan hedefe (çakışma yok: hedef adı zaten seçildi).
        var uploads: [LocalEntry] = []
        collect(local, remote: targetPath, into: &uploads)
        for entry in uploads {
            try checkCancelled()
            progress.currentName = entry.url.lastPathComponent
            update()
            do {
                if entry.isDirectory {
                    do { try await target.makeDirectory(entry.path) } catch {
                        if (try? await target.list(entry.path)) == nil { throw error }
                    }
                } else {
                    let start = progress.completedBytes
                    try await target.upload(entry.url, to: entry.path) { [weak self] bytes in
                        DispatchQueue.main.async { MainActor.assumeIsolated {
                            guard let self else { return }
                            self.progress.completedBytes = start + bytes
                            self.update()
                        } }
                    }
                    progress.completedBytes = start + entry.size
                }
            } catch {
                fail(entry.url.lastPathComponent, error)
                if error is CancellationError || cancelled { throw CancellationError() }
            }
            progress.completedItems += 1
        }
        return errors.count == failuresBefore
    }
}

/// Aynı SFTP sunucusunda kopyalama: sunucuda `cp -Rp` çalıştırır (bağlantıyla aynı ssh ayarları ve parola).
/// Kabuk yoksa (yalnızca SFTP hesabı) ya da sunucu Unix değilse kullanılmaz; o zaman Mac üzerinden aktarılır.
@MainActor
final class RemoteShell {
    private let config: FTPConfig

    /// Sunucuda POSIX kabuk ve `cp` varsa kurulur; yoksa nil.
    init?(config: FTPConfig) async {
        self.config = config
        let probe = await run("command -v cp >/dev/null 2>&1 && echo MACEXPLORER_OK")
        guard probe.status == 0, probe.output.contains("MACEXPLORER_OK") else { return nil }
    }

    /// Kopyalar; başarısızsa false (çağıran Mac üzerinden dener).
    func copy(_ path: String, to target: String, onCancel: @escaping () -> Bool) async -> Bool {
        let result = await run("cp -Rp -- \(Self.quote(path)) \(Self.quote(target))", isCancelled: onCancel)
        return result.status == 0
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func run(_ command: String, isCancelled: @escaping () -> Bool = { false }) async -> (status: Int32, output: String) {
        let config = self.config
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                var args = ["-p", String(config.port), "-o", "StrictHostKeyChecking=accept-new", "-o", "NumberOfPasswordPrompts=1",
                            "-o", "ConnectTimeout=20", "-o", "LogLevel=ERROR", "-T"]
                if !config.keyFile.isEmpty { args += ["-i", (config.keyFile as NSString).expandingTildeInPath] }
                args += config.sshOptions
                args += ["-l", config.user, "--", config.host, command]
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                if let askpass = try? Self.askpassScript() {
                    env["SSH_ASKPASS"] = askpass.path
                    env["SSH_ASKPASS_REQUIRE"] = "force"
                    env["DISPLAY"] = env["DISPLAY"] ?? ":0"
                    env["MACEXPLORER_SSH_SECRET"] = config.password
                }
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { return continuation.resume(returning: (-1, "")) }
                // İptal: ssh kapatılır (sunucudaki o anki kopya yarım kalabilir).
                let watcher = DispatchSource.makeTimerSource(queue: .global())
                watcher.schedule(deadline: .now() + 0.5, repeating: 0.5)
                watcher.setEventHandler {
                    let cancelled = DispatchQueue.main.sync { MainActor.assumeIsolated { isCancelled() } }
                    if cancelled, p.isRunning { p.terminate() }
                }
                watcher.resume()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                watcher.cancel()
                continuation.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// ssh'nin parola sorusunu ortam değişkeninden yanıtlayan küçük betik (parola dosyaya yazılmaz).
    nonisolated private static func askpassScript() throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacExplorer", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("askpass.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$MACEXPLORER_SSH_SECRET\"\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != script { try script.write(to: url, atomically: true, encoding: .utf8) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
