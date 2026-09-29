import Foundation
import zlib

/// Filters the metadata of a PNG by `MetadataPolicy` without touching the
/// image data.
///
/// Always kept: the chunks a decoder needs (including unknown critical ones),
/// the animation chunks of an APNG, and everything that changes how the image
/// looks — transparency, colour profile, gamma, chromaticities, significant
/// bits, CICP and the HDR mastering data. EXIF (eXIf), XMP and text chunks
/// are filtered field by field; the physical size stays with the image info;
/// time and every other ancillary chunk go. At `.keep` only the XMP padding
/// goes. If the image is rotated and no EXIF is left, a minimal eXIf chunk
/// holding only the orientation is written.
enum PNGMetadataFilter {
    struct Malformed: Error {}

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Ancillary chunks that are always kept.
    static let kept: Set<String> = ["tRNS", "iCCP", "sRGB", "gAMA", "cHRM", "sBIT", "cICP", "mDCV", "cLLI",
                                    "acTL", "fcTL", "fdAT"]
    static let xmpKeyword = "XML:com.adobe.xmp"

    static func filter(_ data: Data, level: MetadataHandling, orientation: Int) throws -> Data {
        let b = [UInt8](data)
        guard b.count > signature.count, Array(b[0..<8]) == signature else { throw Malformed() }
        var out = Data(signature)
        var wroteEXIF = false
        var i = 8
        while i + 12 <= b.count {
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length <= b.count - i - 12 else { throw Malformed() }
            let type = String(decoding: b[i + 4..<i + 8], as: UTF8.self)
            let payload = Array(b[i + 8..<i + 8 + length])
            let whole = b[i..<i + 12 + length]
            // Bit 5 of the first letter is clear for critical chunks.
            let critical = b[i + 4] & 0x20 == 0
            let keyword = ["tEXt", "zTXt", "iTXt"].contains(type)
                ? String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self) : nil

            if type == "iTXt", keyword == xmpKeyword {
                if let packet = xmpPacket(payload) {
                    let filtered = level == .keep ? XMPFilter.withoutPadding(packet) : XMPFilter.filter(packet, level: level)
                    if let filtered { out.append(chunk("iTXt", Array(xmpKeyword.utf8) + [0, 0, 0, 0, 0] + filtered)) }
                } else if level == .keep {
                    out.append(contentsOf: whole)
                }
            } else if level == .keep || critical || kept.contains(type) {
                out.append(contentsOf: whole)
            } else if type == "eXIf" {
                if let exif = EXIFFilter.filter(payload, level: level) {
                    out.append(chunk("eXIf", exif))
                    wroteEXIF = true
                }
            } else if let keyword, MetadataPolicy.keeps(MetadataPolicy.group(pngTextKeyword: keyword), at: level) {
                out.append(contentsOf: whole)
            } else if type == "pHYs", MetadataPolicy.keeps(.imageInfo, at: level) {
                out.append(contentsOf: whole)
            }
            i += 12 + length
            if type == "IEND" {
                // The orientation goes before any image data: right after IHDR.
                if !wroteEXIF, level != .keep, orientation != 1, let ihdr = out.firstRange(of: Data("IHDR".utf8)) {
                    let at = ihdr.upperBound + 13 + 4 // IHDR payload and CRC
                    out.insert(contentsOf: chunk("eXIf", JPEGMetadataFilter.minimalTIFF(orientation: orientation)), at: at)
                }
                return out
            }
        }
        throw Malformed() // no IEND
    }

    /// The XMP packet of an iTXt chunk: keyword, NUL, compression flag and
    /// method, language tag, NUL, translated keyword, NUL, text.
    private static func xmpPacket(_ payload: [UInt8]) -> [UInt8]? {
        var i = xmpKeyword.utf8.count + 1
        guard i + 2 <= payload.count else { return nil }
        let compressed = payload[i] == 1
        i += 2
        for _ in 0..<2 { // language tag, translated keyword
            guard let end = payload[i...].firstIndex(of: 0) else { return nil }
            i = end + 1
        }
        let text = Array(payload[i...])
        guard compressed else { return text }
        // zlib: two header bytes, raw deflate, four bytes of checksum.
        guard text.count > 6, let inflated = try? (Data(text.dropFirst(2).dropLast(4)) as NSData).decompressed(using: .zlib)
        else { return nil }
        return [UInt8](inflated as Data)
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

    static func crc32(_ bytes: some Collection<UInt8>) -> UInt32 {
        bytes.withContiguousStorageIfAvailable { UInt32(zlib.crc32(0, $0.baseAddress, uInt($0.count))) }
            ?? UInt32(Array(bytes).withUnsafeBufferPointer { zlib.crc32(0, $0.baseAddress, uInt($0.count)) })
    }
}
