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
        while i < b.count {
            let s = try JPEGMarkers.segment(at: i, in: b)
            if s.marker == 0xD9 { return try !b.view(from: s.end).isPadding } // EOI: anything after it?
            // APP2 "MPF\0": a multi-picture index.
            if s.marker == 0xE2, s.payload.has("MPF\0") { return true }
            i = s.marker == 0xDA ? JPEGMarkers.entropyData(from: s.end, in: b).end : s.end
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
        guard let index = try JPEGMarkers.headers(b).segments.first(where: { $0.marker == 0xE2 && $0.payload.has("MPF\0") })
        else { return nil }
        return try entries(TIFFReader(index.payload.view(from: 4)), tiff: index.offset + 8, fileSize: b.count)
    }

    /// MPEntry (0xB002): 16 bytes per image — attributes, size, offset
    /// (0 for the first), two dependent-image entries.
    private static func entries(_ r: TIFFReader, tiff: Int, fileSize: Int) throws -> (starts: [Int], end: Int)? {
        guard let list = try r.ifd(at: r.firstIFD).entries.first(where: { $0.tag == 0xB002 })?.value,
              list.count >= 16, list.count % 16 == 0
        else { return nil }
        func read(_ at: Int) throws -> Int { try r.bigEndian ? list.be(at, 4) : list.le(at, 4) }
        var end = 0, starts: [Int] = []
        for image in 0..<list.count / 16 {
            let size = try read(image * 16 + 4), offset = try read(image * 16 + 8)
            starts.append(image == 0 ? 0 : tiff + offset)
            end = max(end, image == 0 ? size : tiff + offset + size)
        }
        return end <= fileSize ? (starts, end) : nil
    }

    /// Only indexed images follow the first: no motion-photo video or other
    /// trailer that a rewrite of the file could lose.
    static func holdsOnlyIndexedImages(_ b: ByteView) -> Bool {
        guard let index = imageIndex(b), index.starts.count > 1, let rest = try? b.view(from: index.end) else { return false }
        return rest.isPadding
    }
}
