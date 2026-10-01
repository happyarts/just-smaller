import Foundation
import ImageIO
import OSLog

public enum Outcome: Sendable {
    /// `result` is where the optimized file is: the original's place, or a new file.
    /// `pixelIdentical`: every step was proven to keep every pixel.
    case optimized(originalSize: Int64, newSize: Int64, tools: [String], result: URL, trashedOriginal: URL?,
                   pixelIdentical: Bool)
    /// `copy` is set when an unchanged copy was written to an output folder.
    case alreadyOptimal(size: Int64, copy: URL?)
    /// A smaller result was found but failed verification; the file stays as
    /// it is. `copy` as for `alreadyOptimal`.
    case unchanged(reason: String, size: Int64, copy: URL?)
    case skipped(reason: String, size: Int64?)
}

private let log = Logger(subsystem: "JustSmallerKit", category: "optimizer")

/// Optimizes one file: runs the format's pipeline in a private work
/// directory, verifies every result, and replaces the original only with a
/// verified, smaller file — or one that no longer holds the private data the
/// chosen metadata level removes.
public struct FileOptimizer: Sendable {
    public let settings: OptimizationSettings

    public init(settings: OptimizationSettings) { self.settings = settings }

    public func optimize(_ url: URL, to destination: Destination = .replace,
                  progress: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        let fm = FileManager.default
        let before = try Self.freshValues(of: url, [.fileSizeKey, .contentModificationDateKey, .isWritableKey])
        let size = Int64(before.fileSize ?? 0)

        guard size > 0 else {
            return .skipped(reason: String(localized: "Empty file", bundle: .module), size: 0)
        }
        // Replacing the file needs write access to it and to its folder. In
        // the App Sandbox a single dropped file never has a writable folder;
        // FileReplacer handles that case.
        let folder = url.deletingLastPathComponent().path
        let folderWritable = fm.isWritableFile(atPath: folder) || (Sandbox.isActive && Sandbox.permitsWriting(folder))
        guard destination != .replace || (before.isWritable == true && folderWritable) else {
            return .skipped(reason: String(localized: "The file or its folder is read-only", bundle: .module), size: size)
        }
        guard let format = ImageFormat.detect(at: url) else {
            return .skipped(reason: String(localized: "Not a supported image", bundle: .module), size: size)
        }
        guard settings.isEnabled(format) else {
            return .skipped(reason: String(localized: "\(format.displayName) is turned off in Settings", bundle: .module), size: size)
        }
        guard format == .svg || Self.isComplete(url, format: format) else {
            return .skipped(reason: String(localized: "The file is damaged or incomplete", bundle: .module), size: size)
        }
        guard !Self.hasContentCredentials(url, format: format) else {
            return .skipped(reason: String(localized: "Has Content Credentials (C2PA). Optimizing would invalidate them.", bundle: .module),
                            size: size)
        }
        guard !(format == .png && Self.isAppleCgBI(url)) else {
            return .skipped(reason: String(localized: "Apple’s iPhone PNG variant (CgBI), which only Apple’s tools can read", bundle: .module),
                            size: size)
        }
        // A JPEG with more than one image, or bytes after it, is optimized
        // part by part along its layout — unless the layout says it must
        // stay as it is.
        var jpegHasParts = false
        if format == .jpeg {
            let layout = (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap { JPEGLayout.read(ByteView($0)) }
            switch layout == nil ? .unreadable : layout?.problem {
            case .unreadable:
                return .skipped(reason: String(localized: "The file is damaged or incomplete", bundle: .module), size: size)
            case .video:
                return .skipped(reason: String(localized: "Motion photo (a photo with a video) – left unchanged", bundle: .module), size: size)
            case .unfittingIndex, .unlistedImages:
                return .skipped(reason: String(localized: "Holds images that can’t be read safely – left unchanged", bundle: .module), size: size)
            case nil:
                jpegHasParts = layout?.isPlain == false
            }
        }
        var facts = Self.facts(about: url, format: format, size: size)
        facts.jpegHasParts = jpegHasParts
        // An SVG the rendering can't check still gets re-encoded from UTF-16:
        // that step is proven on the text. Only when all metadata stays,
        // since filtering it needs the rendering check.
        if format == .svg, let reason = SVGContent.uncheckableReason(url) {
            let convertible = facts.isUTF16 && settings.metadata == .keep
                && (try? Data(contentsOf: url)).flatMap(SVGText.utf8) != nil
            guard convertible else {
                return .skipped(reason: String(localized: "\(reason) – left unchanged, it can’t be checked safely", bundle: .module), size: size)
            }
            facts.isUncheckableSVG = true
        }
        let stages = Pipeline.stages(for: format, facts: facts, settings: settings)
        guard !stages.isEmpty else {
            return .skipped(reason: Pipeline.reasonForNoStages(format, facts: facts, settings: settings), size: size)
        }

        let ext = url.pathExtension.isEmpty ? format.rawValue : url.pathExtension
        let (work, source) = try Self.workCopy(of: url, named: "source.\(ext)")
        defer { try? fm.removeItem(at: work) }

        var best = source, bestSize = size, used: [String] = [], lastError: (any Error)?
        // A smaller result that failed verification: the file is not
        // "already optimal", and the list should say why it stayed as it is.
        var rejected: VerificationError?
        // Only formats whose image data is compared exactly can earn the
        // guarantee: pixels for PNG, GIF and WebP, DCT coefficients for JPEG.
        var pixelIdentical = [.png, .gif, .webp, .jpeg, .heic].contains(format)
        // Set when private metadata couldn't be removed as promised: then
        // nothing about the file changes.
        var metadataFailure: String?
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
                            return .failed(error, required: candidate.isRequired)
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
                case .failed(let error, required: true):
                    metadataFailure = (error as? VerificationError)?.reason ?? error.localizedDescription
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
                guard outSize < limit || promised else { continue }
                if structure == nil { structure = StructureCheck.Reference(original: input, format: format, level: settings.metadata) }
                do {
                    // Against this stage's input: after a lossy stage the
                    // following lossless ones must keep the lossy result's pixels.
                    try await Verifier.verify(original: input, result: output, format: format, pixelsMustMatch: !candidate.isLossy,
                                              exactUnderAlpha: !candidate.changesHiddenColour, structure: structure)
                } catch {
                    log.fault("\(candidate.name, privacy: .public) produced a bad result for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    lastError = error
                    if let error = error as? VerificationError { rejected = error }
                    continue
                }
                best = output; bestSize = outSize; used.append(candidate.name)
                if candidate.isLossy { pixelIdentical = false }
                break
            }
        }

        // The whole chain against the original, not just the metadata stage:
        // no later tool may have dropped the rights or brought back what went.
        if best != source, format != .svg, format != .gif {
            do {
                try MetadataCheck.verify(original: source, result: best, level: settings.metadata)
            } catch {
                metadataFailure = (error as? VerificationError)?.reason ?? error.localizedDescription
                best = source
            }
        }

        guard best != source else {
            if metadataFailure == nil, let lastError, used.isEmpty, !(lastError is VerificationError) { throw lastError }
            var copy: URL?
            if case .newFile(let planned, includeUnchanged: true) = destination {
                copy = try FileReplacer.writeNew(source, to: OutputClaims.claim(planned, for: url), attributesFrom: url,
                                                 moveAsideToTrash: settings.moveOriginalsToTrash)
            }
            if let metadataFailure {
                return .unchanged(reason: String(localized: "Unchanged – the metadata couldn’t be filtered safely: \(metadataFailure)", bundle: .module),
                                  size: size, copy: copy)
            }
            if let rejected {
                return .unchanged(reason: String(localized: "Unchanged – result rejected: \(rejected.reason)", bundle: .module),
                                  size: size, copy: copy)
            }
            return .alreadyOptimal(size: size, copy: copy)
        }
        try Task.checkCancellation()

        switch destination {
        case .newFile(let planned, _):
            let target = try FileReplacer.writeNew(best, to: OutputClaims.claim(planned, for: url), attributesFrom: url,
                                                   moveAsideToTrash: settings.moveOriginalsToTrash)
            return .optimized(originalSize: size, newSize: bestSize, tools: used, result: target, trashedOriginal: nil,
                              pixelIdentical: pixelIdentical)
        case .replace:
            // Don't overwrite changes someone made while we were working.
            let now = try Self.freshValues(of: url, [.fileSizeKey, .contentModificationDateKey])
            guard now.fileSize == before.fileSize, now.contentModificationDate == before.contentModificationDate else {
                return .skipped(reason: String(localized: "The file changed while it was being optimized", bundle: .module), size: size)
            }
            let trashed = try FileReplacer.replace(url, with: best, moveOriginalToTrash: settings.moveOriginalsToTrash,
                                                   keepModificationDate: settings.keepModificationDate)
            return .optimized(originalSize: size, newSize: bestSize, tools: used, result: url, trashedOriginal: trashed,
                              pixelIdentical: pixelIdentical)
        }
    }

    private enum Attempt: Sendable {
        case output(Candidate, URL, Int64)
        case failed(any Error, required: Bool)
        case nothing
    }

    // MARK: -

    /// Truncated or corrupt files are left exactly as they are. ImageIO
    /// happily decodes the first part of a truncated PNG, so the container's
    /// end marker is checked as well.
    static func isComplete(_ url: URL, format: ImageFormat) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), hasEndMarker(data, format: format)
        else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    /// C2PA Content Credentials are signed with a hash over the file's bytes,
    /// so any change — even a lossless one — breaks them. Every format embeds
    /// the manifest as a JUMBF box labelled "c2pa" (JPEG APP11, PNG caBX,
    /// WebP C2PA chunk, HEIF uuid box); SVG carries it as base64 in a c2pa
    /// element.
    static func hasContentCredentials(_ url: URL, format: ImageFormat) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        if format == .svg {
            let text = SVGText.encoding(data) == .utf8 ? data : SVGText.utf8(data) ?? data
            return text.range(of: Data("c2pa:manifest".utf8)) != nil
        }
        return data.range(of: Data("jumb".utf8)) != nil && data.range(of: Data("c2pa".utf8)) != nil
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
        case .svg, .heic:
            return true
        }
    }

    /// A private work folder with a copy of the file. On the file's own
    /// volume when it is local (a clone on APFS, and the result moves back
    /// with a rename); on the local disk for network volumes, so intermediate
    /// files never travel over the network — unless the startup disk is full.
    static func workCopy(of url: URL, named name: String) throws -> (work: URL, source: URL) {
        let fm = FileManager.default
        func copy(into work: URL) throws -> (work: URL, source: URL) {
            try fm.copyItem(at: url, to: work.appending(path: name))
            return (work, work.appending(path: name))
        }
        func onVolume() throws -> (work: URL, source: URL) {
            try copy(into: fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true))
        }
        let local = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
        if local { return try onVolume() }
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
        if format == .webp, let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            let chunks = Set(RIFFChunks.webp(ByteView(data)).chunks.map(\.type))
            facts.isLosslessWebP = chunks.contains("VP8L") && !chunks.contains("VP8 ")
            facts.isAnimated = facts.isAnimated || chunks.contains("ANIM")
            facts.hasWebPMetadata = chunks.contains("EXIF") || chunks.contains("XMP ")
        }
        return facts
    }
}
