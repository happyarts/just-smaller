import Foundation

/// Filters the metadata of a JPEG by `MetadataPolicy` without touching the
/// image data.
///
/// Always kept: everything the decoder needs, JFIF, the ICC profile (APP2)
/// and the Adobe marker (APP14, it says how CMYK/YCCK data is to be
/// interpreted). EXIF, XMP (with its extended part) and IPTC (APP13) are
/// filtered field by field; comments and all other APPn segments go. At
/// `.keep` only the XMP padding goes. If the photo is rotated and no EXIF is
/// left, a minimal EXIF block holding only the orientation is written, so it
/// doesn't turn sideways.
enum JPEGMetadataFilter {
    struct Malformed: Error {}

    static let exifHeader = Array("Exif\0\0".utf8)
    static let xmpHeader = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    static let extendedXMPHeader = Array("http://ns.adobe.com/xmp/extension/\0".utf8)
    static let photoshopHeader = Array("Photoshop 3.0\0".utf8)
    /// What an APPn or COM segment holds, by its marker and signature. The
    /// filter rewrites EXIF, XMP and IPTC (Photoshop); the structure check
    /// checks what was rewritten and requires the rest unchanged.
    enum Part {
        case jfif, jfifExtension, exif, xmp, extendedXMP, photoshop, iccProfile, multiPicture, adobe, comment, other
    }

    static func part(_ marker: UInt8, payload: some Collection<UInt8>) -> Part {
        func has(_ header: [UInt8]) -> Bool { payload.starts(with: header) }
        switch marker {
        case 0xE0 where has(Array("JFIF\0".utf8)): return .jfif
        case 0xE0 where has(Array("JFXX\0".utf8)): return .jfifExtension
        case 0xE1 where has(exifHeader): return .exif
        case 0xE1 where has(xmpHeader): return .xmp
        case 0xE1 where has(extendedXMPHeader): return .extendedXMP
        case 0xE2 where has(Array("ICC_PROFILE\0".utf8)): return .iccProfile
        case 0xE2 where has(Array("MPF\0".utf8)): return .multiPicture
        case 0xED where has(photoshopHeader): return .photoshop
        case 0xEE where has(Array("Adobe".utf8)): return .adobe
        case 0xFE: return .comment
        default: return .other
        }
    }

    /// The largest payload of a segment: its length field counts itself.
    private static let maxPayload = 0xFFFF - 2

    static func filter(_ data: Data, level: MetadataHandling, orientation: Int) throws -> Data {
        let (headers, imageData) = try segments(data)
        let payloads = headers.map { Array($0.bytes.dropFirst(4)) }
        func isApp(_ k: Int, _ marker: UInt8, _ header: [UInt8]) -> Bool {
            headers[k].marker == marker && payloads[k].starts(with: header)
        }

        if level == .keep {
            var out = Data([0xFF, 0xD8])
            for (k, s) in headers.enumerated() {
                if isApp(k, 0xE1, xmpHeader) {
                    out.append(segment(0xE1, xmpHeader + XMPFilter.withoutPadding(Array(payloads[k].dropFirst(xmpHeader.count)))))
                } else {
                    out.append(s.bytes)
                }
            }
            out.append(imageData)
            return out
        }

        // IPTC: Photoshop splits large resource blocks over several APP13s.
        let photoshop = headers.indices.filter { isApp($0, 0xED, photoshopHeader) }
        let iptc = photoshop.isEmpty ? IPTCFilter.Result()
            : IPTCFilter.filter(photoshop.flatMap { payloads[$0].dropFirst(photoshopHeader.count) }, level: level)

        // XMP, with the extended part (JPEG's way around the 64 KB limit)
        // merged in when it fits into one segment afterwards.
        let xmpIndex = headers.indices.first { isApp($0, 0xE1, xmpHeader) }
        var xmp: [UInt8]?
        if let xmpIndex {
            let packet = Array(payloads[xmpIndex].dropFirst(xmpHeader.count))
            let extended = reassembleExtendedXMP(payloads.enumerated().filter { isApp($0.offset, 0xE1, extendedXMPHeader) }
                .map { Array($0.element.dropFirst(extendedXMPHeader.count)) }, for: packet)
            xmp = XMPFilter.filter(packet, level: level, merging: extended, digest: iptc.digest)
            if let merged = xmp, merged.count + xmpHeader.count > maxPayload {
                xmp = XMPFilter.filter(packet, level: level, digest: iptc.digest)
            }
            if let packet = xmp, packet.count + xmpHeader.count > maxPayload { xmp = nil }
        }

        let exifIndex = headers.indices.first { isApp($0, 0xE1, exifHeader) }
        let exif = exifIndex.flatMap { EXIFFilter.filter(Array(payloads[$0].dropFirst(exifHeader.count)), level: level) }
            .flatMap { $0.count + exifHeader.count <= maxPayload ? $0 : nil }

        var out = Data([0xFF, 0xD8])
        var wroteEXIF = false
        for (k, s) in headers.enumerated() {
            // EXIF goes right after SOI/JFIF, before anything else.
            if !wroteEXIF, !isApp(k, 0xE0, Array("JFIF\0".utf8)) {
                if let exif {
                    out.append(segment(0xE1, exifHeader + exif))
                } else if orientation != 1 {
                    out.append(minimalEXIF(orientation: orientation))
                }
                wroteEXIF = true
            }
            switch s.marker {
            case 0xE1 where k == xmpIndex:
                if let xmp { out.append(segment(0xE1, xmpHeader + xmp)) }
            case 0xED where k == photoshop.first:
                if let resources = iptc.resources {
                    for chunk in resources.chunked(maxPayload - photoshopHeader.count) {
                        out.append(segment(0xED, photoshopHeader + chunk))
                    }
                }
            case 0xE2 where payloads[k].starts(with: Array("ICC_PROFILE\0".utf8)),
                 0xEE where payloads[k].starts(with: Array("Adobe".utf8)),
                 0xE0 where payloads[k].starts(with: Array("JFIF\0".utf8)):
                out.append(s.bytes)
            case 0xE0...0xEF, 0xFE: // everything else in APPn (EXIF was written above), comments
                break
            default: // tables, frame headers, restart intervals, …
                out.append(s.bytes)
            }
        }
        out.append(imageData)
        return out
    }

    /// Extended XMP chunks: a 32-character GUID (the MD5 of the whole
    /// extension), its full length and this chunk's offset, then the data.
    /// Only the extension the main packet names is used.
    static func reassembleExtendedXMP(_ chunks: [[UInt8]], for packet: [UInt8]) -> [UInt8]? {
        var parts: [String: [(offset: Int, data: [UInt8])]] = [:]
        var lengths: [String: Int] = [:]
        for chunk in chunks where chunk.count > 40 {
            let guid = String(decoding: chunk[0..<32], as: UTF8.self)
            let length = chunk[32..<36].reduce(0) { $0 << 8 | Int($1) }
            let offset = chunk[36..<40].reduce(0) { $0 << 8 | Int($1) }
            parts[guid, default: []].append((offset, Array(chunk[40...])))
            lengths[guid] = length
        }
        guard let guid = parts.keys.first(where: { packet.firstRange(of: Array($0.utf8)) != nil }),
              let length = lengths[guid] else { return nil }
        var whole = [UInt8](repeating: 0, count: length)
        var filled = 0
        for part in parts[guid] ?? [] {
            guard part.offset + part.data.count <= length else { return nil }
            whole.replaceSubrange(part.offset..<part.offset + part.data.count, with: part.data)
            filled += part.data.count
        }
        return filled == length ? whole : nil
    }

    static func segment(_ marker: UInt8, _ payload: [UInt8]) -> Data {
        let length = payload.count + 2
        return Data([0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload)
    }

    /// APP1 "Exif" holding the minimal TIFF block below.
    static func minimalEXIF(orientation: Int) -> Data {
        segment(0xE1, exifHeader + minimalTIFF(orientation: orientation))
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
    static func segments(_ data: Data) throws -> (headers: [(marker: UInt8, bytes: Data)], imageData: Data) {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { throw Malformed() }
        var headers: [(marker: UInt8, bytes: Data)] = []
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { throw Malformed() }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xDA { return (headers, Data(b[i...])) }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { // no length field
                headers.append((marker, Data(b[i..<i + 2])))
                i += 2
                continue
            }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { throw Malformed() }
            headers.append((marker, Data(b[i..<i + 2 + length])))
            i += 2 + length
        }
        throw Malformed()
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements.
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
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
