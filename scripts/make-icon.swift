// Draws the app icon: three Miller columns stitched together by one accent-coloured seam.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1) // origin top-left

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
}
func gradient(_ colors: [CGColor]) -> CGGradient { CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)! }
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// Body: the standard 824pt icon tile centred on a 1024 canvas, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = rounded(body, 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x11111b)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x2a2b3d), rgb(0x14141f)]), start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// A faint glow behind the seam, top right.
ctx.drawRadialGradient(gradient([rgb(0xcba6f7, 0.22), rgb(0xcba6f7, 0)]), startCenter: CGPoint(x: 760, y: 260), startRadius: 0,
                       endCenter: CGPoint(x: 760, y: 260), endRadius: 420, options: [])

// Three columns, each a little brighter than the last.
let colW: CGFloat = 196, gap: CGFloat = 44
let x0 = 512 - (3 * colW + 2 * gap) / 2
let top: CGFloat = 196, colH: CGFloat = 632
let selectedRow = [1, 2, 4]            // the path walks down and to the right
let rowH: CGFloat = 54, rowGap: CGFloat = 30, firstRow = top + 54
let widths: [[CGFloat]] = [[0.78, 0.6, 0.7, 0.5, 0.66, 0.54], [0.64, 0.74, 0.5, 0.7, 0.58, 0.46], [0.7, 0.52, 0.76, 0.6, 0.48, 0.68]]
let accent = gradient([rgb(0x89b4fa), rgb(0xcba6f7)])

func rowRect(_ col: Int, _ row: Int) -> CGRect {
    CGRect(x: x0 + CGFloat(col) * (colW + gap) + 24, y: firstRow + CGFloat(row) * (rowH + rowGap), width: colW - 48, height: rowH)
}

for c in 0..<3 {
    let r = CGRect(x: x0 + CGFloat(c) * (colW + gap), y: top, width: colW, height: colH)
    ctx.addPath(rounded(r, 44)); ctx.setFillColor(rgb(0xffffff, 0.06 + 0.025 * CGFloat(c))); ctx.fillPath()
    ctx.addPath(rounded(r.insetBy(dx: 0.5, dy: 0.5), 44)); ctx.setStrokeColor(rgb(0xffffff, 0.07)); ctx.setLineWidth(1.5); ctx.strokePath()
    for row in 0..<6 where row != selectedRow[c] {
        var b = rowRect(c, row)
        b.size.width *= widths[c][row]
        ctx.addPath(rounded(b, rowH / 2)); ctx.setFillColor(rgb(0xcdd6f4, 0.17)); ctx.fillPath()
    }
}

// The seam: one line through the selected row of every column, stepping in the gaps.
let seamPath = CGMutablePath()
var points: [CGPoint] = []
for c in 0..<3 { let r = rowRect(c, selectedRow[c]); points.append(CGPoint(x: r.minX - 24, y: r.midY)); points.append(CGPoint(x: r.maxX + 24, y: r.midY)) }
seamPath.move(to: points[0])
seamPath.addLine(to: points[1])
for c in 1..<3 {
    let from = points[2 * c - 1], to = points[2 * c]
    let mid = (from.x + to.x) / 2
    seamPath.addCurve(to: to, control1: CGPoint(x: mid, y: from.y), control2: CGPoint(x: mid, y: to.y))
    seamPath.addLine(to: points[2 * c + 1])
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 26, color: rgb(0xb4befe, 0.75))
ctx.addPath(seamPath); ctx.setStrokeColor(rgb(0xb4befe)); ctx.setLineWidth(10); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
ctx.restoreGState()

// Selected rows sit on top of the seam, filled with the accent.
for c in 0..<3 {
    let r = rowRect(c, selectedRow[c])
    ctx.saveGState()
    ctx.addPath(rounded(r, rowH / 2)); ctx.clip()
    ctx.drawLinearGradient(accent, start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
    ctx.restoreGState()
}

// Top highlight along the tile's edge.
ctx.addPath(rounded(body.insetBy(dx: 1, dy: 1), 185)); ctx.setStrokeColor(rgb(0xffffff, 0.14)); ctx.setLineWidth(2); ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let dir = NSTemporaryDirectory() + "seam.iconset"
try? FileManager.default.removeItem(atPath: dir)
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
func write(_ px: Int, _ name: String) throws {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
for s in [16, 32, 128, 256, 512] { try write(s, "icon_\(s)x\(s)"); try write(s * 2, "icon_\(s)x\(s)@2x") }
try write(1024, "preview")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir, "-o", out]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out)" : "iconutil failed")
