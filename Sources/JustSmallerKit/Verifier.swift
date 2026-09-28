import Accelerate
import CoreGraphics
import Foundation
import ImageIO

struct VerificationError: LocalizedError {
    let reason: String
    var errorDescription: String? { String(localized: "Result rejected: \(reason)", bundle: .module) }
}

/// Checks an optimizer's output against the original before it may replace
/// it. Just Smaller never trusts a tool: a result that looks different, lost its
/// colour profile or orientation, or can't be decoded is thrown away.
enum Verifier {
    static func verify(original: URL, result: URL, format: ImageFormat, pixelsMustMatch: Bool) async throws {
        if format == .svg {
            try await compareRenderings(original, result, strict: pixelsMustMatch)
            return
        }
        guard let a = CGImageSourceCreateWithURL(original as CFURL, nil),
              let b = CGImageSourceCreateWithURL(result as CFURL, nil),
              CGImageSourceGetCount(b) > 0
        else { throw VerificationError(reason: String(localized: "unreadable", bundle: .module)) }

        let pa = properties(a), pb = properties(b)
        guard pa.width == pb.width, pa.height == pb.height else {
            throw VerificationError(reason: String(localized: "different dimensions", bundle: .module))
        }
        guard pa.orientation == pb.orientation else {
            throw VerificationError(reason: String(localized: "orientation lost", bundle: .module))
        }
        // Also in lossy mode: an animation must stay one, and no image of a
        // multi-image file (e.g. MPO) may go missing. Merging identical frames
        // is allowed and checked frame by frame below.
        let framesA = CGImageSourceGetCount(a), framesB = CGImageSourceGetCount(b)
        guard framesA <= 1 || framesB > 1, format == .gif || format == .png || format == .webp || framesB >= framesA else {
            throw VerificationError(reason: String(localized: "animation or second image lost", bundle: .module))
        }
        // jpegtran copies the profile byte for byte. Other formats may store an
        // equivalent profile differently (oxipng writes an sRGB chunk instead of
        // an sRGB ICC profile), which the pixel comparison below catches.
        if format == .jpeg || format == .heic, pa.iccProfile != pb.iccProfile {
            throw VerificationError(reason: String(localized: "color profile lost", bundle: .module))
        }
        guard pixelsMustMatch, format != .heic else { return }
        if format == .jpeg {
            // ImageIO decodes identical JPEG data differently depending on the
            // Huffman tables, so JPEGs are compared where the image really
            // lives: the quantized DCT coefficients, read with libjpeg.
            try await compareJPEGCoefficients(original, result)
        } else {
            // GIF transparency is on/off per palette entry and the colour behind
            // it carries no meaning, so only PNG and WebP must keep it too.
            try comparePixels(a, b, exactUnderAlpha: format != .gif)
        }
    }

    // MARK: - JPEG

    private static func compareJPEGCoefficients(_ a: URL, _ b: URL) async throws {
        do {
            try await ToolRunner.run("jpegcmp", [a.path, b.path], in: b.deletingLastPathComponent())
        } catch let error as ToolError where error.status == 1 {
            throw VerificationError(reason: String(localized: "pixels changed", bundle: .module))
        } catch let error as ToolError where error.status == 2 {
            throw VerificationError(reason: String(localized: "unreadable", bundle: .module))
        }
    }

    // MARK: - SVG

    /// Renders both SVGs with resvg (Tools/svg-tool) at the original's own
    /// size and proportions — the longer side at least 1024 and at most 4096
    /// pixels, the result on exactly the same canvas — and compares the
    /// pictures. Rewritten shapes antialias a little differently, so edge
    /// pixels may change slightly: up to 0.1 % of the pixels in lossless mode,
    /// 1 % in lossy mode. Strong changes are what lost content looks like (a
    /// missing island on a map, a different font, a thin line): at most a
    /// handful of pixels may change by more than a quarter of the range,
    /// however large the picture.
    private static func compareRenderings(_ a: URL, _ b: URL, strict: Bool) async throws {
        let ra = try await render(a, canvas: nil)
        let rb = try await render(b, canvas: (ra.width, ra.height))
        guard ra.width == rb.width, ra.height == rb.height else {
            throw VerificationError(reason: String(localized: "different dimensions", bundle: .module))
        }
        let pa = try rgba(ra), pb = try rgba(rb)
        var differing = 0, strong = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            let d = max(abs(Int(pa[i]) - Int(pb[i])), abs(Int(pa[i + 1]) - Int(pb[i + 1])),
                        abs(Int(pa[i + 2]) - Int(pb[i + 2])), abs(Int(pa[i + 3]) - Int(pb[i + 3])))
            if d > 2 { differing += 1 }
            if d > 64 { strong += 1 }
        }
        let pixels = ra.width * ra.height
        guard differing <= pixels / (strict ? 1000 : 100), strong <= (strict ? 10 : 100) else {
            throw VerificationError(reason: String(localized: "looks different", bundle: .module))
        }
    }

    /// Renders an SVG into a square PNG next to it and loads it. Anything
    /// resvg reports it can't draw means the comparison would prove nothing.
    private static func render(_ svg: URL, canvas: (Int, Int)?) async throws -> CGImage {
        let png = svg.deletingLastPathComponent().appending(path: "render-\(UUID().uuidString).png")
        let log = svg.deletingLastPathComponent().appending(path: "render-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: log) }
        var args = ["render", svg.path, png.path]
        if let canvas { args += ["--canvas", String(canvas.0), String(canvas.1)] }
        do {
            try await ToolRunner.run("svg-tool", args, stderr: log, in: svg.deletingLastPathComponent())
        } catch {
            throw VerificationError(reason: String(localized: "SVG could not be rendered", bundle: .module))
        }
        if let messages = try? String(contentsOf: log, encoding: .utf8), messages.contains("unsupported:") {
            throw VerificationError(reason: String(localized: "contains content that can’t be checked", bundle: .module))
        }
        // Read into memory: ImageIO decodes lazily, and the file is deleted on return.
        guard let data = try? Data(contentsOf: png),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else {
            throw VerificationError(reason: String(localized: "SVG could not be rendered", bundle: .module))
        }
        return image
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw VerificationError(reason: String(localized: "unreadable", bundle: .module)) }
        return buffer
    }

    // MARK: - Raster

    private struct Properties {
        var width = 0, height = 0, orientation = 1
        var iccProfile: Data?
    }

    private static func properties(_ source: CGImageSource) -> Properties {
        var p = Properties()
        guard let dict = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return p }
        p.width = dict[kCGImagePropertyPixelWidth] as? Int ?? 0
        p.height = dict[kCGImagePropertyPixelHeight] as? Int ?? 0
        p.orientation = dict[kCGImagePropertyOrientation] as? Int ?? 1
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let space = image.colorSpace, let icc = space.copyICCData() {
            p.iccProfile = icc as Data
        }
        return p
    }

    /// Compares what a viewer would show over time, one frame at a time.
    /// gifsicle merges identical consecutive frames into one longer frame,
    /// which is fine as long as every moment of the animation looks the same.
    private static func comparePixels(_ a: CGImageSource, _ b: CGImageSource, exactUnderAlpha: Bool) throws {
        let da = (0..<CGImageSourceGetCount(a)).map { duration(a, $0) }
        let db = (0..<CGImageSourceGetCount(b)).map { duration(b, $0) }
        if da.count > 1 || db.count > 1, da.reduce(0, +) != db.reduce(0, +) {
            throw VerificationError(reason: String(localized: "animation timing changed", bundle: .module))
        }
        let deep = depth(a, 0) > 8 || depth(b, 0) > 8
        var i = 0, j = 0, endA = da[0], endB = db[0]
        var pa = try pixels(a, 0, deep: deep, straight: exactUnderAlpha), pb = try pixels(b, 0, deep: deep, straight: exactUnderAlpha)
        while true {
            guard pa == pb else { throw VerificationError(reason: String(localized: "pixels changed", bundle: .module)) }
            // Step past whichever frame ends first, or both if they end together.
            let stepA = endA <= endB, stepB = endB <= endA
            if stepA { i += 1 }
            if stepB { j += 1 }
            guard i < da.count, j < db.count else { return }
            if stepA { endA += da[i]; pa = try pixels(a, i, deep: deep, straight: exactUnderAlpha) }
            if stepB { endB += db[j]; pb = try pixels(b, j, deep: deep, straight: exactUnderAlpha) }
        }
    }

    private static func depth(_ source: CGImageSource, _ index: Int) -> Int {
        let dict = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return dict?[kCGImagePropertyDepth] as? Int ?? 8
    }

    /// Decodes a frame into sRGB, so a lost colour profile shows up as
    /// different pixels. `straight` keeps the colour of fully transparent
    /// pixels (unpremultiplied alpha), which a lossless PNG or WebP must not
    /// change either; otherwise alpha is premultiplied and it doesn't count.
    /// 16 bits per channel for deep images, so 16-bit PNGs are compared at
    /// full precision.
    private static func pixels(_ source: CGImageSource, _ index: Int, deep: Bool, straight: Bool) throws -> [UInt8] {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw VerificationError(reason: String(localized: "unreadable", bundle: .module))
        }
        let alpha = straight ? CGImageAlphaInfo.last : CGImageAlphaInfo.premultipliedLast
        let order = deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0
        guard let format = vImage_CGImageFormat(bitsPerComponent: deep ? 16 : 8, bitsPerPixel: deep ? 64 : 32,
                                                colorSpace: srgb,
                                                bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | order)),
              let buffer = try? vImage_Buffer(cgImage: image, format: format)
        else { throw VerificationError(reason: String(localized: "unreadable", bundle: .module)) }
        defer { buffer.free() }
        // Rows may be padded; copy only the pixels.
        let rowBytes = Int(buffer.width) * (deep ? 8 : 4)
        var pixels = [UInt8](repeating: 0, count: rowBytes * Int(buffer.height))
        pixels.withUnsafeMutableBytes { out in
            for row in 0..<Int(buffer.height) {
                let src = buffer.data.advanced(by: row * buffer.rowBytes)
                out.baseAddress!.advanced(by: row * rowBytes).copyMemory(from: src, byteCount: rowBytes)
            }
        }
        return pixels
    }

    private static func duration(_ source: CGImageSource, _ index: Int) -> Int {
        guard let dict = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0 }
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary] {
            guard let frame = dict[key] as? [CFString: Any] else { continue }
            let delay = frame[kCGImagePropertyGIFUnclampedDelayTime] ?? frame[kCGImagePropertyGIFDelayTime]
                ?? frame[kCGImagePropertyAPNGUnclampedDelayTime] ?? frame[kCGImagePropertyAPNGDelayTime]
                ?? frame[kCGImagePropertyWebPUnclampedDelayTime] ?? frame[kCGImagePropertyWebPDelayTime]
            if let seconds = delay as? Double { return Int((seconds * 1000).rounded()) }
        }
        return 0
    }
}
