import AppKit

// K-Dex app icon: macOS squircle, deep navy→blue gradient, white hexagon
// (the Kubernetes ecosystem shape, sans trademarked wheel) framing a heavy K.
// Regenerate with:
//   swift scripts/generate-icon.swift <output-1024.png>

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: 824pt rounded rect centered on a 1024 canvas.
let inset = (size - 824) / 2
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: 824, height: 824),
    xRadius: 186, yRadius: 186
)
squircle.addClip()

let gradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.23, green: 0.45, blue: 0.96, alpha: 1),  // bright blue
        NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.34, alpha: 1),  // deep navy
    ]
)!
gradient.draw(in: squircle, angle: -65)

// Subtle top sheen.
let sheen = NSGradient(
    colors: [NSColor(white: 1, alpha: 0.14), NSColor(white: 1, alpha: 0)]
)!
sheen.draw(in: NSRect(x: inset, y: size / 2, width: 824, height: 412), angle: -90)

// Hexagon (pointy-top), centered.
let center = NSPoint(x: size / 2, y: size / 2)
let radius: CGFloat = 292
let hexagon = NSBezierPath()
for i in 0..<6 {
    let angle = CGFloat(i) * .pi / 3 + .pi / 6
    let point = NSPoint(
        x: center.x + radius * cos(angle),
        y: center.y + radius * sin(angle)
    )
    if i == 0 { hexagon.move(to: point) } else { hexagon.line(to: point) }
}
hexagon.close()
hexagon.lineWidth = 34
hexagon.lineJoinStyle = .round
NSColor(white: 1, alpha: 0.92).setStroke()
hexagon.stroke()

// The K.
let font = NSFont.systemFont(ofSize: 330, weight: .heavy)
let text = NSAttributedString(string: "K", attributes: [
    .font: font,
    .foregroundColor: NSColor.white,
])
let textSize = text.size()
text.draw(at: NSPoint(
    x: center.x - textSize.width / 2,
    y: center.y - textSize.height / 2 + 4
))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
