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

    // Flood-fill the background from the image border rather than a global
    // color threshold, so only paper actually connected to the edge gets keyed
    // out — light crayon highlights *inside* the duck's silhouette survive,
    // instead of being punched into holes by a naive whiteness cutoff.
    func minChannel(at i: Int) -> Int { min(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) }
    let fillThreshold = 220

    var isBackground = [Bool](repeating: false, count: width * height)
    var queue = [Int]()
    queue.reserveCapacity(width * height / 4)

    func tryEnqueue(_ x: Int, _ y: Int) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let idx = y * width + x
        if isBackground[idx] { return }
        if minChannel(at: idx * 4) >= fillThreshold {
            isBackground[idx] = true
            queue.append(idx)
        }
    }
    for x in 0..<width { tryEnqueue(x, 0); tryEnqueue(x, height - 1) }
    for y in 0..<height { tryEnqueue(0, y); tryEnqueue(width - 1, y) }

    var head = 0
    while head < queue.count {
        let idx = queue[head]; head += 1
        let x = idx % width, y = idx / width
        tryEnqueue(x + 1, y); tryEnqueue(x - 1, y)
        tryEnqueue(x, y + 1); tryEnqueue(x, y - 1)
    }

    // Hard mask from the flood fill, then a small box blur for anti-aliased
    // (not jagged) edges, applied in two passes (horizontal, then vertical).
    var alphaMask = [Double](repeating: 0, count: width * height)
    for idx in 0..<(width * height) { alphaMask[idx] = isBackground[idx] ? 0 : 255 }

    func boxBlur(_ input: [Double], radius: Int) -> [Double] {
        var horizontal = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<width {
                var sum = 0.0, count = 0.0
                for dx in -radius...radius {
                    let nx = x + dx
                    guard nx >= 0, nx < width else { continue }
                    sum += input[rowStart + nx]; count += 1
                }
                horizontal[rowStart + x] = sum / count
            }
        }
        var vertical = [Double](repeating: 0, count: width * height)
        for x in 0..<width {
            for y in 0..<height {
                var sum = 0.0, count = 0.0
                for dy in -radius...radius {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    sum += horizontal[ny * width + x]; count += 1
                }
                vertical[y * width + x] = sum / count
            }
        }
        return vertical
    }
    let smoothAlpha = boxBlur(alphaMask, radius: 2)

    for idx in 0..<(width * height) {
        let i = idx * 4
        let a = smoothAlpha[idx] / 255.0
        pixels[i] = UInt8(Double(pixels[i]) * a)
        pixels[i + 1] = UInt8(Double(pixels[i + 1]) * a)
        pixels[i + 2] = UInt8(Double(pixels[i + 2]) * a)
        pixels[i + 3] = UInt8(smoothAlpha[idx])
    }

    // Trim to the duck's bounding box (with a small margin) so the large,
    // near-white margin around it doesn't survive as a faint square halo.
    var minX = width, maxX = 0, minY = height, maxY = 0
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            if pixels[i + 3] > 10 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    let margin = 12
    minX = max(0, minX - margin); minY = max(0, minY - margin)
    maxX = min(width - 1, maxX + margin); maxY = min(height - 1, maxY + margin)

    // Copy the bbox sub-rectangle out by hand (row by row) rather than using
    // CGImage.cropping(to:), whose coordinate origin doesn't match the raw
    // top-down buffer here and was producing a mis-cropped image.
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
        fatalError("could not build cropped image")
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
