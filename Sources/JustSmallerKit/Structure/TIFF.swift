import Foundation

/// The one way the engine reads TIFF structures: EXIF blocks (JPEG APP1,
/// PNG eXIf, WebP EXIF) and JPEG's multi-picture index. The EXIF filter
/// reads leniently, the structure check strictly.
struct TIFFReader {
    struct Entry {
        let tag: Int, type: Int, count: Int
        /// The value's bytes: in the entry up to four bytes, otherwise where
        /// its offset points. nil for an unknown type or a value outside the block.
        let value: ByteView?
        /// Where the value starts in the block, for writing it in place.
        let valueOffset: Int?
    }

    /// Bytes per value of each TIFF type (1–13).
    static let sizes: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
    static let exifPointer = 0x8769, gpsPointer = 0x8825, interopPointer = 0xA005
    /// Tags whose value is the offset of another IFD.
    static let ifdPointers: Set<Int> = [exifPointer, gpsPointer, interopPointer]

    let view: ByteView
    let bigEndian: Bool

    init(_ view: ByteView) throws {
        self.init(view, bigEndian: try Self.byteOrder(view, at: 0))
        guard try read(2, 2) == 42 else { throw FormatError("TIFF header") }
    }

    /// IFDs without a TIFF header, such as a maker note's; offsets count
    /// from the start of `view`.
    init(_ view: ByteView, bigEndian: Bool) {
        self.view = view
        self.bigEndian = bigEndian
    }

    /// "MM" (big-endian) or "II" at `at`.
    static func byteOrder(_ view: ByteView, at: Int) throws -> Bool {
        switch try view.be(at, 2) {
        case 0x4D4D: true
        case 0x4949: false
        default: throw FormatError("byte order")
        }
    }

    func read(_ at: Int, _ length: Int) throws -> Int { try bigEndian ? view.be(at, length) : view.le(at, length) }
    var firstIFD: Int { get throws { try read(4, 4) } }

    /// The entries of the IFD at `offset`, and the offset of the next IFD
    /// (0: none; nil when the block ends before it).
    func ifd(at offset: Int) throws -> (entries: [Entry], next: Int?) {
        guard offset >= 8 else { throw FormatError("IFD offset") }
        let n = try read(offset, 2)
        var entries: [Entry] = []
        for k in 0..<n {
            let at = offset + 2 + 12 * k
            let tag = try read(at, 2), type = try read(at + 2, 2), count = try read(at + 4, 4)
            var value: ByteView?, valueOffset: Int?
            if let size = Self.sizes[type], let offset = size * count > 4 ? try? read(at + 8, 4) : at + 8 {
                value = try? view.view(offset, size * count)
                valueOffset = value == nil ? nil : offset
            }
            entries.append(Entry(tag: tag, type: type, count: count, value: value, valueOffset: valueOffset))
        }
        return (entries, try? read(offset + 2 + 12 * n, 4))
    }

    /// A single SHORT, LONG or IFD value as a number.
    func number(_ entry: Entry) -> Int? {
        guard entry.count == 1, [3, 4, 13].contains(entry.type), let value = entry.value else { return nil }
        return try? bigEndian ? value.be(0, value.count) : value.le(0, value.count)
    }

    /// Where an IFD pointer (LONG or IFD type) points.
    func pointer(_ entry: Entry) -> Int? {
        [4, 13].contains(entry.type) ? number(entry) : nil
    }
}
