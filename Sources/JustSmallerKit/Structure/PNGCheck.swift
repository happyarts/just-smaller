import Foundation

/// PNG after its specification: every chunk's CRC, IHDR's fields, the chunk
/// order rules, the image data inflated to exactly the bytes the header asks
/// for (every row's filter byte valid, Adler-32 right), the same for each
/// APNG frame, and the text, EXIF and XMP a step rewrote.
enum PNGCheck {
    typealias Invalid = FormatError

    /// What the original contributes, read leniently: its ancillary chunks
    /// and colour profile.
    struct Reference {
        let chunks: ChunkSet
        let profile: Data?

        init(_ a: ByteView) {
            let all = ((try? PNGChunks.read(a, strict: false)) ?? []).filter { !PNGChunks.isCritical($0) }
            chunks = ChunkSet(all)
            profile = all.first { $0.type == "iCCP" }.flatMap { try? PNGChunks.text($0).content }
        }
    }


    /// Chunks the tools rewrite as part of their job: palette and colour
    /// reductions touch the colour-type dependent ones, the metadata filter
    /// the text and EXIF chunks, APNG optimization the frame control. All
    /// other ancillary chunks must be the original's.
    private static let rewritten: Set<String> = ["tRNS", "bKGD", "sBIT", "hIST", "sRGB", "iCCP", "acTL", "fcTL", "fdAT"]
    /// Text and EXIF chunks, which the metadata filter writes.
    private static let textAndEXIF: Set<String> = ["tEXt", "zTXt", "iTXt", "eXIf"]
    private static let once: Set<String> = ["IHDR", "PLTE", "IEND", "cHRM", "gAMA", "iCCP", "sBIT", "sRGB", "cICP", "mDCV",
                                            "cLLI", "bKGD", "hIST", "tRNS", "pHYs", "tIME", "acTL", "eXIf"]
    private static let beforePalette: Set<String> = ["cHRM", "gAMA", "iCCP", "sBIT", "sRGB", "cICP", "mDCV", "cLLI"]
    private static let afterPalette: Set<String> = ["tRNS", "bKGD", "hIST"]
    private static let beforeData: Set<String> = ["pHYs", "sPLT", "acTL"]

    private struct Header {
        let width: Int, height: Int, depth: Int, colourType: Int, interlaced: Bool
        var bitsPerPixel: Int { ([0: 1, 2: 3, 3: 1, 4: 2, 6: 4][colourType] ?? 4) * depth } // colour type checked in header(_:)
    }

    static func check(_ b: ByteView, against reference: Reference) throws {
        let chunks = try PNGChunks.read(b, strict: true)
        guard let first = chunks.first, first.type == "IHDR" else { throw Invalid("IHDR not first") }
        guard chunks.last?.type == "IEND", chunks.last?.data.isEmpty == true else { throw Invalid("IEND not last") }
        let header = try header(first.data)

        var seen: Set<String> = [], idat = false, idatEnded = false, palette = 0
        var sequence = 0, frames = 0, expectedFrames = -1
        var image: [Data] = []
        // An APNG frame after the image data, waiting for its fdAT chunks.
        var pending: (width: Int, height: Int)?, frame: [Data] = []
        func finishFrame() throws {
            if let pending {
                guard !frame.isEmpty else { throw Invalid("frame without data") }
                try inflateImage(frame, width: pending.width, height: pending.height, header: header)
            }
            pending = nil
            frame = []
        }
        for chunk in chunks {
            let type = chunk.type, d = chunk.data
            let critical = PNGChunks.isCritical(chunk)
            if critical, !["IHDR", "PLTE", "IDAT", "IEND"].contains(type) { throw Invalid("unknown critical chunk \(type)") }
            if type.utf8.dropFirst(2).first! & 0x20 != 0 { throw Invalid("reserved bit in \(type)") }
            if once.contains(type), seen.contains(type) { throw Invalid("second \(type)") }
            if beforePalette.contains(type), seen.contains("PLTE") || idat { throw Invalid("\(type) after PLTE") }
            if afterPalette.contains(type) || type == "PLTE" || beforeData.contains(type), idat { throw Invalid("\(type) after IDAT") }
            if afterPalette.contains(type), header.colourType == 3, !seen.contains("PLTE") { throw Invalid("\(type) before PLTE") }
            if type == "IDAT", idatEnded { throw Invalid("IDAT chunks not consecutive") }
            if idat, type != "IDAT" { idatEnded = true }
            seen.insert(type)
            switch type {
            case "PLTE":
                guard d.count % 3 == 0, (1...256).contains(d.count / 3), header.colourType != 0, header.colourType != 4,
                      header.colourType != 3 || d.count / 3 <= 1 << header.depth
                else { throw Invalid("PLTE") }
                palette = d.count / 3
            case "tRNS":
                switch header.colourType {
                case 0: guard d.count == 2 else { throw Invalid("tRNS") }
                case 2: guard d.count == 6 else { throw Invalid("tRNS") }
                case 3: guard d.count <= palette else { throw Invalid("tRNS") }
                default: throw Invalid("tRNS with alpha channel")
                }
            case "IDAT":
                idat = true
                image.append(d.bytes)
            case "sRGB":
                guard d.count == 1 else { throw Invalid("sRGB") }
                let intent = try d.u8(0)
                guard intent <= 3 else { throw Invalid("sRGB") }
                // The original's, or one standing for its standard sRGB profile, with the same rendering intent.
                if !reference.chunks.contains(chunk) {
                    guard !reference.chunks.contains(type: "sRGB"), let profile = reference.profile,
                          SRGBProfile.renderingIntent(profile).map(Int.init) == intent
                    else { throw Invalid("sRGB added") }
                }
            case "iCCP":
                guard try PNGChunks.text(chunk).content == reference.profile else { throw Invalid("colour profile changed") }
            case "acTL":
                guard d.count == 8, try d.be(0, 4) > 0 else { throw Invalid("acTL") }
                expectedFrames = try d.be(0, 4)
            case "fcTL":
                guard d.count == 26, try d.be(0, 4) == sequence else { throw Invalid("fcTL") }
                sequence += 1
                let w = try d.be(4, 4), h = try d.be(8, 4), x = try d.be(12, 4), y = try d.be(16, 4)
                guard w > 0, h > 0, x + w <= header.width, y + h <= header.height, try d.u8(24) <= 2, try d.u8(25) <= 1,
                      idat || (w == header.width && h == header.height && x == 0 && y == 0)
                else { throw Invalid("fcTL") }
                try finishFrame()
                if idat { pending = (w, h) } // before IDAT, IDAT is this frame
                frames += 1
            case "fdAT":
                guard d.count > 4, try d.be(0, 4) == sequence, pending != nil else { throw Invalid("fdAT") }
                sequence += 1
                frame.append(d.bytes.dropFirst(4))
            default: break
            }
            // Ancillary chunks: text and EXIF a step wrote are checked, the
            // other rewritten ones were checked above, the rest must be the original's.
            if !critical {
                if textAndEXIF.contains(type) {
                    if !reference.chunks.contains(chunk) { try Invalid.within(type) { try payload(chunk) } }
                } else if !rewritten.contains(type), !reference.chunks.contains(chunk) {
                    throw Invalid("\(type) changed")
                }
            }
        }
        guard idat else { throw Invalid("no IDAT") }
        if header.colourType == 3, palette == 0 { throw Invalid("no PLTE") }
        guard expectedFrames < 0 && frames == 0 || frames == expectedFrames else { throw Invalid("acTL frame count") }
        try finishFrame()
        try inflateImage(image, width: header.width, height: header.height, header: header)
    }

    private static func header(_ d: ByteView) throws -> Header {
        guard d.count == 13 else { throw Invalid("IHDR") }
        let header = Header(width: try d.be(0, 4), height: try d.be(4, 4), depth: try d.u8(8), colourType: try d.u8(9),
                            interlaced: try d.u8(12) == 1)
        let depths: [Int: [Int]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
        guard (1...0x7FFF_FFFF).contains(header.width), (1...0x7FFF_FFFF).contains(header.height),
              depths[header.colourType]?.contains(header.depth) == true,
              try d.u8(10) == 0, try d.u8(11) == 0, try d.u8(12) <= 1
        else { throw Invalid("IHDR") }
        return header
    }

    /// Text, EXIF and XMP a step wrote.
    private static func payload(_ chunk: Chunk) throws {
        if chunk.type == "eXIf" { return try PayloadCheck.tiff(chunk.data) }
        let text = try PNGChunks.text(chunk)
        if text.keyword == PNGChunks.xmpKeyword { try Invalid.within("XMP") { try PayloadCheck.xml(ByteView(text.content)) } }
    }

    /// PNG image data: the rows of each pass, each a filter byte (0–4) and
    /// its pixels, and not one byte more or less.
    private static func inflateImage(_ data: [Data], width: Int, height: Int, header: Header) throws {
        let passes = header.interlaced
            ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            : [(0, 0, 1, 1)]
        var rows: [(count: Int, bytes: Int)] = []
        for (x0, y0, dx, dy) in passes {
            let w = width > x0 ? (width - x0 + dx - 1) / dx : 0, h = height > y0 ? (height - y0 + dy - 1) / dy : 0
            if w > 0, h > 0 { rows.append((h, 1 + (w * header.bitsPerPixel + 7) / 8)) }
        }
        var pass = 0, row = 0, untilFilter = 0, valid = true
        let ok = Zlib.stream(data) { piece in
            var k = piece.startIndex
            while k < piece.endIndex {
                if untilFilter == 0 {
                    guard pass < rows.count, piece[k] <= 4 else { valid = false; return false }
                    untilFilter = rows[pass].bytes
                    row += 1
                    if row == rows[pass].count { pass += 1; row = 0 }
                }
                let take = min(untilFilter, piece.endIndex - k)
                untilFilter -= take
                k += take
            }
            return true
        }
        guard ok, valid, pass == rows.count, untilFilter == 0 else { throw Invalid("image data") }
    }
}
