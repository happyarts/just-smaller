import Foundation
import ImageIO

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
    /// The EXIF orientation ImageIO reads (1 = up; 1 for anything invalid).
    static func orientation(of source: CGImageSource) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        return (1...8).contains(orientation) ? orientation : 1
    }

    static func orientation(of image: Data) -> Int {
        CGImageSourceCreateWithData(image as CFData, nil).map(orientation) ?? 1
    }

    var byteSize: Int64
    /// EXIF orientation (1 = up). Stripping EXIF must keep it.
    var orientation = 1
    /// JPEG only: the quality the file was saved with, estimated.
    var jpegQuality: Int?
    /// Only lossless WebP (VP8L) can be recompressed without loss.
    var isLosslessWebP = false
    /// WebP with EXIF or XMP chunks.
    var hasWebPMetadata = false
    /// JPEG with more images indexed after the first (gain map, depth,
    /// stereo), which `JPEGStructure.images` can take apart.
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
            // A JPEG that holds several images gets both image by image, and
            // no lossy re-encode.
            if facts.hasSecondaryImage {
                return [[jpegImagesMetadata(s.metadata, orientation: facts.orientation)], [jpegImagesScan(effort: s.effort)]]
            }
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
            // Each runs with the ids as they are and with generated ids
            // shortened or removed (fewer ids can also mean a bigger file:
            // collapsed groups repeat their attributes on every child);
            // lossless also more precisely, for drawings where the standard
            // rounding shows. The smallest valid result wins.
            let runs: [SVGRun] = s.lossy ? [.idsKept, .generatedIDsRemoved] : [.idsKept, .generatedIDsRemoved, .precise]
            let optimize = runs.map { oxvg(lossless: !s.lossy, metadata: s.metadata, run: $0) }
            if facts.isUncheckableSVG { return [[svgUTF8()]] }
            return facts.isUTF16 ? [[svgUTF8()], optimize] : [optimize]

        case .heic:
            // Metadata is filtered without touching the image. The image can
            // only be re-encoded, which always loses a little.
            // In lossy mode the re-encode, which writes only the metadata the
            // level keeps, is the promise's second chance.
            let reencode = s.lossy && facts.bitsPerComponent <= 8
            var stages: [[Candidate]] = []
            if s.metadata != .keep, !facts.isAnimated { stages.append([heifMetadata(s.metadata, required: !reencode)]) }
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

    /// A JPEG that holds several images (HDR gain map, depth and mattes,
    /// stereo), taken apart into its images, each changed on its own (in
    /// parallel) and joined again with the multi-picture index rewritten.
    /// `change` gets an image and its number and returns it changed or as it
    /// was. Where the first image's XMP lists the lengths of the others
    /// (Google's container), only the first changes. What lies between and
    /// after the images (leftover bytes from cameras, unknown data) stays as
    /// it is, or goes with `droppingGaps`: it could hold anything.
    private static func changeEachImage(of input: URL, to output: URL, droppingGaps: Bool = false,
                                        _ change: @escaping @Sendable (_ image: Data, _ n: Int) async throws -> Data) async throws {
        let data = try Data(contentsOf: input, options: .alwaysMapped)
        guard let ranges = JPEGStructure.images(ByteView(data)) else { throw JPEGMetadataFilter.Malformed() }
        // The first image starts the file; its header segments are read.
        let onlyFirst = JPEGStructure.listsLengthsInXMP(ByteView(data))
        let images = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (n, range) in ranges.enumerated() {
                let image = data.subdata(in: range)
                group.addTask { (n, n > 0 && onlyFirst ? image : try await change(image, n)) }
            }
            var images = [Data](repeating: Data(), count: ranges.count)
            for try await (n, image) in group { images[n] = image }
            return images
        }
        let gaps = JPEGStructure.gaps(ranges, count: data.count).map { droppingGaps && !onlyFirst ? Data() : data.subdata(in: $0) }
        try JPEGStructure.joined(images, gaps: gaps).write(to: output)
    }

    /// Each image keeps its own orientation. Unknown data between and after
    /// the images goes like unknown metadata segments, unless everything stays.
    static func jpegImagesMetadata(_ level: MetadataHandling, orientation: Int) -> Candidate {
        Candidate(name: String(localized: "Metadata", bundle: .module), isRequired: level != .keep) { input, output, _ in
            try await changeEachImage(of: input, to: output, droppingGaps: level != .keep) { image, n in
                try JPEGMetadataFilter.filter(image, level: level, orientation: n == 0 ? orientation : FileFacts.orientation(of: image))
            }
            try MetadataCheck.verify(original: input, result: output, level: level)
            return true
        }
    }

    /// Each image through jpeg-scan; one it doesn't handle or can't make
    /// smaller stays as it was.
    static func jpegImagesScan(effort: Effort) -> Candidate {
        let scan = jpegScan(effort: effort)
        return Candidate(name: scan.name) { input, output, work in
            try await changeEachImage(of: input, to: output) { image, n in
                let id = UUID().uuidString
                let from = work.appending(path: "image\(n)-\(id).jpg"), to = work.appending(path: "image\(n)-\(id)-scan.jpg")
                defer { try? FileManager.default.removeItem(at: from); try? FileManager.default.removeItem(at: to) }
                try image.write(to: from)
                guard try await scan.run(from, to, work) else { return image }
                let scanned = try Data(contentsOf: to)
                return scanned.count < image.count ? scanned : image
            }
            return true
        }
    }

    /// HEIC's EXIF and XMP, in their items; nothing else changes.
    static func heifMetadata(_ level: MetadataHandling, required: Bool) -> Candidate {
        Candidate(name: String(localized: "Metadata", bundle: .module), isRequired: required) { input, output, _ in
            try HEIFMetadataFilter.filter(Data(contentsOf: input, options: .alwaysMapped), level: level).write(to: output)
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

    enum SVGRun {
        /// Every id stays, as the bundled configurations have it.
        case idsKept
        /// Ids SVGIDs finds safe to touch are shortened or removed.
        case generatedIDsRemoved
        /// As generatedIDsRemoved, with more digits in transforms and paths
        /// and transforms left where they are.
        case precise
    }

    /// The OXVG optimiser through Tools/svg-tool, which writes to stdout
    /// and never reads a configuration other than the one it is given.
    static func oxvg(lossless: Bool, metadata: MetadataHandling, run: SVGRun) -> Candidate {
        Candidate(name: "OXVG", isLossy: !lossless) { input, output, work in
            let preserve = run == .idsKept ? nil : SVGIDs.toPreserve(in: input)
            // No id to touch: the run keeping them all gives the same result.
            if run == .generatedIDsRemoved, preserve == nil { return false }
            let config = try configuration(lossless: lossless, omitting: jobsKeeping(metadata), precise: run == .precise,
                                           preservingIDs: preserve, in: work)
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

    /// A copy of the bundled configuration without the given jobs,
    /// optionally more precise, and with ids shortened and removed except
    /// `preservingIDs` (nil: every id stays, as bundled).
    static func configuration(lossless: Bool, omitting metadataJobs: [String], precise: Bool,
                              preservingIDs: [String]?, in work: URL) throws -> URL {
        guard let bundled = Bundle.module.url(forResource: lossless ? "oxvg-lossless" : "oxvg-lossy", withExtension: "json"),
              var root = try JSONSerialization.jsonObject(with: Data(contentsOf: bundled)) as? [String: Any],
              var optimise = root["optimise"] as? [String: Any], var jobs = optimise["jobs"] as? [String: Any]
        else { throw ToolError(tool: "svg-tool", status: -1, message: String(localized: "The optimizer is missing from the app bundle.", bundle: .module)) }
        let omit = metadataJobs + (precise ? ["applyTransforms"] : [])
        for job in omit { jobs[job] = nil }
        if precise {
            jobs["convertTransform"] = merged(jobs["convertTransform"], ["transformPrecision": 9, "floatPrecision": 7])
            if var pathData = jobs["convertPathData"] as? [String: Any] {
                pathData["tolerance"] = merged(pathData["tolerance"], ["precision": 7])
                jobs["convertPathData"] = pathData
            }
        }
        if let preservingIDs {
            jobs["cleanupIds"] = merged(jobs["cleanupIds"], ["remove": true, "minify": true, "preserve": preservingIDs])
        }
        optimise["jobs"] = jobs
        // Jobs from a preset ("extends") are left out by their snake_case name.
        let snake = omit.map { $0.replacing(/([a-z])([A-Z])/) { "\($0.1)_\($0.2.lowercased())" }.lowercased() }
        optimise["omit"] = (optimise["omit"] as? [String] ?? []) + snake
        root["optimise"] = optimise
        let url = work.appending(path: "oxvg-config-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }

    /// A job's options with some replaced; a job the configuration doesn't
    /// list stays as it is.
    private static func merged(_ options: Any?, _ changes: [String: Any]) -> Any? {
        guard var options = options as? [String: Any] else { return options }
        options.merge(changes) { _, new in new }
        return options
    }


    // MARK: - HEIC

    /// Lossy mode only (lossless mode never re-encodes): a re-encode that
    /// saves less than 1 % leaves the image as it was.
    static func heif(quality: Int, metadata: MetadataHandling) -> Candidate {
        Candidate(name: "ImageIO", isLossy: true, minimumGain: 0.01, isRequired: metadata != .keep) { input, output, _ in
            guard try HEIFEncoder.recompress(input, to: output, quality: Double(quality) / 100, metadata: metadata) else { return false }
            try MetadataCheck.verify(original: input, result: output, level: metadata)
            return true
        }
    }
}
