import Foundation

public struct ToolError: LocalizedError {
    let tool: String
    let status: Int32
    let message: String
    public var errorDescription: String? {
        message.isEmpty ? "\(tool) failed (\(status))" : "\(tool): \(message)"
    }
}

/// Runs the bundled command line optimizers.
public enum ToolRunner {
    /// Where the optimizers are, if not found automatically.
    nonisolated(unsafe) public static var directory: URL?

    /// The optimizers live in the app bundle's Contents/Helpers, or in a
    /// `just-smaller-tools` folder next to the command line tool. The
    /// JUST_SMALLER_TOOLS environment variable or `directory` override that.
    static func executable(_ name: String) -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            directory,
            ProcessInfo.processInfo.environment["JUST_SMALLER_TOOLS"].map { URL(fileURLWithPath: $0) },
            Bundle.main.bundleURL.appending(components: "Contents", "Helpers"),
            exe.appending(path: "just-smaller-tools"),
            exe,
        ].compactMap { $0 }
        return candidates.map { $0.appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs a tool and waits for it. Cancelling the task terminates the process.
    /// Output goes to files, never to pipes, so a chatty tool cannot block on a
    /// full pipe buffer.
    @discardableResult
    static func run(_ name: String, _ arguments: [String], stdout: URL? = nil, in directory: URL) async throws -> Int32 {
        guard let executable = executable(name) else {
            throw ToolError(tool: name, status: -1, message: String(localized: "The optimizer is missing from the app bundle.", bundle: .module))
        }
        let errURL = directory.appending(path: "\(name)-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.qualityOfService = .utility
        process.standardInput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errURL)
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: stdout)
        } else {
            process.standardOutput = FileHandle.nullDevice
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        if status != 0 {
            let message = (try? String(contentsOf: errURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? ""
            throw ToolError(tool: name, status: status, message: message)
        }
        return status
    }
}
