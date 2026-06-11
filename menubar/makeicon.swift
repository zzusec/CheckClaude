import Cocoa

// 生成 App 图标 PNG: 蓝色渐变圆角底 + 白色地球符号
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
path.addClip()
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.26, green: 0.60, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.05, green: 0.30, blue: 0.78, alpha: 1)
])!
grad.draw(in: rect, angle: -90)

let conf = NSImage.SymbolConfiguration(pointSize: size * 0.58, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "globe.asia.australia.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(conf) {
    let sw = sym.size
    sym.draw(in: NSRect(x: (size - sw.width) / 2, y: (size - sw.height) / 2,
                        width: sw.width, height: sw.height))
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("渲染失败\n".data(using: .utf8)!); exit(1)
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
