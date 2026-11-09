import AppKit
import AVKit
import FTPKit
import ImageIO
import MacExplorerCore
import Quartz
import UniformTypeIdentifiers

/// Önizleme bölmesi (Windows Gezgini'nde Alt+P): etkin panelde seçili dosyanın büyük önizlemesi (Hızlı Bakış ile:
/// resim, PDF, video, metin, Office …) ve altında ayrıntıları (boyutlar, çekim tarihi, kamera, süre, sayfa sayısı).
/// Seçim yoksa bulunduğu klasörü, birden çok öğe seçiliyse toplamı gösterir.
@MainActor
final class PreviewPaneController: NSViewController {
    private let quickLook = QLPreviewView(frame: .zero, style: .normal)!
    private let iconView = NSImageView()
    /// Resimler: küçültülmüş hali (Hızlı Bakış'tan hızlı; büyük fotoğraflar bellekte tam boyut açılmaz).
    private let photoView = NSImageView()
    /// Video ve ses: oynatma düğmesi ve zaman çubuğuyla (Hızlı Bakış görünümü yalnızca ilk kareyi gösteriyor).
    private let playerView = AVPlayerView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let grid = NSGridView()
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var shownKey = ""

    override func loadView() {
        let root = BackgroundView { Theme.current.contentColor }

        quickLook.shouldCloseWithWindow = false
        quickLook.autostarts = false
        quickLook.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        photoView.imageScaling = .scaleProportionallyDown
        photoView.translatesAutoresizingMaskIntoConstraints = false
        photoView.isHidden = true
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.isHidden = true
        // Resim ya da uzun metin bölmeyi genişletmesin: bölmenin genişliği ayırıcıyla belirlenir.
        for v in [photoView, iconView, playerView] as [NSView] {
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        grid.rowSpacing = 5
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        for v in [quickLook, iconView, photoView, playerView, titleLabel, grid] as [NSView] { root.addSubview(v) }
        let previewHeight = quickLook.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.55)
        previewHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            quickLook.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            quickLook.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            quickLook.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            previewHeight,
            quickLook.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            photoView.topAnchor.constraint(equalTo: quickLook.topAnchor),
            photoView.bottomAnchor.constraint(equalTo: quickLook.bottomAnchor),
            photoView.leadingAnchor.constraint(equalTo: quickLook.leadingAnchor),
            photoView.trailingAnchor.constraint(equalTo: quickLook.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: quickLook.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: quickLook.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: quickLook.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: quickLook.trailingAnchor),
            iconView.centerXAnchor.constraint(equalTo: quickLook.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: quickLook.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 128),
            iconView.heightAnchor.constraint(equalToConstant: 128),
            titleLabel.topAnchor.constraint(equalTo: quickLook.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            grid.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
        ])
        view = root
    }

    /// Bölme kapanınca önizleme bırakılır (video çalmaya devam etmesin).
    func clear() {
        pending?.cancel()
        quickLook.previewItem = nil
        stopPlayer()
        shownKey = ""
    }

    /// Seçim değişti. Ok tuşlarıyla hızla gezerken her adımda yüklenmesin diye kısa bir gecikmeyle gösterilir.
    func show(selection: [FileItem], folder: URL, folderItemCount: Int) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.update(selection: selection, folder: folder, folderItemCount: folderItemCount) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func update(selection: [FileItem], folder: URL, folderItemCount: Int) {
        let key = selection.map(\.url.locationKey).joined(separator: "|") + "#" + folder.locationKey + "#\(folderItemCount)"
        guard key != shownKey else { return }
        shownKey = key
        generation += 1
        let generation = self.generation

        if selection.count == 1, let item = selection.first {
            titleLabel.stringValue = item.displayName
            let canPreview = !item.url.isRemote && !item.isDirectory
            if canPreview, (UTType(filenameExtension: item.url.pathExtension)?.conforms(to: .image)) == true {
                showPhoto(item.url, icon: icon(for: item), generation: generation)
            } else if canPreview, (UTType(filenameExtension: item.url.pathExtension)?.conforms(to: .audiovisualContent)) == true {
                showMedia(item.url, icon: icon(for: item), generation: generation)
            } else {
                showQuickLook(canPreview ? item.url : nil, icon: icon(for: item))
            }
            setRows(basicRows(item))
            guard !item.url.isRemote else { return }
            let url = item.url, isDirectory = item.isDirectory
            Task.detached(priority: .userInitiated) {
                let extra = isDirectory ? Self.folderRows(url) : Self.mediaRows(url)
                await MainActor.run { [weak self] in
                    guard let self, generation == self.generation, !extra.isEmpty else { return }
                    self.setRows(self.basicRows(item) + extra)
                }
            }
        } else if selection.count > 1 {
            titleLabel.stringValue = String(localized: "\(selection.count) öğe seçili", bundle: .live)
            showQuickLook(nil, icon: NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil) ?? NSImage())
            let folders = selection.filter(\.isDirectory).count
            let sizes = selection.compactMap(\.size)
            var rows: [(String, String)] = []
            if folders > 0 { rows.append((String(localized: "Klasör", bundle: .live), "\(folders)")) }
            if selection.count - folders > 0 { rows.append((String(localized: "Dosya", bundle: .live), "\(selection.count - folders)")) }
            if !sizes.isEmpty {
                rows.append((String(localized: "Boyut", bundle: .live), ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)))
            }
            setRows(rows)
        } else {
            // Seçim yok: bulunduğu klasör.
            let title = folder.isRemote ? (RemoteURL.path(of: folder) == "/" ? (Archives.isArchive(folder) ? Archives.displayName(folder) : (folder.host ?? "/")) : RemotePath.name(RemoteURL.path(of: folder)))
                : FileManager.default.displayName(atPath: folder.path)
            titleLabel.stringValue = title
            let image = folder.isRemote ? RemoteIcons.icon(for: URL(string: folder.absoluteString + "/") ?? folder, size: 128)
                : NSWorkspace.shared.icon(forFile: folder.path)
            showQuickLook(nil, icon: image)
            setRows([(String(localized: "İçerik", bundle: .live), String(localized: "\(folderItemCount) öğe", bundle: .live))])
        }
    }

    private func icon(for item: FileItem) -> NSImage {
        item.url.isRemote ? RemoteIcons.icon(for: item.url, size: 128) : NSWorkspace.shared.icon(forFile: item.url.path)
    }

    /// Resmin önizlemesi: önce simge, küçük resim hazır olunca o (en çok 1600 piksel, yönü düzeltilmiş).
    private func showPhoto(_ url: URL, icon: NSImage, generation: Int) {
        showQuickLook(nil, icon: icon)
        let scale = view.window?.backingScaleFactor ?? 2
        let maxPixels = Int(min(1600, max(quickLook.bounds.width, quickLook.bounds.height, 300) * scale))
        Task.detached(priority: .userInitiated) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
            let size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
            await MainActor.run { [weak self] in
                guard let self, generation == self.generation else { return }
                self.photoView.image = NSImage(cgImage: cg, size: size)
                self.photoView.isHidden = false
                self.iconView.isHidden = true
            }
        }
    }

    /// Video ve ses: oynatıcıda, kendiliğinden başlamadan. AVFoundation'ın açamadığı biçimler (ör. MKV) Hızlı Bakış'a kalır.
    private func showMedia(_ url: URL, icon: NSImage, generation: Int) {
        showQuickLook(nil, icon: icon)
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard let self, generation == self.generation else { return }
            guard playable else { return self.showQuickLook(url, icon: icon) }
            self.playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.playerView.isHidden = false
            self.iconView.isHidden = true
        }
    }

    /// Başka öğe seçilince ya da bölme kapanınca oynatma durur.
    private func stopPlayer() {
        playerView.player?.pause()
        playerView.player = nil
        playerView.isHidden = true
    }

    private func showQuickLook(_ url: URL?, icon: NSImage) {
        stopPlayer()
        photoView.isHidden = true
        // Resim ya da uzun metin bölmeyi genişletmesin: bölmenin genişliği ayırıcıyla belirlenir.
        for v in [photoView, iconView] as [NSView] {
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        photoView.image = nil
        if let url {
            quickLook.previewItem = url as NSURL
            quickLook.isHidden = false
            iconView.isHidden = true
        } else {
            quickLook.previewItem = nil
            quickLook.isHidden = true
            iconView.image = icon
            iconView.isHidden = false
        }
    }

    // MARK: Ayrıntılar

    private func basicRows(_ item: FileItem) -> [(String, String)] {
        var rows: [(String, String)] = []
        if !item.kind.isEmpty { rows.append((String(localized: "Tür", bundle: .live), item.kind)) }
        if let size = item.size {
            rows.append((String(localized: "Boyut", bundle: .live), ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        if let date = item.modified { rows.append((String(localized: "Değiştirilme", bundle: .live), Formatters.date.string(from: date))) }
        if let date = item.created { rows.append((String(localized: "Oluşturulma", bundle: .live), Formatters.date.string(from: date))) }
        return rows
    }

    nonisolated private static func folderRows(_ url: URL) -> [(String, String)] {
        guard let count = try? FileManager.default.contentsOfDirectory(atPath: url.path).filter({ !$0.hasPrefix(".") }).count else { return [] }
        return [(String(localized: "İçerik", bundle: .live), String(localized: "\(count) öğe", bundle: .live))]
    }

    /// Resimde boyutlar, çekim tarihi, kamera, konum; videoda/seste süre; PDF'te sayfa sayısı.
    nonisolated static func mediaRows(_ url: URL) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int {
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            let (w, h) = orientation >= 5 ? (height, width) : (width, height)   // dik çekilmiş fotoğraflar
            rows.append((String(localized: "Boyutlar", bundle: .live), "\(w) × \(h)"))
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            if let taken = exif?[kCGImagePropertyExifDateTimeOriginal] as? String, let date = exifDate(taken) {
                rows.append((String(localized: "Çekim tarihi", bundle: .live), DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)))
            }
            let camera = [tiff?[kCGImagePropertyTIFFMake] as? String, tiff?[kCGImagePropertyTIFFModel] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !camera.isEmpty {
                // "Apple iPhone 15" gibi: model markayı zaten içeriyorsa tekrarlanmaz.
                let text = camera.count == 2 && camera[1].lowercased().hasPrefix(camera[0].lowercased()) ? camera[1] : camera.joined(separator: " ")
                rows.append((String(localized: "Kamera", bundle: .live), text))
            }
            if let lens = (props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any])?[kCGImagePropertyExifAuxLensModel] as? String
                ?? exif?[kCGImagePropertyExifLensModel] as? String {
                rows.append((String(localized: "Objektif", bundle: .live), lens))
            }
            var settings: [String] = []
            if let f = exif?[kCGImagePropertyExifFNumber] as? Double { settings.append(String(format: "ƒ/%.1f", f)) }
            if let t = exif?[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                settings.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
            }
            if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { settings.append("ISO \(iso)") }
            if let focal = exif?[kCGImagePropertyExifFocalLength] as? Double { settings.append(String(format: "%.0f mm", focal)) }
            if !settings.isEmpty { rows.append((String(localized: "Çekim", bundle: .live), settings.joined(separator: "  "))) }
            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let ns = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
                let ew = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
                rows.append((String(localized: "Konum", bundle: .live), String(format: "%.5f, %.5f", ns, ew)))
            }
            return rows
        }
        if url.pathExtension.lowercased() == "pdf", let pdf = CGPDFDocument(url as CFURL) {
            rows.append((String(localized: "Sayfa", bundle: .live), "\(pdf.numberOfPages)"))
            return rows
        }
        // Video ve ses: Spotlight bilgisi (hızlı; dosyayı açmaz).
        if let md = MDItemCreateWithURL(nil, url as CFURL) {
            if let w = MDItemCopyAttribute(md, kMDItemPixelWidth) as? Int, let h = MDItemCopyAttribute(md, kMDItemPixelHeight) as? Int, w > 0 {
                rows.append((String(localized: "Boyutlar", bundle: .live), "\(w) × \(h)"))
            }
            if let seconds = MDItemCopyAttribute(md, kMDItemDurationSeconds) as? Double, seconds > 0 {
                let f = DateComponentsFormatter()
                f.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
                f.zeroFormattingBehavior = .pad
                rows.append((String(localized: "Süre", bundle: .live), f.string(from: seconds) ?? ""))
            }
            if let pages = MDItemCopyAttribute(md, kMDItemNumberOfPages) as? Int, pages > 0 {
                rows.append((String(localized: "Sayfa", bundle: .live), "\(pages)"))
            }
        }
        return rows
    }

    nonisolated private static func exifDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: text)
    }

    private func setRows(_ rows: [(String, String)]) {
        // removeRow hücre görünümlerini kaldırmaz; eski satırlar üst üste çizilmesin.
        grid.subviews.forEach { $0.removeFromSuperview() }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        for (name, value) in rows {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            let text = NSTextField(wrappingLabelWithString: value)
            text.font = .systemFont(ofSize: 11)
            text.isSelectable = true
            text.preferredMaxLayoutWidth = 200
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.init(700), for: .horizontal)
            grid.addRow(with: [label, text])
        }
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }
    }

    /// Geliştirme: gösterilenler.
    var debugSummary: String {
        let rows = (0..<grid.numberOfRows).compactMap { i -> String? in
            let cells = (0..<grid.numberOfColumns).compactMap { (grid.cell(atColumnIndex: $0, rowIndex: i).contentView as? NSTextField)?.stringValue }
            return cells.joined(separator: ": ")
        }
        let mode = !playerView.isHidden ? "oynatıcı" : !photoView.isHidden ? "resim" : quickLook.isHidden ? "simge" : "Hızlı Bakış"
        return "başlık: \(titleLabel.stringValue) | önizleme: \(mode) | " + rows.joined(separator: " · ")
    }
}
