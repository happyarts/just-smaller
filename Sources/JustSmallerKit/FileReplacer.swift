import Darwin
import Foundation

/// Puts an optimized file in place of the original.
///
/// The swap is atomic: at every moment either the original or the finished
/// result is at the original's path, even if the app crashes or the disk
/// fills up. One exception: in the App Sandbox, a single file the user
/// dropped may be written but nothing may be created next to it, so there is
/// no room for a backup. Then the original goes to the Trash first and the
/// result takes its place right after (see `replaceViaTrash`); in the moment
/// between, the original is safe in the Trash.
///
/// The result takes over the original's permissions, ACL, extended
/// attributes (Finder tags, comments, quarantine) and creation date. The
/// modification date is "now" unless the user wants to keep it.
enum FileReplacer {
    /// `result` may be anywhere and is used up: it is moved onto the
    /// original's volume first, so the swap itself is a rename. Returns where
    /// the original went when it was moved to the Trash.
    static func replace(_ original: URL, with result: URL,
                        moveOriginalToTrash: Bool, keepModificationDate: Bool) throws -> URL? {
        let fm = FileManager.default
        let dates = try FileOptimizer.freshValues(of: original, [.creationDateKey, .contentModificationDateKey])
        // Decided up front, before anything is created next to the original:
        // in the sandbox a single dropped file's folder is off limits, and
        // replaceItemAt would swap the files first and only then fail to
        // create the backup.
        if moveOriginalToTrash, !fm.isWritableFile(atPath: original.deletingLastPathComponent().path) {
            // Staged when the system allows it (the volume's own temporary
            // folder), so a half-copied file never appears under the
            // original's name; otherwise moved over directly.
            let staged = try? stage(result, onVolumeOf: original, as: original.lastPathComponent)
            defer { if let staged { try? fm.removeItem(at: staged.folder) } }
            let source = staged?.file ?? result
            try copyMetadata(from: original, to: source)
            let trashed = try replaceViaTrash(original, with: source)
            restoreDates(dates, on: original, keepModificationDate: keepModificationDate)
            return trashed
        }
        let staged = try stage(result, onVolumeOf: original, as: original.lastPathComponent)
        defer { try? fm.removeItem(at: staged.folder) }
        let replacement = staged.file
        try copyMetadata(from: original, to: replacement)
        let backupName = moveOriginalToTrash ? uniqueBackupName(for: original) : nil
        let resulting: URL?
        do {
            resulting = try fm.replaceItemAt(original, withItemAt: replacement, backupItemName: backupName,
                                             options: backupName == nil ? [.usingNewMetadataOnly]
                                                                        : [.usingNewMetadataOnly, .withoutDeletingBackupItem])
        } catch let error as NSError {
            // If the swap failed half-way, the original may be parked at a
            // temporary location. Put it back.
            if let parked = error.userInfo["NSFileOriginalItemLocationKey"] as? URL,
               !fm.fileExists(atPath: original.path), fm.fileExists(atPath: parked.path) {
                try? fm.moveItem(at: parked, to: original)
            }
            throw error
        }

        restoreDates(dates, on: resulting ?? original, keepModificationDate: keepModificationDate)

        guard let backupName else { return nil }
        let backup = original.deletingLastPathComponent().appending(path: backupName)
        do {
            return try Trash.move(backup)
        } catch {
            // No Trash on this volume (most network shares), or it refused:
            // the replacement is already done, so the original stays next to
            // the result under its backup name rather than being deleted.
            return backup
        }
    }

    /// Moves `file` into a temporary folder on the volume of `place` (an
    /// existing file or folder), named `name`, so the final step there is a
    /// rename. The caller removes `folder`.
    private static func stage(_ file: URL, onVolumeOf place: URL, as name: String) throws -> (folder: URL, file: URL) {
        let fm = FileManager.default
        let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: place, create: true)
        let staged = folder.appending(path: name)
        do {
            try fm.moveItem(at: file, to: staged)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return (folder, staged)
    }

    /// The creation date stays the original's; the modification date is
    /// "now" — the content did change, which backup and sync tools need to
    /// see — unless the user wants to keep it.
    private static func restoreDates(_ dates: URLResourceValues, on url: URL, keepModificationDate: Bool) {
        var restored = URLResourceValues()
        restored.creationDate = dates.creationDate
        restored.contentModificationDate = keepModificationDate ? dates.contentModificationDate : Date()
        var target = url
        try? target.setResourceValues(restored)
    }

    /// replaceItemAt would reset the permissions to the replacement's (0600
    /// for a temporary file), so the original's are copied first and the swap
    /// keeps the replacement's metadata.
    private static func copyMetadata(from original: URL, to replacement: URL) throws {
        if copyfile(original.path, replacement.path, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR)) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// For a single file in the App Sandbox: the original goes to the Trash
    /// under its own name (so Finder's Put Back returns it to where it was),
    /// then the result is moved to its path. If that fails, the original
    /// comes back from the Trash.
    private static func replaceViaTrash(_ original: URL, with replacement: URL) throws -> URL? {
        let fm = FileManager.default
        let trashed = try Trash.move(original)
        do {
            try fm.moveItem(at: replacement, to: original)
        } catch {
            guard let trashed else { throw error }
            // A move across volumes may have left a partial copy; it is ours.
            if fm.fileExists(atPath: original.path) { try? fm.removeItem(at: original) }
            do {
                try fm.moveItem(at: trashed, to: original)
            } catch {
                throw OriginalInTrash(name: trashed.lastPathComponent)
            }
            throw error
        }
        return trashed
    }

    /// The result couldn't take the original's place, and the original
    /// couldn't come back from the Trash either: say where it is.
    struct OriginalInTrash: LocalizedError {
        let name: String
        var errorDescription: String? {
            String(localized: "The optimized file couldn’t be put in place. The original is in the Trash as “\(name)”.", bundle: .module)
        }
    }

    /// Writes an optimized file (used up, like in `replace`) to a new place
    /// and leaves the original untouched. Returns where it went: `target`, or
    /// "name 2.ext" on a drive without a Trash, where an earlier file of that
    /// name can't be moved out of the way. Finder tags and comments carry over. A file already at
    /// `target` (usually an earlier result) goes to the Trash rather than
    /// being overwritten.
    @discardableResult
    static func writeNew(_ result: URL, to target: URL, attributesFrom original: URL) throws -> URL {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Staged on the target's volume, so the final step is a rename and a
        // half-written file never appears under the target's name.
        let (staging, staged) = try stage(result, onVolumeOf: folder, as: target.lastPathComponent)
        defer { try? fm.removeItem(at: staging) }
        _ = copyfile(original.path, staged.path, nil, copyfile_flags_t(COPYFILE_XATTR))
        if fm.fileExists(atPath: target.path) {
            // Another spelling of the original's own path (a case-insensitive
            // volume, a symlinked folder): never trash the original for a copy.
            if isSameFile(target, original) { throw OutputIsOriginal() }
            do {
                try Trash.move(target)
            } catch where Trash.isUnavailable(error) {
                let free = freeName(for: target)
                try fm.moveItem(at: staged, to: free)
                return free
            }
        }
        try fm.moveItem(at: staged, to: target)
        return target
    }

    struct OutputIsOriginal: LocalizedError {
        var errorDescription: String? {
            String(localized: "The output would take the original’s place. Choose another output folder or suffix.", bundle: .module)
        }
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let ia = try? FileOptimizer.freshValues(of: a, key).fileResourceIdentifier,
              let ib = try? FileOptimizer.freshValues(of: b, key).fileResourceIdentifier else { return false }
        return ia.isEqual(ib)
    }

    /// "name 2.ext", "name 3.ext" … — the first that doesn't exist.
    private static func freeName(for url: URL) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        var n = 2
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appending(path: "\(stem) \(n)\(ext)")
            n += 1
        }
        return candidate
    }

    /// The word in "photo (original).jpg", localized, plus the English one:
    /// both mark a kept original that must not be optimized again.
    static var backupLabels: Set<String> {
        ["original", String(localized: "original", bundle: .module, comment: "Suffix for the backup of an optimized file, as in 'photo (original).jpg'").lowercased()]
    }

    /// "photo (original).jpg", or "photo (original 2).jpg" if that is taken.
    private static func uniqueBackupName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let dir = url.deletingLastPathComponent()
        let label = String(localized: "original", bundle: .module, comment: "Suffix for the backup of an optimized file, as in 'photo (original).jpg'")
        var name = "\(stem) (\(label))\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appending(path: name).path) {
            name = "\(stem) (\(label) \(n))\(ext)"
            n += 1
        }
        return name
    }
}
