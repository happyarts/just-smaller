import Foundation

/// The one way the engine walks a JPEG's markers: the metadata filter, the
/// quality estimate, the multi-picture index and the structure check all
/// read through here, and through ByteView.
enum JPEGMarkers {
    static let exifHeader = Array("Exif\0\0".utf8)
    static let xmpHeader = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    static let extendedXMPHeader = Array("http://ns.adobe.com/xmp/extension/\0".utf8)
    static let photoshopHeader = Array("Photoshop 3.0\0".utf8)

    /// What an APPn or COM segment holds, by its marker and signature. The
    /// metadata filter rewrites EXIF, XMP and IPTC (Photoshop); the structure
    /// check checks what was rewritten and requires the rest unchanged.
    enum Part {
        case jfif, jfifExtension, exif, xmp, extendedXMP, photoshop, iccProfile, multiPicture, isoGainMap, adobe, comment, other
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
        case 0xE2 where has(Array("urn:iso:std:iso:ts:21496:-1\0".utf8)): return .isoGainMap
        case 0xED where has(photoshopHeader): return .photoshop
        case 0xEE where has(Array("Adobe".utf8)): return .adobe
        case 0xFE: return .comment
        default: return .other
        }
    }

    /// A segment with a length field: marker, length, payload.
    static func write(_ marker: UInt8, _ payload: [UInt8]) -> Data {
        let length = payload.count + 2
        return Data([0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload)
    }

    /// One part of JPEG's extended XMP (after its header): the GUID of the
    /// packet it belongs to, the whole packet's length, where this part goes.
    static func extendedXMPPart(_ p: ByteView) throws -> (guid: String, length: Int, offset: Int, data: ByteView) {
        let guid = try p.view(0, 32)
        guard guid.bytes.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) }) else { throw FormatError("GUID") }
        let part = (guid: String(decoding: guid.bytes, as: UTF8.self), length: try p.be(32, 4), offset: try p.be(36, 4),
                    data: try p.view(from: 40))
        guard part.offset + part.data.count <= part.length else { throw FormatError("part outside the packet") }
        return part
    }

    /// The extended XMP packet with `packet`'s GUID, put together from its
    /// parts; nil unless the parts fill it exactly. Its length is taken from
    /// the file only once the parts' data adds up to it.
    static func extendedXMP(_ chunks: [Data], for packet: Data) -> Data? {
        let parts = chunks.compactMap { try? extendedXMPPart(ByteView($0)) }
        guard let guid = parts.map(\.guid).first(where: { packet.range(of: Data($0.utf8)) != nil }) else { return nil }
        let mine = parts.filter { $0.guid == guid }
        let length = mine[0].length
        guard mine.allSatisfy({ $0.length == length }), mine.reduce(0, { $0 + $1.data.count }) == length else { return nil }
        var whole = Data(count: length)
        var covered = IndexSet()
        for part in mine {
            let range = part.offset..<part.offset + part.data.count
            guard !covered.intersects(integersIn: range) else { return nil }
            covered.insert(integersIn: range)
            whole.replaceSubrange(range, with: part.data.bytes)
        }
        return whole
    }

    /// The quantization tables of a DQT payload: id and 64 steps (8 or 16
    /// bit). Leniently, the tables before a truncated one.
    static func quantTables(_ p: ByteView, strict: Bool = true) throws -> [(id: Int, precision: Int, steps: [Int])] {
        var out: [(id: Int, precision: Int, steps: [Int])] = [], k = 0
        while k < p.count {
            do {
                let precision = try p.u8(k) >> 4, id = try p.u8(k) & 15
                let steps = try (0..<64).map { try precision == 0 ? p.u8(k + 1 + $0) : p.be(k + 1 + 2 * $0, 2) }
                out.append((id, precision, steps))
                k += precision == 0 ? 65 : 129
            } catch where !strict {
                break
            }
        }
        return out
    }
    struct Segment {
        let marker: UInt8
        /// Where the marker starts (after any fill bytes).
        let offset: Int
        /// The whole segment: marker, length and payload.
        let whole: ByteView
        /// After the length field; empty for markers without one.
        let payload: ByteView
        var end: Int { offset + whole.count }
    }

    /// SOI, EOI, the restart markers and TEM stand alone, without a length.
    static func hasLength(_ marker: UInt8) -> Bool { !(marker == 0x01 || (0xD0...0xD9).contains(marker)) }

    /// The segment at `i`, after any 0xFF fill bytes.
    static func segment(at i: Int, in b: ByteView) throws -> Segment {
        guard try b.u8(i) == 0xFF else { throw FormatError("data between segments") }
        var at = i
        while try b.u8(at + 1) == 0xFF { at += 1 }
        let marker = UInt8(try b.u8(at + 1))
        guard hasLength(marker) else {
            return Segment(marker: marker, offset: at, whole: try b.view(at, 2), payload: try b.view(at + 2, 0))
        }
        let length = try b.be(at + 2, 2)
        guard length >= 2 else { throw FormatError("segment length") }
        return Segment(marker: marker, offset: at, whole: try b.view(at, 2 + length), payload: try b.view(at + 4, length - 2))
    }

    /// The segments from after SOI up to the first scan (SOS), and where it starts.
    static func headers(_ b: ByteView) throws -> (segments: [Segment], scan: Int) {
        guard try b.be(0, 2) == 0xFFD8 else { throw FormatError("no SOI") }
        var segments: [Segment] = [], i = 2
        while true {
            let s = try segment(at: i, in: b)
            if s.marker == 0xDA { return (segments, s.offset) }
            if s.marker == 0xD9 { throw FormatError("no scan") }
            segments.append(s)
            i = s.end
        }
    }

    /// Where the JPEG that starts at `start` ends: after its EOI.
    static func imageEnd(from start: Int, in b: ByteView) throws -> Int {
        guard try b.be(start, 2) == 0xFFD8 else { throw FormatError("no SOI") }
        var i = start + 2
        while true {
            let s = try segment(at: i, in: b)
            if s.marker == 0xD9 { return s.end }
            i = s.marker == 0xDA ? entropyData(from: s.end, in: b).end : s.end
        }
    }

    /// Entropy-coded data from `start`: where the marker after it begins
    /// (the view's end when none follows), how many restart markers are on
    /// the way, and whether they count 0–7 in turn.
    static func entropyData(from start: Int, in b: ByteView) -> (end: Int, restarts: Int, inSequence: Bool) {
        var k = start, restarts = 0, inSequence = true
        while let next = b.index(of: 0xFF, from: k), let m = try? b.u8(next + 1) {
            switch m {
            case 0x00: k = next + 2 // a stuffed 0xFF
            case 0xFF: k = next + 1 // fill before a marker
            case 0xD0...0xD7:
                inSequence = inSequence && m - 0xD0 == restarts % 8
                restarts += 1
                k = next + 2
            default: return (next, restarts, inSequence)
            }
        }
        return (b.count, restarts, inSequence)
    }
}
