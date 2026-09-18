// Puts the window renders from `TypeReviewApp --screenshots` on the App Store's
// canvas, and checks what it made.
//
//   compose-screenshots <raw folder> <output folder>
//
// AppKit draws a window's contents, frame and toolbar into an image; the
// rounded corners and the shadow belong to the window server, so they are
// added here. Both are measured from the 1.0 screenshots, which the window
// server drew: a corner of about 24 points, and a soft shadow that reaches
// further below a window than above it.
//
// Every image is then read back and checked: exactly 2880 × 1800, which is one
// of the four sizes App Store Connect accepts for a Mac, and no alpha channel,
// which it refuses. Nothing here opens a window, so it runs anywhere.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Placed: Decodable {
    let file: String
    let x, y, width, height, scale: Double
    let titled: Bool
}

struct Shot: Decodable {
    let name: String
    let dark: Bool
    let windows: [Placed]
}

let canvas = CGSize(width: 2880, height: 1800)
/// Clear space kept around the windows, in pixels, so the shadow is not cut.
let margin: CGFloat = 150
/// The window server's corner, in points.
let cornerRadius: CGFloat = 24
/// The shadow, in points: how far it drops, how soft it is, how dark.
let shadowDrop: CGFloat = 12
let shadowBlur: CGFloat = 36
let shadowAlpha: CGFloat = 0.32

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("compose: \(message)\n".utf8))
    exit(1)
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("cannot read \(url.path)") }
    return image
}

func compose(_ shot: Shot, from raw: URL) -> CGImage {
    guard let first = shot.windows.first else { fail("\(shot.name) has no windows") }
    let frames = shot.windows.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    let union = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
    // Pixels per point on the canvas: the render's own scale, reduced only if
    // the windows would not otherwise fit inside the margin.
    let fit = min(
        1, (canvas.width - 2 * margin) / (union.width * first.scale),
        (canvas.height - 2 * margin) / (union.height * first.scale))
    let scale = CGFloat(first.scale) * fit
    if fit < 1 { print("compose: \(shot.name) scaled to \(Int(fit * 100))% to fit") }
    // Centred, then lifted by half the shadow's drop, so the window and its
    // shadow sit in the middle together.
    let origin = CGPoint(
        x: ((canvas.width - union.width * scale) / 2).rounded(),
        y: ((canvas.height - union.height * scale) / 2 + shadowDrop * scale / 2).rounded())

    guard
        let context = CGContext(
            data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fail("cannot make a canvas") }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: canvas))
    context.interpolationQuality = .high

    for (placed, frame) in zip(shot.windows, frames) {
        let image = loadImage(raw.appendingPathComponent(placed.file))
        let expected = (Int((frame.width * placed.scale).rounded()), Int((frame.height * placed.scale).rounded()))
        guard (image.width, image.height) == expected else {
            fail("\(placed.file) is \(image.width)x\(image.height), its frame says \(expected.0)x\(expected.1)")
        }
        let rect = CGRect(
            x: origin.x + (frame.minX - union.minX) * scale, y: origin.y + (frame.minY - union.minY) * scale,
            width: frame.width * scale, height: frame.height * scale)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -shadowDrop * scale), blur: shadowBlur * scale,
            color: CGColor(gray: 0, alpha: shadowAlpha))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if placed.titled {
            let radius = cornerRadius * scale
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
        }
        context.draw(image, in: rect)
        context.endTransparencyLayer()
        context.restoreGState()
    }
    guard let image = context.makeImage() else { fail("cannot finish \(shot.name)") }
    return image
}

func write(_ image: CGImage, to url: URL) {
    guard
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot finish \(url.path)") }
}

/// Reads the file's own header rather than trusting the encoder, or ImageIO's
/// reading of it: the IHDR chunk's size and colour type are what App Store
/// Connect reads. Colour type 2 is RGB; 6 would be RGB with alpha.
func check(_ url: URL) {
    guard let data = FileManager.default.contents(atPath: url.path), data.count > 26,
        data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        data[12..<16] == Data("IHDR".utf8)
    else { fail("\(url.lastPathComponent) is not a PNG") }
    let number = { (at: Int) in data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
    let (width, height, colour) = (number(16), number(20), data[25])
    guard width == Int(canvas.width), height == Int(canvas.height) else {
        fail("\(url.lastPathComponent) is \(width)x\(height), not 2880x1800")
    }
    guard colour == 2 else {
        fail("\(url.lastPathComponent) has PNG colour type \(colour), not 2 (RGB, no alpha)")
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: compose-screenshots <raw folder> <output folder>") }
let raw = URL(fileURLWithPath: arguments[1], isDirectory: true)
let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
let names = (try? FileManager.default.contentsOfDirectory(atPath: raw.path))?
    .filter { $0.hasSuffix(".json") }.sorted() ?? []
guard !names.isEmpty else { fail("no scenes in \(raw.path)") }
for name in names {
    guard let data = FileManager.default.contents(atPath: raw.appendingPathComponent(name).path),
        let shot = try? JSONDecoder().decode(Shot.self, from: data)
    else { fail("cannot read \(name)") }
    let url = out.appendingPathComponent("\(shot.name).png")
    write(compose(shot, from: raw), to: url)
    check(url)
    print("composed \(url.lastPathComponent)")
}
print("COMPOSE OK: \(names.count) screenshots, 2880x1800, opaque")
