import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacExplorerCore

/// Windows "Özellikler" penceresinin Genel sekmesi: tür, birlikte açılır, konum, boyut, disk boyutu, içerik,
/// tarihler ve öznitelikler (Salt okunur, Gizli). Klasör boyutu arka planda, sayıldıkça güncellenerek hesaplanır.
@MainActor
final class PropertiesModel: ObservableObject {
    let urls: [URL]
    let icon: NSImage
    let title: String
    let kind: String
    let location: String
    let created: Date?
    let modified: Date?
    let accessed: Date?
    let isFolderLike: Bool

    @Published var bytes: Int64 = 0
    @Published var allocated: Int64 = 0
    @Published var files = 0
    @Published var folders = 0
    @Published var counting = true
    @Published var readOnly: Bool
    @Published var hidden: Bool
    @Published var defaultApp: URL?

    private var task: Task<Void, Never>?

    init(urls: [URL]) {
        self.urls = urls
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey,
                                         .contentAccessDateKey, .isDirectoryKey, .isUserImmutableKey, .isHiddenKey]
        let values = urls.map { try? $0.resourceValues(forKeys: keys) }
        let single = urls.count == 1
        icon = single ? NSWorkspace.shared.icon(forFile: urls[0].path) : NSWorkspace.shared.icon(forFiles: urls.map(\.path)) ?? NSImage()
        icon.size = NSSize(width: 48, height: 48)

        let folderCount = values.filter { $0?.isDirectory == true }.count
        let fileCount = urls.count - folderCount
        if single {
            title = FileManager.default.displayName(atPath: urls[0].path)
        } else {
            title = String(localized: "\(fileCount) dosya, \(folderCount) klasör", bundle: .live)
        }
        let kinds = Set(values.compactMap { $0?.localizedTypeDescription })
        kind = kinds.count == 1 ? kinds.first! : String(localized: "Birden çok türde", bundle: .live)
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        let parent = parents.count == 1 ? parents.first! : ""
        location = single || parents.count == 1 ? parent : String(localized: "Çeşitli konumlar", bundle: .live)
        created = single ? values[0]?.creationDate : nil
        modified = single ? values[0]?.contentModificationDate : nil
        accessed = single ? values[0]?.contentAccessDate : nil
        isFolderLike = !single || folderCount > 0
        readOnly = values.allSatisfy { $0?.isUserImmutable == true }
        hidden = values.allSatisfy { $0?.isHidden == true }
        if single && folderCount == 0 { defaultApp = NSWorkspace.shared.urlForApplication(toOpen: urls[0]) }
        startCounting()
    }

    deinit { task?.cancel() }

    private func startCounting() {
        let urls = self.urls
        nonisolated(unsafe) weak var owner = self
        task = Task.detached(priority: .utility) {
            var bytes: Int64 = 0, allocated: Int64 = 0, files = 0, folders = 0
            var lastPublish = Date()
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
            func add(_ url: URL) {
                let v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true { folders += 1 } else {
                    files += 1
                    bytes += Int64(v?.fileSize ?? 0)
                    allocated += Int64(v?.totalFileAllocatedSize ?? 0)
                }
            }
            for url in urls {
                if FileInfo.isRealDirectory(url) {
                    let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
                    while let child = e?.nextObject() as? URL {
                        if Task.isCancelled { return }
                        add(child)
                        if Date().timeIntervalSince(lastPublish) > 0.25 {
                            lastPublish = Date()
                            let snapshot = (bytes, allocated, files, folders)
                            await MainActor.run { owner?.publish(snapshot, done: false) }
                        }
                    }
                } else {
                    add(url)
                }
            }
            let snapshot = (bytes, allocated, files, folders)
            await MainActor.run { owner?.publish(snapshot, done: true) }
        }
    }

    private func publish(_ s: (Int64, Int64, Int, Int), done: Bool) {
        (bytes, allocated, files, folders) = s
        counting = !done
    }

    /// Salt okunur = macOS "Kilitli" (değiştirilemez) bayrağı.
    func setReadOnly(_ value: Bool) -> String? {
        apply { $0.isUserImmutable = value }
    }

    func setHidden(_ value: Bool) -> String? {
        apply { $0.isHidden = value }
    }

    private func apply(_ change: (inout URLResourceValues) -> Void) -> String? {
        for var url in urls {
            var values = URLResourceValues()
            change(&values)
            do { try url.setResourceValues(values) } catch { return error.localizedDescription }
        }
        return nil
    }

    /// "Değiştir…": bu türdeki tüm dosyaları açacak uygulamayı seçer (Windows gibi tür genelinde).
    func changeDefaultApp(in window: NSWindow?) {
        guard let file = urls.first, let type = (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Seç", bundle: .live)
        panel.message = String(localized: "Bu türdeki dosyaları açacak uygulamayı seçin.", bundle: .live)
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.defaultApp = NSWorkspace.shared.urlForApplication(toOpen: file) }
                }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }
}

struct PropertiesView: View {
    @ObservedObject var model: PropertiesModel
    let close: () -> Void
    @State private var error: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: model.icon)
                Text(verbatim: model.title).font(.title3).textSelection(.enabled).lineLimit(2)
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                row("Tür:", model.kind)
                if let app = model.defaultApp {
                    GridRow {
                        label("Birlikte açılır:")
                        HStack {
                            Image(nsImage: Self.smallIcon(app))
                            Text(verbatim: FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
                            Spacer()
                            Button("Değiştir…") { model.changeDefaultApp(in: NSApp.keyWindow) }
                        }
                    }
                }
                divider
                row("Konum:", model.location)
                row("Boyut:", sizeText(model.bytes))
                row("Disk boyutu:", sizeText(model.allocated))
                if model.isFolderLike {
                    row("İçerik:", String(localized: "\(model.files) dosya, \(model.folders) klasör", bundle: .live)
                        + (model.counting ? "  …" : ""))
                }
                if model.created != nil || model.modified != nil || model.accessed != nil {
                    divider
                    if let d = model.created { row("Oluşturma:", Self.dateFormatter.string(from: d)) }
                    if let d = model.modified { row("Değiştirme:", Self.dateFormatter.string(from: d)) }
                    if let d = model.accessed { row("Erişim:", Self.dateFormatter.string(from: d)) }
                }
                divider
                GridRow(alignment: .firstTextBaseline) {
                    label("Öznitelikler:")
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Salt okunur (kilitli)", isOn: Binding(
                            get: { model.readOnly },
                            set: { value in
                                if let message = model.setReadOnly(value) { error = message } else { model.readOnly = value }
                            }))
                        Toggle("Gizli", isOn: Binding(
                            get: { model.hidden },
                            set: { value in
                                if let message = model.setHidden(value) { error = message } else { model.hidden = value }
                            }))
                    }
                }
            }
            if let error {
                Text(verbatim: error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Tamam", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var divider: some View {
        GridRow { Divider().gridCellColumns(2) }
    }

    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            label(key)
            Text(verbatim: value).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
        }
    }

    /// "1,2 MB (1.234.567 bayt)" (Windows gibi).
    private func sizeText(_ bytes: Int64) -> String {
        let grouped = NumberFormatter.localizedString(from: NSNumber(value: bytes), number: .decimal)
        return String(localized: "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) (\(grouped) bayt)", bundle: .live)
    }

    private static func smallIcon(_ app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

@MainActor
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [PropertiesWindowController] = []

    /// `parent`: Özellikler'in ortasında açılacağı MacExplorer penceresi.
    static func show(for urls: [URL], over parent: NSWindow?) {
        guard !urls.isEmpty else { return }
        let controller = PropertiesWindowController(urls: urls)
        openControllers.append(controller)
        controller.window?.center(over: parent)
        controller.showWindow(nil)
    }

    private init(urls: [URL]) {
        let model = PropertiesModel(urls: urls)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = String(localized: "\(model.title) Özellikleri", bundle: .live)
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: PropertiesView(model: model) { [weak window] in window?.close() }.liveLocale())
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    func windowWillClose(_ notification: Notification) {
        Self.openControllers.removeAll { $0 === self }
    }
}
