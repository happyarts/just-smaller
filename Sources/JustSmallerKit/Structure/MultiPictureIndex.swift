import Foundation

/// The multi-picture index (CIPA DC-007): an APP2 "MPF" segment in which a
/// JPEG's first image lists all images of the file — HDR gain maps, depth
/// and mattes, stereo pairs, previews. Reader and writer; where the images
/// really lie, and what may change, is `JPEGLayout`'s.
enum MultiPictureIndex {
    /// One image the index lists: where it starts (the first at 0) and the
    /// size the index gives it.
    struct Entry: Equatable {
        let start: Int, size: Int
    }

    /// APP2 "MPF\0". Every image has one; the first image's lists them all.
    static func isIndex(_ s: JPEGMarkers.Segment) -> Bool {
        s.marker == 0xE2 && s.payload.has("MPF\0")
    }

    /// The images the index lists, in its order: nil without an index, empty
    /// when it can't be read. `headers` are the first image's, when already
    /// read. Offsets in the index count from its own TIFF header.
    static func read(_ b: ByteView, headers: [JPEGMarkers.Segment]? = nil) -> [Entry]? {
        guard let segments = headers ?? (try? JPEGMarkers.headers(b).segments), let segment = segments.first(where: isIndex) else { return nil }
        guard let list = try? list(segment) else { return [] }
        return (try? (0..<list.count).map { n in
            Entry(start: n == 0 ? 0 : try segment.offset + 8 + list.reader.read(list.at + 16 * n + 8, 4),
                  size: try list.reader.read(list.at + 16 * n + 4, 4))
        }) ?? []
    }

    /// The segment's TIFF block and its list of images (MPEntry, 0xB002):
    /// where the list starts in the block, and how many images it holds —
    /// 16 bytes each: attributes, size, offset (0 for the first), two
    /// dependent-image entries.
    private static func list(_ segment: JPEGMarkers.Segment) throws -> (reader: TIFFReader, at: Int, count: Int) {
        let reader = try TIFFReader(segment.payload.view(from: 4))
        guard let entry = try reader.ifd(at: reader.firstIFD).entries.first(where: { $0.tag == 0xB002 }),
              let value = entry.value, let at = entry.valueOffset, value.count >= 16, value.count % 16 == 0
        else { throw FormatError("multi-picture index") }
        return (reader, at, value.count / 16)
    }

    /// The writer: `first` (the first image, starting at the file's first
    /// byte) with each image's size written into its index, and its start as
    /// it follows from the sizes and the `gaps` after each image. The index
    /// keeps its length, so it is written in place and nothing before it
    /// moves. It must list exactly as many images.
    static func rewritten(_ first: Data, sizes: [Int], gaps: [Int]) throws -> Data {
        let headers = try JPEGMarkers.headers(ByteView(first)).segments
        guard let segment = headers.first(where: isIndex), case let list = try list(segment), list.count == sizes.count, gaps.count == sizes.count
        else { throw FormatError("multi-picture index") }
        let tiff = segment.offset + 8
        var out = first, start = 0
        func write(_ value: Int, at offset: Int) throws {
            guard let v = UInt32(exactly: value) else { throw FormatError("file too large for the index") }
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: v >> (list.reader.bigEndian ? 24 - 8 * $0 : 8 * $0)) }
            out.replaceSubrange(out.startIndex + tiff + offset..<out.startIndex + tiff + offset + 4, with: bytes)
        }
        for n in sizes.indices {
            try write(sizes[n], at: list.at + 16 * n + 4)
            try write(n == 0 ? 0 : start - tiff, at: list.at + 16 * n + 8)
            start += sizes[n] + gaps[n]
        }
        return out
    }

    /// The index segment with the sizes and offsets left out: all the writer
    /// may change. nil without a readable index.
    static func withoutPositions(_ b: ByteView) -> Data? {
        guard let segment = try? JPEGMarkers.headers(b).segments.first(where: isIndex), let list = try? list(segment) else { return nil }
        var out = segment.whole.bytes
        for n in 0..<list.count {
            let field = out.startIndex + 8 + list.at + 16 * n + 4
            out.replaceSubrange(field..<field + 8, with: [UInt8](repeating: 0, count: 8))
        }
        return out
    }
}
