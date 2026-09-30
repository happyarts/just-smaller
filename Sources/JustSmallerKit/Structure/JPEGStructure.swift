import Foundation

/// Finds JPEGs that are more than one picture. HDR gain maps (Apple, Ultra
/// HDR, ISO 21496), depth and mattes of portraits, and stereo (MPO) files
/// store more images after the first image's end, indexed by an "MPF"
/// segment; motion photos store a video there. jpeg-scan and the
/// coefficient check see only one image, so such a file is taken apart
/// into its images (`images`), each is optimized and checked on its own, and
/// they are joined again with the index rewritten (`joined`); whatever lies
/// between and after them stays byte for byte. Reads through ByteView; a
/// file it can't read counts as a single image.
enum JPEGStructure {
    /// A multi-picture index, or anything but padding after the first
    /// image's end.
    static func hasSecondaryImage(_ b: ByteView) -> Bool {
        if (try? JPEGMarkers.headers(b))?.segments.contains(where: isIndex) == true { return true }
        guard let end = try? imageEnd(b, from: 0), let rest = try? b.view(from: end) else { return false }
        return !rest.isPadding
    }

    /// APP2 "MPF\0": a multi-picture index (CIPA DC-007). Every image has
    /// one; the first image's also lists all images.
    private static func isIndex(_ s: JPEGMarkers.Segment) -> Bool {
        s.marker == 0xE2 && s.payload.has("MPF\0")
    }

    /// One image the index lists: where it starts (the first at 0) and the
    /// size the index gives it.
    struct IndexEntry: Equatable {
        let start: Int, size: Int
    }

    /// The images the multi-picture index lists, in its order; nil without
    /// a readable index. Offsets in the index count from its own TIFF header.
    static func imageIndex(_ b: ByteView) -> [IndexEntry]? {
        try? findIndex(b)
    }

    /// The index segment, and its list of images (MPEntry, 0xB002): 16 bytes
    /// per image — attributes, size, offset (0 for the first), two
    /// dependent-image entries.
    /// Where the index's TIFF header is, its byte order, the list, and where
    /// the list starts after the TIFF header.
    private static func indexList(_ b: ByteView) throws -> (tiff: Int, bigEndian: Bool, list: ByteView, at: Int)? {
        guard let index = try JPEGMarkers.headers(b).segments.first(where: isIndex) else { return nil }
        let reader = try TIFFReader(index.payload.view(from: 4))
        guard let entry = try reader.ifd(at: reader.firstIFD).entries.first(where: { $0.tag == 0xB002 }),
              let list = entry.value, let at = entry.valueOffset, list.count >= 16, list.count % 16 == 0
        else { return nil }
        return (index.offset + 8, reader.bigEndian, list, at)
    }

    private static func findIndex(_ b: ByteView) throws -> [IndexEntry]? {
        guard let (tiff, bigEndian, value, _) = try indexList(b) else { return nil }
        func read(_ at: Int) throws -> Int { try bigEndian ? value.be(at, 4) : value.le(at, 4) }
        return try (0..<value.count / 16).map { image in
            IndexEntry(start: image == 0 ? 0 : try tiff + read(image * 16 + 8), size: try read(image * 16 + 4))
        }
    }

    /// Where each image the index lists lies, read from the images
    /// themselves: each a JPEG from its SOI to its EOI, in the index's order.
    /// The sizes the index gives are not needed (some writers get the first
    /// one wrong), and cameras leave leftover bytes between and after the
    /// images (`gaps`). nil for a single image, or an index that doesn't fit
    /// the file.
    static func images(_ b: ByteView) -> [Range<Int>]? {
        try? findImages(b)
    }

    private static func findImages(_ b: ByteView) throws -> [Range<Int>]? {
        guard let index = try findIndex(b), index.count > 1 else { return nil }
        var images: [Range<Int>] = [], end = 0
        for entry in index {
            guard entry.start >= end else { return nil }
            let image = entry.start..<(try imageEnd(b, from: entry.start))
            images.append(image)
            end = image.upperBound
        }
        return images
    }

    /// What lies after each image up to the next one, and after the last one
    /// up to the end of the file.
    static func gaps(_ images: [Range<Int>], count: Int) -> [Range<Int>] {
        images.indices.map { images[$0].upperBound..<(images.indices.contains($0 + 1) ? images[$0 + 1].lowerBound : count) }
    }

    /// A motion photo: a video lies after the images. Google says so in the
    /// first image's XMP (GCamera:MotionPhoto or MicroVideo set to 1, as an
    /// attribute or an element); Samsung's trailer has its own signatures,
    /// and an MP4 file starts with an ftyp box.
    static func holdsVideo(_ b: ByteView, images: [Range<Int>]) -> Bool {
        let marks = ["MotionPhoto=\"1\"", "MotionPhoto>1<", "MicroVideo=\"1\"", "MicroVideo>1<"].map { Data($0.utf8) }
        let xmp = (try? JPEGMarkers.headers(b))?.segments.contains { s in
            [.xmp, .extendedXMP].contains(JPEGMarkers.part(s.marker, payload: s.payload.bytes))
                && marks.contains { s.payload.bytes.range(of: $0) != nil }
        } ?? false
        let trailer = (try? b.view(from: images.last?.upperBound ?? b.count))?.bytes ?? Data()
        return xmp || trailer.prefix(64).range(of: Data("ftyp".utf8)) != nil
            || ["MotionPhoto_Data", "SEFT"].contains { trailer.range(of: Data($0.utf8)) != nil }
    }

    /// Where the JPEG that starts at `start` ends: after its EOI.
    private static func imageEnd(_ b: ByteView, from start: Int) throws -> Int {
        guard try b.be(start, 2) == 0xFFD8 else { throw FormatError("no SOI") }
        var i = start + 2
        while true {
            let s = try JPEGMarkers.segment(at: i, in: b)
            if s.marker == 0xD9 { return s.end }
            i = s.marker == 0xDA ? JPEGMarkers.entropyData(from: s.end, in: b).end : s.end
        }
    }

    /// The writer next to `imageIndex`: `images` one after another, each
    /// followed by its gap as it was, and the index in the first rewritten to
    /// their sizes and offsets. The index keeps its length, so it is written
    /// in place and nothing before it moves. The index must list exactly
    /// these images.
    static func joined(_ images: [Data], gaps: [Data]? = nil) throws -> Data {
        let gaps = gaps ?? images.map { _ in Data() }
        guard let first = images.first, gaps.count == images.count else { throw FormatError("no image") }
        var out = first
        guard let (tiff, bigEndian, list, at) = try indexList(ByteView(first)), list.count == 16 * images.count
        else { throw FormatError("multi-picture index") }
        func write(_ value: Int, at offset: Int) throws {
            guard let v = UInt32(exactly: value) else { throw FormatError("file too large for the index") }
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: v >> (bigEndian ? 24 - 8 * $0 : 8 * $0)) }
            out.replaceSubrange(out.startIndex + offset..<out.startIndex + offset + 4, with: bytes)
        }
        var start = 0
        for (n, image) in images.enumerated() {
            try write(image.count, at: tiff + at + 16 * n + 4)
            try write(n == 0 ? 0 : start - tiff, at: tiff + at + 16 * n + 8)
            start += image.count + gaps[n].count
        }
        out.append(gaps[0])
        for (image, gap) in zip(images, gaps).dropFirst() { out.append(image + gap) }
        return out
    }

    /// Google's container (Ultra HDR, motion photos) also lists the lengths
    /// of the images after the first, in the first one's XMP. Those images
    /// must then stay as they are.
    static func listsLengthsInXMP(_ image: ByteView) -> Bool {
        let container = Data("http://ns.google.com/photos/1.0/container/".utf8)
        return (try? JPEGMarkers.headers(image))?.segments.contains {
            [.xmp, .extendedXMP].contains(JPEGMarkers.part($0.marker, payload: $0.payload.bytes))
                && $0.payload.bytes.range(of: container) != nil
        } ?? false
    }

    /// The first image's index segment with the sizes and offsets left out:
    /// all the writer may change. nil without a readable index.
    static func indexWithoutPositions(_ b: ByteView) -> Data? {
        guard let segment = try? JPEGMarkers.headers(b).segments.first(where: isIndex),
              let (tiff, _, list, at) = try? indexList(b) else { return nil }
        var out = segment.whole.bytes
        for n in 0..<list.count / 16 {
            let field = out.startIndex + tiff - segment.offset + at + 16 * n + 4
            out.replaceSubrange(field..<field + 8, with: [UInt8](repeating: 0, count: 8))
        }
        return out
    }

    /// The images of `original` and of `result`, pair by pair (the first
    /// included); nil when neither holds several. Throws when they don't
    /// hold as many.
    static func imagePairs(_ original: Data, _ result: Data) throws -> [(original: Data, result: Data)]? {
        let a = images(ByteView(original)), b = images(ByteView(result))
        if a == nil, b == nil { return nil }
        guard let a, let b, a.count == b.count else { throw FormatError("images lost") }
        return zip(a, b).map { (original.subdata(in: $0), result.subdata(in: $1)) }
    }
}
