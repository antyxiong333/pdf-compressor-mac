import AppKit
import CoreGraphics

let S = 1024.0
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// --- rounded-rect background with vertical gradient (macOS "squircle"-ish) ---
let r = S * 0.223
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                    cornerWidth: r, cornerHeight: r, transform: nil)
ctx.addPath(bgPath); ctx.clip()

let colors = [
    CGColor(red: 0.98, green: 0.36, blue: 0.36, alpha: 1),  // warm red top
    CGColor(red: 0.84, green: 0.13, blue: 0.24, alpha: 1)   // deep red bottom
] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

// --- white PDF page ---
func rrect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ rad: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: rad, cornerHeight: rad, transform: nil)
}
let pw = S * 0.44, ph = S * 0.56
let px = (S - pw) / 2, py = (S - ph) / 2 + S * 0.03

// soft shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.05,
              color: CGColor(gray: 0, alpha: 0.28))
ctx.addPath(rrect(px, py, pw, ph, S*0.03)); ctx.setFillColor(.white); ctx.fillPath()
ctx.restoreGState()

// folded corner
let fold = S * 0.11
ctx.setFillColor(CGColor(gray: 0.90, alpha: 1))
ctx.move(to: CGPoint(x: px + pw - fold, y: py + ph))
ctx.addLine(to: CGPoint(x: px + pw, y: py + ph - fold))
ctx.addLine(to: CGPoint(x: px + pw - fold, y: py + ph - fold))
ctx.closePath(); ctx.fillPath()

// "PDF" label
let label = NSAttributedString(string: "PDF", attributes: [
    .font: NSFont.systemFont(ofSize: S*0.11, weight: .heavy),
    .foregroundColor: NSColor(red: 0.84, green: 0.13, blue: 0.24, alpha: 1)
])
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let lsz = label.size()
label.draw(at: NSPoint(x: px + (pw - lsz.width)/2, y: py + ph*0.60))

// --- compression arrows (two chevrons pointing inward = "compress") ---
ctx.setStrokeColor(CGColor(red: 0.84, green: 0.13, blue: 0.24, alpha: 1))
ctx.setLineWidth(S*0.028); ctx.setLineCap(.round); ctx.setLineJoin(.round)
let cx = px + pw/2, midY = py + ph*0.40
let aw = pw*0.34, gap = S*0.045
// top chevron pointing down
ctx.move(to: CGPoint(x: cx - aw/2, y: midY + gap + aw*0.5))
ctx.addLine(to: CGPoint(x: cx, y: midY + gap))
ctx.addLine(to: CGPoint(x: cx + aw/2, y: midY + gap + aw*0.5))
ctx.strokePath()
// bottom chevron pointing up
ctx.move(to: CGPoint(x: cx - aw/2, y: midY - gap - aw*0.5))
ctx.addLine(to: CGPoint(x: cx, y: midY - gap))
ctx.addLine(to: CGPoint(x: cx + aw/2, y: midY - gap - aw*0.5))
ctx.strokePath()
NSGraphicsContext.restoreGraphicsState()

// --- write PNG ---
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("icon written")
