import AppKit
import SwiftUI
import MacExplorerCore

/// Hakkında penceresindeki bir özellik kartı.
private struct Feature: Identifiable {
    let id = UUID()
    let symbol: String
    let color: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
}

struct AboutView: View {
    let close: () -> Void

    private let accent = Color(nsColor: Theme.current.accentColor)
    private let macRARInstalled = MacRARInstaller.isInstalled
    private let macNoteInstalled = MacNoteInstaller.isInstalled
    @State private var updateChecking = false
    @State private var updateResult: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return String(localized: "Geliştirme sürümü", bundle: .live) }
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return String(localized: "Sürüm \(short) (\(build))", bundle: .live)
    }

    private var system: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "macOS \(v.majorVersion).\(v.minorVersion) · \(machine == "arm64" ? "Apple silicon" : "Intel")"
    }

    private let features: [Feature] = [
        Feature(symbol: "rectangle.split.2x1", color: .blue, title: "Sekmeler ve çift panel", detail: "F9 ile yan yana iki klasör"),
        Feature(symbol: "scissors", color: .orange, title: "Gerçek Kes / Yapıştır", detail: "Finder panosuyla uyumlu"),
        Feature(symbol: "arrow.uturn.backward", color: .purple, title: "Geri al ve yinele", detail: "Tüm dosya işlemleri için"),
        Feature(symbol: "eye", color: .teal, title: "Hızlı Bakış", detail: "F3 ya da ⌘Y ile önizleme"),
        Feature(symbol: "archivebox", color: .red, title: "MacRAR entegrasyonu", detail: "Sağ tıkla sıkıştır, çıkar"),
        Feature(symbol: "square.grid.2x2", color: .indigo, title: "Altı görünüm", detail: "Simgeler, Liste, Ayrıntılar"),
        Feature(symbol: "paintpalette", color: .pink, title: "Temalar", detail: "Aydınlık ve karanlık"),
        Feature(symbol: "keyboard", color: .gray, title: "Windows klavyesi", detail: "Ctrl kısayolları, F2, Delete"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 18) {
                Text("macOS için Windows Gezgini tarzı dosya yöneticisi")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(features) { FeatureCard(feature: $0) }
                }

                HStack(spacing: 8) {
                    Chip(symbol: "desktopcomputer", text: Text(verbatim: system), color: .secondary)
                    Chip(symbol: macRARInstalled ? "checkmark.circle.fill" : "minus.circle",
                         text: Text(macRARInstalled ? "MacRAR kurulu" : "MacRAR kurulu değil"),
                         color: macRARInstalled ? .green : .secondary)
                    Chip(symbol: macNoteInstalled ? "checkmark.circle.fill" : "minus.circle",
                         text: Text(macNoteInstalled ? "MacNote++ kurulu" : "MacNote++ kurulu değil"),
                         color: macNoteInstalled ? .green : .secondary)
                }

                if !macRARInstalled {
                    // MacRAR yoksa: GitLab sayfası ya da en son sürümü indirip kurma
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox.fill").foregroundStyle(.red)
                        Text("Sağ tıkla sıkıştırma ve çıkarma için ücretsiz MacRAR'ı kurun.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Sayfası") { MacRARInstaller.openPage() }
                        Button("İndir ve kur") { MacRARInstaller.downloadAndInstall(over: NSApp.keyWindow) }
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                    }
                    .controlSize(.small)
                    .padding(10)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                if !macNoteInstalled {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill").foregroundStyle(.green)
                        Text("F3 ve F4 için ücretsiz MacNote++'ı kurun.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Sayfası") { MacNoteInstaller.openPage() }
                        Button("İndir ve kur") { MacNoteInstaller.downloadAndInstall(over: NSApp.keyWindow) }
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                    }
                    .controlSize(.small)
                    .padding(10)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(spacing: 3) {
                    Text("Geliştiricileri").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "Rafet SAPANCI").font(.callout.weight(.medium))
                    Text(verbatim: "Mustafa YILDIRIM").font(.callout.weight(.medium))
                    Text("© 2026 · GPL-3.0 lisansıyla ücretsiz ve açık kaynak").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "https://gitlab.com/freeware2/macexplorer") { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Kaynak kodu", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .focusEffectDisabled()
                Button {
                    if let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { NSWorkspace.shared.open(license) }
                } label: {
                    Label("Lisans", systemImage: "doc.text")
                }
                .focusEffectDisabled()
                Spacer()
                Button(action: close) {
                    Text("Kapat").frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: close)   // Esc
    }

    /// Sürümün altında: güncelse ya da hata varsa sonuç burada yazar; yeni sürüm varsa Hakkında kapanıp soru açılır.
    private var updateButton: some View {
        VStack(spacing: 6) {
            Button {
                Task { await checkForUpdates() }
            } label: {
                Text("Güncellemeleri Denetle…")
            }
            .controlSize(.small)
            .disabled(updateChecking)
            .focusEffectDisabled()
            if updateChecking {
                Text("Denetleniyor…").font(.caption).foregroundStyle(.white.opacity(0.85))
            } else if let updateResult {
                Text(verbatim: updateResult)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
        }
    }

    private func checkForUpdates() async {
        updateChecking = true
        updateResult = nil
        let outcome = await Updater.checkNow()
        updateChecking = false
        switch outcome {
        case .upToDate:
            updateResult = String(localized: "MacExplorer güncel.", bundle: .live) + " "
                + String(localized: "Kullandığınız sürüm (\(Updater.currentVersion)) en son sürüm.", bundle: .live)
        case .failed(let message):
            updateResult = message
        case .newer(let release):
            close()
            Updater.offer(release)
        }
    }

    /// Temanın renginde degrade, yumuşak ışık halkaları, simge ve sürüm etiketi.
    private var header: some View {
        VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 108, height: 108)
                    .shadow(color: .white.opacity(0.35), radius: 18)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 5)
                Text(verbatim: "MacExplorer")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(verbatim: version)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.2), in: Capsule())
                updateButton
        }
        .padding(.top, 6)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
        // Zemin saydam başlık çubuğunun altına da uzanır; içerik onun altında kalır.
        .background {
            ZStack {
                LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.10)).frame(width: 260).offset(x: -190, y: -70)
                Circle().fill(.white.opacity(0.07)).frame(width: 200).offset(x: 210, y: 60)
                Circle().stroke(.white.opacity(0.12), lineWidth: 1.5).frame(width: 150).offset(x: 160, y: -80)
            }
            .clipped()
            .ignoresSafeArea()
        }
    }
}

private struct FeatureCard: View {
    let feature: Feature

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feature.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(feature.color.gradient, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(feature.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Chip: View {
    let symbol: String
    let text: Text
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color)
            text.foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = String(localized: "MacExplorer Hakkında", bundle: .live)
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

    /// Her açılışta yeniden çizilir: o anki tema ve MacRAR durumu görünsün.
    func present() {
        let host = NSHostingController(rootView: AboutView { [weak self] in self?.window?.close() }.liveLocale())
        host.sizingOptions = [.preferredContentSize]
        window?.contentViewController = host
        window?.layoutIfNeeded()
        window?.center()   // her zaman ekranın ortasında
        showWindow(nil)
        NSApp.activate()
    }
}
