import Foundation

/// Expands dropped folders into the image files they contain.
public enum FolderScanner {
    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "jpe", "gif", "webp", "svg", "heic", "heif"]

    /// Whether a file found in a folder looks like an image Just Smaller handles:
    /// an image extension, not hidden, not inside a package.
    public static func isCandidate(_ url: URL) -> Bool {
        guard extensions.contains(url.pathExtension.lowercased()),
              !url.pathComponents.contains(where: { $0.hasPrefix(".") }) else { return false }
        return !url.deletingLastPathComponent().pathComponents.contains { component in
            ["app", "bundle", "framework", "photoslibrary", "xcassets"].contains((component as NSString).pathExtension.lowercased())
        }
    }

    public struct Found: Sendable {
        public let file: URL
        /// The dropped folder the file was found in, if any.
        public let root: URL?
    }

    /// Files given directly are kept whatever their name (the optimizer checks
    /// their contents); inside folders only files with an image extension are
    /// picked up, and `skip` can exclude more (Just Smaller's own results). Hidden
    /// files and package contents are skipped.
    public static func imageFiles(in urls: [URL], skip: @escaping @Sendable (URL) -> Bool = { _ in false }) async -> [Found] {
        await Task.detached(priority: .userInitiated) { scan(urls, skip: skip) }.value
    }

    private static func scan(_ urls: [URL], skip: (URL) -> Bool) -> [Found] {
        var result: [Found] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isPackage != true else {
                if values?.isRegularFile == true { result.append(Found(file: url, root: nil)) }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            var found: [URL] = []
            for case let file as URL in enumerator
            where extensions.contains(file.pathExtension.lowercased())
                && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && !skip(file) {
                found.append(file)
            }
            result += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .map { Found(file: $0, root: url) }
        }
        return result
    }
}
