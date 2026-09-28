import Foundation

/// Finds JPEGs that are more than one picture. HDR gain maps (Apple, Ultra
/// HDR, ISO 21496), motion photos and stereo (MPO) files store a second image
/// or a video after the first image's end, indexed by an "MPF" segment or
/// found by position. jpegtran rewrites only the first image and drops the
/// rest, and the coefficient check compares only the first image, so such
/// files are left alone.
enum JPEGStructure {
    static func hasSecondaryImage(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return hasSecondaryImage([UInt8](data))
    }

    static func hasSecondaryImage(_ b: [UInt8]) -> Bool {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return false }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return false }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD9 { return hasData(after: i + 2, in: b) } // EOI
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue } // no length
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { return false }
            // APP2 "MPF\0": a multi-picture index.
            if marker == 0xE2, length >= 6, b[i + 4..<i + 8].elementsEqual(Array("MPF\0".utf8)) { return true }
            i += 2 + length
            if marker == 0xDA { i = endOfScan(from: i, in: b) } // SOS: entropy-coded data follows
        }
        return false
    }

    /// The position of the next marker after entropy-coded data: 0xFF
    /// followed by anything but a stuffed zero or a restart marker.
    private static func endOfScan(from start: Int, in b: [UInt8]) -> Int {
        var i = start
        while i + 1 < b.count {
            if b[i] == 0xFF, b[i + 1] != 0x00, !(0xD0...0xD7).contains(b[i + 1]) { return i }
            i += 1
        }
        return b.count
    }

    /// Anything but padding (zeros or 0xFF fill) after the end of the image.
    private static func hasData(after end: Int, in b: [UInt8]) -> Bool {
        b[min(end, b.count)...].contains { $0 != 0x00 && $0 != 0xFF }
    }
}
