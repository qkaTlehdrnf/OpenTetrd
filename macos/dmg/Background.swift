// Renders the drag-to-Applications background of the OpenTetrd disk image.
// Usage: Background <output.png> <scale>
import AppKit

let width: CGFloat = 640
let height: CGFloat = 400
// Icon centers used by scripts/package_macos_dmg.sh (Finder measures from the top left).
let appCenter = CGPoint(x: 170, y: height - 190)
let applicationsCenter = CGPoint(x: 470, y: height - 190)

func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerY: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let bounds = string.size()
    string.draw(at: CGPoint(x: (width - bounds.width) / 2, y: centerY - bounds.height / 2))
}

func drawBackground() {
    NSGradient(
        starting: NSColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
        ending: NSColor(srgbRed: 0.89, green: 0.92, blue: 0.97, alpha: 1)
    )?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    drawText("OpenTetrd 설치", size: 22, weight: .bold,
             color: NSColor(srgbRed: 0.12, green: 0.15, blue: 0.22, alpha: 1), centerY: 350)
    drawText("OpenTetrd 아이콘을 Applications 폴더로 드래그하세요", size: 14, weight: .medium,
             color: NSColor(srgbRed: 0.30, green: 0.35, blue: 0.45, alpha: 1), centerY: 62)

    // Dashed arrow from the app icon toward the Applications folder.
    let arrowColor = NSColor(srgbRed: 0.24, green: 0.47, blue: 0.93, alpha: 0.85)
    arrowColor.setStroke()
    arrowColor.setFill()
    let startX = appCenter.x + 90
    let tipX = applicationsCenter.x - 90
    let y = appCenter.y
    let shaft = NSBezierPath()
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.setLineDash([12, 10], count: 2, phase: 0)
    shaft.move(to: CGPoint(x: startX, y: y))
    shaft.line(to: CGPoint(x: tipX - 16, y: y))
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: tipX, y: y))
    head.line(to: CGPoint(x: tipX - 22, y: y + 15))
    head.line(to: CGPoint(x: tipX - 22, y: y - 15))
    head.close()
    head.fill()
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Double(arguments[2]), scale >= 1 else {
    FileHandle.standardError.write("usage: Background <output.png> <scale>\n".data(using: .utf8)!)
    exit(2)
}
let pixelsWide = Int(width * CGFloat(scale))
let pixelsHigh = Int(height * CGFloat(scale))
guard let context = CGContext(
    data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
drawBackground()
NSGraphicsContext.restoreGraphicsState()

guard let image = context.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: width, height: height)  // Records 144 dpi for the Retina variant.
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[1]))
