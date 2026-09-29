import Foundation
import zlib

extension StructureCheck {
    private struct Chunk {
        let type: String
        let data: ArraySlice<UInt8>
        var critical: Bool { type.utf8.first! & 0x20 == 0 }
    }

    /// Chunks the tools rewrite as part of their job: palette and colour
    /// reductions touch the colour-type dependent ones, the metadata filter
    /// the text and EXIF chunks, APNG optimization the frame control. All
    /// other ancillary chunks must be the original's.
    private static let pngRewritten: Set<String> = ["tRNS", "bKGD", "sBIT", "hIST", "sRGB", "iCCP",
                                                     "tEXt", "zTXt", "iTXt", "eXIf", "acTL", "fcTL", "fdAT"]
    private static let pngOnce: Set<String> = ["IHDR", "PLTE", "IEND", "cHRM", "gAMA", "iCCP", "sBIT", "sRGB", "cICP", "mDCV",
                                               "cLLI", "bKGD", "hIST", "tRNS", "pHYs", "tIME", "acTL", "eXIf"]
    private static let pngBeforePalette: Set<String> = ["cHRM", "gAMA", "iCCP", "sBIT", "sRGB", "cICP", "mDCV", "cLLI"]
    private static let pngAfterPalette: Set<String> = ["tRNS", "bKGD", "hIST"]
    private static let pngBeforeData: Set<String> = ["pHYs", "sPLT", "acTL"]

    /// Every chunk's CRC, IHDR's fields, the chunk order rules of the PNG
    /// specification, the image data inflated to exactly the bytes the
    /// header asks for (every row's filter byte valid, Adler-32 right), and
    /// the same for each APNG frame.
    static func png(_ b: [UInt8], original a: [UInt8]) throws {
        let chunks = try pngChunks(b)
        let before = (try? pngChunks(a, checksums: false)) ?? []
        guard let header = chunks.first, header.type == "IHDR", header.data.count == 13 else { throw Invalid("IHDR not first") }
        guard chunks.last?.type == "IEND", chunks.last?.data.isEmpty == true else { throw Invalid("IEND not last") }
        let h = header.data.startIndex
        func u32(_ d: ArraySlice<UInt8>, _ at: Int) -> Int {
            Int(d[at]) << 24 | Int(d[at + 1]) << 16 | Int(d[at + 2]) << 8 | Int(d[at + 3])
        }
        let width = u32(header.data, h), height = u32(header.data, h + 4)
        let depth = Int(header.data[h + 8]), colourType = Int(header.data[h + 9]), interlaced = header.data[h + 12] == 1
        let depths: [Int: [Int]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
        guard (1...0x7FFF_FFFF).contains(width), (1...0x7FFF_FFFF).contains(height),
              depths[colourType]?.contains(depth) == true,
              header.data[h + 10] == 0, header.data[h + 11] == 0, header.data[h + 12] <= 1
        else { throw Invalid("IHDR") }
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][colourType]!

        var seen: Set<String> = [], idat = false, idatEnded = false, palette = 0
        var sequence = 0, frames = 0, expectedFrames = -1
        var stream: [UInt8] = []
        // An APNG frame after the image data, waiting for its fdAT chunks.
        var pending: (width: Int, height: Int)?, frameData: [UInt8] = []
        func finishFrame() throws {
            if let pending {
                guard !frameData.isEmpty else { throw Invalid("frame without data") }
                try inflateImage(frameData, width: pending.width, height: pending.height, bits: channels * depth, interlaced: interlaced)
            }
            pending = nil
            frameData = []
        }
        for chunk in chunks {
            let type = chunk.type, d = chunk.data, s = d.startIndex
            if chunk.critical, !["IHDR", "PLTE", "IDAT", "IEND"].contains(type) { throw Invalid("unknown critical chunk \(type)") }
            if type.utf8.dropFirst(2).first! & 0x20 != 0 { throw Invalid("reserved bit in \(type)") }
            if pngOnce.contains(type), seen.contains(type) { throw Invalid("second \(type)") }
            if pngBeforePalette.contains(type), seen.contains("PLTE") || idat { throw Invalid("\(type) after PLTE") }
            if pngAfterPalette.contains(type) || type == "PLTE" || pngBeforeData.contains(type), idat { throw Invalid("\(type) after IDAT") }
            if pngAfterPalette.contains(type), colourType == 3, !seen.contains("PLTE") { throw Invalid("\(type) before PLTE") }
            if type == "IDAT", idatEnded { throw Invalid("IDAT chunks not consecutive") }
            if idat, type != "IDAT" { idatEnded = true }
            seen.insert(type)
            switch type {
            case "PLTE":
                guard d.count % 3 == 0, (1...256).contains(d.count / 3), colourType != 0, colourType != 4,
                      colourType != 3 || d.count / 3 <= 1 << depth
                else { throw Invalid("PLTE") }
                palette = d.count / 3
            case "tRNS":
                switch colourType {
                case 0: guard d.count == 2 else { throw Invalid("tRNS") }
                case 2: guard d.count == 6 else { throw Invalid("tRNS") }
                case 3: guard d.count <= palette else { throw Invalid("tRNS") }
                default: throw Invalid("tRNS with alpha channel")
                }
            case "IDAT":
                idat = true
                stream += d
            case "iCCP":
                guard let profile = compressedText(d) else { throw Invalid("iCCP") }
                if !before.contains(where: { $0.type == "iCCP" && compressedText($0.data) == profile }) {
                    throw Invalid("colour profile changed")
                }
            case "sRGB":
                guard d.count == 1, d[s] <= 3 else { throw Invalid("sRGB") }
                if !before.contains(where: { $0.type == "sRGB" || $0.type == "iCCP" }) { throw Invalid("sRGB added") }
            case "zTXt":
                guard compressedText(d) != nil else { throw Invalid("zTXt") }
            case "iTXt":
                // keyword NUL, compression flag, method, language NUL, translated keyword NUL, text
                guard let k = d.firstIndex(of: 0), k + 2 < d.endIndex, d[k + 1] <= 1, d[k + 2] == 0 else { throw Invalid("iTXt") }
                if d[k + 1] == 1 {
                    let rest = d[(k + 3)...]
                    guard let l = rest.firstIndex(of: 0), let t = rest[(l + 1)...].firstIndex(of: 0),
                          inflated(Array(d[(t + 1)...])) != nil
                    else { throw Invalid("iTXt") }
                }
            case "acTL":
                guard d.count == 8, u32(d, s) > 0 else { throw Invalid("acTL") }
                expectedFrames = u32(d, s)
            case "fcTL":
                guard d.count == 26, u32(d, s) == sequence else { throw Invalid("fcTL") }
                sequence += 1
                let w = u32(d, s + 4), h = u32(d, s + 8), x = u32(d, s + 12), y = u32(d, s + 16)
                guard w > 0, h > 0, x + w <= width, y + h <= height, d[s + 24] <= 2, d[s + 25] <= 1,
                      idat || (w == width && h == height && x == 0 && y == 0)
                else { throw Invalid("fcTL") }
                try finishFrame()
                if idat { pending = (w, h) } // before IDAT, IDAT is this frame
                frames += 1
            case "fdAT":
                guard d.count > 4, u32(d, s) == sequence, pending != nil else { throw Invalid("fdAT") }
                sequence += 1
                frameData += d.dropFirst(4)
            default: break
            }
            if !chunk.critical, !pngRewritten.contains(type),
               !before.contains(where: { $0.type == type && $0.data.elementsEqual(d) }) {
                throw Invalid("\(type) changed")
            }
        }
        guard idat else { throw Invalid("no IDAT") }
        if colourType == 3, palette == 0 { throw Invalid("no PLTE") }
        guard expectedFrames < 0 && frames == 0 || frames == expectedFrames else { throw Invalid("acTL frame count") }
        try finishFrame()
        try inflateImage(stream, width: width, height: height, bits: channels * depth, interlaced: interlaced)
    }

    private static func pngChunks(_ b: [UInt8], checksums: Bool = true) throws -> [Chunk] {
        guard b.count >= 8, Array(b[0..<8]) == PNGMetadataFilter.signature else { throw Invalid("PNG signature") }
        var out: [Chunk] = [], i = 8
        while i < b.count {
            guard i + 12 <= b.count else { throw Invalid("truncated chunk") }
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length <= 0x7FFF_FFFF, length <= b.count - i - 12 else { throw Invalid("chunk length") }
            guard b[i + 4..<i + 8].allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) else {
                throw Invalid("chunk type")
            }
            let type = String(decoding: b[i + 4..<i + 8], as: UTF8.self)
            let stored = UInt32(b[i + 8 + length]) << 24 | UInt32(b[i + 9 + length]) << 16
                | UInt32(b[i + 10 + length]) << 8 | UInt32(b[i + 11 + length])
            guard !checksums || PNGMetadataFilter.crc32(b[i + 4..<i + 8 + length]) == stored else { throw Invalid("\(type) checksum") }
            out.append(Chunk(type: type, data: b[i + 8..<i + 8 + length]))
            i += 12 + length
            if type == "IEND", i != b.count { throw Invalid("data after IEND") }
        }
        return out
    }

    /// The text of iCCP/zTXt: keyword, NUL, method 0, zlib data.
    private static func compressedText(_ d: ArraySlice<UInt8>) -> [UInt8]? {
        guard let k = d.firstIndex(of: 0), k > d.startIndex, k + 1 < d.endIndex, d[k + 1] == 0 else { return nil }
        return inflated(Array(d[(k + 2)...]))
    }

    /// Inflates one complete zlib stream (header and Adler-32 checked by
    /// zlib). nil if it is damaged, doesn't end, or data follows it.
    private static func inflated(_ data: [UInt8]) -> [UInt8]? {
        let limit = 64 << 20
        var out: [UInt8] = []
        let ok = inflateStream(data) { piece in
            out += piece
            return out.count <= limit
        }
        return ok ? out : nil
    }

    /// PNG image data: the rows of each pass, each a filter byte (0–4) and
    /// its pixels, and not one byte more or less.
    private static func inflateImage(_ data: [UInt8], width: Int, height: Int, bits: Int, interlaced: Bool) throws {
        let passes = interlaced
            ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            : [(0, 0, 1, 1)]
        var rows: [(count: Int, bytes: Int)] = []
        for (x0, y0, dx, dy) in passes {
            let w = width > x0 ? (width - x0 + dx - 1) / dx : 0, h = height > y0 ? (height - y0 + dy - 1) / dy : 0
            if w > 0, h > 0 { rows.append((h, 1 + (w * bits + 7) / 8)) }
        }
        var pass = 0, row = 0, untilFilter = 0, valid = true
        let ok = inflateStream(data) { piece in
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

    /// Runs zlib over `data`, handing each inflated piece to `sink` (which
    /// may stop it). True if the stream ended exactly at the end of `data`.
    private static func inflateStream(_ data: [UInt8], sink: (ArraySlice<UInt8>) -> Bool) -> Bool {
        guard !data.isEmpty else { return false }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return false }
        defer { inflateEnd(&stream) }
        var buffer = [UInt8](repeating: 0, count: 256 << 10)
        return data.withUnsafeBufferPointer { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                guard sink(buffer[0..<produced]) else { return false }
                if status == Z_STREAM_END { return stream.avail_in == 0 }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { return false }
            }
        }
    }
}
