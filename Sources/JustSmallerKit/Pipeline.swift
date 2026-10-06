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
    /// JPEG only: the original's parts and what may change in them, read
    /// once. A plain JPEG stays plain through every step (the checks see to
    /// it); any other is read again from each step's input, where gaps may
    /// have gone.
    var jpegLayout: JPEGLayout?
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
            // Every step works image by image along the layout; a plain JPEG
            // is its one image, changed as a whole.
            let layout = facts.jpegLayout
            var stages: [[Candidate]] = []
            // Re-encode only when the original is of higher quality than the
            // target; otherwise re-encoding only adds generation loss and the
            // lossless steps below are all it gets (jpegoptim's rule). And
            // only where the layout lets an image change with loss.
            if s.lossy, layout?.mayChangeWithLoss ?? true, (facts.jpegQuality ?? 100) > s.jpegQuality {
                stages.append([jpegli(quality: s.jpegQuality, layout: layout)])
            }
            stages.append([jpegMetadata(s.metadata, orientation: facts.orientation, layout: layout)])
            stages.append([jpegScan(effort: s.effort, layout: layout)])
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
            // Lossless keeps coordinates to five decimals and transform factors
            // to seven; lossy allows oxvg's (svgo's) approximations such as
            // curves turned into arcs.
            // Each runs with the ids as they are and with generated ids
            // shortened or removed (fewer ids can also mean a bigger file:
            // collapsed groups repeat their attributes on every child). The
            // smallest valid result wins.
            let optimize = [SVGRun.idsKept, .generatedIDsRemoved].map { oxvg(lossless: !s.lossy, metadata: s.metadata, run: $0) }
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

    /// Each image keeps its own orientation.
    static func jpegMetadata(_ level: MetadataHandling, orientation: Int, layout: JPEGLayout?) -> Candidate {
        Candidate(name: String(localized: "Metadata", bundle: .module), isRequired: level != .keep) { input, output, work in
            // Below "keep everything" the images Google's container lists are
            // filtered too, their new lengths written into its directory.
            _ = try await eachImage(of: input, to: output, layout: layout, work: work, level: level,
                                    writingLengths: level != .keep) { from, to, n, lengths in
                let image = try Data(contentsOf: from)
                try JPEGMetadataFilter.filter(image, level: level, orientation: n == 0 ? orientation : FileFacts.orientation(of: image),
                                              itemLengths: lengths).write(to: to)
                return true
            }
            try MetadataCheck.verify(original: input, result: output, level: level)
            return true
        }
    }

    /// Tools/jpeg-scan: finds the progressive scan split that codes this
    /// image's coefficients smallest, and writes it with libjpeg-turbo.
    /// Exit status 3: a JPEG it doesn't handle (12-bit, lossless,
    /// arithmetic); that image stays as it was.
    static func jpegScan(effort: Effort, layout: JPEGLayout?) -> Candidate {
        Candidate(name: "jpeg-scan") { input, output, work in
            // Gaps the metadata step left stay.
            try await eachImage(of: input, to: output, layout: layout, work: work, level: .keep, onlySmaller: true) { from, to, _, _ in
                do {
                    try await ToolRunner.run("jpeg-scan", ["--effort", effort.rawValue, from.path, to.path], in: work)
                } catch let error as ToolError where error.status == 3 {
                    return false
                }
                return true
            }
        }
    }

    /// jpegli (Google, BSD). It drops metadata, so the original's is put back.
    static func jpegli(quality: Int, layout: JPEGLayout?) -> Candidate {
        Candidate(name: "jpegli", isLossy: true) { input, output, work in
            try await eachImage(of: input, to: output, layout: layout, work: work, level: .keep, withLoss: true, onlySmaller: true) { from, to, _, _ in
                let encoded = work.appending(path: "jpegli-\(UUID().uuidString).jpg")
                try await ToolRunner.run("cjpegli", [from.path, encoded.path, "--quality=\(quality)"], in: work)
                try JPEGMetadataFilter.transplant(metadataFrom: Data(contentsOf: from), into: Data(contentsOf: encoded)).write(to: to)
                return true
            }
        }
    }

    /// A step on a JPEG, image by image along its `JPEGLayout` (the
    /// original's; nil counts as plain). A plain JPEG is its one image:
    /// `change` gets the file itself, nothing is copied or read. Otherwise
    /// the input's own layout is read (the images may have moved), and each
    /// image it lets change (`withLoss`: encoded anew) gets a file of its
    /// own; all are changed in parallel and joined again, the multi-picture
    /// index rewritten; the bytes between and after them stay, or go where
    /// the layout lets them at `level`.
    /// `change` writes image `n` changed and returns true, or returns false
    /// to leave it as it was; `onlySmaller` keeps it only when it got
    /// smaller. Returns what `change` returned for a plain JPEG, else true.
    /// `writingLengths`: the images Google's container lists may change too;
    /// they are changed first, and `change` gets their new lengths for the
    /// photo's directory (entry → bytes; empty for every other image).
    private static func eachImage(of input: URL, to output: URL, layout original: JPEGLayout?, work: URL, level: MetadataHandling,
                                  withLoss lossy: Bool = false, onlySmaller: Bool = false, writingLengths: Bool = false,
                                  _ change: @escaping @Sendable (_ from: URL, _ to: URL, _ n: Int, _ lengths: [Int: Int]) async throws -> Bool)
        async throws -> Bool {
        if original?.isPlain ?? true { return try await change(input, output, 0, [:]) }
        let data = try Data(contentsOf: input, options: .alwaysMapped)
        guard let layout = JPEGLayout.read(ByteView(data)), layout.problem == nil else { throw FormatError("JPEG layout") }
        func changed(_ n: Int, _ lengths: [Int: Int]) async throws -> Data {
            let image = data.subdata(in: layout.images[n])
            guard layout.mayChange(image: n, withLoss: lossy, writingLengths: writingLengths) else { return image }
            let id = UUID().uuidString
            let from = work.appending(path: "image\(n)-\(id).jpg"), to = work.appending(path: "image\(n)-\(id)-changed.jpg")
            defer { try? FileManager.default.removeItem(at: from); try? FileManager.default.removeItem(at: to) }
            try image.write(to: from)
            guard try await change(from, to, n, lengths) else { return image }
            let result = try Data(contentsOf: to)
            return !onlySmaller || result.count < image.count ? result : image
        }
        // The photo last when it has to name the others' lengths.
        let photoLast = writingLengths && layout.index == .container
        var images = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for n in layout.images.indices where !(photoLast && n == 0) {
                group.addTask { (n, try await changed(n, [:])) }
            }
            var images = [Data](repeating: Data(), count: layout.images.count)
            for try await (n, image) in group { images[n] = image }
            return images
        }
        if photoLast {
            let lengths = Dictionary(uniqueKeysWithValues: zip(layout.containerEntries, images.dropFirst().map(\.count)))
            images[0] = try await changed(0, lengths)
        }
        try layout.assembled(images, from: data, level: level).write(to: output)
        return true
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
    }

    /// The OXVG optimiser through Tools/svg-tool, which writes to stdout
    /// and never reads a configuration other than the one it is given.
    static func oxvg(lossless: Bool, metadata: MetadataHandling, run: SVGRun) -> Candidate {
        Candidate(name: "OXVG", isLossy: !lossless) { input, output, work in
            let preserve = run == .idsKept ? nil : SVGIDs.toPreserve(in: input)
            // No id to touch: the run keeping them all gives the same result.
            if run == .generatedIDsRemoved, preserve == nil { return false }
            let config = try configuration(lossless: lossless, omitting: jobsKeeping(metadata), preservingIDs: preserve, in: work)
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

    /// A copy of the bundled configuration without the given jobs, and with
    /// ids shortened and removed except `preservingIDs` (nil: every id
    /// stays, as bundled).
    static func configuration(lossless: Bool, omitting metadataJobs: [String], preservingIDs: [String]?,
                              in work: URL) throws -> URL {
        guard let bundled = Bundle.module.url(forResource: lossless ? "oxvg-lossless" : "oxvg-lossy", withExtension: "json"),
              var root = try JSONSerialization.jsonObject(with: Data(contentsOf: bundled)) as? [String: Any],
              var optimise = root["optimise"] as? [String: Any], var jobs = optimise["jobs"] as? [String: Any]
        else { throw ToolError(tool: "svg-tool", status: -1, message: String(localized: "The optimizer is missing from the app bundle.", bundle: .module)) }
        for job in metadataJobs { jobs[job] = nil }
        if let preservingIDs {
            jobs["cleanupIds"] = merged(jobs["cleanupIds"], ["remove": true, "minify": true, "preserve": preservingIDs])
        }
        optimise["jobs"] = jobs
        // Jobs from a preset ("extends") are left out by their snake_case name.
        let snake = metadataJobs.map { $0.replacing(/([a-z])([A-Z])/) { "\($0.1)_\($0.2.lowercased())" }.lowercased() }
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
