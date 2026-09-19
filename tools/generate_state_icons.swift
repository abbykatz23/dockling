// One-off Phase 0 asset generator: turns the reference duck drawing into
// placeholder per-state Dock tile PNGs (white background keyed to alpha,
// plus a colored ring so each state bucket is visually distinct at a glance).
// Not part of the shipped app — real art comes from adapted sprite packs in Phase 2.
//
// Usage: swift tools/generate_state_icons.swift dockling_transparent.jpg DocklingAgent/Sources/DocklingAgent/Resources

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Usage: swift generate_state_icons.swift <source.jpg> <output-dir>")
    exit(1)
}
let sourcePath = args[1]
let outputDir = args[2]

guard let sourceImage = NSImage(contentsOfFile: sourcePath),
      let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("Failed to load source image at \(sourcePath)")
    exit(1)
}

let canvasSize = 256
let duckMargin = 24 // px of padding around the duck within the canvas

func keyedDuckImage() -> CGImage {
    let width = sourceCGImage.width
    let height = sourceCGImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: width * 4, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create bitmap context")
    }
    ctx.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Soft key on "whiteness" (min channel) rather than a hard per-channel cutoff,
    // since JPEG compression leaves the background a noisy off-white, not flat 255.
    let opaqueBelow: Int = 195   // min(r,g,b) at/under this stays fully opaque
    let transparentAbove: Int = 240 // min(r,g,b) at/over this goes fully transparent
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        let minChannel = min(r, g, b)
        if minChannel >= transparentAbove {
            pixels[i + 3] = 0
        } else if minChannel > opaqueBelow {
            let t = Double(minChannel - opaqueBelow) / Double(transparentAbove - opaqueBelow)
            let newAlpha = Double(pixels[i + 3]) * (1.0 - t)
            pixels[i + 3] = UInt8(max(0, min(255, newAlpha)))
        }
    }
    guard let outCtx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let result = outCtx.makeImage() else {
        fatalError("could not rebuild keyed image")
    }
    return result
}

let duckKeyed = keyedDuckImage()

struct StateSpec {
    let name: String
    let ringColor: NSColor? // nil = no ring (idle)
}

let states: [StateSpec] = [
    StateSpec(name: "idle", ringColor: nil),
    StateSpec(name: "bash", ringColor: NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.18, alpha: 1)),
    StateSpec(name: "edit", ringColor: NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.95, alpha: 1)),
    StateSpec(name: "search", ringColor: NSColor(calibratedRed: 0.58, green: 0.35, blue: 0.92, alpha: 1)),
    StateSpec(name: "other", ringColor: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1)),
    StateSpec(name: "awaiting-input", ringColor: NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.10, alpha: 1)),
    StateSpec(name: "error", ringColor: NSColor(calibratedRed: 0.88, green: 0.20, blue: 0.20, alpha: 1)),
]

let fileManager = FileManager.default
try? fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for state in states {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvasSize, pixelsHigh: canvasSize,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let canvasRect = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
    ctx.cgContext.clear(canvasRect)

    if let ringColor = state.ringColor {
        let ringInset: CGFloat = 8
        let ringRect = canvasRect.insetBy(dx: ringInset, dy: ringInset)
        let ringPath = NSBezierPath(ovalIn: ringRect)
        ringColor.withAlphaComponent(0.16).setFill()
        ringPath.fill()
        ringPath.lineWidth = 6
        ringColor.setStroke()
        ringPath.stroke()
    }

    let duckAspect = CGFloat(duckKeyed.width) / CGFloat(duckKeyed.height)
    let available = CGFloat(canvasSize - duckMargin * 2)
    var drawWidth = available
    var drawHeight = available / duckAspect
    if drawHeight > available {
        drawHeight = available
        drawWidth = available * duckAspect
    }
    let drawRect = NSRect(x: (CGFloat(canvasSize) - drawWidth) / 2,
                           y: (CGFloat(canvasSize) - drawHeight) / 2,
                           width: drawWidth, height: drawHeight)
    ctx.cgContext.draw(duckKeyed, in: drawRect)

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to encode PNG for state \(state.name)")
    }
    let outPath = (outputDir as NSString).appendingPathComponent("\(state.name).png")
    try! pngData.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath)")
}
