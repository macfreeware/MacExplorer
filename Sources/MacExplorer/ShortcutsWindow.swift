import AppKit
import SwiftUI

/// Klavye kısayolları yardımı (F1 ya da Yardım ▸ Klavye Kısayolları). Seçili klavye düzenine göre açılır.
private struct Shortcut: Identifiable {
    let id = UUID()
    let action: String
    let windows: String
    let mac: String
}

private struct ShortcutGroup: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let items: [Shortcut]
}

private let shortcutGroups: [ShortcutGroup] = [
    ShortcutGroup(title: String(localized: "Gezinme", bundle: .live), symbol: "arrow.up.and.down.and.arrow.left.and.right", items: [
        Shortcut(action: String(localized: "Aç", bundle: .live), windows: "Enter", mac: "⌘↓"),
        Shortcut(action: String(localized: "Üst klasör", bundle: .live), windows: "Backspace · Alt+↑", mac: "⌘↑"),
        Shortcut(action: String(localized: "Geri / İleri", bundle: .live), windows: "Alt+← / Alt+→", mac: "⌘[ / ⌘]"),
        Shortcut(action: String(localized: "Adres çubuğu", bundle: .live), windows: "Ctrl+L · Alt+D", mac: "⌘L"),
        Shortcut(action: String(localized: "İlk / son öğe", bundle: .live), windows: "Home / End", mac: "Home / End"),
        Shortcut(action: String(localized: "Bir sayfa yukarı / aşağı", bundle: .live), windows: "Page Up / Page Down", mac: "Page Up / Page Down"),
        Shortcut(action: String(localized: "Seçimi oraya kadar genişlet", bundle: .live), windows: "Shift + Home · End · Page Up · Page Down", mac: "Shift + Home · End · Page Up · Page Down"),
        Shortcut(action: String(localized: "Ara", bundle: .live), windows: "Ctrl+F", mac: "⌘F"),
        Shortcut(action: String(localized: "Yenile", bundle: .live), windows: String(localized: "F5 (tek panel) · Ctrl+R", bundle: .live), mac: "⌘R"),
    ]),
    ShortcutGroup(title: String(localized: "Dosya işlemleri", bundle: .live), symbol: "doc.on.doc", items: [
        Shortcut(action: String(localized: "Kes / Kopyala / Yapıştır", bundle: .live), windows: "Ctrl+X / Ctrl+C / Ctrl+V", mac: "⌘X / ⌘C / ⌘V"),
        Shortcut(action: String(localized: "Yeniden adlandır", bundle: .live), windows: "F2", mac: "Enter · F2"),
        Shortcut(action: String(localized: "Sil (Çöp Sepeti)", bundle: .live), windows: "Delete · F8", mac: "⌘⌫ · F8"),
        Shortcut(action: String(localized: "Kalıcı olarak sil", bundle: .live), windows: "Shift+Delete", mac: "⌥⌘⌫"),
        Shortcut(action: String(localized: "Yeni klasör", bundle: .live), windows: "Ctrl+Shift+N · F7", mac: "⇧⌘N · F7"),
        Shortcut(action: String(localized: "Geri al / Yinele", bundle: .live), windows: "Ctrl+Z / Ctrl+Y", mac: "⌘Z / ⇧⌘Z"),
        Shortcut(action: String(localized: "Hızlı Bakış", bundle: .live), windows: "F3 · ⌘Y", mac: String(localized: "Boşluk · ⌘Y · F3", bundle: .live)),
        Shortcut(action: String(localized: "İşaretle (klavyeyle çoklu seçim)", bundle: .live),
                 windows: String(localized: "Boşluk · Insert · Ctrl+Boşluk", bundle: .live), mac: "Insert"),
        Shortcut(action: String(localized: "İşaretleri kaldır", bundle: .live), windows: "Esc", mac: "Esc"),
        Shortcut(action: String(localized: "Desene göre seç / seçimden çıkar", bundle: .live), windows: "Num + / Num −", mac: "Num + / Num −"),
        Shortcut(action: String(localized: "Seçimi tersine çevir", bundle: .live), windows: "Num *", mac: "Num *"),
        Shortcut(action: String(localized: "Düzenle (metin düzenleyicide aç)", bundle: .live), windows: "F4", mac: "F4"),
        Shortcut(action: String(localized: "Özellikler", bundle: .live), windows: "Alt+Enter", mac: "⌘I"),
        Shortcut(action: String(localized: "Yolu kopyala", bundle: .live), windows: "⌥⌘C", mac: "⌥⌘C"),
        Shortcut(action: String(localized: "Terminalde aç", bundle: .live), windows: "⌥⌘T", mac: "⌥⌘T"),
    ]),
    ShortcutGroup(title: String(localized: "Sekmeler, paneller ve pencereler", bundle: .live), symbol: "rectangle.split.2x1", items: [
        Shortcut(action: String(localized: "Çift panel", bundle: .live), windows: "F9", mac: "F9"),
        Shortcut(action: String(localized: "Önizleme bölmesi", bundle: .live), windows: "Alt+P", mac: "⇧⌘P"),
        Shortcut(action: String(localized: "Diğer panele geç", bundle: .live), windows: "Tab", mac: "Tab"),
        Shortcut(action: String(localized: "Diğer panele kopyala", bundle: .live), windows: "F5", mac: "F5"),
        Shortcut(action: String(localized: "Diğer panele taşı", bundle: .live), windows: "F6", mac: "F6"),
        Shortcut(action: String(localized: "Yeni sekme / Sekmeyi kapat", bundle: .live), windows: "Ctrl+T / Ctrl+W", mac: "⌘T / ⌘W"),
        Shortcut(action: String(localized: "Sonraki / önceki sekme", bundle: .live), windows: "Ctrl+Tab / Ctrl+Shift+Tab", mac: "⌃Tab / ⌃⇧Tab"),
        Shortcut(action: String(localized: "Yeni pencere", bundle: .live), windows: "Ctrl+N", mac: "⌘N"),
    ]),
    ShortcutGroup(title: String(localized: "Görünüm", bundle: .live), symbol: "square.grid.2x2", items: [
        Shortcut(action: String(localized: "Görünümler (Çok büyük simgeler … Ayrıntılar)", bundle: .live), windows: "Ctrl+Shift+1…6", mac: "⌘1…⌘6"),
        Shortcut(action: String(localized: "Gizli öğeler", bundle: .live), windows: "⇧⌘.", mac: "⇧⌘."),
        Shortcut(action: String(localized: "Kenar çubuğu", bundle: .live), windows: "⌃⌘S", mac: "⌃⌘S"),
        Shortcut(action: String(localized: "Bu yardım", bundle: .live), windows: "F1", mac: "F1"),
    ]),
]

private struct ShortcutsView: View {
    @State private var mode: KeyboardMode = Preferences.keyboardMode
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Klavye Kısayolları").font(.title2.weight(.semibold))
                Spacer()
                Picker("", selection: $mode) {
                    Text("Windows düzeni").tag(KeyboardMode.windows)
                    Text("Mac düzeni").tag(KeyboardMode.mac)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(shortcutGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(group.title, systemImage: group.symbol)
                                .font(.headline)
                                .foregroundStyle(Color(nsColor: Theme.current.accentColor))
                            VStack(spacing: 0) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    HStack {
                                        Text(verbatim: item.action)
                                        Spacer(minLength: 16)
                                        KeyCaps(text: mode == .windows ? item.windows : item.mac)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(index.isMultiple(of: 2) ? Color.secondary.opacity(0.06) : .clear)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
                        }
                    }
                    Label("MacBook'ta F1…F12 için fn tuşunu basılı tutun. Touch Bar'lı modellerde işlev tuşları Touch Bar'da da görünür.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }

            Divider()
            HStack {
                Button("Klavye ayarları…") { SettingsWindowController.shared.show(.keyboard) }
                Spacer()
                Button("Kapat", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 620, height: 640)
        .onExitCommand(perform: close)
    }
}

/// Tuş birleşimini klavye tuşu görünümünde çizer ("Ctrl+C / ⌘C").
private struct KeyCaps: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

@MainActor
final class ShortcutsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ShortcutsWindowController()

    private init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = String(localized: "Klavye Kısayolları", bundle: .live)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    /// Kapanınca içerik bellekten bırakılır; bir sonraki açılışta yeniden kurulur.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard self?.window?.isVisible == false else { return }
            self?.window?.contentViewController = nil
        }
    }

    /// Her açılışta seçili klavye düzeniyle; MacExplorer penceresinin ortasında.
    func present(over parent: NSWindow?) {
        window?.title = String(localized: "Klavye Kısayolları", bundle: .live)
        window?.contentViewController = NSHostingController(rootView: ShortcutsView { [weak self] in self?.window?.close() }.liveLocale())
        let anchor = parent ?? NSApp.windows.first { $0.isVisible && $0.windowController is BrowserWindowController }
        window?.center(over: anchor)
        showWindow(nil)
        NSApp.activate()
    }
}
