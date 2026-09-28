import Darwin
import Foundation

/// What the App Sandbox changes for file access, in one place for the engine
/// and the app.
public enum Sandbox {
    public static let isActive = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// Whether the folder's own permissions allow writing, ignoring the
    /// sandbox (which answers "no" for the folder of every single dropped file).
    public static func permitsWriting(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        if info.st_uid == getuid() { return info.st_mode & S_IWUSR != 0 }
        if info.st_gid == getgid() { return info.st_mode & S_IWGRP != 0 }
        return info.st_mode & S_IWOTH != 0
    }

    /// The user's real home folder. Inside the sandbox, FileManager's home,
    /// Desktop and Pictures point into the app's container instead.
    public static var realHome: URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
