import Foundation

/// Moves files to the Trash. Everything Just Smaller puts in the Trash goes
/// through here, so tests can keep the user's Trash out of it.
public enum Trash {
    /// Tests only: items go into this folder instead of the user's Trash,
    /// each in a subfolder of its own so names stay as they were. The app and
    /// the command line tool never set it.
    nonisolated(unsafe) public static var testFolder: URL?

    /// Moves `url` to the Trash and returns where it ended up.
    @discardableResult
    public static func move(_ url: URL) throws -> URL? {
        let fm = FileManager.default
        guard let testFolder else {
            var trashed: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &trashed)
            return trashed as URL?
        }
        let folder = testFolder.appending(path: UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let trashed = folder.appending(path: url.lastPathComponent)
        try fm.moveItem(at: url, to: trashed)
        return trashed
    }
}
