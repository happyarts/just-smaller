import Foundation
import ImageIO
import OSLog

private let log = Logger(subsystem: "JustSmallerKit", category: "optimizer")

/// Optimizes one file: runs the format's pipeline in a private work
/// directory, verifies every result, and replaces the original only with a
/// verified, smaller file — or one that no longer holds the private data the
/// chosen metadata level removes.
public struct FileOptimizer: Sendable {
    public let settings: OptimizationSettings
    /// Picks the quality of lossy encodings in lossy mode, instead of
    /// `settings.quality`.
    public let chooser: (any QualityChooser)?

    /// Listed among the steps when a hidden gain map shows again (`JPEGLayout.hidesGainMap`).
    static var repairedHDR: String { String(localized: "HDR marking repaired", bundle: .module) }

    public init(settings: OptimizationSettings, chooser: (any QualityChooser)? = nil) {
        self.settings = settings
        self.chooser = chooser
    }

    public func optimize(_ url: URL, to destination: Destination = .replace,
                  progress: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        let fm = FileManager.default
        let before = try Self.freshValues(of: url, [.fileSizeKey, .contentModificationDateKey, .isWritableKey])
        let size = Int64(before.fileSize ?? 0)
        func unchanged(_ reason: Unchanged.Reason) throws -> Outcome {
            try keep(url, reason, size: size, destination: destination)
        }

        guard size > 0 else { return try unchanged(.empty) }
        guard let format = ImageFormat.detect(at: url) else { return try unchanged(.notAnImage) }
        // Replacing the file needs write access to it and to its folder. In
        // the App Sandbox a single dropped file never has a writable folder;
        // FileReplacer handles that case.
        let folder = url.deletingLastPathComponent().path
        let folderWritable = fm.isWritableFile(atPath: folder) || (Sandbox.isActive && Sandbox.permitsWriting(folder))
        guard destination != .replace || (before.isWritable == true && folderWritable) else { return try unchanged(.readOnly) }
        guard settings.isEnabled(format) else { return try unchanged(.turnedOff(format)) }
        if format != .svg, let damage = Self.incompleteness(of: url, format: format) { return try unchanged(.damaged(damage)) }
        guard !Self.hasContentCredentials(url, format: format) else { return try unchanged(.contentCredentials) }
        guard !(format == .png && Self.isAppleCgBI(url)) else { return try unchanged(.appleCgBI) }
        // A JPEG is optimized image by image along its layout — unless the
        // layout says it must stay as it is.
        var jpegLayout: JPEGLayout?
        if format == .jpeg {
            guard let layout = (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap({ JPEGLayout.read(ByteView($0)) }) else {
                return try unchanged(.damaged(nil))
            }
            switch layout.problem {
            case .video: return try unchanged(.motionPhotoVideo)
            case .unfittingIndex, .unreadableXMP, .unlistedImages: return try unchanged(.unreadableImages)
            case nil: jpegLayout = layout
            }
        }
        var facts = Self.facts(about: url, format: format, size: size)
        facts.jpegLayout = jpegLayout
        // A JPEG XL is stored anew from the JPEG it holds: that JPEG must
        // rebuild and be one a JPEG XL shows in full.
        if format == .jxl, facts.isJPEGInJXL, let reason = await FileConverter.obstacleToRecompressing(url) {
            return try unchanged(reason)
        }
        // An SVG the rendering can't check still gets re-encoded from UTF-16:
        // that step is proven on the text. Only when all metadata stays,
        // since filtering it needs the rendering check.
        if format == .svg, let reason = SVGContent.uncheckableReason(url) {
            let convertible = facts.isUTF16 && settings.metadata == .keep
                && (try? Data(contentsOf: url)).flatMap(SVGText.utf8) != nil
            guard convertible else { return try unchanged(.uncheckable(reason)) }
            facts.isUncheckableSVG = true
        }
        let stages = Pipeline.stages(for: format, facts: facts, settings: settings, chooser: chooser)
        guard !stages.isEmpty else { return try unchanged(.notSupported(Pipeline.reasonForNoStages(format, facts: facts, settings: settings))) }

        let ext = url.pathExtension.isEmpty ? format.rawValue : url.pathExtension
        let (work, source) = try Self.workCopy(of: url, named: "source.\(ext)")
        defer { try? fm.removeItem(at: work) }

        var best = source, bestSize = size, used: [String] = [], lastError: (any Error)?
        // Every result that failed its check, kept when its steps are
        // discarded. The last one counted (see `beforeTrial`) says why the
        // file stayed as it is: it is not "already optimal".
        var rejections: [Rejection] = [], counted = 0
        // A check's finding: listed when it judged a result, and returned as
        // the reason in words.
        func record(_ error: any Error, step: String) -> String {
            guard let error = error as? VerificationError else { return error.localizedDescription }
            rejections.append(Rejection(error, step: step))
            counted = rejections.count
            return error.reason
        }
        // The best result before the first lossy step: what stays when a
        // chosen encoding fails its last check. Set while the result holds a
        // lossy step.
        var beforeLoss: (best: URL, size: Int64, used: [String])?
        // Set while the result holds a step that changed the colour under
        // fully transparent pixels.
        var clearedHiddenColour = false
        // Set when private metadata couldn't be removed as promised: then
        // nothing about the file changes.
        var metadataFailure: String?
        // Before a step judged on the finished file: the state to go back to,
        // and the size the finished file must stay below. What the discarded
        // steps ran into goes with them.
        var beforeTrial: (best: URL, size: Int64, used: [String], clearedHiddenColour: Bool,
                          beforeLoss: (best: URL, size: Int64, used: [String])?,
                          counted: Int, lastError: (any Error)?, limit: Int64)?
        stages: for (n, stage) in stages.enumerated() {
            try Task.checkCancellation()
            var shown = Set<String>()
            progress(stage.map(\.name).filter { shown.insert($0).inserted }.joined(separator: ", "))
            let input = best
            let attempts = await withTaskGroup(of: Attempt.self) { group in
                for (k, candidate) in stage.enumerated() {
                    group.addTask {
                        let output = work.appending(path: "stage\(n)-\(k).\(ext)")
                        do {
                            guard try await candidate.run(input, output, work) else { return .nothing }
                            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                            return size > 0 ? .output(candidate, output, Int64(size)) : .nothing
                        } catch is CancellationError {
                            return .nothing
                        } catch {
                            log.error("\(candidate.name, privacy: .public) failed on \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
                            return .failed(error, candidate)
                        }
                    }
                }
                var all: [Attempt] = []
                for await attempt in group { all.append(attempt) }
                return all
            }
            var results: [(Candidate, URL, Int64)] = []
            for attempt in attempts {
                switch attempt {
                case .output(let candidate, let output, let size): results.append((candidate, output, size))
                case .failed(let error, let candidate) where candidate.isRequired:
                    metadataFailure = record(error, step: candidate.name)
                    best = source
                    break stages
                case .failed(let error, _): lastError = error
                case .nothing: break
                }
            }
            results.sort { $0.2 < $1.2 }
            // Read once, for the first candidate that gets verified.
            var structure: StructureCheck.Reference?
            lazy var hasFieldsToRemove = MetadataCheck.hasFieldsToRemove(input, level: settings.metadata)
            for (candidate, output, outSize) in results {
                let limit = candidate.minimumGain > 0 ? Int64(Double(bestSize) * (1 - candidate.minimumGain)) : bestSize
                // Removing private data is a promise, not an optimization: it
                // counts even when the file grows (ImageIO writes metadata
                // less compactly), as long as there was something to remove.
                let promised = candidate.isRequired && hasFieldsToRemove
                guard outSize < limit || promised || candidate.judgedFinished else { continue }
                if structure == nil { structure = StructureCheck.Reference(original: input, format: format, level: settings.metadata) }
                let keptHiddenColour: Bool
                do {
                    // Against this stage's input: after a lossy stage the
                    // following lossless ones must keep the lossy result's pixels.
                    keptHiddenColour = try await Verifier.verify(original: input, result: output, format: format, pixelsMustMatch: !candidate.isLossy,
                                              exactUnderAlpha: !candidate.changesHiddenColour, structure: structure)
                } catch {
                    log.fault("\(candidate.name, privacy: .public) produced a bad result for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    lastError = error
                    let reason = record(error, step: candidate.name)
                    // The promise can't be kept: say why here, rather than
                    // let later stages work on the unfiltered file.
                    if promised {
                        metadataFailure = reason
                        best = source
                        break stages
                    }
                    continue
                }
                if candidate.judgedFinished { beforeTrial = (best, bestSize, used, clearedHiddenColour, beforeLoss, counted, lastError, limit) }
                if candidate.isLossy, beforeLoss == nil { beforeLoss = (best, bestSize, used) }
                if !keptHiddenColour { clearedHiddenColour = true }
                best = output; bestSize = outSize; used.append(candidate.name)
                break
            }
        }
        if let trial = beforeTrial, best != source, bestSize >= trial.limit {
            (best, bestSize, used, clearedHiddenColour, beforeLoss) = (trial.best, trial.size, trial.used, trial.clearedHiddenColour, trial.beforeLoss)
            (counted, lastError) = (trial.counted, trial.lastError)
        }

        // A chosen encoding is measured once more, as the finished file. If
        // it fails, the result without loss stays.
        if let lossless = beforeLoss, let chooser, chooser.formats.contains(format) {
            do {
                try await chooser.verify(original: source, result: best, format: format, work: work)
            } catch {
                try Task.checkCancellation()
                log.fault("The chosen encoding of \(url.lastPathComponent, privacy: .private) failed its check: \(error.localizedDescription, privacy: .public)")
                (best, bestSize, used) = lossless
                beforeLoss = nil
            }
        }
        // The whole chain against the original, not just the metadata stage:
        // no later tool may have dropped the rights or brought back what went.
        if best != source, format != .svg, format != .gif {
            do {
                try MetadataCheck.verify(original: source, result: best, level: settings.metadata)
            } catch {
                metadataFailure = record(error, step: used.joined(separator: " + "))
                best = source
            }
        }

        guard best != source else {
            // Nothing came of it: when the original itself isn't sound, that
            // is the reason, not what a tool or a check said about it.
            let damage = lastError != nil || metadataFailure != nil ? await Verifier.damage(of: source, format: format) : nil
            if damage == nil, metadataFailure == nil, let lastError, used.isEmpty, !(lastError is VerificationError) { throw lastError }
            let reason: Unchanged.Reason = if let damage { .damaged(damage) }
                else if let metadataFailure { .metadataNotFilterable(metadataFailure) }
                else if counted > 0 { .resultRejected(rejections[counted - 1].reason) }
                else { .alreadyOptimal }
            return try keep(url, reason, size: size, destination: destination, from: source, rejected: rejections)
        }
        try Task.checkCancellation()
        // Listed like a step: the gain map the original hid shows everywhere
        // now, ImageIO too (it may have found it before by other means).
        if let layout = jpegLayout, layout.hidesGainMap, let result = try? Data(contentsOf: best, options: .alwaysMapped),
           layout.showsGainMap(in: ByteView(result)), let a = CGImageSourceCreateWithURL(source as CFURL, nil),
           let b = CGImageSourceCreateWithData(result as CFData, nil), AuxiliaryImages.all(b).count > AuxiliaryImages.all(a).count {
            used.append(Self.repairedHDR)
        }

        // Only formats whose image data is compared exactly earn the guarantee.
        let fidelity: Fidelity = beforeLoss != nil ? .lossy : clearedHiddenColour ? .visiblyIdentical
            : Verifier.comparesExactly(format) ? .pixelIdentical : .lossless
        switch destination {
        case .newFile(let planned, _):
            let target = try FileReplacer.writeNew(best, to: OutputClaims.claim(planned, for: url), attributesFrom: url,
                                                   moveAsideToTrash: settings.moveOriginalsToTrash)
            return .optimized(originalSize: size, newSize: bestSize, tools: used, result: target, trashedOriginal: nil,
                              fidelity: fidelity, rejected: rejections)
        case .replace:
            // Don't overwrite changes someone made while we were working.
            let now = try Self.freshValues(of: url, [.fileSizeKey, .contentModificationDateKey])
            guard now.fileSize == before.fileSize, now.contentModificationDate == before.contentModificationDate else {
                return try keep(url, .changedMeanwhile, size: size, destination: destination, rejected: rejections)
            }
            let trashed = try FileReplacer.replace(url, with: best, moveOriginalToTrash: settings.moveOriginalsToTrash,
                                                   keepModificationDate: settings.keepModificationDate)
            return .optimized(originalSize: size, newSize: bestSize, tools: used, result: url, trashedOriginal: trashed,
                              fidelity: fidelity, rejected: rejections)
        }
    }

    /// The file stays as it is. When the reason says it belongs in an
    /// output folder, an unchanged copy goes there: of `file`, the copy from
    /// before the work (used up), or else of the original.
    private func keep(_ url: URL, _ reason: Unchanged.Reason, size: Int64, destination: Destination,
                      from file: URL? = nil, rejected: [Rejection] = []) throws -> Outcome {
        let holdsPrivateData = Unchanged.holdsPrivateData(file ?? url, reason: reason, level: settings.metadata)
        var copy: URL?
        if reason.belongsInOutputFolder, case .newFile(let planned, includeUnchanged: true) = destination {
            func write(_ source: URL) throws -> URL {
                try FileReplacer.writeNew(source, to: OutputClaims.claim(planned, for: url), attributesFrom: url,
                                          moveAsideToTrash: settings.moveOriginalsToTrash)
            }
            if let file {
                copy = try write(file)
            } else {
                let (work, source) = try Self.workCopy(of: url, named: url.lastPathComponent)
                defer { try? FileManager.default.removeItem(at: work) }
                copy = try write(source)
            }
        }
        return .unchanged(Unchanged(reason: reason, size: size, copy: copy, holdsPrivateData: holdsPrivateData, rejected: rejected))
    }

    private enum Attempt: Sendable {
        case output(Candidate, URL, Int64)
        case failed(any Error, Candidate)
        case nothing
    }

    // MARK: -

    /// Why a file is truncated or corrupt, or nil when it reads to its end.
    /// Such files are left exactly as they are. ImageIO happily decodes the
    /// first part of a truncated PNG, so the container's end marker is
    /// checked as well.
    static func incompleteness(of url: URL, format: ImageFormat) -> String? {
        let unreadable = String(localized: "unreadable", bundle: .module)
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return unreadable }
        guard hasEndMarker(data, format: format) else {
            return format == .webp ? String(localized: "truncated", bundle: .module) : String(localized: "no end marker", bundle: .module)
        }
        // From the file, as other apps open it: ImageIO takes the name's
        // extension as a hint (an .mpo is read as MPO, not as plain JPEG).
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return unreadable }
        for status in [CGImageSourceGetStatus(source), CGImageSourceGetStatusAtIndex(source, 0)] where status != .statusComplete {
            return status == .statusIncomplete || status == .statusUnexpectedEOF ? String(localized: "truncated", bundle: .module) : unreadable
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) == nil ? unreadable : nil
    }

    /// C2PA Content Credentials are signed with a hash over the file's bytes,
    /// so any change — even a lossless one — breaks them. Every format embeds
    /// the manifest as a JUMBF box labelled "c2pa" (JPEG APP11, PNG caBX,
    /// WebP C2PA chunk, HEIF uuid box); SVG carries it as base64 in a c2pa
    /// element.
    static func hasContentCredentials(_ url: URL, format: ImageFormat) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        func holdsManifest(_ d: Data) -> Bool { d.range(of: Data("jumb".utf8)) != nil && d.range(of: Data("c2pa".utf8)) != nil }
        if format == .svg {
            let text = SVGText.encoding(data) == .utf8 ? data : SVGText.utf8(data) ?? data
            return text.range(of: Data("c2pa:manifest".utf8)) != nil
        }
        // Where the format keeps it — a JPEG's APP11, elsewhere among its
        // metadata (PNG's caBX, WebP's C2PA chunk, a HEIF uuid box) — never in
        // image data: there (and in Base64 depth data) the words turn up by chance.
        if format == .jpeg, let headers = try? JPEGMarkers.headers(ByteView(data)).segments {
            return headers.contains { $0.marker == 0xEB && holdsManifest($0.payload.bytes) }
        }
        // A JPEG XL keeps it in a JUMBF box labelled "c2pa" (one made from a
        // JPEG with Content Credentials keeps the JPEG's in its reconstruction
        // data: the recompression looks at the rebuilt JPEG).
        if format == .jxl {
            return (try? JXLContainer.read(ByteView(data)))?.jumbf.contains { $0.range(of: Data("c2pa".utf8)) != nil } ?? false
        }
        return MetadataRegions.of(data).contains(where: holdsManifest)
    }

    /// Xcode's "compressed PNG" for iOS apps puts a CgBI chunk before IHDR and
    /// stores pixels in a form other PNG tools can't read.
    static func isAppleCgBI(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        return head.count == 16 && head.suffix(4) == Data("CgBI".utf8)
    }

    static func hasEndMarker(_ data: Data, format: ImageFormat) -> Bool {
        let tail = data.suffix(64)
        switch format {
        case .png:
            return tail.range(of: Data("IEND".utf8)) != nil
        case .jpeg:
            // Some cameras append data after the image, so look for the end of
            // image marker anywhere after the start of scan.
            return data.range(of: Data([0xFF, 0xD9]), options: .backwards) != nil
        case .gif:
            return tail.contains(0x3B)
        case .webp:
            guard data.count >= 12 else { return false }
            let size = data.subdata(in: 4..<8).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
            return data.count >= size + 8
        case .svg, .heic, .jxl:
            return true
        }
    }

    /// A private work folder with a copy of the file. On the file's own
    /// volume when it can clone files (APFS: the copy takes no space, and the
    /// result moves back with a rename); otherwise on the startup disk, so
    /// intermediate files never travel over the network or fill a memory
    /// card — unless the startup disk is full.
    static func workCopy(of url: URL, named name: String) throws -> (work: URL, source: URL) {
        let fm = FileManager.default
        func copy(into work: URL) throws -> (work: URL, source: URL) {
            try fm.copyItem(at: url, to: work.appending(path: name))
            return (work, work.appending(path: name))
        }
        func onVolume() throws -> (work: URL, source: URL) {
            try copy(into: fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true))
        }
        let volume = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeSupportsFileCloningKey])
        if volume?.volumeIsLocal ?? true, volume?.volumeSupportsFileCloning ?? true { return try onVolume() }
        let temp = fm.temporaryDirectory.appending(path: "JustSmaller-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            return try copy(into: temp)
        } catch where isOutOfSpace(error) {
            try? fm.removeItem(at: temp)
            return try onVolume()
        }
    }

    private static func isOutOfSpace(_ error: any Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
    }

    /// A URL keeps the resource values it has read; the same URL asked again
    /// later would report the old size and date. These are read afresh.
    static func freshValues(of url: URL, _ keys: Set<URLResourceKey>) throws -> URLResourceValues {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: keys)
    }

    static func facts(about url: URL, format: ImageFormat, size: Int64) -> FileFacts {
        var facts = FileFacts(byteSize: size)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            facts.isAnimated = CGImageSourceGetCount(source) > 1
            facts.orientation = FileFacts.orientation(of: source)
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                facts.bitsPerComponent = props[kCGImagePropertyDepth] as? Int ?? 8
            }
        }
        if format == .jpeg, let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            facts.jpegQuality = JPEGQuality.estimate(data)
        }
        if format == .svg, let data = try? Data(contentsOf: url, options: .alwaysMapped), SVGText.encoding(data) != .utf8 {
            facts.isUTF16 = true
        }
        if format == .jxl, let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            facts.isJPEGInJXL = (try? JXLContainer.read(ByteView(data)))?.hasReconstructionData ?? false
        }
        if format == .webp, let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            let chunks = Set(RIFFChunks.webp(ByteView(data)).chunks.map(\.type))
            facts.isLosslessWebP = chunks.contains("VP8L") && !chunks.contains("VP8 ")
            facts.isAnimated = facts.isAnimated || chunks.contains("ANIM")
            facts.hasWebPMetadata = chunks.contains("EXIF") || chunks.contains("XMP ")
        }
        return facts
    }
}
