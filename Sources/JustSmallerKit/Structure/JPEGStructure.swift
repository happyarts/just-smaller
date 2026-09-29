import Foundation

/// Finds JPEGs that are more than one picture. HDR gain maps (Apple, Ultra
/// HDR, ISO 21496), motion photos and stereo (MPO) files store a second image
/// or a video after the first image's end, indexed by an "MPF" segment or
/// found by position. jpeg-scan rewrites only the first image and drops the
/// rest, and the coefficient check compares only the first image, so such
/// files get only their metadata filtered. Reads through ByteView; a file it
/// can't read counts as a single image.
enum JPEGStructure {
    static func hasSecondaryImage(_ b: ByteView) -> Bool {
        (try? secondaryImage(b)) ?? false
    }

    private static func secondaryImage(_ b: ByteView) throws -> Bool {
        guard try b.be(0, 2) == 0xFFD8 else { return false }
        var i = 2
        while i + 4 <= b.count {
            guard try b.u8(i) == 0xFF else { return false }
            let marker = try b.u8(i + 1)
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD9 { return try !b.view(from: i + 2).isPadding } // EOI
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue } // no length
            let length = try b.be(i + 2, 2)
            guard length >= 2 else { return false }
            // APP2 "MPF\0": a multi-picture index.
            if marker == 0xE2, b.has("MPF\0", at: i + 4) { return true }
            i += 2 + length
            if marker == 0xDA { i = endOfScan(from: i, in: b) } // SOS: entropy-coded data follows
        }
        return false
    }

    /// Where each image a multi-picture index (APP2 "MPF") lists starts (the
    /// first at 0), and where the last of them ends. nil without a readable
    /// index. Offsets in the index count from its own TIFF header.
    static func imageIndex(_ b: ByteView) -> (starts: [Int], end: Int)? {
        try? findIndex(b)
    }

    private static func findIndex(_ b: ByteView) throws -> (starts: [Int], end: Int)? {
        guard try b.be(0, 2) == 0xFFD8 else { return nil }
        var i = 2
        while try b.u8(i) == 0xFF {
            let marker = try b.u8(i + 1)
            if marker == 0xFF { i += 1; continue }
            if marker == 0xDA || marker == 0xD9 { return nil }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = try b.be(i + 2, 2)
            guard length >= 2 else { return nil }
            if marker == 0xE2, b.has("MPF\0", at: i + 4) {
                return try entries(TIFFReader(b.view(i + 8, length - 6)), tiff: i + 8, fileSize: b.count)
            }
            i += 2 + length
        }
        return nil
    }

    private static func entries(_ r: TIFFReader, tiff: Int, fileSize: Int) throws -> (starts: [Int], end: Int)? {
        let ifd = try r.firstIFD
        for k in 0..<(try r.read(ifd, 2)) {
            let e = ifd + 2 + k * 12
            guard try r.read(e, 2) == 0xB002 else { continue } // MPEntry: 16 bytes per image
            let length = try r.read(e + 4, 4), start = try r.read(e + 8, 4)
            guard length >= 16, length % 16 == 0 else { return nil }
            var end = 0, starts: [Int] = []
            for image in 0..<length / 16 {
                let size = try r.read(start + image * 16 + 4, 4), offset = try r.read(start + image * 16 + 8, 4)
                starts.append(image == 0 ? 0 : tiff + offset)
                end = max(end, image == 0 ? size : tiff + offset + size)
            }
            return end <= fileSize ? (starts, end) : nil
        }
        return nil
    }

    /// Only indexed images follow the first: no motion-photo video or other
    /// trailer that a rewrite of the file could lose.
    static func holdsOnlyIndexedImages(_ b: ByteView) -> Bool {
        guard let index = imageIndex(b), index.starts.count > 1, let rest = try? b.view(from: index.end) else { return false }
        return rest.isPadding
    }

    /// The position of the next marker after entropy-coded data: 0xFF
    /// followed by anything but a stuffed zero or a restart marker.
    private static func endOfScan(from start: Int, in b: ByteView) -> Int {
        var i = start
        while let next = b.index(of: 0xFF, from: i), let m = try? b.u8(next + 1) {
            if m != 0x00, !(0xD0...0xD7).contains(m) { return next }
            i = next + 1
        }
        return b.count
    }
}
