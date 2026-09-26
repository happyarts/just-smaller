import Foundation

/// One way of producing a smaller version of a file. Writes `output` and
/// returns true, or returns false when it has nothing better to offer.
struct Candidate: Sendable {
    /// Shown while the step runs.
    let name: String
    /// Lossy candidates are never checked for identical pixels.
    var isLossy = false
    /// A lossy re-encode must save at least this fraction to be worth the
    /// generation loss.
    var minimumGain = 0.0
    let run: @Sendable (_ input: URL, _ output: URL, _ work: URL) async throws -> Bool
}

/// What the pipeline needs to know about a file beyond its format.
struct FileFacts: Sendable {
    var byteSize: Int64
    /// EXIF orientation (1 = up). Stripping EXIF must keep it.
    var orientation = 1
    /// JPEG only: the quality the file was saved with, estimated.
    var jpegQuality: Int?
    /// Only lossless WebP (VP8L) can be recompressed without loss.
    var isLosslessWebP = false
    var isAnimated = false
    var bitsPerComponent = 8
}

/// The optimizers for each format, as stages. The candidates within a stage
/// run in parallel on the best result so far and the smallest valid output
/// wins; stages run in order.
enum Pipeline {
    static func stages(for format: ImageFormat, facts: FileFacts, settings s: OptimizationSettings) -> [[Candidate]] {
        let strip = s.metadata == .strip
        switch format {
        case .png:
            var stages: [[Candidate]] = []
            if s.lossy { stages.append([pngQuantize()]) }
            stages.append([oxipng(effort: s.effort, strip: strip, lossy: s.lossy, facts: facts)])
            return stages

        case .jpeg:
            // jpegtran rewrites the entropy coding (Huffman tables, progressive
            // scans) without touching the DCT coefficients: lossless. It keeps
            // whatever markers are left; stripping is done by our own filter.
            var stages: [[Candidate]] = []
            // Re-encode only when the original is of higher quality than the
            // target; otherwise re-encoding only adds generation loss and the
            // lossless steps below are all it gets (jpegoptim's rule).
            if s.lossy, (facts.jpegQuality ?? 100) > s.jpegQuality { stages.append([jpegli(quality: s.jpegQuality)]) }
            if strip { stages.append([jpegMetadata(orientation: facts.orientation)]) }
            stages.append([jpegtran()])
            return stages

        case .gif:
            // GIF gets its own optimizer in a later version.
            return []

        case .webp:
            // Lossy WebP would need a lossy re-encode; animations need a
            // different tool. Both are left alone for now.
            guard facts.isLosslessWebP, !facts.isAnimated else { return [] }
            return [[cwebp(effort: s.effort, strip: strip)]]

        case .svg:
            // Lossless keeps the geometry exact to five digits; lossy allows
            // oxvg's (svgo's) approximations such as curves turned into arcs.
            return [[oxvg(lossless: !s.lossy)]]

        case .heic:
            // HEIC can only be re-encoded, which always loses a little.
            guard s.lossy, facts.bitsPerComponent <= 8 else { return [] }
            return [[heif(quality: s.jpegQuality, strip: strip)]]
        }
    }

    /// Why a file gets no stages at all, for the status column.
    static func reasonForNoStages(_ format: ImageFormat, facts: FileFacts, settings: OptimizationSettings) -> String {
        switch format {
        case .webp where facts.isAnimated: String(localized: "Animated WebP is not supported yet", bundle: .module)
        case .webp: String(localized: "Lossy WebP can’t be optimized without loss", bundle: .module)
        case .gif: String(localized: "GIF optimization comes in a later version", bundle: .module)
        case .heic where !settings.lossy: String(localized: "HEIC can only be optimized in lossy mode", bundle: .module)
        case .heic: String(localized: "HDR HEIC images are left untouched", bundle: .module)
        default: String(localized: "Nothing to optimize", bundle: .module)
        }
    }

    // MARK: - PNG

    /// Measured on the corpus (181 PNGs, 62 MB, 8 cores): -o2 saves 13.1 % in
    /// 42 s, -o4 13.9 % in 87 s, -o6 14.1 % in 258 s; "max" is no better than 6.
    /// Zopfli adds 0.1–1.8 % at 7–25 times the time: 72 s for a 1 MB PNG,
    /// 5 minutes for 4 MB with no gain at all. So it only runs on smaller files.
    static let zopfliByteLimit: Int64 = 1_500_000

    /// Chunks that change how a PNG looks. oxipng's own "safe" set leaves out
    /// gAMA and cHRM, which colour-managed viewers apply: an old Photoshop
    /// export with gamma 1/1.8 looked different without it. mDCV and cLLI
    /// describe HDR content.
    static let pngDisplayChunks = "gAMA,cHRM,sBIT,mDCV,cLLI,display"

    static func oxipng(effort: Effort, strip: Bool, lossy: Bool, facts: FileFacts) -> Candidate {
        let zopfli = effort == .maximum && facts.byteSize <= zopfliByteLimit
        return Candidate(name: zopfli ? "OxiPNG + Zopfli" : "OxiPNG") { input, output, work in
            let level = switch effort { case .fast: "2"; case .balanced: "4"; case .thorough, .maximum: "6" }
            var args = ["-o", level, "-i", "0"]
            // -a rewrites the colour of fully transparent pixels. Invisible,
            // but not identical, so only in lossy mode (it gains ~0.1 %).
            if lossy { args += ["-a"] }
            if zopfli { args += ["--zopfli"] }
            // A rotated PNG keeps its eXIf chunk: the orientation is in it.
            if strip { args += ["--keep", facts.orientation != 1 ? "eXIf," + pngDisplayChunks : pngDisplayChunks] }
            args += ["--out", output.path, "--", input.path]
            try await ToolRunner.run("oxipng", args, in: work)
            return true
        }
    }

    /// Palette reduction with quantizr (MIT) through our png-quantize, which
    /// keeps the colour metadata. Measured against pngquant: same size, equal
    /// or better SSIMULACRA2, twice as fast.
    static func pngQuantize() -> Candidate {
        Candidate(name: "quantizr", isLossy: true) { input, output, work in
            do {
                try await ToolRunner.run("png-quantize", [input.path, output.path], in: work)
            } catch let error as ToolError where error.status == 97 || error.status == 98 {
                return false // HDR, or already a palette image
            }
            return true
        }
    }

    // MARK: - JPEG

    static func jpegMetadata(orientation: Int) -> Candidate {
        Candidate(name: String(localized: "Metadata", bundle: .module)) { input, output, _ in
            let data = try Data(contentsOf: input)
            try JPEGMetadataFilter.strip(data, orientation: orientation).write(to: output)
            return true
        }
    }

    static func jpegtran() -> Candidate {
        Candidate(name: "jpegtran") { input, output, work in
            try await ToolRunner.run("jpegtran", ["-copy", "all", "-optimize", "-progressive",
                                                  "-outfile", output.path, input.path], in: work)
            return true
        }
    }

    /// jpegli (Google, BSD): at equal visual quality as small as jpegoptim
    /// when recompressing JPEGs, 7× faster, and 16–21 % smaller than mozjpeg
    /// from pristine sources (see docs/tools-research.md). It drops metadata,
    /// so the original's is put back.
    static func jpegli(quality: Int) -> Candidate {
        Candidate(name: "jpegli", isLossy: true) { input, output, work in
            let encoded = work.appending(path: "jpegli-\(UUID().uuidString).jpg")
            try await ToolRunner.run("cjpegli", [input.path, encoded.path, "--quality=\(quality)"], in: work)
            let merged = try JPEGMetadataFilter.transplant(metadataFrom: Data(contentsOf: input),
                                                           into: Data(contentsOf: encoded))
            try merged.write(to: output)
            return true
        }
    }

    // MARK: - WebP

    static func cwebp(effort: Effort, strip: Bool) -> Candidate {
        Candidate(name: "cwebp") { input, output, work in
            // -exact keeps the colour of fully transparent pixels; without it
            // cwebp changes them, which is not lossless.
            let level = effort == .fast ? "7" : "9"
            try await ToolRunner.run("cwebp", ["-quiet", "-lossless", "-exact", "-z", level,
                                               "-metadata", strip ? "icc" : "all",
                                               "-o", output.path, "--", input.path], in: work)
            return true
        }
    }

    // MARK: - SVG

    static func oxvg(lossless: Bool) -> Candidate {
        Candidate(name: "OXVG", isLossy: !lossless) { input, output, work in
            // oxvg writes to stdout. It runs in the empty work directory so it
            // can't pick up an oxvgrc.json lying next to the image.
            var args = ["optimise"]
            if lossless {
                guard let config = Bundle.module.url(forResource: "oxvg-lossless", withExtension: "json") else {
                    throw ToolError(tool: "oxvg", status: -1, message: String(localized: "The optimizer is missing from the app bundle.", bundle: .module))
                }
                args += ["--config", config.path]
            }
            try await ToolRunner.run("oxvg", args + ["--", input.path], stdout: output, in: work)
            return true
        }
    }

    // MARK: - HEIC

    static func heif(quality: Int, strip: Bool) -> Candidate {
        Candidate(name: "ImageIO", isLossy: true, minimumGain: 0.05) { input, output, _ in
            try HEIFEncoder.recompress(input, to: output, quality: Double(quality) / 100, stripPrivateData: strip)
        }
    }
}
