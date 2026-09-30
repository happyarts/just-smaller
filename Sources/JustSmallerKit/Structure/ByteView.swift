import Foundation

/// A file (or part of one) that isn't what its format says. Every reader
/// throws it; the structure check reports it, the filters treat the part
/// as unreadable.
struct FormatError: Error {
    let detail: String
    init(_ detail: String) { self.detail = detail }

    /// Runs `body`, naming the part a failure is in ("EXIF: truncated data").
    static func within<T>(_ part: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as FormatError {
            throw FormatError("\(part): \(error.detail)")
        }
    }
}

/// Bounds-checked reads over a file's bytes. A result file is untrusted
/// input to the checks: a length or offset that points past the end must
/// reject the file, never stop the app. Every read of a file's structure goes
/// through here, with offsets relative to the start of the view. A view of
/// memory-mapped data reads the file in place, without a copy.
struct ByteView {
    private let data: Data

    init(_ data: Data) { self.data = data }
    init(_ bytes: [UInt8]) { data = Data(bytes) }

    var count: Int { data.count }
    var isEmpty: Bool { data.isEmpty }
    /// The bytes themselves, for comparing, hashing and inflating.
    var bytes: Data { data }

    private func require(_ at: Int, _ length: Int) throws {
        guard at >= 0, length >= 0, at <= count - length else { throw FormatError("truncated data") }
    }

    func u8(_ at: Int) throws -> Int {
        try require(at, 1)
        return Int(data[data.startIndex + at])
    }

    /// An unsigned big-endian number of `length` bytes (at most 8).
    func be(_ at: Int, _ length: Int) throws -> Int {
        try require(at, length)
        let s = data.startIndex + at
        return (0..<length).reduce(0) { $0 << 8 | Int(data[s + $1]) }
    }

    /// An unsigned little-endian number of `length` bytes (at most 8).
    func le(_ at: Int, _ length: Int) throws -> Int {
        try require(at, length)
        let s = data.startIndex + at
        return (0..<length).reduce(0) { $0 | Int(data[s + $1]) << (8 * $1) }
    }

    func view(_ at: Int, _ length: Int) throws -> ByteView {
        try require(at, length)
        let s = data.startIndex + at
        return ByteView(data[s..<s + length])
    }

    func view(from at: Int) throws -> ByteView {
        try view(at, count - at)
    }

    func has(_ prefix: [UInt8], at: Int = 0) -> Bool {
        at >= 0 && at <= count - prefix.count && data[(data.startIndex + at)...].starts(with: prefix)
    }

    func has(_ prefix: String, at: Int = 0) -> Bool { has(Array(prefix.utf8), at: at) }

    /// The next `byte` at or after `from`, or nil.
    func index(of byte: UInt8, from: Int) -> Int? {
        guard from >= 0, from < count else { return nil }
        return data.withUnsafeBytes { p in
            guard let base = p.baseAddress, let hit = memchr(base + from, Int32(byte), p.count - from) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    /// Nothing but padding (zero or 0xFF bytes).
    var isPadding: Bool { data.allSatisfy { $0 == 0 || $0 == 0xFF } }
}
