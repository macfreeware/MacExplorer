// Kullanım: swift scripts/make_icon.swift <çıktı.png>
// Mavi zemin üzerinde, ön yüzü iki panele bölünmüş sarı bir klasör çizen 1024x1024 uygulama simgesi üretir.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS simge ızgarası: kenarlarda boşluk bırakan yuvarlatılmış kare
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor.black.setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(colors: [NSColor(red: 0.16, green: 0.52, blue: 0.98, alpha: 1),
                    NSColor(red: 0.07, green: 0.29, blue: 0.75, alpha: 1)])!
    .draw(in: tile, angle: -90)

// Klasörün arka yüzü ve sekmesi
let back = NSBezierPath()
let left: CGFloat = 230, right: CGFloat = 794, bottom: CGFloat = 250, top: CGFloat = 700
back.move(to: NSPoint(x: left, y: bottom + 40))
back.line(to: NSPoint(x: left, y: top - 30))
back.curve(to: NSPoint(x: left + 30, y: top), controlPoint1: NSPoint(x: left, y: top - 12), controlPoint2: NSPoint(x: left + 12, y: top))
back.line(to: NSPoint(x: 420, y: top))
back.line(to: NSPoint(x: 470, y: top - 50))
back.line(to: NSPoint(x: right - 30, y: top - 50))
back.curve(to: NSPoint(x: right, y: top - 80), controlPoint1: NSPoint(x: right - 12, y: top - 50), controlPoint2: NSPoint(x: right, y: top - 62))
back.line(to: NSPoint(x: right, y: bottom + 40))
back.close()
NSColor(red: 0.95, green: 0.68, blue: 0.10, alpha: 1).setFill()
back.fill()

// Ön yüz
let front = CGRect(x: left, y: bottom, width: right - left, height: 380)
let frontPath = NSBezierPath(roundedRect: front, xRadius: 36, yRadius: 36)
NSGradient(colors: [NSColor(red: 1.00, green: 0.86, blue: 0.36, alpha: 1),
                    NSColor(red: 0.99, green: 0.76, blue: 0.20, alpha: 1)])!
    .draw(in: frontPath, angle: -90)

// İki panel: ön yüzde iki açık pencere
let paneWidth = (front.width - 3 * 44) / 2
for i in 0..<2 {
    let x = front.minX + 44 + CGFloat(i) * (paneWidth + 44)
    let pane = CGRect(x: x, y: front.minY + 50, width: paneWidth, height: front.height - 110)
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: pane, xRadius: 18, yRadius: 18).fill()
    NSColor(red: 0.16, green: 0.52, blue: 0.98, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: pane.minX, y: pane.maxY - 46, width: pane.width, height: 46), xRadius: 18, yRadius: 18).fill()
    NSRect(x: pane.minX, y: pane.maxY - 46, width: pane.width, height: 20).fill()
    NSColor(white: 0.78, alpha: 1).setFill()
    for row in 0..<3 {
        let y = pane.maxY - 90 - CGFloat(row) * 44
        NSBezierPath(roundedRect: CGRect(x: pane.minX + 26, y: y, width: pane.width - 52 - CGFloat(row) * 30, height: 18), xRadius: 9, yRadius: 9).fill()
    }
}
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
