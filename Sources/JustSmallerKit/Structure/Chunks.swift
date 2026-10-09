import Foundation
import zlib

/// A chunk of a PNG or RIFF (WebP) file.
struct Chunk {
    let type: String
    /// The payload.
    let data: ByteView
    /// Length, type, payload and CRC (PNG); type, size and payload (RIFF).
    let whole: ByteView
}

/// The original's chunks, to ask whether a result's chunk is one of them.
struct ChunkSet {
    private var byType: [String: [Data]] = [:]

    init(_ chunks: [Chunk]) {
        for chunk in chunks { byType[chunk.type, default: []].append(chunk.data.bytes) }
    }

    func contains(_ chunk: Chunk) -> Bool { byType[chunk.type]?.contains(chunk.data.bytes) ?? false }
    func contains(type: String) -> Bool { byType[type] != nil }
}

/// The one way the engine walks a PNG's chunks: the metadata filter, the
/// structure check's view of the original (lenient) and of the result (strict).
enum PNGChunks {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let xmpKeyword = "XML:com.adobe.xmp"

    /// Bit 5 of the first letter is clear for chunks a decoder must understand.
    static func isCritical(_ chunk: Chunk) -> Bool { chunk.type.utf8.first.map { $0 & 0x20 == 0 } ?? true }

    static func crc32(_ bytes: Data) -> UInt32 {
        bytes.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count))) }
    }

    /// A chunk: length, type, payload, CRC over type and payload.
    static func write(_ type: String, _ payload: [UInt8]) -> Data {
        let body = Data(type.utf8) + payload
        let n = UInt32(payload.count), crc = crc32(body)
        return Data([UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + body
            + Data([UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
    }

    /// A 1 × 1 grey PNG with `chunk` in front of its image data: for
    /// readers that read a chunk only along with an image.
    static func image(holding chunk: Chunk) -> Data {
        var png = Data(signature)
        png.append(write("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0])) // 1 × 1, grey, 8 bits
        png.append(chunk.whole.bytes)
        png.append(write("IDAT", [0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01])) // zlib: filter 0, pixel 0
        png.append(write("IEND", []))
        return png
    }

    /// The keyword of a text chunk (tEXt, zTXt, iTXt) or the name of an
    /// iCCP profile: 1–79 bytes before the first NUL.
    static func keyword(_ chunk: Chunk) throws -> String {
        guard let k = chunk.data.index(of: 0, from: 0), (1...79).contains(k) else { throw FormatError("\(chunk.type) keyword") }
        return String(decoding: try chunk.data.view(0, k).bytes, as: UTF8.self)
    }

    /// The keyword and text of a tEXt, zTXt or iTXt chunk, or the name and
    /// profile of an iCCP chunk, inflated where compressed:
    /// keyword (1–79 bytes) NUL, then tEXt: text; zTXt/iCCP: method 0, zlib
    /// data; iTXt: compression flag, method 0, language NUL, translated
    /// keyword NUL, text.
    static func text(_ chunk: Chunk) throws -> (keyword: String, content: Data) {
        let d = chunk.data, keyword = try keyword(chunk)
        guard let k = d.index(of: 0, from: 0) else { throw FormatError("\(chunk.type) keyword") }
        switch chunk.type {
        case "tEXt":
            return (keyword, try d.view(from: k + 1).bytes)
        case "zTXt", "iCCP":
            guard try d.u8(k + 1) == 0 else { throw FormatError("\(chunk.type) compression method") }
            return (keyword, try Zlib.inflate([d.view(from: k + 2).bytes]))
        case "iTXt":
            let compressed = try d.u8(k + 1)
            guard compressed <= 1, try d.u8(k + 2) == 0,
                  let language = d.index(of: 0, from: k + 3), let translated = d.index(of: 0, from: language + 1)
            else { throw FormatError("iTXt") }
            let raw = try d.view(from: translated + 1).bytes
            return (keyword, compressed == 1 ? try Zlib.inflate([raw]) : raw)
        default:
            throw FormatError("\(chunk.type) is no text chunk")
        }
    }

    /// Leniently, as many chunks as fit, CRCs unread. Strictly, every chunk
    /// with letters for a type and a right CRC, and nothing after IEND.
    static func read(_ b: ByteView, strict: Bool) throws -> [Chunk] {
        guard b.has(signature) else { throw FormatError("PNG signature") }
        var out: [Chunk] = [], i = 8
        while i < b.count {
            let chunk: Chunk
            do {
                chunk = try self.chunk(at: i, in: b, strict: strict)
            } catch where !strict {
                return out
            }
            out.append(chunk)
            i += chunk.whole.count
            if strict, chunk.type == "IEND", i != b.count { throw FormatError("data after IEND") }
        }
        return out
    }

    private static func chunk(at i: Int, in b: ByteView, strict: Bool) throws -> Chunk {
        let length = try b.be(i, 4)
        guard length <= 0x7FFF_FFFF else { throw FormatError("chunk length") }
        let typeBytes = try b.view(i + 4, 4).bytes
        let type = String(decoding: typeBytes, as: UTF8.self)
        let whole = try b.view(i, 12 + length)
        if strict {
            guard typeBytes.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) else {
                throw FormatError("chunk type")
            }
            guard try Int(crc32(b.view(i + 4, 4 + length).bytes)) == b.be(i + 8 + length, 4) else {
                throw FormatError("\(type) checksum")
            }
        }
        return Chunk(type: type, data: try b.view(i + 8, length), whole: whole)
    }
}

/// The one way the engine walks a RIFF file's chunks (WebP): the metadata
/// filter, the file facts and the structure check.
enum RIFFChunks {
    /// The chunks of `body` (a RIFF file after "RIFF", size and form type,
    /// or an ANMF payload). Leniently, as many as fit, and whether they
    /// reached the end. Strictly, they fill it exactly, with zero padding
    /// after odd sizes.
    static func read(_ body: ByteView, strict: Bool) throws -> (chunks: [Chunk], complete: Bool) {
        var out: [Chunk] = [], i = 0
        while i < body.count {
            // A few stray bytes at the end are no chunk; readers skip them.
            if !strict, body.count - i < 8 { break }
            do {
                let size = try body.le(i + 4, 4)
                let padded = size + (size & 1)
                let data = try body.view(i + 8, size)
                if strict, size & 1 == 1, try body.u8(i + 8 + size) != 0 { throw FormatError("chunk padding") }
                out.append(Chunk(type: String(decoding: try body.view(i, 4).bytes, as: UTF8.self), data: data, whole: try body.view(i, 8 + size)))
                i += 8 + padded
            } catch where !strict {
                return (out, false)
            }
        }
        return (out, true)
    }

    /// Where a chunk belongs in an extended WebP (after VP8X): ICCP, ANIM,
    /// image data, EXIF, XMP, then unknown chunks.
    static func webpOrder(_ type: String) -> Int {
        ["VP8X": 0, "ICCP": 1, "ANIM": 2, "ALPH": 3, "VP8 ": 3, "VP8L": 3, "ANMF": 3, "EXIF": 4, "XMP ": 5][type] ?? 6
    }

    /// Where the TIFF data of a WebP EXIF chunk starts: some writers put
    /// JPEG's "Exif\0\0" in front of it.
    static func tiffOffset(_ payload: some Collection<UInt8>) -> Int {
        payload.starts(with: JPEGMarkers.exifHeader) ? JPEGMarkers.exifHeader.count : 0
    }

    /// A RIFF file of `form` ("WEBP") holding `chunks` in the order given:
    /// little-endian sizes, odd payloads padded with a zero byte.
    static func write(form: String, _ chunks: [(type: String, payload: Data)]) -> Data {
        func size(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)] }
        let body = 4 + chunks.reduce(0) { $0 + 8 + $1.payload.count + ($1.payload.count & 1) }
        var out = Data(capacity: 8 + body)
        out.append(contentsOf: Array("RIFF".utf8) + size(body) + Array(form.utf8))
        for chunk in chunks {
            out.append(contentsOf: Array(chunk.type.utf8) + size(chunk.payload.count))
            out.append(chunk.payload)
            if chunk.payload.count & 1 == 1 { out.append(0) }
        }
        return out
    }

    /// The chunks of a whole WebP file, leniently.
    static func webp(_ file: ByteView) -> (chunks: [Chunk], complete: Bool) {
        // What follows the size the RIFF header gives isn't part of the file.
        guard file.has("RIFF"), file.has("WEBP", at: 8), let size = try? file.le(4, 4), size >= 4,
              let body = try? file.view(12, min(size - 4, file.count - 12))
        else { return ([], false) }
        return (try? read(body, strict: false)) ?? ([], false)
    }
}
