import ArgumentParser
import Foundation
import JustSmallerKit

@main
struct JustSmallerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "just-smaller",
        abstract: "Makes images smaller without making them worse.",
        discussion: """
            PNG, JPEG, WebP, SVG, HEIC and JPEG XL files are optimized in place; folders are \
            searched for images. Lossless results are proven identical before they \
            replace anything, and replaced originals go to the Trash.

            With --to jxl, JPEGs are converted to JPEG XL instead, without loss: the \
            JPEG can be rebuilt from it byte for byte, which --to jpeg does.
            """,
        version: "2.0")

    @Argument(help: "Images or folders.", completion: .file())
    var paths: [String]

    @Flag(help: "Lossy compression (default: lossless, every pixel stays identical).")
    var lossy = false

    @Option(help: "Quality for lossy compression, 1–100.")
    var quality = 85

    @Option(help: """
        Which metadata stays: keep (everything), private (default: removes location, serial numbers, \
        persons shown, editing history), copyright (only creator and rights) or none. \
        Colour profile, orientation and resolution always stay.
        """)
    var metadata = MetadataHandling.removePrivate.rawValue

    @Option(help: "How long to search for the smallest file: fast, balanced, thorough, maximum.")
    var effort = "balanced"

    @Option(help: """
        Convert instead of optimizing: jxl turns JPEGs into JPEG XL without loss (photo.jpg → photo.jxl); \
        jpeg turns such a JPEG XL back into the JPEG it was made from.
        """)
    var to: String?

    @Option(help: "Write results next to the originals, with this suffix added to the name.")
    var suffix: String?

    @Option(help: "Write results into this folder instead of replacing the originals.", completion: .directory)
    var output: String?

    @Flag(help: "Delete replaced originals instead of moving them to the Trash.")
    var noTrash = false

    @Flag(help: "Print one JSON object per file.")
    var json = false

    @Option(help: "Files in parallel (default: twice the number of cores, at most one per GB of memory).")
    var jobs: Int?

    @Option(help: "Folder with the optimizer tools (default: next to this program).", completion: .directory)
    var tools: String?

    mutating func validate() throws {
        guard (1...100).contains(quality) else { throw ValidationError("--quality must be between 1 and 100.") }
        guard Effort(rawValue: effort) != nil else { throw ValidationError("--effort must be fast, balanced, thorough or maximum.") }
        guard MetadataHandling(rawValue: metadata) != nil else { throw ValidationError("--metadata must be keep, private, copyright or none.") }
        guard to.map({ ConversionTarget(rawValue: $0) != nil }) ?? true else { throw ValidationError("--to must be jxl or jpeg.") }
        guard to == nil || !lossy else { throw ValidationError("--to converts without loss; it can't be combined with --lossy.") }
        guard suffix == nil || output == nil else { throw ValidationError("Use either --suffix or --output.") }
        if let suffix {
            // An empty suffix would make "next to the original" mean "over it".
            guard !suffix.trimmingCharacters(in: .whitespaces).isEmpty, !suffix.contains("/") else {
                throw ValidationError("--suffix must not be empty or contain \"/\".")
            }
        }
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else { throw ValidationError("Not found: \(missing.joined(separator: ", "))") }
    }

    mutating func run() async throws {
        if let tools { ToolRunner.directory = URL(fileURLWithPath: tools) }

        var settings = OptimizationSettings()
        settings.lossy = lossy
        settings.quality = quality
        settings.metadata = MetadataHandling(rawValue: metadata) ?? .removePrivate
        settings.effort = Effort(rawValue: effort) ?? .balanced
        settings.moveOriginalsToTrash = !noTrash
        if let suffix {
            (settings.outputLossless, settings.outputLossy, settings.suffix) = (.suffix, .suffix, suffix)
        }
        if let output {
            (settings.outputLossless, settings.outputLossy) = (.folder, .folder)
            settings.outputFolder = URL(fileURLWithPath: output).standardizedFileURL.path
        }
        let fixed = settings
        // A file given twice, or given and also inside a given folder, is
        // optimized once.
        var seen = Set<String>()
        let conversion = to.flatMap(ConversionTarget.init(rawValue:))
        let found = await FolderScanner.imageFiles(in: paths.map { URL(fileURLWithPath: $0) },
                                                   extensions: conversion?.sourceExtensions ?? FolderScanner.extensions) {
            OutputPlanner.isOwnOutput($0, settings: fixed)
        }.filter { seen.insert($0.file.standardizedFileURL.path.lowercased()).inserted }
        // As in the app: twice the cores, but at most one file per GB of memory.
        let gigabytes = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        let limit = max(1, jobs ?? min(2 * ProcessInfo.processInfo.activeProcessorCount, max(2, gigabytes)))
        let optimizer = FileOptimizer(settings: fixed)
        let converter = FileConverter(settings: fixed)
        let asJSON = json

        var failed = 0, skipped = 0, saved: Int64 = 0, total: Int64 = 0
        await withTaskGroup(of: Report.self) { group in
            var pending = found[...]
            func startNext() {
                guard let entry = pending.popFirst() else { return }
                group.addTask {
                    do {
                        if let conversion {
                            let (target, replaces) = OutputPlanner.conversion(for: entry.file, root: entry.root, settings: fixed, to: conversion)
                            return Report(file: entry.file, outcome: try await converter.convert(entry.file, to: conversion, destination: target,
                                                                                                replacesOriginal: replaces) { _ in })
                        }
                        let destination = OutputPlanner.destination(for: entry.file, root: entry.root, settings: fixed)
                        return Report(file: entry.file, outcome: try await optimizer.optimize(entry.file, to: destination) { _ in })
                    } catch {
                        return Report(file: entry.file, error: error.localizedDescription)
                    }
                }
            }
            for _ in 0..<limit { startNext() }
            for await report in group {
                print(asJSON ? report.json : report.line)
                if report.status == "failed" { failed += 1 }
                if report.status == "unchanged" && report.reason != "alreadyOptimal" { skipped += 1 }
                saved += report.saved
                if report.status == "optimized" || report.reason == "alreadyOptimal" { total += report.originalSize }
                startNext()
            }
        }
        if !asJSON && total > 0 {
            let percent = Double(saved) / Double(total)
            print("\(found.count == 1 ? "1 file" : "\(found.count) files"), \(saved.formatted(.byteCount(style: .file))) saved (\(percent.formatted(.percent.precision(.fractionLength(1)))))")
        }
        // 0: all fine, 1: some files left unchanged for a reason other than being optimal, 2: errors.
        if failed > 0 { throw ExitCode(2) }
        if skipped > 0 { throw ExitCode(1) }
    }
}

/// One line of output per file.
struct Report: Sendable {
    let file: URL
    var status = "failed"
    var originalSize: Int64 = 0
    var newSize: Int64 = 0
    var result: URL?
    var tools: [String] = []
    var identical = false
    /// A lossy step is part of the result.
    var lossy = false
    /// Why the file stays as it is (`Unchanged.Reason.code`), or nil.
    var reason: String?
    /// Which kind of not supported or not convertible, or nil.
    var kind: String?
    /// The reason or the error, in words.
    var message: String?
    var holdsPrivateData: Bool?
    var rejected: [Rejection] = []

    var saved: Int64 { status == "optimized" ? originalSize - newSize : 0 }

    init(file: URL, outcome: Outcome) {
        self.file = file
        switch outcome {
        case .optimized(let before, let after, let tools, let result, _, let fidelity, let rejected):
            (status, originalSize, newSize, self.result, self.tools) = ("optimized", before, after, result, tools)
            (identical, lossy, self.rejected) = (fidelity == .pixelIdentical, fidelity == .lossy, rejected)
        case .unchanged(let kept):
            (status, originalSize, newSize, result) = ("unchanged", kept.size, kept.size, kept.copy)
            (reason, kind, message) = (kept.reason.code, kept.reason.kind, kept.reason.description)
            (holdsPrivateData, rejected) = (kept.holdsPrivateData, kept.rejected)
            identical = kept.reason == .alreadyOptimal
        }
    }

    init(file: URL, error: String) {
        self.file = file
        message = error
    }

    var line: String {
        let name = file.lastPathComponent
        switch status {
        case "optimized":
            // A file grows only when private metadata had to go.
            let percent = (Double(abs(saved)) / Double(max(originalSize, 1))).formatted(.percent.precision(.fractionLength(1)))
            return "✓ \(name)  \(originalSize.formatted(.byteCount(style: .file))) → \(newSize.formatted(.byteCount(style: .file)))  \(saved < 0 ? "+" : "−")\(percent)  \(tools.joined(separator: " + "))\(identical ? "  (identical)" : "")"
        case "unchanged":
            let note = holdsPrivateData == true ? "  (private data stays in)" : ""
            return reason == "alreadyOptimal" ? "= \(name)  already optimal\(note)" : "– \(name)  \(message ?? "")\(note)"
        default: return "! \(name)  \(message ?? "failed")"
        }
    }

    var json: String {
        var object: [String: Any] = ["file": file.path, "status": status, "originalSize": originalSize, "size": newSize,
                                     "saved": saved, "identical": identical, "lossy": lossy, "tools": tools]
        if let result, result != file { object["result"] = result.path }
        if let reason { object["reason"] = reason }
        if let kind { object["kind"] = kind }
        if let message { object["message"] = message }
        if let holdsPrivateData { object["privateData"] = holdsPrivateData }
        if !rejected.isEmpty {
            object["rejected"] = rejected.map { ["step": $0.step, "reason": $0.reason, "pixelsChanged": $0.pixelsChanged] as [String: Any] }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
