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
    /// `stderr`, if given, receives the tool's messages and is left for the
    /// caller; otherwise they are only used for the error.
    static func run(_ name: String, _ arguments: [String], stdout: URL? = nil, stderr: URL? = nil,
                    in directory: URL, timeout: Duration = .seconds(3600)) async throws -> Int32 {
        guard let executable = executable(name) else {
            throw ToolError(tool: name, status: -1, message: String(localized: "The optimizer is missing from the app bundle.", bundle: .module))
        }
        let errURL = stderr ?? directory.appending(path: "\(name)-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { if stderr == nil { try? FileManager.default.removeItem(at: errURL) } }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.qualityOfService = .utility
        process.standardInput = FileHandle.nullDevice
        // Closed as soon as the tool is done: some volumes (WebDAV) refuse to
        // delete a file that is still open.
        let errHandle = try FileHandle(forWritingTo: errURL)
        var outHandle: FileHandle?
        defer { try? errHandle.close(); try? outHandle?.close() }
        process.standardError = errHandle
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            outHandle = try FileHandle(forWritingTo: stdout)
            process.standardOutput = outHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
        }

        // Cancellation and the time limit may come before the process has
        // started; the guard makes sure it is stopped either way.
        let guardian = ProcessGuard(process)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            guardian.stop(timedOut: true)
        }
        defer { watchdog.cancel() }
        try Task.checkCancellation()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try guardian.start() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            guardian.stop(timedOut: false)
        }
        try Task.checkCancellation()
        if guardian.timedOut {
            throw ToolError(tool: name, status: status, message: String(localized: "The optimizer took too long and was stopped.", bundle: .module))
        }
        if status != 0 {
            let message = (try? String(contentsOf: errURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? ""
            throw ToolError(tool: name, status: status, message: message)
        }
        return status
    }
}

/// Starts and stops a process from any thread without racing: a stop that
/// comes before the start stops it right after it has started.
private final class ProcessGuard: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var stopped = false
    private(set) var timedOut = false

    init(_ process: Process) { self.process = process }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        try process.run()
        if stopped { process.terminate() }
    }

    func stop(timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if timedOut { self.timedOut = true }
        if process.isRunning { process.terminate() }
    }
}
