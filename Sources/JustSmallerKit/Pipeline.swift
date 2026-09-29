import Foundation

/// One way of producing a smaller version of a file. Writes `output` and
/// returns true, or returns false when it has nothing better to offer.
struct Candidate: Sendable {
    /// Shown while the step runs.
    let name: String
    /// Lossy candidates are never checked for identical pixels.
    var isLossy = false
    /// Lossy mode lets lossless tools rewrite the colour of fully transparent
    /// pixels (invisible); every visible pixel must still be identical.
    var changesHiddenColour = false
    /// A lossy re-encode must save at least this fraction to be worth the
    /// generation loss.
    var minimumGain = 0.0
    /// When this candidate fails, the file stays as it is: removing private
    /// metadata is a promise, not an optimization.
    var isRequired = false
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
    /// WebP with EXIF or XMP chunks.
    var hasWebPMetadata = false
    /// JPEG with more images indexed after the first (gain map, depth).
    var hasSecondaryImage = false
    var isAnimated = false
    var bitsPerComponent = 8
    /// SVG in UTF-16.
    var isUTF16 = false
    /// SVG content the rendering comparison can't vouch for.
    var isUncheckableSVG = false
}

/// The optimizers for each format, as stages. The candidates within a stage
/// run in parallel on the best result so far and the smallest valid output
/// wins; stages run in order.
enum Pipeline {
    static func stages(for format: ImageFormat, facts: FileFacts, settings s: OptimizationSettings) -> [[Candidate]] {
        switch format {
        case .png:
            var stages: [[Candidate]] = []
            // quantizr reads one frame; an animation would become a still image.
            if s.lossy, !facts.isAnimated { stages.append([pngQuantize()]) }
            stages.append([pngMetadata(s.metadata, orientation: facts.orientation)])
            stages.append(pngCompressors(effort: s.effort, lossy: s.lossy, facts: facts))
            return stages

        case .jpeg:
            // jpeg-scan rewrites the entropy coding (Huffman tables, progressive
            // scans) without touching the DCT coefficients: lossless. It keeps
            // whatever markers are left; filtering is done by our own filter.
            // Our tools rewrite only the first image; ImageIO keeps them all.
            if facts.hasSecondaryImage { return s.metadata == .keep ? [] : [[imageIOMetadata(s.metadata, required: true)]] }
            var stages: [[Candidate]] = []
            // Re-encode only when the original is of higher quality than the
            // target; otherwise re-encoding only adds generation loss and the
            // lossless steps below are all it gets (jpegoptim's rule).
            if s.lossy, (facts.jpegQuality ?? 100) > s.jpegQuality { stages.append([jpegli(quality: s.jpegQuality)]) }
            stages.append([jpegMetadata(s.metadata, orientation: facts.orientation)])
            stages.append([jpegScan(effort: s.effort)])
            return stages

        case .gif:
            // GIF gets its own optimizer in a later version.
            return []

        case .webp:
            // Metadata is filtered in any WebP. Recompressing needs a lossless
            // one: lossy WebP would need a lossy re-encode, animations a
            // different tool.
            var stages: [[Candidate]] = []
            if facts.hasWebPMetadata { stages.append([webpMetadata(s.metadata)]) }
            if facts.isLosslessWebP, !facts.isAnimated { stages.append([cwebp(effort: s.effort)]) }
            return stages

        case .svg:
            // Lossless keeps the geometry exact to five digits; lossy allows
            // oxvg's (svgo's) approximations such as curves turned into arcs.
            let optimize = [oxvg(lossless: !s.lossy, metadata: s.metadata)]
            if facts.isUncheckableSVG { return [[svgUTF8()]] }
            return facts.isUTF16 ? [[svgUTF8()], optimize] : [optimize]

        case .heic:
            // Metadata is filtered without touching the image. The image can
            // only be re-encoded, which always loses a little.
            // In lossy mode the re-encode, which writes only the metadata the
            // level keeps, is the promise's second chance.
            let reencode = s.lossy && facts.bitsPerComponent <= 8
            var stages: [[Candidate]] = []
            if s.metadata != .keep, !facts.isAnimated { stages.append([imageIOMetadata(s.metadata, required: !reencode)]) }
            if reencode { stages.append([heif(quality: s.jpegQuality, metadata: s.metadata)]) }
            return stages
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

    /// Metadata is filtered by our own filter before compressing: ECT's
    /// --strip would drop the colour profile too.
    static func pngMetadata(_ level: MetadataHandling, orientation: Int) -> Candidate {
        metadata(level) { try PNGMetadataFilter.filter($0, level: level, orientation: orientation) }
    }

    /// A metadata filter as a candidate. Its result is checked against the
    /// original with ImageIO before it counts.
    private static func metadata(_ level: MetadataHandling, _ filter: @escaping @Sendable (Data) throws -> Data) -> Candidate {
        Candidate(name: String(localized: "Metadata", bundle: .module), isRequired: level != .keep) { input, output, _ in
            try filter(Data(contentsOf: input)).write(to: output)
            try MetadataCheck.verify(original: input, result: output, level: level)
            return true
        }
    }

    /// Maximum effort also tries every filter strategy, but only on files
    /// small enough for that to end in practical time.
    static let allFiltersByteLimit: Int64 = 256_000

    /// ECT and OxiPNG each win on different images, so from Balanced on both
    /// run in parallel and the smaller result is kept. ECT breaks animated
    /// PNGs (it palette-reduces the first frame only); those get OxiPNG alone.
    static func pngCompressors(effort: Effort, lossy: Bool, facts: FileFacts) -> [Candidate] {
        if facts.isAnimated { return [oxipng(level: effort == .fast ? "2" : "4", lossy: lossy)] }
        switch effort {
        case .fast:
            return [oxipng(level: "2", lossy: lossy)]
        case .balanced:
            return [ect(["-5"], lossy: lossy), oxipng(level: "2", lossy: lossy)]
        case .thorough:
            return [ect(["-7"], lossy: lossy), oxipng(level: "4", lossy: lossy)]
        case .maximum:
            var candidates = [ect(["-8"], lossy: lossy), ect(["-9"], lossy: lossy), oxipng(level: "6", lossy: lossy)]
            if facts.byteSize <= allFiltersByteLimit { candidates.append(ect(["-9", "--allfilters-b"], lossy: lossy)) }
            return candidates
        }
    }

    /// ECT rewrites the file in place, so it works on a copy.
    static func ect(_ options: [String], lossy: Bool) -> Candidate {
        Candidate(name: "ECT", changesHiddenColour: lossy) { input, output, work in
            try FileManager.default.copyItem(at: input, to: output)
            var args = options
            // Without --strict ECT rewrites the colour of fully transparent
            // pixels. Invisible, but not identical, so only in lossy mode.
            if !lossy { args += ["--strict"] }
            try await ToolRunner.run("ect-png", args + [output.path], in: work)
            return true
        }
    }

    static func oxipng(level: String, lossy: Bool) -> Candidate {
        Candidate(name: "OxiPNG", changesHiddenColour: lossy) { input, output, work in
            var args = ["-o", level, "-i", "0", "--strip", "none"]
            // -a rewrites the colour of fully transparent pixels. Invisible,
            // but not identical, so only in lossy mode.
            if lossy { args += ["-a"] }
            args += ["--out", output.path, "--", input.path]
            try await ToolRunner.run("oxipng", args, in: work)
            return true
        }
    }

    /// Palette reduction with quantizr (MIT) through our png-quantize, which
    /// keeps the colour metadata.
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

    static func jpegMetadata(_ level: MetadataHandling, orientation: Int) -> Candidate {
        metadata(level) { try JPEGMetadataFilter.filter($0, level: level, orientation: orientation) }
    }

    /// Tools/jpeg-scan: finds the progressive scan split that codes this
    /// image's coefficients smallest, and writes it with libjpeg-turbo.
    /// Exit status 3: a JPEG it doesn't handle (12-bit, lossless, arithmetic).
    static func jpegScan(effort: Effort) -> Candidate {
        Candidate(name: "jpeg-scan") { input, output, work in
            do {
                try await ToolRunner.run("jpeg-scan", ["--effort", effort.rawValue, input.path, output.path], in: work)
            } catch let error as ToolError where error.status == 3 {
                return false
            }
            return true
        }
    }

    /// jpegli (Google, BSD). It drops metadata, so the original's is put back.
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

    /// Metadata through ImageIO, for HEIC and multi-image JPEGs.
    static func imageIOMetadata(_ level: MetadataHandling, required: Bool) -> Candidate {
        Candidate(name: String(localized: "Metadata", bundle: .module), isRequired: required) { input, output, _ in
            guard try ImageIOMetadata.copy(input, to: output, level: level) else { return false }
            try MetadataCheck.verify(original: input, result: output, level: level)
            return true
        }
    }

    // MARK: - WebP

    static func webpMetadata(_ level: MetadataHandling) -> Candidate {
        metadata(level) { try WebPMetadataFilter.filter($0, level: level) }
    }

    /// Metadata was filtered before; cwebp copies what is left.
    static func cwebp(effort: Effort) -> Candidate {
        Candidate(name: "cwebp") { input, output, work in
            // -exact keeps the colour of fully transparent pixels; without it
            // cwebp changes them, which is not lossless.
            let level = effort == .fast ? "7" : "9"
            try await ToolRunner.run("cwebp", ["-quiet", "-lossless", "-exact", "-z", level,
                                               "-metadata", "all",
                                               "-o", output.path, "--", input.path], in: work)
            return true
        }
    }

    // MARK: - SVG

    /// The same text in UTF-8, which the optimizer and the renderer read.
    static func svgUTF8() -> Candidate {
        Candidate(name: "UTF-8") { input, output, _ in
            guard let converted = SVGText.utf8(try Data(contentsOf: input)) else { return false }
            try converted.write(to: output)
            return true
        }
    }

    /// The OXVG optimiser through Tools/svg-tool, which writes to stdout
    /// and never reads a configuration other than the one it is given.
    static func oxvg(lossless: Bool, metadata: MetadataHandling) -> Candidate {
        Candidate(name: "OXVG", isLossy: !lossless) { input, output, work in
            // Both configurations keep every id: other files and pages refer to
            // them (sprites, <use href="icons.svg#x">), which no rendering of
            // this file can show.
            guard let bundled = Bundle.module.url(forResource: lossless ? "oxvg-lossless" : "oxvg-lossy", withExtension: "json") else {
                throw ToolError(tool: "svg-tool", status: -1, message: String(localized: "The optimizer is missing from the app bundle.", bundle: .module))
            }
            let config = try omitting(jobsKeeping(metadata), from: bundled, in: work)
            try await ToolRunner.run("svg-tool", ["optimise", "--config", config.path, input.path], stdout: output, in: work)
            return true
        }
    }

    /// The jobs to leave out so a level's metadata stays. Editor data
    /// (Inkscape, Illustrator — often with the author's file paths) and
    /// comments go unless everything is kept; title, description and the
    /// metadata element (creator and licence) go only when nothing is kept.
    static func jobsKeeping(_ level: MetadataHandling) -> [String] {
        switch level {
        case .keep: ["removeMetadata", "removeComments", "removeEditorsNSData", "removeDesc", "removeTitle"]
        case .removePrivate, .copyrightOnly: ["removeMetadata", "removeDesc", "removeTitle"]
        case .removeAll: []
        }
    }

    /// A copy of the configuration without the given jobs.
    private static func omitting(_ metadataJobs: [String], from config: URL, in work: URL) throws -> URL {
        guard !metadataJobs.isEmpty, var root = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any],
              var optimise = root["optimise"] as? [String: Any] else { return config }
        var jobs = optimise["jobs"] as? [String: Any] ?? [:]
        for job in metadataJobs { jobs[job] = nil }
        optimise["jobs"] = jobs
        // Jobs from a preset ("extends") are left out by their snake_case name.
        let snake = metadataJobs.map { $0.replacing(/([a-z])([A-Z])/) { "\($0.1)_\($0.2.lowercased())" }.lowercased() }
        optimise["omit"] = (optimise["omit"] as? [String] ?? []) + snake
        root["optimise"] = optimise
        let url = work.appending(path: "oxvg-config-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }


    // MARK: - HEIC

    static func heif(quality: Int, metadata: MetadataHandling) -> Candidate {
        Candidate(name: "ImageIO", isLossy: true, minimumGain: 0.05, isRequired: metadata != .keep) { input, output, _ in
            guard try HEIFEncoder.recompress(input, to: output, quality: Double(quality) / 100, metadata: metadata) else { return false }
            try MetadataCheck.verify(original: input, result: output, level: metadata)
            return true
        }
    }
}
