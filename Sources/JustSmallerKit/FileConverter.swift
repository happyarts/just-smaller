import Foundation
import OSLog

/// The formats a file can be converted to. A conversion changes the format,
/// so it only ever happens when asked for — never as part of optimizing.
public enum ConversionTarget: String, CaseIterable, Codable, Sendable {
    /// A JPEG into a JPEG XL that holds it without loss: about a fifth
    /// smaller, and the JPEG can be rebuilt from it byte for byte.
    case jxl
    /// A JPEG XL made from a JPEG back into that JPEG.
    case jpeg

    public var pathExtension: String { self == .jxl ? "jxl" : "jpg" }

    /// The file name extensions of what can be converted to this target.
    public var sourceExtensions: Set<String> { self == .jxl ? ["jpg", "jpeg", "jpe"] : ["jxl"] }

    /// Where a file goes by its contents: a JPEG to JPEG XL, a JPEG XL back
    /// to JPEG; nil for anything else. Whether it can is up to `FileConverter`.
    public static func direction(for url: URL) -> ConversionTarget? {
        if ImageFormat.detect(at: url) == .jpeg { return .jxl }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        return JXLContainer.isJXL(ByteView(head)) ? .jpeg : nil
    }
}

private let log = Logger(subsystem: "JustSmallerKit", category: "converter")

/// Converts one file between JPEG and JPEG XL without loss. The JPEG XL holds
/// the JPEG's coefficients and everything needed to rebuild the JPEG; a
/// conversion counts only when that rebuilding gives exactly the JPEG and
/// every viewer shows the same picture (`Verifier.verifyConversion`).
///
/// A JPEG is converted only when a JPEG XL viewer will show all of it: one
/// image, no gain map, depth map, second view or motion photo video — those
/// stay in the file for rebuilding, but no viewer would show them. The
/// metadata level applies as when optimizing; the JPEG XL is made from the
/// filtered JPEG, so rebuilding gives that one. Going back to JPEG gives the
/// JPEG as it was put in, metadata and all.
public struct FileConverter: Sendable {
    public let settings: OptimizationSettings

    public init(settings: OptimizationSettings) { self.settings = settings }

    /// `destination` names the new file (see `OutputPlanner.conversion`).
    /// With `replacesOriginal`, the original goes to the Trash once the new
    /// file is in place (or is deleted, with the command line's --no-trash).
    public func convert(_ url: URL, to target: ConversionTarget, destination: URL, replacesOriginal: Bool,
                        progress: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        let before = try FileOptimizer.freshValues(of: url, [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let size = Int64(before.fileSize ?? 0)
        func unchanged(_ reason: Unchanged.Reason, rejected: [Rejection] = []) -> Outcome {
            // Said of a JPEG only: going back to JPEG gives the JPEG as it was
            // put in, metadata and all.
            let level = target == .jxl && ImageFormat.detect(at: url) == .jpeg ? settings.metadata : .keep
            return .unchanged(Unchanged(reason: reason, size: size, holdsPrivateData: Unchanged.holdsPrivateData(url, reason: reason, level: level),
                                        rejected: rejected))
        }
        guard size > 0 else { return unchanged(.empty) }
        // The output folder may not exist yet: what counts is where it will be made.
        var folder = destination.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder.deleteLastPathComponent() }
        guard FileManager.default.isWritableFile(atPath: folder.path) || (Sandbox.isActive && Sandbox.permitsWriting(folder.path)) else {
            return unchanged(.readOnly)
        }
        if let reason = target == .jxl ? Self.obstacleToJXL(url) : Self.obstacleToJPEG(url) { return unchanged(reason) }

        let (work, source) = try FileOptimizer.workCopy(of: url, named: "source.\(target == .jxl ? "jpg" : "jxl")")
        defer { try? FileManager.default.removeItem(at: work) }
        let result: URL
        switch target {
        case .jxl:
            switch try await toJXL(source, smallerThan: size, work: work, progress: progress) {
            case .converted(let jxl): result = jxl
            case .refused(let reason): return unchanged(reason)
            case .rejected(let rejections): return unchanged(.resultRejected(rejections.last?.reason ?? ""), rejected: rejections)
            }
        case .jpeg:
            progress("jxl-transcode")
            let jpeg = work.appending(path: "rebuilt.jpg")
            do {
                try await ToolRunner.run("jxl-transcode", ["decode", source.path, jpeg.path], in: work)
            } catch let error as ToolError {
                return unchanged(error.status == 4 ? .notConvertible(Self.notFromJPEG) : .damaged(nil))
            }
            do {
                try await Verifier.verifyConversion(jpeg: jpeg, jxl: source, tolerance: .foreign, rebuilt: true)
                try Self.checkJPEG(jpeg)
            } catch let error as VerificationError {
                return unchanged(.resultRejected(error.reason), rejected: [Rejection(error, step: "jxl-transcode")])
            }
            result = jpeg
        }
        try Task.checkCancellation()

        // Don't act on a file someone changed while we were working.
        let now = try FileOptimizer.freshValues(of: url, [.fileSizeKey, .contentModificationDateKey])
        guard now.fileSize == before.fileSize, now.contentModificationDate == before.contentModificationDate else {
            return unchanged(.changedMeanwhile)
        }
        let newSize = Int64((try? result.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0)
        // A file of that name that isn't one of ours (another picture called
        // photo.jxl) is never moved aside: the new file gets a free name.
        var name = OutputClaims.claim(destination, for: url)
        if FileManager.default.fileExists(atPath: name.path) { name = OutputClaims.claim(FileReplacer.freeName(for: name), for: url) }
        // Permissions, ACL and extended attributes as the original's; the
        // creation date stays, the modification date is "now" unless kept.
        try FileReplacer.copyMetadata(from: url, to: result)
        let written = try FileReplacer.writeNew(result, to: name, attributesFrom: url, moveAsideToTrash: settings.moveOriginalsToTrash)
        FileReplacer.restoreDates(before, on: written, keepModificationDate: settings.keepModificationDate)

        // The new file is in place and checked. If the original can't go
        // (no Trash on the volume, a locked file), it stays next to it.
        var trashed: URL?
        if replacesOriginal {
            do {
                if settings.moveOriginalsToTrash { trashed = try Trash.move(url) } else { try FileReplacer.remove(url) }
            } catch {
                log.error("The original stays next to the converted file: \(error.localizedDescription, privacy: .public)")
            }
        }
        return .optimized(originalSize: size, newSize: newSize, tools: ["jxl-transcode"], result: written,
                          trashedOriginal: trashed, fidelity: .pixelIdentical, rejected: [])
    }

    private enum Conversion {
        case converted(URL)
        /// The file can't become a JPEG XL; it stays as it is.
        case refused(Unchanged.Reason)
        /// Each JPEG XL made failed a check.
        case rejected([Rejection])
    }

    /// Only a JPEG XL smaller than the original file (`smallerThan` bytes)
    /// counts: a tiny JPEG can come out larger.
    private func toJXL(_ source: URL, smallerThan limit: Int64, work: URL,
                       progress: @escaping @Sendable (String) -> Void) async throws -> Conversion {
        // The metadata level, as when optimizing: the same filter, checked
        // the same way (coefficients unchanged, only what the level removes
        // gone).
        progress(String(localized: "Metadata", bundle: .module))
        var jpeg = source
        let level = settings.metadata
        let filtered = work.appending(path: "filtered.jpg")
        do {
            let data = try Data(contentsOf: source)
            try JPEGMetadataFilter.filter(data, level: level, orientation: FileFacts.orientation(of: data), itemLengths: [:])
                .write(to: filtered)
            try MetadataCheck.verify(original: source, result: filtered, level: level)
            try await Verifier.verify(original: source, result: filtered, format: .jpeg, pixelsMustMatch: true,
                                      structure: StructureCheck.Reference(original: source, format: .jpeg, level: level))
            jpeg = filtered
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Removing private data is a promise: without it, no conversion.
            if level != .keep {
                let reason = (error as? VerificationError)?.reason ?? error.localizedDescription
                return .refused(.metadataNotFilterable(reason))
            }
        }

        progress("jxl-transcode")
        let candidates = try await Self.encodings(of: jpeg, effort: settings.effort, work: work)
        guard !candidates.isEmpty else {
            return .refused(.notConvertible(String(localized: "This JPEG can’t be stored as JPEG XL without loss (CMYK, arithmetic coding, 12 bits, or too much data after the image)",
                                                   bundle: .module)))
        }
        let smaller = candidates.filter { $0.size < limit }
        guard !smaller.isEmpty else {
            return .refused(.notConvertible(String(localized: "As JPEG XL it wouldn’t be smaller", bundle: .module)))
        }
        progress(String(localized: "Checking", bundle: .module))
        var rejected: [Rejection] = []
        for (jxl, _) in smaller {
            do {
                try await Verifier.verifyConversion(jpeg: jpeg, jxl: jxl, tolerance: .converted)
                try MetadataCheck.verifyConverted(jpeg: jpeg, jxl: jxl)
                return .converted(jxl)
            } catch let error as VerificationError {
                log.fault("JPEG XL rejected: \(error.reason, privacy: .public)")
                rejected.append(Rejection(error, step: "jxl-transcode"))
            }
        }
        return .rejected(rejected)
    }

    /// `jpeg` as JPEG XL, smallest first: effort 7, at Maximum also 9.
    /// Empty when libjxl can't take this JPEG without loss.
    static func encodings(of jpeg: URL, effort: Effort, work: URL) async throws -> [(url: URL, size: Int64)] {
        try await withThrowingTaskGroup(of: (url: URL, size: Int64)?.self) { group in
            for e in effort == .maximum ? [9, 7] : [7] {
                group.addTask {
                    let jxl = work.appending(path: "e\(e)-\(UUID().uuidString).jxl")
                    do {
                        try await ToolRunner.run("jxl-transcode", ["encode", "--effort", "\(e)", jpeg.path, jxl.path], in: work)
                    } catch is ToolError {
                        return nil // a JPEG libjxl can't take without loss, or can't read
                    }
                    return (jxl, Int64((try? jxl.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0))
                }
            }
            var all: [(url: URL, size: Int64)] = []
            for try await candidate in group { if let candidate { all.append(candidate) } }
            return all.sorted { $0.size < $1.size }
        }
    }

    /// Why a JPEG XL made from a JPEG can't be stored anew, or nil: its
    /// JPEG doesn't rebuild (edited since, damaged), holds more than the
    /// photo, or has Content Credentials.
    static func obstacleToRecompressing(_ jxl: URL) async -> Unchanged.Reason? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "JustSmaller-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: work) }
        let rebuilt = work.appending(path: "rebuilt.jpg")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try await ToolRunner.run("jxl-transcode", ["decode", jxl.path, rebuilt.path], in: work)
        } catch {
            return .notSupported(String(localized: "The JPEG in this JPEG XL can’t be rebuilt (damaged, or changed since it was made)", bundle: .module))
        }
        guard let data = try? Data(contentsOf: rebuilt, options: .alwaysMapped),
              let layout = JPEGLayout.read(ByteView(data)), layout.jxlObstacle == nil else {
            return .notSupported(String(localized: "The JPEG in this JPEG XL holds more than the photo (HDR gain map, depth map or video)", bundle: .module))
        }
        if FileOptimizer.hasContentCredentials(rebuilt, format: .jpeg) { return .contentCredentials }
        return nil
    }

    static let notFromJPEG = String(localized: "This JPEG XL wasn’t made from a JPEG, so there is no JPEG to go back to", bundle: .module)

    /// Why `url` can't become a JPEG XL that shows all of it, or nil.
    static func obstacleToJXL(_ url: URL) -> Unchanged.Reason? {
        guard ImageFormat.detect(at: url) == .jpeg else {
            return .notConvertible(String(localized: "Only JPEGs can be converted to JPEG XL", bundle: .module))
        }
        if let damage = FileOptimizer.incompleteness(of: url, format: .jpeg) { return .damaged(damage) }
        guard !FileOptimizer.hasContentCredentials(url, format: .jpeg) else { return .contentCredentials }
        guard let layout = (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap({ JPEGLayout.read(ByteView($0)) }) else {
            return .damaged(nil)
        }
        switch layout.jxlObstacle {
        case .video?:
            return .notConvertible(String(localized: "Motion photo – a JPEG XL viewer would show only the photo, not the video", bundle: .module))
        case .moreImages?:
            return .notConvertible(String(localized: "Holds more than one image (HDR gain map, depth map or a second view) – a JPEG XL viewer would show only the photo",
                                          bundle: .module))
        case .otherData?:
            return .notConvertible(String(localized: "Holds data after the image that a JPEG XL viewer wouldn’t know", bundle: .module))
        case nil:
            return nil
        }
    }

    /// Why `url` can't go back to JPEG, or nil.
    static func obstacleToJPEG(_ url: URL) -> Unchanged.Reason? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), JXLContainer.isJXL(ByteView(data)) else {
            return .notConvertible(String(localized: "Only JPEG XL files can be converted back to JPEG", bundle: .module))
        }
        guard let file = try? JXLContainer.read(ByteView(data)) else { return .damaged(nil) }
        return file.hasReconstructionData ? nil : .notConvertible(notFromJPEG)
    }

    /// A rebuilt JPEG reads cleanly, the strict way, before it is written.
    private static func checkJPEG(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard JPEGLayout.read(ByteView(data)) != nil else {
            throw VerificationError(reason: String(localized: "invalid file structure (JPEG)", bundle: .module))
        }
        try StructureCheck.verify(result: url, against: StructureCheck.Reference(original: url, format: .jpeg))
    }
}
