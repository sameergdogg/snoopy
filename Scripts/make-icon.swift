import AppKit
import CoreGraphics

func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((h>>16)&0xff)/255, green: CGFloat((h>>8)&0xff)/255, blue: CGFloat(h&0xff)/255, alpha: a)
}

func drawIcon(size S: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.interpolationQuality = .high
    let u = S / 1024.0   // unit scale

    // ---- Squircle body (macOS icon grid: ~824 body in 1024, small drop) ----
    let body: CGFloat = 824 * u
    let originX = (S - body) / 2
    let originY = (S - body) / 2 - 8 * u   // nudge down a touch for optical balance
    let rect = CGRect(x: originX, y: originY, width: body, height: body)
    let radius = 185 * u
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // soft ambient shadow under the body
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u, color: hex(0x0B1020, 0.35))
    ctx.setFillColor(hex(0x000000, 1)); ctx.fillPath()
    ctx.restoreGState()

    // gradient fill (indigo -> violet, top to bottom)
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
        colors: [hex(0x5B5BF0), hex(0x7C3AED), hex(0x6D28D9)] as CFArray,
        locations: [0.0, 0.6, 1.0])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY), options: [])
    // top sheen
    let sheen = CGGradient(colorsSpace: cs,
        colors: [hex(0xFFFFFF, 0.20), hex(0xFFFFFF, 0.0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.maxY - body*0.45), options: [])
    ctx.restoreGState()

    // subtle inner top-edge highlight
    ctx.saveGState()
    ctx.addPath(squircle); ctx.setLineWidth(3 * u)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.addPath(squircle); ctx.setStrokeColor(hex(0xFFFFFF, 0.25)); ctx.setLineWidth(3*u); ctx.strokePath()
    ctx.restoreGState()

    // ---- Magnifying glass ----
    let cx = S/2 - 58*u, cy = S/2 + 60*u   // lens center
    let lensR = 210 * u
    let ring = 58 * u
    // handle first (behind ring end), from lens edge toward lower-right
    let ang = CGFloat.pi / 4 * 5   // 225° direction -> lower-right when y-up flipped
    let dir = CGPoint(x: cos(-CGFloat.pi/4), y: sin(-CGFloat.pi/4)) // toward lower-right (y-up)
    let hStart = CGPoint(x: cx + dir.x*(lensR - 4*u), y: cy + dir.y*(lensR - 4*u))
    let hEnd = CGPoint(x: cx + dir.x*(lensR + 150*u), y: cy + dir.y*(lensR + 150*u))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6*u), blur: 16*u, color: hex(0x2A0E5E, 0.45))
    ctx.setLineCap(.round)
    ctx.setStrokeColor(hex(0xFFFFFF)); ctx.setLineWidth(ring)
    ctx.move(to: hStart); ctx.addLine(to: hEnd); ctx.strokePath()
    // lens ring
    ctx.setLineWidth(ring)
    ctx.addEllipse(in: CGRect(x: cx-lensR, y: cy-lensR, width: lensR*2, height: lensR*2))
    ctx.strokePath()
    ctx.restoreGState()

    // glass tint inside lens
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: cx-(lensR-ring/2), y: cy-(lensR-ring/2),
                              width: (lensR-ring/2)*2, height: (lensR-ring/2)*2))
    ctx.clip()
    let glass = CGGradient(colorsSpace: cs,
        colors: [hex(0xFFFFFF, 0.22), hex(0xFFFFFF, 0.06)] as CFArray, locations: [0,1])!
    ctx.drawLinearGradient(glass, start: CGPoint(x: cx-lensR, y: cy+lensR),
                           end: CGPoint(x: cx+lensR, y: cy-lensR), options: [])
    ctx.restoreGState()

    // ---- Paw print inside the lens (the "Snoopy" nod) ----
    let pawColor = hex(0xFFFFFF, 0.95)
    ctx.setFillColor(pawColor)
    // main pad
    let padW = 128*u, padH = 100*u
    let padRect = CGRect(x: cx - padW/2, y: cy - 78*u, width: padW, height: padH)
    ctx.addPath(CGPath(ellipseIn: padRect, transform: nil)); ctx.fillPath()
    // toes (kept inside the inner lens radius)
    let toeR = 38*u
    let toes: [(CGFloat, CGFloat, CGFloat)] = [
        (-94, 44, 1.0), (-33, 82, 1.06), (33, 82, 1.06), (94, 44, 1.0)
    ]
    for (dx, dy, s) in toes {
        let r = toeR * s
        ctx.addEllipse(in: CGRect(x: cx + dx*u - r, y: cy + dy*u - r, width: r*2, height: r*2))
    }
    ctx.fillPath()

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// (filename, pixel size)
let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in variants { writePNG(drawIcon(size: px), to: "\(outDir)/\(name)") }
writePNG(drawIcon(size: 1024), to: "\(outDir)/master_1024.png")
print("wrote \(variants.count) icons + master to \(outDir)")
