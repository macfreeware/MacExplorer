import AppKit

/// Tam Disk Erişimi (Ayarlar ▸ Genel). Dosya yöneticisi için uygun izin: açıkken macOS klasör klasör sormaz. Uygulama bunu
/// kendisi açamaz, yalnızca kullanıcıyı Sistem Ayarları'ndaki listeye götürür. İzin imzaya bağlıdır (bkz. scripts/build_app.sh).
enum FullDiskAccess {
    /// Bu klasörler yalnızca Tam Disk Erişimi ile listelenebilir; deneme izin penceresi açmaz. Birkaç aday: hepsi her Mac'te olmayabilir.
    private static let probes = ["Library/Safari", "Library/Mail", "Library/Messages", "Library/Metadata/CoreSpotlight"]

    static var isGranted: Bool {
        let manager = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let folder = probes.map({ home.appending(path: $0).path }).first(where: manager.fileExists(atPath:)) else { return false }
        return (try? manager.contentsOfDirectory(atPath: folder)) != nil
    }

    /// Uygulama listeye kendiliğinden girmez: kullanıcı + ile ekler ya da sürükler. Bu yüzden Finder'da da gösterilir.
    @MainActor
    static func openSettings() {
        NSWorkspace.shared.selectFile(Bundle.main.bundlePath, inFileViewerRootedAtPath: "")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
