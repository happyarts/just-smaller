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
    /// `exactUnderAlpha` false allows a different colour under fully
    /// transparent pixels (lossy mode's lossless steps); visible pixels must
    /// still match.
    /// `structure` is what the structure check needs from the original; the
    /// caller reads it once for all candidates of a step.
    static func verify(original: URL, result: URL, format: ImageFormat, pixelsMustMatch: Bool,
                       exactUnderAlpha: Bool = true, structure: StructureCheck.Reference? = nil) async throws {
        let structure = structure ?? StructureCheck.Reference(original: original, format: format)
        try StructureCheck.verify(result: result, against: structure)
        if format == .jxl {
            try await verifyRecompressedJXL(original: original, result: result)
            return
        }
        if format == .svg {
            // UTF-16 → UTF-8 is proven on the text itself; the renderer reads UTF-8 only.
            if let a = try? Data(contentsOf: original), SVGText.encoding(a) != .utf8 {
                guard SVGText.isSameText(original: a, result: try Data(contentsOf: result)) else {
                    throw VerificationError(reason: String(localized: "text changed", bundle: .module))
                }
                return
            }
            try await compareRenderings(original, result, strict: pixelsMustMatch)
            return
        }
        // A gain map the original hid by where its index lay shows in the
        // result (`JPEGLayout.hidesGainMap`): compared with the original as
        // it shows it.
        var shown: Data?
        if let jpeg = structure.jpeg, let layout = jpeg.layout, layout.hidesGainMap,
           let b = try? Data(contentsOf: result, options: .alwaysMapped) {
            shown = layout.withGainMapShown(jpeg.original, for: ByteView(b))
        }
        guard let a = shown.map({ CGImageSourceCreateWithData($0 as CFData, nil) }) ?? CGImageSourceCreateWithURL(original as CFURL, nil),
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
        guard pa.resolution == pb.resolution, format != .jpeg || pa.browserSize == pb.browserSize else {
            throw VerificationError(reason: String(localized: "resolution changed", bundle: .module))
        }
        // Also in lossy mode: an animation must stay one, and no image of a
        // multi-image file (e.g. MPO) may go missing. Merging identical frames
        // is allowed and checked frame by frame below.
        let framesA = CGImageSourceGetCount(a), framesB = CGImageSourceGetCount(b)
        guard framesA <= 1 || framesB > 1, format == .gif || format == .png || format == .webp || framesB >= framesA else {
            throw VerificationError(reason: String(localized: "animation or second image lost", bundle: .module))
        }
        // jpeg-scan copies the profile byte for byte. Other formats may store an
        // equivalent profile differently (our PNG metadata filter writes an sRGB
        // chunk instead of a standard sRGB ICC profile), which the pixel
        // comparison below catches.
        if format == .jpeg || format == .heic, pa.iccProfile != pb.iccProfile {
            throw VerificationError(reason: String(localized: "color profile lost", bundle: .module))
        }
        // A HEIC whose coded image, properties and auxiliary images are the
        // same bytes (only EXIF and XMP changed) is proven without decoding.
        let sameImage = format == .heic && pixelsMustMatch
            && (try? HEIFItems.sameImage(ByteView(Data(contentsOf: original, options: .alwaysMapped)),
                                         ByteView(Data(contentsOf: result, options: .alwaysMapped)))) == true
        // HEIC's lossy re-encode encodes the auxiliary images anew too.
        if format == .jpeg || format == .heic {
            try compareAuxiliaryImages(a, b, exact: format == .jpeg || pixelsMustMatch, knownSame: sameImage)
        }
        // Every image of the file must read to its end.
        guard CGImageSourceGetStatus(b) == .statusComplete,
              (0..<framesB).allSatisfy({ CGImageSourceGetStatusAtIndex(b, $0) == .statusComplete })
        else { throw VerificationError(reason: String(localized: "unreadable", bundle: .module)) }
        guard pixelsMustMatch else {
            // libjpeg reads the whole JPEG without a warning; other formats
            // are decoded once by ImageIO.
            if format == .jpeg {
                try await compareJPEGCoefficients(original: nil, result)
            } else if CGImageSourceCreateImageAtIndex(b, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) == nil {
                throw VerificationError(reason: String(localized: "unreadable", bundle: .module))
            }
            return
        }
        if format == .jpeg {
            // ImageIO decodes identical JPEG data differently depending on the
            // Huffman tables, so JPEGs are compared where the image really
            // lives: the quantized DCT coefficients, read with libjpeg.
            try await compareJPEGCoefficients(original: original, result)
        } else if sameImage {
            return
        } else {
            // GIF transparency is on/off per palette entry and the colour behind
            // it carries no meaning, so only PNG and WebP must keep it too.
            try comparePixels(a, b, exactUnderAlpha: format != .gif && exactUnderAlpha)
        }
    }

    // MARK: - JPEG XL

    /// How far what a JPEG XL decoder shows may lie from what a JPEG decoder
    /// shows of the same coefficients, in 8-bit steps: on average, in the
    /// worst 8×8 block, at the worst pixel. JPEG XL decodes with more
    /// precision than JPEG decoders do; the limits only let that through.
    struct DecodeTolerance: Sendable {
        let mean: Double, block: Double, max: Int
        /// Our own conversions (chroma from luma off).
        static let converted = DecodeTolerance(mean: 1.5, block: 4, max: 40)
        /// JPEG XL files from elsewhere, possibly with chroma from luma.
        static let foreign = DecodeTolerance(mean: 3, block: 12, max: 64)
    }

    /// A JPEG and a JPEG XL holding it (made from it, or rebuilt into it)
    /// show the same picture: the JPEG XL is sound and rebuilds into exactly
    /// `jpeg`; jxl-rs — the decoder of Chrome and Firefox, written apart from
    /// libjxl — shows what libjpeg shows of the JPEG, within `tolerance`,
    /// with the same orientation; ImageIO shows both alike (size,
    /// orientation, colour profile, one image).
    /// `rebuilt`: the JPEG was just rebuilt from the JPEG XL (going back),
    /// so it is not rebuilt again to compare.
    static func verifyConversion(jpeg: URL, jxl: URL, tolerance: DecodeTolerance, rebuilt isRebuilt: Bool = false) async throws {
        let work = jxl.deletingLastPathComponent()
        let file: JXLContainer.File
        do {
            file = try JXLContainer.read(ByteView(Data(contentsOf: jxl, options: .alwaysMapped)))
        } catch let error as FormatError {
            throw VerificationError(reason: String(localized: "invalid file structure (\(error.detail))", bundle: .module))
        }
        guard file.hasReconstructionData else {
            throw VerificationError(reason: String(localized: "the JPEG can’t be rebuilt from it", bundle: .module))
        }

        let rebuilt = work.appending(path: "rebuilt-\(UUID().uuidString).jpg")
        let pixels = work.appending(path: "pixels-\(UUID().uuidString).ppm")
        let output = work.appending(path: "pixels-\(UUID().uuidString).txt")
        defer { for url in [rebuilt, pixels, output] { try? FileManager.default.removeItem(at: url) } }
        if !isRebuilt {
            do {
                try await ToolRunner.run("jxl-transcode", ["decode", jxl.path, rebuilt.path], in: work)
            } catch is ToolError {
                throw VerificationError(reason: String(localized: "the JPEG can’t be rebuilt from it", bundle: .module))
            }
            guard try Data(contentsOf: rebuilt, options: .alwaysMapped) == Data(contentsOf: jpeg, options: .alwaysMapped) else {
                throw VerificationError(reason: String(localized: "the rebuilt JPEG differs", bundle: .module))
            }
        }

        do {
            try await ToolRunner.run("jxl-pixels", [jxl.path, pixels.path], stdout: output, in: work)
        } catch is ToolError {
            throw VerificationError(reason: String(localized: "unreadable", bundle: .module))
        }
        let stated = (try? String(contentsOf: output, encoding: .utf8))?.firstMatch(of: /orientation (\d)/).flatMap { Int($0.1) }
        guard stated == FileFacts.orientation(of: try Data(contentsOf: jpeg, options: .alwaysMapped)) else {
            throw VerificationError(reason: String(localized: "orientation lost", bundle: .module))
        }
        do {
            try await ToolRunner.run("jpegcmp", ["--pixels", jpeg.path, pixels.path], stdout: output, in: work)
        } catch let error as ToolError where error.status == 1 {
            throw VerificationError(reason: String(localized: "different dimensions", bundle: .module))
        } catch is ToolError {
            throw VerificationError(reason: String(localized: "unreadable", bundle: .module))
        }
        let report = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        guard let m = report.firstMatch(of: /mean ([0-9.]+) block ([0-9.]+) max (\d+)/),
              let mean = Double(m.1), let block = Double(m.2), let max = Int(m.3),
              mean <= tolerance.mean, block <= tolerance.block, max <= tolerance.max
        else { throw VerificationError(reason: String(localized: "a JPEG XL viewer would show it differently", bundle: .module)) }

        // What Finder, Preview and Safari show.
        guard let a = CGImageSourceCreateWithURL(jpeg as CFURL, nil), let b = CGImageSourceCreateWithURL(jxl as CFURL, nil),
              CGImageSourceGetCount(b) == 1, let image = CGImageSourceCreateImageAtIndex(b, 0, nil)
        else { throw VerificationError(reason: String(localized: "unreadable", bundle: .module)) }
        let pa = properties(a), pb = properties(b, image: image)
        guard pa.width == pb.width, pa.height == pb.height else {
            throw VerificationError(reason: String(localized: "different dimensions", bundle: .module))
        }
        guard pa.orientation == pb.orientation else {
            throw VerificationError(reason: String(localized: "orientation lost", bundle: .module))
        }
        // How the JPEG would look as JPEG XL. A JPEG XL stored anew is
        // compared with the old one instead (verifyRecompressedJXL): it may
        // show as its JPEG would not, as long as it shows as it did.
        if isRebuilt { return }
        // A JPEG whose colour space only its EXIF names (Adobe RGB), or a grey
        // one without a profile, is shown in other colours as JPEG XL.
        guard pa.iccProfile == pb.iccProfile else {
            throw VerificationError(reason: String(localized: "it would be shown in other colours", bundle: .module))
        }
        // A JPEG that browsers show at the size its EXIF resolution gives
        // would be shown larger as JPEG XL: they don't do so for JPEG XL.
        // A resolution only JFIF states is lost (JPEG XL has no JFIF); it is
        // the size apps show and print at by default, which any app lets
        // you change, so that may go.
        guard pa.browserSize == [pa.width, pa.height] else {
            throw VerificationError(reason: String(localized: "it would be shown at another size", bundle: .module))
        }
    }

    /// A JPEG XL made from a JPEG, stored anew: both rebuild into JPEGs with
    /// the same coefficients; the new one rebuilds and decodes as a
    /// conversion must; and ImageIO shows the old and the new alike.
    private static func verifyRecompressedJXL(original: URL, result: URL) async throws {
        let work = result.deletingLastPathComponent(), id = UUID().uuidString
        let a = work.appending(path: "before-\(id).jpg"), b = work.appending(path: "after-\(id).jpg")
        defer { for url in [a, b] { try? FileManager.default.removeItem(at: url) } }
        for (jxl, jpeg) in [(original, a), (result, b)] {
            do {
                try await ToolRunner.run("jxl-transcode", ["decode", jxl.path, jpeg.path], in: work)
            } catch is ToolError {
                throw VerificationError(reason: String(localized: "the JPEG can’t be rebuilt from it", bundle: .module))
            }
        }
        try await jpegcmp(a, b)
        try await verifyConversion(jpeg: b, jxl: result, tolerance: .converted, rebuilt: true)
        guard let x = CGImageSourceCreateWithURL(original as CFURL, nil), let y = CGImageSourceCreateWithURL(result as CFURL, nil) else {
            throw VerificationError(reason: String(localized: "unreadable", bundle: .module))
        }
        let px = properties(x), py = properties(y)
        guard px.width == py.width, px.height == py.height else {
            throw VerificationError(reason: String(localized: "different dimensions", bundle: .module))
        }
        guard px.orientation == py.orientation else {
            throw VerificationError(reason: String(localized: "orientation lost", bundle: .module))
        }
        guard px.iccProfile == py.iccProfile else {
            throw VerificationError(reason: String(localized: "color profile lost", bundle: .module))
        }
        guard px.resolution == py.resolution else {
            throw VerificationError(reason: String(localized: "resolution changed", bundle: .module))
        }
    }

    // MARK: - JPEG

    /// Without an original, only reads the result. A JPEG that holds several
    /// images is compared image by image, in parallel: jpegcmp reads only
    /// the first.
    private static func compareJPEGCoefficients(original: URL?, _ result: URL) async throws {
        guard let original else { return try await jpegcmp(nil, result) }
        let pairs: [(original: Data, result: Data)]
        do {
            pairs = try JPEGLayout.imagePairs(Data(contentsOf: original, options: .alwaysMapped),
                                              Data(contentsOf: result, options: .alwaysMapped))
        } catch is FormatError {
            throw VerificationError(reason: String(localized: "animation or second image lost", bundle: .module))
        }
        let folder = result.deletingLastPathComponent()
        try await withThrowingTaskGroup(of: Void.self) { group in
            // The first image: jpegcmp reads it from the whole files.
            group.addTask { try await jpegcmp(original, result) }
            for pair in pairs {
                group.addTask {
                    let a = folder.appending(path: "image-\(UUID().uuidString).jpg"), b = folder.appending(path: "image-\(UUID().uuidString).jpg")
                    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
                    try pair.original.write(to: a)
                    try pair.result.write(to: b)
                    try await jpegcmp(a, b)
                }
            }
            try await group.waitForAll()
        }
    }

    private static func jpegcmp(_ original: URL?, _ result: URL) async throws {
        do {
            try await ToolRunner.run("jpegcmp", [original?.path ?? "--check", result.path], in: result.deletingLastPathComponent())
        } catch let error as ToolError where error.status == 1 {
            throw VerificationError(reason: String(localized: "pixels changed", bundle: .module))
        } catch let error as ToolError where error.status == 2 {
            throw VerificationError(reason: String(localized: "unreadable", bundle: .module))
        } catch let error as ToolError where error.status == 3 {
            throw VerificationError(reason: String(localized: "the decoder reports damaged data", bundle: .module))
        }
    }

    /// A photo's auxiliary images (HDR gain map, depth, mattes) are all
    /// still there and decode as before (`exact`) or at least have the same
    /// size, and the photo is shown as bright as
    /// before: the HDR headroom comes from metadata (Apple's maker note, XMP,
    /// ISO 21496-1) that a filter must not lose. Reading the headroom
    /// doesn't decode the photo.
    /// `knownSame`: their bytes are proven the same, only the brightness is
    /// left to compare.
    private static func compareAuxiliaryImages(_ a: CGImageSource, _ b: CGImageSource, exact: Bool, knownSame: Bool = false) throws {
        if !knownSame {
            guard let aux = AuxiliaryImages.same(a, b, exact: exact) else {
                throw VerificationError(reason: String(localized: "animation or second image lost", bundle: .module))
            }
            guard !aux.isEmpty else { return }
        }
        let hdr = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary
        guard CGImageSourceCreateImageAtIndex(a, 0, hdr)?.contentHeadroom == CGImageSourceCreateImageAtIndex(b, 0, hdr)?.contentHeadroom else {
            throw VerificationError(reason: String(localized: "HDR brightness changed", bundle: .module))
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
        /// The resolution ImageIO reads (72 dpi without one): apps that size
        /// images by it (AppKit) show and print the image at that size.
        var resolution = [72.0, 72.0]
        /// The size browsers show a JPEG at: one whose EXIF states a
        /// resolution and the pixel size that matches it at 72 dpi is shown
        /// at that size (HTML's density-corrected natural size). Safari and
        /// Chrome do so for JPEG only.
        var browserSize: [Int] = []
    }

    /// `image`: the first image, when it is decoded already.
    private static func properties(_ source: CGImageSource, image decoded: CGImage? = nil) -> Properties {
        var p = Properties()
        guard let dict = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return p }
        p.width = dict[kCGImagePropertyPixelWidth] as? Int ?? 0
        p.height = dict[kCGImagePropertyPixelHeight] as? Int ?? 0
        p.orientation = dict[kCGImagePropertyOrientation] as? Int ?? 1
        p.resolution = [dict[kCGImagePropertyDPIWidth] as? Double ?? 72, dict[kCGImagePropertyDPIHeight] as? Double ?? 72]
        p.browserSize = [p.width, p.height]
        let tiff = dict[kCGImagePropertyTIFFDictionary] as? [CFString: Any], exif = dict[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if let x = tiff?[kCGImagePropertyTIFFXResolution] as? Double, let y = tiff?[kCGImagePropertyTIFFYResolution] as? Double,
           x > 0, y > 0, tiff?[kCGImagePropertyTIFFResolutionUnit] as? Int ?? 2 == 2,
           let w = exif?[kCGImagePropertyExifPixelXDimension] as? Int, let h = exif?[kCGImagePropertyExifPixelYDimension] as? Int,
           w > 0, h > 0, Double(p.width) * 72 / x == Double(w), Double(p.height) * 72 / y == Double(h) {
            p.browserSize = [w, h]
        }
        if let image = decoded ?? CGImageSourceCreateImageAtIndex(source, 0, nil),
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

    /// Pixels vImage can't convert (packed 10-bit, as in iPhone
    /// screenshots), drawn at 16 bits into one wide colour space (BT.2020),
    /// so a changed colour space still shows up as different pixels. Only
    /// for images without alpha, where premultiplied and straight are the same.
    private static func drawn(_ image: CGImage, deep: Bool) throws -> [UInt8] {
        guard deep, [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo),
              let space = CGColorSpace(name: CGColorSpace.itur_2020),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: image.width * 8,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
              let data = context.data
        else { throw VerificationError(reason: String(localized: "unreadable", bundle: .module)) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return [UInt8](UnsafeRawBufferPointer(start: data, count: image.width * 8 * image.height))
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
        else { return try drawn(image, deep: deep) }
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
