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
    /// What a tool prints goes to files, never to pipes this process would
    /// have to drain, so a chatty tool cannot block on a full pipe buffer.
    /// `stderr`, if given, receives the tool's messages and is left for the
    /// caller; otherwise they are only used for the error.
    public static func run(_ name: String, _ arguments: [String], stdout: URL? = nil, stderr: URL? = nil,
                           in directory: URL, timeout: Duration = .seconds(3600)) async throws {
        try await run([(name, arguments)], stdout: stdout, stderr: stderr, in: directory, timeout: timeout)
    }

    /// Runs `name` with its standard output piped into `next`, and waits for
    /// both: what passes between them is never written to a disk. When both
    /// fail, the error is the first one's (the second only lacked its input);
    /// so `next` must read all its input before it may fail on its own.
    static func run(_ name: String, _ arguments: [String], into next: String, _ nextArguments: [String],
                    stdout: URL? = nil, in directory: URL, timeout: Duration = .seconds(3600)) async throws {
        try await run([(name, arguments), (next, nextArguments)], stdout: stdout, stderr: nil, in: directory, timeout: timeout)
    }

    /// Each tool's standard output is the next one's standard input; the
    /// last one's goes to `stdout`, and `stderr` takes its messages.
    private static func run(_ tools: [(name: String, arguments: [String])], stdout: URL?, stderr: URL?,
                            in directory: URL, timeout: Duration) async throws {
        let fm = FileManager.default
        let errURLs = tools.indices.map { i in
            (i == tools.count - 1 ? stderr : nil) ?? directory.appending(path: "\(tools[i].name)-\(UUID().uuidString).stderr")
        }
        defer { for url in errURLs where url != stderr { try? fm.removeItem(at: url) } }

        var processes: [Process] = []
        // Closed as soon as the tools are done: some volumes (WebDAV) refuse to
        // delete a file that is still open.
        var handles: [FileHandle] = []
        defer { for handle in handles { try? handle.close() } }
        var input: Any = FileHandle.nullDevice
        for (i, tool) in tools.enumerated() {
            guard let executable = executable(tool.name) else {
                throw ToolError(tool: tool.name, status: -1, message: String(localized: "The optimizer is missing from the app bundle.", bundle: .module))
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = tool.arguments
            process.currentDirectoryURL = directory
            process.qualityOfService = .utility
            process.standardInput = input
            fm.createFile(atPath: errURLs[i].path, contents: nil)
            let errHandle = try FileHandle(forWritingTo: errURLs[i])
            handles.append(errHandle)
            process.standardError = errHandle
            if i < tools.count - 1 {
                // Process closes this side's ends of the pipe once the tools
                // have started, so a tool that ends early leaves the next one
                // at the end of its input.
                let pipe = Pipe()
                process.standardOutput = pipe
                input = pipe
            } else if let stdout {
                fm.createFile(atPath: stdout.path, contents: nil)
                let outHandle = try FileHandle(forWritingTo: stdout)
                handles.append(outHandle)
                process.standardOutput = outHandle
            } else {
                process.standardOutput = FileHandle.nullDevice
            }
            processes.append(process)
        }

        // Cancellation and the time limit may come before the processes have
        // started; the guard makes sure they are stopped either way.
        let guardian = ProcessGuard(processes)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            guardian.stop(timedOut: true)
        }
        defer { watchdog.cancel() }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(count: processes.count, continuation)
                for process in processes { process.terminationHandler = { _ in waiter.finished() } }
                do {
                    try guardian.start()
                } catch {
                    waiter.failed(error)
                }
            }
        } onCancel: {
            guardian.stop(timedOut: false)
        }
        try Task.checkCancellation()
        let statuses = processes.map(\.terminationStatus)
        if guardian.timedOut {
            throw ToolError(tool: tools[0].name, status: statuses[0],
                            message: String(localized: "The optimizer took too long and was stopped.", bundle: .module))
        }
        if let i = statuses.firstIndex(where: { $0 != 0 }) {
            let message = (try? String(contentsOf: errURLs[i], encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? ""
            throw ToolError(tool: tools[i].name, status: statuses[i], message: message)
        }
    }
}

/// Resumes once: when all processes have ended, or starting them failed.
private final class Waiter: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Int
    private var continuation: CheckedContinuation<Void, any Error>?

    init(count: Int, _ continuation: CheckedContinuation<Void, any Error>) {
        running = count
        self.continuation = continuation
    }

    func finished() {
        lock.lock(); defer { lock.unlock() }
        running -= 1
        guard running == 0 else { return }
        continuation?.resume()
        continuation = nil
    }

    func failed(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Starts and stops processes from any thread without racing: a stop that
/// comes before the start stops them right after they have started. If one
/// can't start, those already running are stopped.
private final class ProcessGuard: @unchecked Sendable {
    private let processes: [Process]
    private let lock = NSLock()
    private var stopped = false
    private(set) var timedOut = false

    init(_ processes: [Process]) { self.processes = processes }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        for (i, process) in processes.enumerated() {
            do {
                try process.run()
            } catch {
                for started in processes[..<i] { started.terminate() }
                throw error
            }
        }
        if stopped { for process in processes { process.terminate() } }
    }

    func stop(timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if timedOut { self.timedOut = true }
        for process in processes where process.isRunning { process.terminate() }
    }
}
