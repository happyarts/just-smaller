import Foundation

/// Finds JPEGs that are more than one picture. HDR gain maps (Apple, Ultra
/// HDR, ISO 21496), motion photos and stereo (MPO) files store a second image
/// or a video after the first image's end, indexed by an "MPF" segment or
/// found by position. jpeg-scan rewrites only the first image and drops the
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

    /// The images a multi-picture index (APP2 "MPF") lists, and where the
    /// last of them ends. nil without a readable index. Offsets in the index
    /// count from its own TIFF header; the first image starts at 0.
    static func indexedImages(_ b: [UInt8]) -> (count: Int, end: Int)? {
        imageIndex(b).map { ($0.starts.count, $0.end) }
    }

    /// Where each indexed image starts (the first at 0), and where the last ends.
    static func imageIndex(_ b: [UInt8]) -> (starts: [Int], end: Int)? {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xDA || marker == 0xD9 { return nil }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { return nil }
            if marker == 0xE2, length >= 16, b[i + 4..<i + 8].elementsEqual(Array("MPF\0".utf8)) {
                return mpEntries(b, tiff: i + 8, segmentEnd: i + 2 + length)
            }
            i += 2 + length
        }
        return nil
    }

    private static func mpEntries(_ b: [UInt8], tiff: Int, segmentEnd: Int) -> (starts: [Int], end: Int)? {
        let bigEndian: Bool
        switch (b[tiff], b[tiff + 1]) {
        case (0x4D, 0x4D): bigEndian = true
        case (0x49, 0x49): bigEndian = false
        default: return nil
        }
        func u16(_ at: Int) -> Int { bigEndian ? Int(b[at]) << 8 | Int(b[at + 1]) : Int(b[at + 1]) << 8 | Int(b[at]) }
        func u32(_ at: Int) -> Int { bigEndian ? u16(at) << 16 | u16(at + 2) : u16(at + 2) << 16 | u16(at) }
        let ifd = tiff + u32(tiff + 4)
        guard ifd + 2 <= segmentEnd else { return nil }
        let n = u16(ifd)
        guard ifd + 2 + n * 12 <= segmentEnd else { return nil }
        for k in 0..<n {
            let e = ifd + 2 + k * 12
            guard u16(e) == 0xB002 else { continue } // MPEntry: 16 bytes per image
            let length = u32(e + 4), start = tiff + u32(e + 8)
            guard length >= 16, length % 16 == 0, start + length <= segmentEnd else { return nil }
            var end = 0, starts: [Int] = []
            for image in 0..<length / 16 {
                let size = u32(start + image * 16 + 4), offset = u32(start + image * 16 + 8)
                starts.append(image == 0 ? 0 : tiff + offset)
                end = max(end, image == 0 ? size : tiff + offset + size)
            }
            return end <= b.count ? (starts, end) : nil
        }
        return nil
    }

    /// Only indexed images follow the first: no motion-photo video or other
    /// trailer that a rewrite of the file could lose.
    static func holdsOnlyIndexedImages(_ b: [UInt8]) -> Bool {
        guard let index = indexedImages(b), index.count > 1 else { return false }
        return !hasData(after: index.end, in: b)
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
    static func hasData(after end: Int, in b: [UInt8]) -> Bool {
        hasData(in: b[min(end, b.count)...])
    }

    static func hasData(in bytes: ArraySlice<UInt8>) -> Bool {
        bytes.contains { $0 != 0x00 && $0 != 0xFF }
    }
}
