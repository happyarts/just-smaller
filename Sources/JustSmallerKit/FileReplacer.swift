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
    /// `replacement` must live in the item replacement directory of
    /// `original`, so the swap stays on one volume. Returns where the original
    /// went when it was moved to the Trash.
    static func replace(_ original: URL, with replacement: URL,
                        moveOriginalToTrash: Bool, keepModificationDate: Bool) throws -> URL? {
        let fm = FileManager.default
        let dates = try original.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])

        // replaceItemAt would reset the permissions to the replacement's
        // (0600 for a temporary file), so copy the original's first and tell it
        // to keep the replacement's metadata.
        if copyfile(original.path, replacement.path, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR)) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // Decided up front, not by trying: in the sandbox replaceItemAt swaps
        // the files first and only then fails to create the backup.
        if moveOriginalToTrash, !fm.isWritableFile(atPath: original.deletingLastPathComponent().path) {
            return try replaceViaTrash(original, with: replacement, dates: dates, keepModificationDate: keepModificationDate)
        }
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

        var restored = URLResourceValues()
        restored.creationDate = dates.creationDate
        // copyfile carried the old dates over; the content did change, which
        // backup and sync tools need to see unless asked otherwise.
        restored.contentModificationDate = keepModificationDate ? dates.contentModificationDate : Date()
        var target = resulting ?? original
        try? target.setResourceValues(restored)

        guard let backupName else { return nil }
        let backup = original.deletingLastPathComponent().appending(path: backupName)
        var trashed: NSURL?
        do {
            try fm.trashItem(at: backup, resultingItemURL: &trashed)
            return trashed as URL?
        } catch {
            // No Trash on this volume (e.g. some network shares): the original
            // stays next to the result under its backup name rather than being
            // deleted.
            return backup
        }
    }

    /// For a single file in the App Sandbox: the original goes to the Trash
    /// under its own name (so Finder's Put Back returns it to where it was),
    /// then the result is moved to its path. If that fails, the original
    /// comes back from the Trash.
    private static func replaceViaTrash(_ original: URL, with replacement: URL,
                                        dates: URLResourceValues, keepModificationDate: Bool) throws -> URL? {
        let fm = FileManager.default
        var trashed: NSURL?
        try fm.trashItem(at: original, resultingItemURL: &trashed)
        do {
            try fm.moveItem(at: replacement, to: original)
        } catch {
            guard let trashed = trashed as URL? else { throw error }
            do {
                try fm.moveItem(at: trashed, to: original)
            } catch {
                throw OriginalInTrash(name: trashed.lastPathComponent)
            }
            throw error
        }
        var restored = URLResourceValues()
        restored.creationDate = dates.creationDate
        restored.contentModificationDate = keepModificationDate ? dates.contentModificationDate : Date()
        var target = original
        try? target.setResourceValues(restored)
        return trashed as URL?
    }

    /// The result couldn't take the original's place, and the original
    /// couldn't come back from the Trash either: say where it is.
    struct OriginalInTrash: LocalizedError {
        let name: String
        var errorDescription: String? {
            String(localized: "The optimized file couldn’t be put in place. The original is in the Trash as “\(name)”.", bundle: .module)
        }
    }

    /// Writes an optimized file to a new place and leaves the original
    /// untouched. Finder tags and comments carry over. A file already at
    /// `target` (usually an earlier result) goes to the Trash rather than
    /// being overwritten.
    static func writeNew(_ result: URL, to target: URL, attributesFrom original: URL) throws {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Staged on the target's volume, so the final step is a rename and a
        // half-written file never appears under the target's name.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appending(path: target.lastPathComponent)
        try fm.copyItem(at: result, to: staged)
        _ = copyfile(original.path, staged.path, nil, copyfile_flags_t(COPYFILE_XATTR))
        if fm.fileExists(atPath: target.path) {
            try fm.trashItem(at: target, resultingItemURL: nil)
        }
        try fm.moveItem(at: staged, to: target)
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
