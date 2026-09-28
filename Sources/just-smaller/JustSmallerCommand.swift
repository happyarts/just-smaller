import ArgumentParser
import Foundation
import JustSmallerKit

@main
struct JustSmallerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "just-smaller",
        abstract: "Makes images smaller without making them worse.",
        discussion: """
            PNG, JPEG, WebP, SVG and HEIC files are optimized in place; folders are \
            searched for images. Lossless results are proven identical before they \
            replace anything, and replaced originals go to the Trash.
            """,
        version: "2.0")

    @Argument(help: "Images or folders.", completion: .file())
    var paths: [String]

    @Flag(help: "Lossy compression (default: lossless, every pixel stays identical).")
    var lossy = false

    @Option(help: "Quality for lossy compression, 1–100.")
    var quality = 85

    @Flag(help: "Keep all metadata (default: remove private metadata; colour profile and orientation always stay).")
    var keepMetadata = false

    @Option(help: "How long to search for the smallest file: fast, balanced, thorough, maximum.")
    var effort = "balanced"

    @Option(help: "Write results next to the originals, with this suffix added to the name.")
    var suffix: String?

    @Option(help: "Write results into this folder instead of replacing the originals.", completion: .directory)
    var output: String?

    @Flag(help: "Delete replaced originals instead of moving them to the Trash.")
    var noTrash = false

    @Flag(help: "Print one JSON object per file.")
    var json = false

    @Option(help: "Files in parallel (default: twice the number of cores).")
    var jobs: Int?

    @Option(help: "Folder with the optimizer tools (default: next to this program).", completion: .directory)
    var tools: String?

    mutating func validate() throws {
        guard (1...100).contains(quality) else { throw ValidationError("--quality must be between 1 and 100.") }
        guard Effort(rawValue: effort) != nil else { throw ValidationError("--effort must be fast, balanced, thorough or maximum.") }
        guard suffix == nil || output == nil else { throw ValidationError("Use either --suffix or --output.") }
    }

    mutating func run() async throws {
        if let tools { ToolRunner.directory = URL(fileURLWithPath: tools) }

        var settings = OptimizationSettings()
        settings.lossy = lossy
        settings.quality = quality
        settings.metadata = keepMetadata ? .keep : .strip
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
        let found = await FolderScanner.imageFiles(in: paths.map { URL(fileURLWithPath: $0) }) {
            OutputPlanner.isOwnOutput($0, settings: fixed)
        }
        let limit = max(1, jobs ?? 2 * ProcessInfo.processInfo.activeProcessorCount)
        let optimizer = FileOptimizer(settings: fixed)
        let asJSON = json

        var failed = 0, saved: Int64 = 0, total: Int64 = 0
        await withTaskGroup(of: Report.self) { group in
            var pending = found[...]
            func startNext() {
                guard let entry = pending.popFirst() else { return }
                group.addTask {
                    let destination = OutputPlanner.destination(for: entry.file, root: entry.root, settings: fixed)
                    do {
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
                saved += report.saved
                total += report.originalSize
                startNext()
            }
        }
        if !asJSON && total > 0 {
            let percent = Double(saved) / Double(total)
            print("\(found.count == 1 ? "1 file" : "\(found.count) files"), \(saved.formatted(.byteCount(style: .file))) saved (\(percent.formatted(.percent.precision(.fractionLength(1)))))")
        }
        if failed > 0 { throw ExitCode(2) }
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
    var reason: String?

    var saved: Int64 { status == "optimized" ? originalSize - newSize : 0 }

    init(file: URL, outcome: Outcome) {
        self.file = file
        switch outcome {
        case .optimized(let before, let after, let tools, let result, _, let identical):
            (status, originalSize, newSize, self.result, self.tools, self.identical) = ("optimized", before, after, result, tools, identical)
        case .alreadyOptimal(let size, let copy):
            (status, originalSize, newSize, result, identical) = ("unchanged", size, size, copy, true)
        case .unchanged(let reason, let size, let copy):
            (status, originalSize, newSize, result, self.reason) = ("rejected", size, size, copy, reason)
        case .skipped(let reason, let size):
            (status, originalSize, newSize, self.reason) = ("skipped", size ?? 0, size ?? 0, reason)
        }
    }

    init(file: URL, error: String) {
        self.file = file
        reason = error
    }

    var line: String {
        let name = file.lastPathComponent
        switch status {
        case "optimized":
            let percent = (Double(saved) / Double(max(originalSize, 1))).formatted(.percent.precision(.fractionLength(1)))
            return "✓ \(name)  \(originalSize.formatted(.byteCount(style: .file))) → \(newSize.formatted(.byteCount(style: .file)))  −\(percent)  \(tools.joined(separator: " + "))\(identical ? "  (identical)" : "")"
        case "unchanged": return "= \(name)  already optimal"
        case "skipped", "rejected": return "– \(name)  \(reason ?? "")"
        default: return "! \(name)  \(reason ?? "failed")"
        }
    }

    var json: String {
        var object: [String: Any] = ["file": file.path, "status": status, "originalSize": originalSize, "size": newSize,
                                     "saved": saved, "identical": identical, "tools": tools]
        if let result, result != file { object["result"] = result.path }
        if let reason { object["reason"] = reason }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
