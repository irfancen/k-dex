import AppKit

// K-Dex app icon: macOS squircle, Kubernetes-blue gradient, a heavy "K"
// beside three "index rows" — the K(ubernetes) (in)dex. Regenerate with:
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
        NSColor(calibratedRed: 0.26, green: 0.47, blue: 0.94, alpha: 1),  // #4278F0
        NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.45, alpha: 1),  // #1A2E73
    ]
)!
gradient.draw(in: squircle, angle: -60)

// Subtle top sheen.
let sheen = NSGradient(
    colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0)]
)!
sheen.draw(in: NSRect(x: inset, y: size / 2, width: 824, height: 412), angle: -90)

// The "K".
let font = NSFont.systemFont(ofSize: 520, weight: .heavy)
let text = NSAttributedString(string: "K", attributes: [
    .font: font,
    .foregroundColor: NSColor.white,
])
let textSize = text.size()
text.draw(at: NSPoint(x: 250, y: (size - textSize.height) / 2 + 10))

// Three index rows (the "dex").
let rowHeights: [(y: CGFloat, width: CGFloat, alpha: CGFloat)] = [
    (620, 210, 0.95),
    (482, 150, 0.65),
    (344, 210, 0.40),
]
for row in rowHeights {
    let rect = NSRect(x: 560, y: row.y, width: row.width, height: 62)
    let bar = NSBezierPath(roundedRect: rect, xRadius: 31, yRadius: 31)
    NSColor(white: 1, alpha: row.alpha).setFill()
    bar.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
