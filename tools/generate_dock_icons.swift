// Builds the live per-state, per-color Dock tile PNGs from the duck source
// art in icons/<color>/<adjective>_dockling.png. Most sources are already
// real-alpha PNGs; only yellow's front_dockling.jpg is a JPEG with a
// checkerboard pattern baked into its pixels instead of real transparency,
// so it goes through keyCheckerboard() first (every other source, including
// every other color's front pose, is already a clean PNG). Every source then
// gets cropped to its content bounding box and normalized onto the same
// canvas size, so swapping states or colors doesn't visually jump per
// DOCKLING_SPEC.md's Dock-tile art requirements.
//
// Usage: swift tools/generate_dock_icons.swift <icons-dir> <resources-output-dir>

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Usage: swift generate_dock_icons.swift <icons-dir> <resources-output-dir>")
    exit(1)
}
let iconsDir = args[1]
let outputRoot = args[2]
let canvasSize = 256
let margin = 20 // px of padding around the duck within the canvas

// Every character color Dockling can assign to a session. Source filenames
// are all "<adjective>_dockling.png" (or .jpg — see loadSourceImage) inside
// icons/<color>/, with no color in the filename itself.
let colors = ["yellow", "blue", "babyblue", "gray", "green", "lavender", "orange", "pink", "tan"]

func loadCGImage(_ path: String) -> CGImage {
    guard let source = NSImage(contentsOfFile: path),
          let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("could not load \(path)")
    }
    return image
}

/// Loads `icons/<color>/<adjective>_dockling.<ext>`, trying .png then .jpg —
/// every source is a PNG except yellow's front pose, which is a checkerboard
/// JPEG needing keyCheckerboard() first (see file header).
func loadSourceImage(colorDir: String, adjective: String) -> CGImage {
    let pngPath = (colorDir as NSString).appendingPathComponent("\(adjective)_dockling.png")
    if FileManager.default.fileExists(atPath: pngPath) {
        return loadCGImage(pngPath)
    }
    let jpgPath = (colorDir as NSString).appendingPathComponent("\(adjective)_dockling.jpg")
    return keyCheckerboard(loadCGImage(jpgPath))
}

func rgbaBuffer(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int, colorSpace: CGColorSpace) {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: width * 4, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create bitmap context")
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height, colorSpace)
}

/// Keys out a checkerboard "transparency" pattern that got flattened into a
/// JPEG's actual pixels (checker squares are ~grayscale; the artwork itself
/// is colorful, or near-black for outlines) — flood-filled from the image
/// border so only background connected to the edge is removed, then feathered
/// for an anti-aliased edge instead of a jagged one. Same technique used for
/// the original crayon-JPEG assets earlier in this project.
func keyCheckerboard(_ image: CGImage) -> CGImage {
    var (pixels, width, height, colorSpace) = rgbaBuffer(image)

    func isCheckerBackground(at i: Int) -> Bool {
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        let spread = max(r, g, b) - min(r, g, b)
        return spread <= 6 && min(r, g, b) >= 150 // grayscale AND light — excludes the near-black outline
    }

    var isBackground = [Bool](repeating: false, count: width * height)
    var queue = [Int]()
    func tryEnqueue(_ x: Int, _ y: Int) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let idx = y * width + x
        if isBackground[idx] { return }
        if isCheckerBackground(at: idx * 4) {
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

    // Second pass: also key out isolated pockets of the same checker color
    // that flood-fill couldn't reach — e.g. small fully-enclosed gaps (like
    // the loops in the duck's hair), which are real background but sealed
    // off from the border by a ring of outline.
    for idx in 0..<(width * height) where !isBackground[idx] {
        if isCheckerBackground(at: idx * 4) { isBackground[idx] = true }
    }

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

    guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: width * 4, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let result = ctx.makeImage() else {
        fatalError("could not rebuild keyed image")
    }
    return result
}

/// Crops an already-transparent image tightly to its alpha bounding box, via
/// a manual row-by-row byte copy rather than CGImage.cropping(to:) — that
/// API's coordinate origin doesn't match a top-down raw pixel buffer, which
/// previously produced a mis-cropped (bottom-clipped) image here.
func cropToBBox(_ image: CGImage) -> CGImage {
    let (pixels, width, height, colorSpace) = rgbaBuffer(image)

    // Threshold is intentionally high (not just "> 0" or a low value like 10):
    // some source PNGs have scattered near-invisible noise pixels (alpha ~2-3)
    // out near their canvas edges, invisible to the eye but enough to blow out
    // the measured bounding box and make the fitted duck render smaller than
    // it should — this is what caused non-yellow colors to look smaller than
    // yellow (whose pipeline, checkerboard flood-fill, isn't susceptible to
    // this). A real edge's alpha ramps to 255 within a pixel or two, so this
    // only tightens the crop negligibly for genuine artwork.
    let contentThreshold: UInt8 = 128
    var minX = width, maxX = 0, minY = height, maxY = 0
    for y in 0..<height {
        for x in 0..<width {
            if pixels[(y * width + x) * 4 + 3] > contentThreshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard minX <= maxX, minY <= maxY else { fatalError("image is fully transparent") }

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

// Maps each Dock tile output (DockState.rawValue) to the source art
// adjective that produces it. Several states intentionally share one pose —
// per-bucket art is a later refinement once more poses exist.
let poseForState: [(output: String, adjective: String)] = [
    ("idle", "idle"),
    ("bash", "construction"),
    ("search", "detective"),
    ("other", "thinking"),
    ("eureka", "eureka"),
    ("awaiting-input", "front"),
    ("error", "angry"),
    ("edit", "coding"),
    ("thumbs-up", "thumbsup"),
    ("butt", "butt"),
    // Two separate outputs, not one — DockIconController resolves which
    // asset actually backs .committing at load time (config: commit_pose),
    // so both need to exist as their own file rather than picking a winner
    // here.
    ("committing-groom", "groom"),
    ("committing-bride", "bride"),
    ("pulling", "fishing"),
    ("pushing", "box"),
]

for color in colors {
    let colorDir = (iconsDir as NSString).appendingPathComponent(color)
    let outputDir = (outputRoot as NSString).appendingPathComponent(color)
    try? fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    // Cache: several outputs share the same source adjective (e.g. "thinking"
    // feeds bash/search/other), so load+crop each adjective only once.
    var croppedByAdjective: [String: CGImage] = [:]
    for (outputName, adjective) in poseForState {
        let cropped = croppedByAdjective[adjective] ?? cropToBBox(loadSourceImage(colorDir: colorDir, adjective: adjective))
        croppedByAdjective[adjective] = cropped
        renderOnCanvas(cropped, outPath: (outputDir as NSString).appendingPathComponent("\(outputName).png"))
    }
}
