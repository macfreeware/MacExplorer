// Kullanım: swift scripts/make_icon_from_checker.swift <girdi.png> <çıktı.png>
// "Saydam" görünmesi için arkasına dama deseni çizilmiş (gerçekte saydam olmayan) bir simgeyi gerçek saydam
// simgeye çevirir: kenarlardan başlayıp yalnızca nötr gri / açık pikseller üzerinden yayılarak arka planı bulur,
// saydamlaştırır, kenarı yumuşatır; macOS simge ızgarasında yuvarlatılmış kare zeminin ortasına gölgeyle yerleştirir.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { fputs("kullanım: make_icon_from_checker.swift girdi.png çıktı.png\n", stderr); exit(1) }
let input = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: args[1])))!
let w = input.pixelsWide, h = input.pixelsHigh

// RGBA8 kopya
let rgba = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rgba)
input.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
let px = rgba.bitmapData!

/// Dama deseni ve yumuşak gölge: renksiz (nötr) ve açık.
func isBackground(_ i: Int) -> Bool {
    let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
    return min(r, g, b) > 120 && max(r, g, b) - min(r, g, b) <= 8
}

/// Kenardaki renksiz (gölge ile desenin karışımı) pikseller: soyulurlar.
func isGrayFringe(_ i: Int) -> Bool {
    let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
    return max(r, g, b) - min(r, g, b) <= 18 && max(r, g, b) > 90
}

// Kenarlardan yayılarak arka planı bul (simgenin içindeki açık griler korunur).
var background = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
while let i = stack.popLast() {
    guard !background[i], isBackground(i) else { continue }
    background[i] = true
    let x = i % w, y = i / w
    if x > 0 { stack.append(i - 1) }
    if x < w - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - w) }
    if y < h - 1 { stack.append(i + w) }
}

// Kenarda kalan renksiz saçağı birkaç adımda soy (simgenin renkli kenarına gelince durur).
for _ in 0..<6 {
    var peel: [Int] = []
    for y in 1..<(h - 1) { for x in 1..<(w - 1) {
        let i = y * w + x
        guard !background[i], isGrayFringe(i) else { continue }
        if background[i - 1] || background[i + 1] || background[i - w] || background[i + w] { peel.append(i) }
    } }
    if peel.isEmpty { break }
    peel.forEach { background[$0] = true }
}

// Saydamlık: arka plan 0, simge 255; sınırda 3x3 ortalama ile yumuşak kenar.
var alpha = background.map { $0 ? 0.0 : 1.0 }
var smooth = alpha
for y in 1..<(h - 1) { for x in 1..<(w - 1) {
    let i = y * w + x
    var sum = 0.0
    for dy in -1...1 { for dx in -1...1 { sum += alpha[i + dy * w + dx] } }
    if sum > 0 && sum < 9 { smooth[i] = alpha[i] == 0 ? 0 : sum / 9 }
} }
alpha = smooth
var minX = w, minY = h, maxX = 0, maxY = 0
for i in 0..<(w * h) {
    let a = alpha[i]
    px[i * 4 + 3] = UInt8(max(0, min(255, a * 255)))
    // Önceden çarpılmış renk: saydamlığa göre koyulaştır
    for c in 0..<3 { px[i * 4 + c] = UInt8(Double(px[i * 4 + c]) * a) }
    if a > 0.5 { let x = i % w, y = i / w; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
}
let object = NSImage(size: NSSize(width: w, height: h))
object.addRepresentation(rgba)

// macOS simge ızgarası: 824 px'lik yuvarlatılmış kare zemin (macOS, kare olmayan simgeleri kendi gri
// plakasına koyar; kendi zeminimiz olunca o plaka görünmez), nesne zeminin ortasında ve gölgeli.
let size: CGFloat = 1024, area: CGFloat = 700
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let objectW = CGFloat(maxX - minX + 1), objectH = CGFloat(maxY - minY + 1)
let scale = min(area / objectW, area / objectH)
let target = NSRect(x: (size - objectW * scale) / 2, y: (size - objectH * scale) / 2 + 10, width: objectW * scale, height: objectH * scale)
// Kaynak dikdörtgeni (çizim koordinatları sol alttan)
let from = NSRect(x: CGFloat(minX), y: CGFloat(h - 1 - maxY), width: objectW, height: objectH)

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current?.imageInterpolation = .high
let plate = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let plateShadow = NSShadow()
plateShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
plateShadow.shadowBlurRadius = 24
plateShadow.shadowOffset = NSSize(width: 0, height: -12)
plateShadow.set()
NSColor.white.setFill()
plate.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
plate.addClip()
NSGradient(colors: [NSColor(red: 0.97, green: 0.985, blue: 1.0, alpha: 1), NSColor(red: 0.82, green: 0.89, blue: 0.96, alpha: 1)])!
    .draw(in: tile, angle: -90)
NSGraphicsContext.restoreGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(red: 0.05, green: 0.15, blue: 0.35, alpha: 0.35)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.set()
object.draw(in: target, from: from, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("nesne", minX, minY, maxX, maxY, "ölçek", String(format: "%.2f", scale))
