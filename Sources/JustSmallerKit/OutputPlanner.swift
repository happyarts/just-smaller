import Foundation

/// Where the optimized version of a file goes.
public enum Destination: Equatable, Sendable {
    /// In place of the original.
    case replace
    /// A new file; the original stays untouched. `includeUnchanged` also
    /// copies files that were already optimal, so an output folder ends up
    /// complete.
    case newFile(URL, includeUnchanged: Bool)

    /// The folder a new file is created in, which must be writable; nil
    /// when the original is replaced.
    public var createdIn: URL? {
        if case .newFile(let target, _) = self { target.deletingLastPathComponent() } else { nil }
    }

    /// The folder that must be writable to write the result for `file`.
    /// Replacing a file only needs the file itself — except on a network
    /// volume: without a Trash there, the original is kept next to the result.
    public func folderNeeded(for file: URL) -> URL? {
        if let createdIn { return createdIn }
        let local = (try? file.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
        return local ? nil : file.deletingLastPathComponent()
    }
}

/// Output names claimed by the files of this process, so two different
/// originals never write to the same result (e.g. two "IMG_1.jpg" from
/// different folders into one output folder). The same original writing again
/// gets its earlier name back.
enum OutputClaims {
    nonisolated(unsafe) private static var owners: [String: String] = [:]
    private static let lock = NSLock()

    /// `target`, or "name 2.ext", "name 3.ext" … if another original has it.
    static func claim(_ target: URL, for original: URL) -> URL {
        lock.lock(); defer { lock.unlock() }
        let owner = original.standardizedFileURL.path
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension.isEmpty ? "" : "." + target.pathExtension
        var candidate = target, n = 2
        while let other = owners[candidate.path.lowercased()], other != owner {
            candidate = target.deletingLastPathComponent().appending(path: "\(stem) \(n)\(ext)")
            n += 1
        }
        owners[candidate.path.lowercased()] = owner
        return candidate
    }
}

public enum OutputPlanner {
    /// `root` is the dropped folder the file was found in. Its name and
    /// subfolders are mirrored in the output folder, so files from different
    /// folders don't collide.
    public static func destination(for file: URL, root: URL?, settings: OptimizationSettings) -> Destination {
        switch settings.output {
        case .replace:
            return .replace
        case .suffix:
            let stem = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            let name = ext.isEmpty ? stem + settings.suffix : "\(stem)\(settings.suffix).\(ext)"
            return .newFile(file.deletingLastPathComponent().appending(path: name), includeUnchanged: false)
        case .folder:
            var relative = file.lastPathComponent
            if let root {
                let rootPath = root.standardizedFileURL.path
                let filePath = file.standardizedFileURL.path
                if filePath.hasPrefix(rootPath + "/") {
                    relative = root.lastPathComponent + "/" + filePath.dropFirst(rootPath.count + 1)
                }
            }
            let target = URL(fileURLWithPath: settings.outputFolder, isDirectory: true).appending(path: relative)
            // An output folder that is the file's own folder means: replace.
            return target.standardizedFileURL == file.standardizedFileURL
                ? .replace : .newFile(target, includeUnchanged: true)
        }
    }

    /// Whether a file found while scanning a folder is one of Just Smaller's own
    /// results, which must not be optimized a second time.
    public static func isOwnOutput(_ file: URL, settings: OptimizationSettings) -> Bool {
        let modes = [settings.outputLossless, settings.outputLossy]
        if modes.contains(.suffix), file.deletingPathExtension().lastPathComponent.hasSuffix(settings.suffix) {
            return true
        }
        if modes.contains(.folder) {
            let folder = URL(fileURLWithPath: settings.outputFolder).standardizedFileURL.path + "/"
            if file.standardizedFileURL.path.hasPrefix(folder) { return true }
        }
        return false
    }
}
