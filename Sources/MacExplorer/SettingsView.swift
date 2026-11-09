import SwiftUI
import AppKit

/// Ayarlar sekmeleri. Yeni bir bölüm eklemek için buraya bir durum ve aşağıda görünümünü ekleyin.
enum SettingsPane: String, CaseIterable {
    case general, appearance, interface, keyboard, servers, macRAR

    var title: String {
        switch self {
        case .general: return String(localized: "Genel", bundle: .live)
        case .appearance: return String(localized: "Görünüm", bundle: .live)
        case .interface: return String(localized: "Arayüz", bundle: .live)
        case .keyboard: return String(localized: "Klavye", bundle: .live)
        case .servers: return String(localized: "Sunucular", bundle: .live)
        case .macRAR: return "MacRAR"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .interface: return "macwindow"
        case .keyboard: return "keyboard"
        case .servers: return "server.rack"
        case .macRAR: return "archivebox"
        }
    }

    /// Ayarlar penceresinin sabit içerik boyu: en uzun sekme (Arayüz) kaydırmadan sığar; sekme değişince pencere boyu
    /// değişmez. Ekran daha küçükse ekrana sığacak kadar (o zaman uzun sekmeler kaydırılır).
    @MainActor static var contentSize: NSSize {
        let wanted: CGFloat = 800   // Türkçe metinler İngilizceden biraz uzun
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        let chrome: CGFloat = 100   // başlık ve sekme çubuğu, biraz pay
        return NSSize(width: 640, height: max(360, min(wanted, screen - chrome)))
    }

    /// Sekmenin içeriği; tüm sekmeler aynı boyda.
    @MainActor
    var controller: NSViewController {
        let view: AnyView
        switch self {
        case .general: view = AnyView(GeneralSettings())
        case .appearance: view = AnyView(AppearanceSettings())
        case .interface: view = AnyView(InterfaceSettings())
        case .keyboard: view = AnyView(KeyboardSettings())
        case .servers: view = AnyView(ServersSettings())
        case .macRAR: view = AnyView(MacRARSettings())
        }
        let size = Self.contentSize
        let host = NSHostingController(rootView: view.formStyle(.grouped).frame(width: size.width, height: size.height).liveLocale())
        host.sizingOptions = [.preferredContentSize]
        host.title = title
        return host
    }
}

// MARK: - Ortak parçalar

/// Sistem Ayarları'ndaki gibi renkli, yuvarlatılmış kare içinde simge.
private struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Simge, başlık, isteğe bağlı açıklama ve sağda denetim.
private struct SettingRow<Control: View>: View {
    let symbol: String
    let color: Color
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

/// Açma/kapama satırı.
private struct ToggleRow: View {
    let symbol: String
    let color: Color
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(symbol: symbol, color: color, title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

// MARK: - Sekmeler

private struct GeneralSettings: View {
    @AppStorage(Preferences.Key.showHidden) private var showHidden = false
    @AppStorage(Preferences.Key.restoreSession) private var restoreSession = true
    @AppStorage(Preferences.Key.sizeDisplay) private var sizeDisplay: SizeDisplay = .automatic
    @AppStorage(Preferences.Key.selectIncludesFolders) private var selectIncludesFolders = false
    @AppStorage(Preferences.Key.updateAutoCheck) private var updateAutoCheck = true
    @State private var fullDiskAccess = FullDiskAccess.isGranted
    @State private var language = AppLanguage.saved

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "globe", color: .blue, title: "Dil", subtitle: "Arayüzün dili; değişiklik hemen uygulanır. Dosya türü adları (Klasör, PDF belgesi …) macOS’tan gelir, uygulama yeniden açılınca değişir.") {
                    Picker("", selection: $language) {
                        ForEach(AppLanguage.allCases) { (Text(verbatim: "\($0.flag)  ") + Text($0.title)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: language) { _, new in
                        // Yeniden başlatmadan: menüler ve pencereler yeni dilde yeniden kurulur (bu pencere dahil).
                        DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.applyLanguage(new) }
                    }
                }
                ToggleRow(symbol: "eye", color: .gray, title: "Gizli öğeleri göster",
                          subtitle: "Adı noktayla başlayan dosyalar ve sistem klasörleri.", isOn: $showHidden)
                ToggleRow(symbol: "clock.arrow.circlepath", color: .teal, title: "Son pencereleri geri yükle",
                          subtitle: "Açılışta pencereler, sekmeler, klasörler, çift panel ve görünümler kaldığı gibi açılır.",
                          isOn: $restoreSession)
                ToggleRow(symbol: "checklist", color: .green, title: "Desene göre seçimde klasörleri de dahil et",
                          subtitle: "Num + / Num − (desene göre seç / çıkar) ve Num * (seçimi tersine çevir). Kapalıyken yalnızca dosyalar seçilir.",
                          isOn: $selectIncludesFolders)
                SettingRow(symbol: "internaldrive", color: .orange, title: "Boyut gösterimi",
                           subtitle: "Listedeki Boyut sütunu. Windows Gezgini boyutu her zaman KB gösterir.") {
                    Picker("", selection: $sizeDisplay) {
                        Text("Otomatik (KB, MB, GB)").tag(SizeDisplay.automatic)
                        Text("Windows gibi (KB)").tag(SizeDisplay.kilobytes)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Section {
                ToggleRow(symbol: "arrow.down.circle", color: .teal, title: "Güncellemeleri otomatik denetle",
                          subtitle: "Günde bir kez GitLab'daki son sürüme bakılır; yeni sürüm varsa notlarıyla sorulur.",
                          isOn: $updateAutoCheck)
                HStack {
                    Text(verbatim: String(localized: "Sürüm \(Updater.currentVersion)", bundle: .live)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Şimdi Denetle") { Updater.check(userInitiated: true) }
                }
            }
            Section {
                SettingRow(symbol: "lock.open", color: .indigo, title: "Tam Disk Erişimi",
                           subtitle: "Açıkken İndirilenler, Belgeler, Masaüstü, harici diskler ve ağ birimleri için ayrı ayrı izin sorulmaz. MacExplorer listede yoksa Finder’da gösterilen uygulamayı listeye sürükleyin ya da + ile ekleyin, sonra açın.") {
                    if fullDiskAccess {
                        Label("Açık", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Sistem Ayarları’nı Aç") { FullDiskAccess.openSettings() }
                    }
                }
            }
        }
        // Kullanıcı Sistem Ayarları'ndan dönünce durum yenilensin.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = FullDiskAccess.isGranted
        }
    }
}

private struct AppearanceSettings: View {
    @AppStorage(Preferences.Key.appearance) private var appearance: AppearanceMode = .system
    @AppStorage(Preferences.Key.theme) private var themeID = Theme.system.id

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "circle.lefthalf.filled", color: .indigo, title: "Görünüm") {
                    Picker("", selection: $appearance) {
                        Text("Sistem").tag(AppearanceMode.system)
                        Text("Aydınlık").tag(AppearanceMode.light)
                        Text("Karanlık").tag(AppearanceMode.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: appearance) { _, _ in Theme.applyAppearance() }
                }
            }
            Section {
                SettingRow(symbol: "paintpalette", color: .pink, title: "Tema", subtitle: "Sekme çubuğu, liste, seçim ve vurgu renkleri.") { EmptyView() }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(Theme.all) { theme in
                        ThemeCard(theme: theme, selected: theme.id == themeID) {
                            themeID = theme.id
                            NotificationCenter.default.post(name: Theme.didChange, object: nil)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct InterfaceSettings: View {
    @AppStorage(Preferences.Key.toolbarDisplay) private var toolbarDisplay: ToolbarDisplay = .icon
    @AppStorage(UIElement.statusBar.key) private var showStatusBar = true
    @AppStorage(UIElement.viewButtons.key) private var showViewButtons = true
    @AppStorage(UIElement.functionBar.key) private var showFunctionBar = true
    @AppStorage(UIElement.toolbarEdit.key) private var showToolbarEdit = true
    @AppStorage(UIElement.toolbarViewMode.key) private var showToolbarViewMode = true
    @AppStorage(UIElement.toolbarTerminal.key) private var showToolbarTerminal = true
    @AppStorage(UIElement.toolbarHidden.key) private var showToolbarHidden = true
    @AppStorage(UIElement.toolbarDualPane.key) private var showToolbarDualPane = true
    @AppStorage(UIElement.toolbarPreview.key) private var showToolbarPreview = true
    @AppStorage(UIElement.toolbarNewWindow.key) private var showToolbarNewWindow = true
    @AppStorage(Preferences.Key.dimInactivePane) private var dimInactivePane = true

    var body: some View {
        Form {
            Section("Araç çubuğu") {
                SettingRow(symbol: "textformat", color: .blue, title: "Gösterim") {
                    Picker("", selection: $toolbarDisplay) {
                        Text("Yalnızca simge").tag(ToolbarDisplay.icon)
                        Text("Simge ve metin").tag(ToolbarDisplay.iconAndLabel)
                        Text("Yalnızca metin").tag(ToolbarDisplay.label)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ToggleRow(symbol: "scissors", color: .orange, title: "Düzen düğmeleri",
                          subtitle: "Yeni klasör, Kes, Kopyala, Yapıştır, Yeniden adlandır, Sil", isOn: $showToolbarEdit)
                ToggleRow(symbol: "square.grid.2x2", color: .indigo, title: "Görünüm menüsü", isOn: $showToolbarViewMode)
                ToggleRow(symbol: "apple.terminal", color: .black, title: "Terminal düğmesi", isOn: $showToolbarTerminal)
                ToggleRow(symbol: "eye", color: .gray, title: "Gizli öğeler düğmesi", isOn: $showToolbarHidden)
                ToggleRow(symbol: "rectangle.split.2x1", color: .teal, title: "Çift panel düğmesi", isOn: $showToolbarDualPane)
                ToggleRow(symbol: "sidebar.right", color: .blue, title: "Önizleme bölmesi düğmesi", isOn: $showToolbarPreview)
                ToggleRow(symbol: "macwindow.badge.plus", color: .indigo, title: "Yeni pencere düğmesi", isOn: $showToolbarNewWindow)
            }
            Section("Çift panel") {
                ToggleRow(symbol: "rectangle.lefthalf.inset.filled", color: .teal, title: "Etkin olmayan paneli soldur",
                          subtitle: "Etkin panel sekmesindeki vurgu çizgisiyle belli olur; bu, diğer paneli de hafifçe soluklaştırır.",
                          isOn: $dimInactivePane)
            }
            Section {
                ToggleRow(symbol: "keyboard", color: .purple, title: "İşlev tuşu çubuğu",
                          subtitle: "F2 Ad değiştir, F4 Düzenle, F5 Kopyala, F6 Taşı …", isOn: $showFunctionBar)
                ToggleRow(symbol: "rectangle.bottomthird.inset.filled", color: .green, title: "Durum çubuğu",
                          subtitle: "Öğe sayısı, seçim ve boyut", isOn: $showStatusBar)
                ToggleRow(symbol: "square.grid.3x2", color: .mint, title: "Durum çubuğunda görünüm düğmeleri", isOn: $showViewButtons)
                    .disabled(!showStatusBar)
            } header: {
                Text("Pencerenin altı")
            } footer: {
                Text("Daha sade bir pencere için kapatın; komutlar menülerde ve kısayollarda kalır.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct KeyboardSettings: View {
    @AppStorage(Preferences.Key.keyboardMode) private var keyboardMode: KeyboardMode = .windows
    @AppStorage(Preferences.Key.editorApp) private var editorPath = ""

    private var editorName: String {
        Preferences.editorApp.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? String(localized: "Yok", bundle: .live)
    }

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "keyboard", color: .gray, title: "Klavye düzeni") {
                    Picker("", selection: $keyboardMode) {
                        Text("Windows").tag(KeyboardMode.windows)
                        Text("Mac").tag(KeyboardMode.mac)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(keyboardMode == .windows
                     ? "Enter: Aç · Backspace: Üst klasör · F2: Yeniden adlandır · Delete: Sil · Alt+←/→: Geri/İleri · Ctrl+Z / Ctrl+Y: Geri al / Yinele · Boşluk: Hızlı Bakış. Ctrl kısayolları (Ctrl+C, Ctrl+V, Ctrl+T …) ⌘ ile aynı çalışır."
                     : "⌘↓: Aç · ⌘↑: Üst klasör · Enter: Yeniden adlandır · ⌘⌫: Sil · ⌘[ / ⌘]: Geri/İleri · ⌘Z / ⇧⌘Z: Geri al / Yinele · Boşluk: Hızlı Bakış.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                SettingRow(symbol: "pencil", color: .orange, title: "F4 Düzenle", subtitle: "Dosyaların açılacağı metin düzenleyici") {
                    HStack(spacing: 6) {
                        if let app = Preferences.editorApp { Image(nsImage: Self.icon(app)) }
                        Text(verbatim: editorName).foregroundStyle(.secondary)
                        Button("Değiştir…") { chooseEditor() }
                        if !editorPath.isEmpty { Button("Sıfırla") { editorPath = "" } }
                    }
                }
                SettingRow(symbol: "questionmark.circle", color: .blue, title: "Tüm kısayollar ve işlev tuşları",
                           subtitle: "MacBook'ta F1…F12 için fn tuşunu basılı tutun. Touch Bar'lı modellerde MacExplorer'ın işlev tuşları Touch Bar'da görünür.") {
                    Button("Klavye Kısayolları…") { ShortcutsWindowController.shared.present(over: nil) }
                }
            }
        }
    }

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Seç", bundle: .live)
        panel.message = String(localized: "F4 ile dosyaların açılacağı düzenleyiciyi seçin.", bundle: .live)
        if panel.runModal() == .OK, let url = panel.url { editorPath = url.path }
    }

    private static func icon(_ app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

private struct ServersSettings: View {
    @State private var servers = ServerStore.servers
    @State private var recentCount = ServerStore.recent.count

    var body: some View {
        Form {
            Section {
                if servers.isEmpty {
                    SettingRow(symbol: "server.rack", color: .gray, title: "Kayıtlı sunucu yok",
                               subtitle: "Git ▸ Sunucuya Bağlan… (⌘K) ile bağlanırken “Bu sunucuyu kaydet”i seçin.") { EmptyView() }
                }
                ForEach(servers) { server in
                    HStack(spacing: 10) {
                        SettingsIcon(symbol: server.kind.symbol, color: .blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: server.displayName)
                            Text(verbatim: server.url?.absoluteString ?? server.host).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if ServerKeychain.password(for: server.id) != nil {
                            Image(systemName: "key.fill").foregroundStyle(.secondary).help(Text("Parola Anahtar Zinciri'nde"))
                        }
                        Button("Düzenle…") { ConnectServerController.present(over: NSApp.keyWindow, editing: server) }
                        Button(role: .destructive) { ConnectServerController.confirmDelete(server, over: NSApp.keyWindow) } label: {
                            Image(systemName: "trash")
                        }
                        .help(Text("Bağlantıyı Sil…"))
                    }
                }
            } header: {
                Text("Kayıtlı sunucular")
            } footer: {
                Text("Parolalar yalnızca macOS Anahtar Zinciri'nde saklanır. Silmek kaydı ve parolasını birlikte kaldırır; sunucudaki dosyalara dokunulmaz.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Yeni sunucu…") { ConnectServerController.present(over: NSApp.keyWindow) }
                    Spacer()
                    Button("Son bağlantıları temizle") { ServerStore.clearRecent() }.disabled(recentCount == 0)
                    Button("Tümünü sil…", role: .destructive) { confirmDeleteAll() }.disabled(servers.isEmpty)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerStore.didChange)) { _ in
            servers = ServerStore.servers
            recentCount = ServerStore.recent.count
        }
    }

    private func confirmDeleteAll() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Tüm kayıtlı bağlantılar silinsin mi?", bundle: .live)
        alert.informativeText = String(localized: "Kayıtlar, Anahtar Zinciri'ndeki parolaları ve son bağlantılar silinir.", bundle: .live)
        alert.addButton(withTitle: String(localized: "Tümünü sil", bundle: .live)).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "İptal", bundle: .live))
        alert.confirmsWithKeyboard()
        if alert.runModal() == .alertFirstButtonReturn { ServerStore.deleteAll() }
    }
}

private struct MacRARSettings: View {
    @State private var app = MacRARInstaller.isInstalled
        ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.macrar.app") : nil

    private var version: String? {
        app.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if let app {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable()
                        } else {
                            Image(systemName: "archivebox.fill").resizable().scaledToFit().padding(10)
                                .foregroundStyle(.white).background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(verbatim: "MacRAR").font(.title2.weight(.semibold))
                            if let version { Text(verbatim: version).font(.caption).foregroundStyle(.secondary) }
                            Label(app != nil ? "Kurulu" : "Kurulu değil", systemImage: app != nil ? "checkmark.circle.fill" : "minus.circle")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(app != nil ? .green : .secondary)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background((app != nil ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
                        }
                        Text("macOS için ücretsiz ve açık kaynak, WinRAR tarzı arşiv yöneticisi. MacExplorer'ın sağ tık menüsündeki sıkıştırma ve çıkarma komutlarını sağlar.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("MacRAR ile") {
                SettingRow(symbol: "doc.zipper", color: .red, title: "RAR, ZIP, 7Z ve TAR",
                           subtitle: "Arşivleri açın, çıkarın ve yeni arşiv oluşturun") { EmptyView() }
                SettingRow(symbol: "contextualmenu.and.cursorarrow", color: .blue, title: "Sağ tık menüsünde",
                           subtitle: "Buraya Çıkar, “ad.rar” olarak Sıkıştır, Zaman Damgalı ZIP’e Sıkıştır …") { EmptyView() }
                SettingRow(symbol: "lock.fill", color: .gray, title: "Parolalı arşivler",
                           subtitle: "Parolalar macOS Anahtar Zinciri'nde saklanır") { EmptyView() }
            }
            Section {
                HStack {
                    if let app {
                        Button("MacRAR’ı aç") { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) }
                    } else {
                        Button("İndir ve kur") { MacRARInstaller.downloadAndInstall(over: NSApp.keyWindow) }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("GitLab sayfasını aç") { MacRARInstaller.openPage() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app = MacRARInstaller.isInstalled ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.macrar.app") : nil
        }
    }
}

/// Tema kartı: temanın sekme çubuğu, gezinme çubuğu ve liste renkleriyle küçük bir pencere çizimi.
private struct ThemeCard: View {
    let theme: Theme
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                VStack(spacing: 0) {
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: theme.chromeColor))
                            .overlay(alignment: .top) {
                                Rectangle().fill(Color(nsColor: theme.accentColor)).frame(height: 2).padding(.horizontal, 5)
                            }
                            .frame(width: 34, height: 11)
                        Spacer()
                    }
                    .padding(.horizontal, 5).padding(.top, 5)
                    .frame(height: 16)
                    .background(Color(nsColor: theme.stripColor))
                    VStack(alignment: .leading, spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: 46, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: theme.accentColor)).frame(height: 7)
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: 52, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: 38, height: 4)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: theme.contentColor))
                }
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Color(nsColor: theme.accentColor) : Color.secondary.opacity(0.3), lineWidth: selected ? 2.5 : 1)
                )
                Text(verbatim: theme.title)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// macOS'un standart sekmeli Ayarlar penceresi (araç çubuğunda simgeli sekmeler).
@MainActor
final class SettingsWindowController: NSWindowController {
    private(set) static var shared = SettingsWindowController()

    /// Dil değişince: pencere yeni dilde yeniden kurulur; açıksa aynı yerde, aynı sekmeyle açılır.
    static func rebuild() {
        let old = shared
        let wasVisible = old.window?.isVisible == true
        let tab = (old.window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex ?? 0
        let frame = old.window?.frame
        old.close()
        shared = SettingsWindowController()
        guard wasVisible else { return }
        (shared.window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab
        if let frame { shared.window?.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY)) }
        shared.keepOnScreen()
        shared.showWindow(nil)
    }

    /// Pencerenin tamamı ekranda kalsın (alt kenar ekranın altından taşmasın).
    func keepOnScreen() {
        guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let item = NSTabViewItem(viewController: pane.controller)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    func show(_ pane: SettingsPane) {
        (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: pane) ?? 0
        keepOnScreen()
        showWindow(nil)
        NSApp.activate()
    }
}
