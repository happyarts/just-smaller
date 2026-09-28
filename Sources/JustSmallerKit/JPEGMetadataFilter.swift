import Foundation

/// Removes metadata from a JPEG without touching the image data.
///
/// Kept: everything the decoder needs, the ICC profile (APP2) and the Adobe
/// marker (APP14, it says how CMYK/YCCK data is to be interpreted). Removed:
/// EXIF and XMP (APP1), IPTC (APP13), comments and all other APPn segments.
/// If the photo is rotated, a minimal EXIF block holding only the orientation
/// is written back, so it doesn't turn sideways.
enum JPEGMetadataFilter {
    struct Malformed: Error {}

    static func strip(_ data: Data, orientation: Int) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { throw Malformed() }
        var out = Data([0xFF, 0xD8])
        var wroteOrientation = false
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { throw Malformed() }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue } // fill byte
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { throw Malformed() }
            let segment = b[i..<i + 2 + length]
            let payload = b[i + 4..<i + 2 + length]

            // The orientation goes right after SOI/JFIF, before anything else.
            if !wroteOrientation, marker != 0xE0 {
                if orientation != 1 { out.append(minimalEXIF(orientation: orientation)) }
                wroteOrientation = true
            }

            switch marker {
            case 0xDA: // start of scan: the rest is entropy-coded data, copy verbatim
                out.append(contentsOf: b[i...])
                return out
            case 0xE2 where payload.starts(with: Array("ICC_PROFILE\0".utf8)),
                 0xEE where payload.starts(with: Array("Adobe".utf8)),
                 0xE0 where payload.starts(with: Array("JFIF\0".utf8)):
                out.append(contentsOf: segment)
            case 0xE0...0xEF, 0xFE: // other APPn, comments
                break
            default: // tables, frame headers, restart intervals, …
                out.append(contentsOf: segment)
            }
            i += 2 + length
        }
        throw Malformed() // no image data
    }

    /// APP1 "Exif" holding the minimal TIFF block below.
    static func minimalEXIF(orientation: Int) -> Data {
        let payload = Array("Exif\0\0".utf8) + minimalTIFF(orientation: orientation)
        let length = payload.count + 2
        return Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload)
    }

    /// A big-endian TIFF header and one IFD entry: Orientation (0x0112),
    /// SHORT, count 1. Also the payload of a PNG eXIf chunk.
    static func minimalTIFF(orientation: Int) -> [UInt8] {
        var tiff: [UInt8] = Array("MM".utf8) + [0x00, 0x2A, 0x00, 0x00, 0x00, 0x08] // header, IFD0 at offset 8
        tiff += [0x00, 0x01]                                  // one entry
        tiff += [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01] // tag, type SHORT, count 1
        tiff += [0x00, UInt8(clamping: orientation), 0x00, 0x00] // value, left-aligned
        tiff += [0x00, 0x00, 0x00, 0x00]                      // no next IFD
        return tiff
    }

    /// Puts the original's metadata into a freshly encoded JPEG. Encoders
    /// like cjpegli drop EXIF (with the orientation), XMP and IPTC. Taken from
    /// the original: JFIF, EXIF/XMP (APP1), the ICC profile (APP2), IPTC and
    /// comments. Not taken: the Adobe marker (APP14) — it says how the colour
    /// components are coded and belongs to the original's encoding.
    static func transplant(metadataFrom original: Data, into encoded: Data) throws -> Data {
        let source = try segments(original)
        let target = try segments(encoded)
        var out = Data([0xFF, 0xD8])
        for s in source.headers where s.marker == 0xFE || (0xE0...0xEF).contains(s.marker) && s.marker != 0xEE {
            out.append(s.bytes)
        }
        for s in target.headers where s.marker != 0xFE && !(0xE0...0xEF).contains(s.marker) {
            out.append(s.bytes)
        }
        out.append(target.imageData)
        return out
    }

    /// The segments before the image data, and the image data from SOS on.
    private static func segments(_ data: Data) throws -> (headers: [(marker: UInt8, bytes: Data)], imageData: Data) {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { throw Malformed() }
        var headers: [(marker: UInt8, bytes: Data)] = []
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { throw Malformed() }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xDA { return (headers, Data(b[i...])) }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { throw Malformed() }
            headers.append((marker, Data(b[i..<i + 2 + length])))
            i += 2 + length
        }
        throw Malformed()
    }
}

/// Estimates the libjpeg-style quality (1–100) a JPEG was saved with, from
/// its luminance quantization table. Compares the table's average step with
/// the standard table scaled to each quality, which also copes with custom
/// tables from cameras and editors.
enum JPEGQuality {
    private static let standard: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]

    static func estimate(_ data: Data) -> Int? {
        guard let table = luminanceTable(data) else { return nil }
        let mean = Double(table.reduce(0, +)) / 64
        var best = (quality: 100, error: Double.infinity)
        for quality in 1...100 {
            let scale = quality < 50 ? 5000 / quality : 200 - 2 * quality
            let steps = standard.map { min(255, max(1, ($0 * scale + 50) / 100)) }
            let error = abs(Double(steps.reduce(0, +)) / 64 - mean)
            if error < best.error { best = (quality, error) }
        }
        return best.quality
    }

    /// Table 0 of the first DQT segment (luminance by convention).
    private static func luminanceTable(_ data: Data) -> [Int]? {
        let b = [UInt8](data.prefix(256 * 1024))
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if marker == 0xDA { return nil }
            if marker == 0xDB {
                var j = i + 4
                while j < i + 2 + length, j < b.count {
                    let precision = b[j] >> 4, id = b[j] & 0x0F
                    let size = precision == 0 ? 64 : 128
                    guard j + 1 + size <= b.count else { return nil }
                    let values = precision == 0
                        ? b[(j + 1)..<(j + 65)].map(Int.init)
                        : stride(from: j + 1, to: j + 129, by: 2).map { Int(b[$0]) << 8 | Int(b[$0 + 1]) }
                    if id == 0 { return values }
                    j += 1 + size
                }
            }
            i += 2 + length
        }
        return nil
    }
}
