// Génère Resources/AppIcon.icns : fond noir, un M blanc tracé d'un seul trait comme une onde de voix
// (même tracé que `LogoShape` dans l'app).
// (Fond noir plutôt que blanc : avec les icônes macOS en mode sombre, le système assombrit un fond
// blanc mais laisse le M noir, qui devient illisible ; un fond noir reste tel quel.)
// Usage : swift tools/make-icon.swift <dossier de sortie>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)

    // Carré arrondi façon macOS (marge de 10 %), noir.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSColor(white: 0.04, alpha: 1).setFill()
    shape.fill()

    // Le M : entrée plate, deux crêtes, sortie plate, dans un cadre 5:2 centré.
    let w = rect.width * 0.75, h = w * 0.4
    let origin = NSPoint(x: rect.midX - w / 2, y: rect.midY - h / 2)
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * w, y: origin.y + y * h) }
    let path = NSBezierPath()
    path.move(to: p(0, 0))
    path.curve(to: p(0.283, 1), controlPoint1: p(0.15, 0), controlPoint2: p(0.167, 1))
    path.curve(to: p(0.5, 0.25), controlPoint1: p(0.4, 1), controlPoint2: p(0.417, 0.25))
    path.curve(to: p(0.717, 1), controlPoint1: p(0.583, 0.25), controlPoint2: p(0.6, 1))
    path.curve(to: p(1, 0), controlPoint1: p(0.833, 1), controlPoint2: p(0.85, 0))
    path.lineWidth = h * 0.25
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor(white: 0.98, alpha: 1).setStroke()
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Icône générée : \(outDir.appendingPathComponent("AppIcon.icns").path)")
