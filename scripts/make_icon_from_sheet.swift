// Kullanım: swift scripts/make_icon_from_sheet.swift <tasarım.png> <x> <y> <genişlik> [<yükseklik>] <çıktı.png>
// Tasarım sayfasından (birden çok simge) bir simgeyi keser; arka planı yuvarlatılmış kare maskeyle atar ve
// macOS simge ızgarasına (1024 px tuval, 824 px kare, gölge) yerleştirir.
import AppKit

let args = CommandLine.arguments
guard args.count == 6 || args.count == 7, let x = Double(args[2]), let y = Double(args[3]), let side = Double(args[4]) else {
    fputs("kullanım: make_icon_from_sheet.swift tasarım.png x y genişlik [yükseklik] çıktı.png\n", stderr); exit(1)
}
let height = args.count == 7 ? Double(args[5]) ?? side : side
let output = args[args.count - 1]
let sheet = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: args[1])))!
let source = NSImage(size: NSSize(width: sheet.pixelsWide, height: sheet.pixelsHigh))
source.addRepresentation(sheet)

let size: CGFloat = 1024, inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// Simgenin kendi köşeleri (~%22,5); maske birkaç piksel içeride: arka planın kenar hâlesi kalmasın.
let radius = tile.width * 0.225
let mask = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: radius, yRadius: radius)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
mask.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
mask.addClip()
// Sayfa koordinatları sol üstten; çizim sol alttan.
let from = NSRect(x: x, y: Double(sheet.pixelsHigh) - y - height, width: side, height: height)
source.draw(in: tile, from: from, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
