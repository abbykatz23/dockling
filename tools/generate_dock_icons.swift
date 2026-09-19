// Builds the live per-state Dock tile PNGs from real-alpha source art
// (dockling.png / thinking_dockling.png — no chroma-keying needed, unlike the
// old crayon-JPEG pipeline these replace). Normalizes each source onto the
// same canvas size with the same fit-to-bbox scaling, so swapping states
// doesn't visually jump per DOCKLING_SPEC.md's Dock-tile art requirements.
//
// Usage: swift tools/generate_dock_icons.swift <dir-with-dockling.png-and-thinking_dockling.png> <output-dir>

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Usage: swift generate_dock_icons.swift <source-dir> <output-dir>")
    exit(1)
}
let sourceDir = args[1]
let outputDir = args[2]
let canvasSize = 256
let margin = 20 // px of padding around the duck within the canvas

/// Loads a PNG and crops it tightly to its alpha bounding box, via a manual
/// row-by-row byte copy rather than CGImage.cropping(to:) — that API's
/// coordinate origin doesn't match a top-down raw pixel buffer, which
/// previously produced a mis-cropped (bottom-clipped) image here.
func loadCroppedImage(_ path: String) -> CGImage {
    guard let source = NSImage(contentsOfFile: path),
          let full = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("could not load \(path)")
    }
    let width = full.width, height = full.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: width * 4, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create bitmap context")
    }
    ctx.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width, maxX = 0, minY = height, maxY = 0
    for y in 0..<height {
        for x in 0..<width {
            if pixels[(y * width + x) * 4 + 3] > 10 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard minX <= maxX, minY <= maxY else { fatalError("\(path) is fully transparent") }

    let cropWidth = maxX - minX
    let cropHeight = maxY - minY
    var cropped = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
    for row in 0..<cropHeight {
        let srcRowStart = ((minY + row) * width + minX) * 4
        let dstRowStart = row * cropWidth * 4
        cropped.withUnsafeMutableBytes { dst in
            pixels.withUnsafeBytes { src in
                dst.baseAddress!.advanced(by: dstRowStart)
                    .copyMemory(from: src.baseAddress!.advanced(by: srcRowStart), byteCount: cropWidth * 4)
            }
        }
    }
    guard let croppedCtx = CGContext(data: &cropped, width: cropWidth, height: cropHeight, bitsPerComponent: 8,
                                      bytesPerRow: cropWidth * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let result = croppedCtx.makeImage() else {
        fatalError("could not build cropped image for \(path)")
    }
    return result
}

func renderOnCanvas(_ cropped: CGImage, outPath: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvasSize, pixelsHigh: canvasSize,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.clear(NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

    let available = CGFloat(canvasSize - margin * 2)
    let aspect = CGFloat(cropped.width) / CGFloat(cropped.height)
    var drawWidth = available
    var drawHeight = available / aspect
    if drawHeight > available {
        drawHeight = available
        drawWidth = available * aspect
    }
    let drawRect = NSRect(x: (CGFloat(canvasSize) - drawWidth) / 2,
                           y: (CGFloat(canvasSize) - drawHeight) / 2,
                           width: drawWidth, height: drawHeight)
    ctx.cgContext.draw(cropped, in: drawRect)
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to encode PNG for \(outPath)")
    }
    try! pngData.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath)")
}

let fileManager = FileManager.default
try? fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let idleImage = loadCroppedImage((sourceDir as NSString).appendingPathComponent("dockling.png"))
let thinkingImage = loadCroppedImage((sourceDir as NSString).appendingPathComponent("thinking_dockling.png"))
let eurekaImage = loadCroppedImage((sourceDir as NSString).appendingPathComponent("eureka_dockling.png"))

renderOnCanvas(idleImage, outPath: (outputDir as NSString).appendingPathComponent("idle.png"))
renderOnCanvas(eurekaImage, outPath: (outputDir as NSString).appendingPathComponent("eureka.png"))

// Every "actively doing something" bucket shares the same thinking pose for
// now — per-bucket art is a later refinement once more poses exist.
for state in ["bash", "edit", "search", "other", "awaiting-input", "error"] {
    renderOnCanvas(thinkingImage, outPath: (outputDir as NSString).appendingPathComponent("\(state).png"))
}
