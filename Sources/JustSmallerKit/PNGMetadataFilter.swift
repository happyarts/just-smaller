import Foundation

/// Removes metadata from a PNG without touching the image data.
///
/// Kept: the chunks a decoder needs (including unknown critical ones), the
/// animation chunks of an APNG, and everything that changes how the image
/// looks — transparency, colour profile, gamma, chromaticities, significant
/// bits, CICP and the HDR mastering data. Removed: text, time, physical size,
/// EXIF and every other ancillary chunk. If the image is rotated, a minimal
/// eXIf chunk holding only the orientation is written back.
enum PNGMetadataFilter {
    struct Malformed: Error {}

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Ancillary chunks that are kept.
    static let kept: Set<String> = ["tRNS", "iCCP", "sRGB", "gAMA", "cHRM", "sBIT", "cICP", "mDCV", "cLLI",
                                    "acTL", "fcTL", "fdAT"]

    static func strip(_ data: Data, orientation: Int) throws -> Data {
        let b = [UInt8](data)
        guard b.count > signature.count, Array(b[0..<8]) == signature else { throw Malformed() }
        var out = Data(signature)
        var i = 8
        while i + 12 <= b.count {
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length <= b.count - i - 12 else { throw Malformed() }
            let type = String(decoding: b[i + 4..<i + 8], as: UTF8.self)
            // Bit 5 of the first letter is clear for critical chunks.
            let critical = b[i + 4] & 0x20 == 0
            if critical || kept.contains(type) { out.append(contentsOf: b[i..<i + 12 + length]) }
            // The orientation goes right after the header, before any image data.
            if type == "IHDR", orientation != 1 {
                out.append(chunk("eXIf", JPEGMetadataFilter.minimalTIFF(orientation: orientation)))
            }
            i += 12 + length
            if type == "IEND" { return out }
        }
        throw Malformed() // no IEND
    }

    static func chunk(_ type: String, _ payload: [UInt8]) -> Data {
        let body = Array(type.utf8) + payload
        var out = Data()
        out.append(contentsOf: bigEndian(UInt32(payload.count)))
        out.append(contentsOf: body)
        out.append(contentsOf: bigEndian(crc32(body)))
        return out
    }

    private static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
