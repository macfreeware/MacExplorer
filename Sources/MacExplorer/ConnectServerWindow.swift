import AppKit
import SwiftUI

/// "Sunucuya Bağlan" (⌘K) ve kayıtlı sunucuyu düzenleme penceresi.
@MainActor
final class ConnectServerModel: ObservableObject {
    @Published var address = ""
    @Published var kind: ServerKind = .smb
    @Published var host = ""
    @Published var port = ""
    @Published var path = ""
    @Published var user = ""
    @Published var password = ""
    @Published var keyFile = ""
    @Published var savePassword = true
    @Published var saveServer = true
    @Published var name = ""
    @Published var addressError = false

    let editing: ServerBookmark?
    let hasStoredPassword: Bool

    init(editing: ServerBookmark?) {
        self.editing = editing
        hasStoredPassword = editing.map { ServerKeychain.password(for: $0.id) != nil } ?? false
        if let editing { fill(from: editing) }
    }

    func fill(from server: ServerBookmark) {
        kind = ServerKind.available.contains(server.kind) ? server.kind : .smb
        host = server.host
        port = server.port.map(String.init) ?? ""
        path = server.path
        user = server.user
        keyFile = server.keyFile
        name = server.name
        address = server.url?.absoluteString ?? ""
    }

    /// Yapıştırılan adresten alanları doldurur.
    func applyAddress() {
        guard let server = ServerBookmark(address: address), ServerKind.available.contains(server.kind) else {
            addressError = !address.trimmingCharacters(in: .whitespaces).isEmpty
            return
        }
        addressError = false
        let keepName = name
        fill(from: server)
        name = keepName
    }

    var bookmark: ServerBookmark {
        var server = ServerBookmark(name: name.trimmingCharacters(in: .whitespaces), kind: kind,
                                    host: host.trimmingCharacters(in: .whitespaces), port: Int(port),
                                    user: user.trimmingCharacters(in: .whitespaces), path: path.trimmingCharacters(in: .whitespaces),
                                    keyFile: kind == .sftp ? keyFile.trimmingCharacters(in: .whitespaces) : "")
        if let editing { server.id = editing.id }
        return server
    }

    var canConnect: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    /// ~/.ssh/config'teki bir sunucu: ssh kullanıcıyı, portu ve anahtarı kendi yapılandırmasından alır.
    func fill(sshHost: String) {
        kind = .sftp
        host = sshHost
        port = ""
        user = ""
        keyFile = ""
        if name.isEmpty { name = sshHost }
        address = "sftp://\(sshHost)"
    }

    var defaultPort: String {
        switch kind {
        case .sftp: return "22"
        case .ftp, .ftpes: return "21"
        case .ftps: return "990"
        default: return String(localized: "varsayılan", bundle: .live)
        }
    }

    func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = String(localized: "SSH özel anahtar dosyasını seçin (örn. id_ed25519).", bundle: .live)
        if panel.runModal() == .OK, let url = panel.url {
            keyFile = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

private struct ConnectServerView: View {
    @ObservedObject var model: ConnectServerModel
    let recent: [ServerBookmark]
    let sshHosts: [String]
    let finish: (Bool) -> Void

    private var isEditing: Bool { model.editing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.kind.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color(nsColor: Theme.current.accentColor).gradient, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Sunucuyu Düzenle" : "Sunucuya Bağlan").font(.title3.weight(.semibold))
                    Text("SFTP ve FTP sunucuları panelde açılır; Windows / NAS paylaşımları, WebDAV, AFP ve NFS disk gibi bağlanır.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !sshHosts.isEmpty && !isEditing {
                    Menu {
                        ForEach(sshHosts, id: \.self) { host in
                            Button(host) { model.fill(sshHost: host) }
                        }
                    } label: {
                        Label("SSH sunucuları", systemImage: "terminal")
                    }
                    .fixedSize()
                    .help(Text("~/.ssh/config dosyasındaki sunucular"))
                }
                if !recent.isEmpty && !isEditing {
                    Menu {
                        ForEach(recent) { server in
                            Button(server.url?.absoluteString ?? server.host) { model.fill(from: server) }
                        }
                    } label: {
                        Label("Son bağlantılar", systemImage: "clock")
                    }
                    .fixedSize()
                }
            }
            .padding(20)

            Form {
                Section {
                    TextField("Adres", text: $model.address, prompt: Text(verbatim: "sftp://kullanici@sunucu  ·  smb://nas.local/Paylaşım"))
                        .onSubmit { model.applyAddress() }
                    if model.addressError {
                        Text("Bu adres tanınmadı. sftp://, ftp://, ftps://, smb://, https://, afp:// ya da nfs:// ile başlamalı.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    Picker("Tür", selection: $model.kind) {
                        ForEach(ServerKind.available) { Text(verbatim: $0.title).tag($0) }
                    }
                    TextField("Sunucu", text: $model.host, prompt: Text("ad ya da IP adresi"))
                    TextField("Port", text: $model.port, prompt: Text(verbatim: model.defaultPort))
                    TextField(model.kind == .smb ? "Paylaşım" : "Klasör", text: $model.path,
                              prompt: Text(model.kind == .smb ? "boş bırakılırsa paylaşımlar listelenir"
                                           : model.kind.isRemote ? "boş: ana dizin" : "isteğe bağlı"))
                }
                if model.kind.usesCredentials {
                    Section {
                        TextField("Kullanıcı", text: $model.user, prompt: Text(userPrompt))
                        SecureField("Parola", text: $model.password,
                                    prompt: Text(model.hasStoredPassword ? "Anahtar Zinciri'nde kayıtlı" : passwordPrompt))
                        if model.kind == .sftp {
                            HStack {
                                TextField("Anahtar dosyası", text: $model.keyFile, prompt: Text("boş: ssh-agent ve ~/.ssh anahtarları"))
                                Button("Seç…") { model.chooseKeyFile() }
                            }
                        }
                        Toggle("Parolayı Anahtar Zinciri'nde sakla", isOn: $model.savePassword)
                    }
                }
                if !isEditing {
                    Section {
                        Toggle("Bu sunucuyu kaydet (kenar çubuğunda Sunucular)", isOn: $model.saveServer)
                        if model.saveServer {
                            TextField("Ad", text: $model.name, prompt: Text(verbatim: model.host.isEmpty ? "NAS" : model.host))
                        }
                    }
                } else {
                    Section { TextField("Ad", text: $model.name, prompt: Text(verbatim: model.host)) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("İptal") { finish(false) }.keyboardShortcut(.cancelAction)
                Button(isEditing ? "Kaydet" : "Bağlan") { finish(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConnect)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 560, height: model.kind == .sftp ? 650 : model.kind.usesCredentials ? 610 : 480)
    }

    private var userPrompt: LocalizedStringKey {
        switch model.kind {
        case .sftp: return "boş: ssh varsayılanı (Mac kullanıcı adınız)"
        case .ftp, .ftpes, .ftps: return "boş: anonim giriş"
        default: return "boş: macOS sorar"
        }
    }

    private var passwordPrompt: LocalizedStringKey {
        switch model.kind {
        case .sftp: return "boş: SSH anahtarı; gerekirse sorulur"
        case .ftp, .ftpes, .ftps: return "boş: gerekirse sorulur"
        default: return "boş: macOS sorar"
        }
    }
}

/// Pencereyi açar. Düzenlemede yalnızca kaydeder; yeni bağlantıda bağlanır ve isteğe göre kaydeder.
@MainActor
enum ConnectServerController {
    private static var open: NSWindow?

    static func present(over parent: NSWindow?, editing: ServerBookmark? = nil, connected: @escaping (URL) -> Void = { _ in }) {
        // Zaten açıksa ikincisi açılmaz; açık olan öne gelir.
        if let open, open.isVisible {
            open.makeKeyAndOrderFront(nil)
            return
        }
        let model = ConnectServerModel(editing: editing)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let finish: (Bool) -> Void = { ok in
            if let parent, sheet.sheetParent === parent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
            open = nil
            guard ok else { return }
            let server = model.bookmark
            let typed = model.password
            if editing != nil || model.saveServer {
                ServerStore.save(server)
                if model.kind.usesCredentials {
                    if model.savePassword, !typed.isEmpty {
                        ServerKeychain.set(typed, for: server.id, label: server.displayName)
                    } else if !model.savePassword {
                        ServerKeychain.delete(for: server.id)
                    }
                }
            }
            guard editing == nil else { return }
            let password = typed.isEmpty ? ServerKeychain.password(for: server.id) : typed
            ServerConnector.connect(server, password: password, over: parent, completion: connected)
        }
        sheet.contentViewController = NSHostingController(rootView: ConnectServerView(model: model, recent: ServerStore.recent, sshHosts: SSHConfig.hosts(), finish: finish).liveLocale())
        open = sheet
        if let parent, parent.attachedSheet == nil { parent.beginSheet(sheet) } else { sheet.center(); sheet.makeKeyAndOrderFront(nil) }
    }

    /// Kayıtlı sunucuya bağlanır (parola Anahtar Zinciri'nden; yoksa macOS sorar).
    static func connect(_ server: ServerBookmark, over window: NSWindow?, connected: @escaping (URL) -> Void) {
        ServerConnector.connect(server, password: ServerKeychain.password(for: server.id), over: window, completion: connected)
    }

    /// Kaydı silmeden önce sorar (parolası da Anahtar Zinciri'nden silinir).
    static func confirmDelete(_ server: ServerBookmark, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(server.displayName)” bağlantısı silinsin mi?", bundle: .live)
        alert.informativeText = String(localized: "Kayıt ve Anahtar Zinciri'ndeki parolası silinir. Sunucudaki dosyalara dokunulmaz.", bundle: .live)
        alert.addButton(withTitle: String(localized: "Sil", bundle: .live)).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        alert.confirmsWithKeyboard()
        let handler: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { ServerStore.delete(server) } }
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: handler) } else { handler(alert.runModal()) }
    }
}
