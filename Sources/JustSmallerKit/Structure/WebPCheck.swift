import Foundation

/// WebP after its container specification: the RIFF size and every chunk
/// size and padding byte, the chunk order and VP8X flags, and the bitstream
/// headers with the dimensions the container states. The colour profile and
/// unknown chunks must be the original's; EXIF and XMP a step rewrote are
/// checked on their own.
enum WebPCheck {
    typealias Invalid = StructureCheck.Invalid

    /// What the original contributes: its chunks, read leniently.
    struct Reference {
        let chunks: ChunkSet
        init(_ a: ByteView) { chunks = ChunkSet(WebPCheck.chunks(lenient: a)) }
    }

    /// Image data: checked above, never compared with the original's.
    private static let imageData: Set<String> = ["ALPH", "VP8 ", "VP8L", "ANMF"]

    /// ICCP, ANIM, image data, EXIF, XMP, then unknown chunks.
    private static let rank: [String: Int] = ["ICCP": 1, "ANIM": 2, "ALPH": 3, "VP8 ": 3, "VP8L": 3, "ANMF": 3, "EXIF": 4, "XMP ": 5]

    static func check(_ b: ByteView, against reference: Reference) throws {
        guard b.has("RIFF"), b.has("WEBP", at: 8) else { throw Invalid("RIFF header") }
        guard try b.le(4, 4) == b.count - 8 else { throw Invalid("RIFF size") }
        let chunks = try chunks(b.view(from: 12))
        guard let first = chunks.first else { throw Invalid("no image") }

        switch first.type {
        case "VP8 ", "VP8L":
            guard chunks.count == 1 else { throw Invalid("chunks after a simple image") }
            _ = try bitstreamSize(first)
        case "VP8X":
            try extended(first.data, Array(chunks.dropFirst()), reference: reference)
        default:
            throw Invalid("unknown first chunk")
        }
    }

    private static func extended(_ p: ByteView, _ rest: [Chunk], reference: Reference) throws {
        guard p.count == 10, try p.u8(0) & 0b1100_0001 == 0, try p.be(1, 3) == 0 else { throw Invalid("VP8X") }
        let flags = try p.u8(0)
        let canvas = (try p.le(4, 3) + 1, try p.le(7, 3) + 1)
        guard canvas.0 * canvas.1 <= 0xFFFF_FFFF else { throw Invalid("VP8X canvas") }
        func has(_ t: String) -> Bool { rest.contains { $0.type == t } }
        guard (flags & 0x20 != 0) == has("ICCP"), (flags & 0x08 != 0) == has("EXIF"),
              (flags & 0x04 != 0) == has("XMP "), (flags & 0x02 != 0) == has("ANIM")
        else { throw Invalid("VP8X flags don’t match the chunks") }

        var last = 0, seen: Set<String> = []
        for (k, chunk) in rest.enumerated() {
            let r = rank[chunk.type] ?? 6
            guard r >= last else { throw Invalid("\(chunk.type) out of order") }
            last = r
            guard chunk.type == "ANMF" || r == 6 || seen.insert(chunk.type).inserted else { throw Invalid("second \(chunk.type)") }
            if chunk.type == "ALPH", k + 1 == rest.count || rest[k + 1].type != "VP8 " { throw Invalid("ALPH without VP8") }
        }

        if flags & 0x02 != 0 {
            guard has("ANMF"), !has("VP8 "), !has("VP8L"), !has("ALPH") else { throw Invalid("animation") }
            guard rest.first(where: { $0.type == "ANIM" })?.data.count == 6 else { throw Invalid("ANIM") }
            for frame in rest where frame.type == "ANMF" {
                try animationFrame(frame.data, canvas: canvas)
            }
        } else {
            guard !has("ANMF"), let image = rest.first(where: { $0.type == "VP8 " || $0.type == "VP8L" }) else { throw Invalid("no image") }
            guard try bitstreamSize(image) == canvas else { throw Invalid("canvas size") }
            if let alpha = rest.first(where: { $0.type == "ALPH" }) {
                guard flags & 0x10 != 0 else { throw Invalid("alpha flag missing") }
                try alphaHeader(alpha.data)
            }
        }

        for chunk in rest where !imageData.contains(chunk.type) && !reference.chunks.contains(chunk) {
            switch chunk.type {
            case "EXIF":
                try Invalid.within("EXIF") { try PayloadCheck.tiff(chunk.data.view(from: WebPMetadataFilter.tiffOffset(chunk.data.bytes))) }
            case "XMP ":
                try Invalid.within("XMP") { try PayloadCheck.xml(chunk.data) }
            case "ICCP":
                throw Invalid("colour profile changed")
            default:
                throw Invalid("\(chunk.type) changed")
            }
        }
    }

    /// The chunks of a file read leniently: as many as fit.
    static func chunks(lenient a: ByteView) -> [Chunk] {
        var out: [Chunk] = [], i = 12
        while let size = try? a.le(i + 4, 4), let data = try? a.view(i + 8, size), let type = try? a.view(i, 4) {
            out.append(Chunk(type: String(decoding: type.bytes, as: UTF8.self), data: data))
            i += 8 + size + (size & 1)
        }
        return out
    }

    /// The chunks of a RIFF body, which they must fill exactly.
    static func chunks(_ b: ByteView) throws -> [Chunk] {
        var out: [Chunk] = [], i = 0
        while i < b.count {
            let size = try b.le(i + 4, 4)
            out.append(Chunk(type: String(decoding: try b.view(i, 4).bytes, as: UTF8.self), data: try b.view(i + 8, size)))
            i += 8 + size
            if size & 1 == 1 {
                guard try b.u8(i) == 0 else { throw Invalid("chunk padding") }
                i += 1
            }
        }
        return out
    }

    private static func animationFrame(_ p: ByteView, canvas: (Int, Int)) throws {
        let x = 2 * (try p.le(0, 3)), y = 2 * (try p.le(3, 3)), w = try p.le(6, 3) + 1, h = try p.le(9, 3) + 1
        guard x + w <= canvas.0, y + h <= canvas.1, try p.u8(15) & 0b1111_1100 == 0 else { throw Invalid("ANMF") }
        let inner = try chunks(p.view(from: 16))
        guard let image = inner.first(where: { $0.type == "VP8 " || $0.type == "VP8L" }), try bitstreamSize(image) == (w, h)
        else { throw Invalid("ANMF image") }
        if let k = inner.firstIndex(where: { $0.type == "ALPH" }) {
            guard k == 0, inner.count > 1, inner[1].type == "VP8 " else { throw Invalid("ANMF alpha") }
            try alphaHeader(inner[0].data)
        }
    }

    private static func alphaHeader(_ p: ByteView) throws {
        let h = try p.u8(0)
        guard h & 0b1100_0000 == 0, h & 0b11 <= 1, (h >> 4) & 0b11 <= 1 else { throw Invalid("ALPH") }
    }

    /// Width and height from a VP8 key frame or VP8L header.
    private static func bitstreamSize(_ chunk: Chunk) throws -> (Int, Int) {
        let p = chunk.data
        if chunk.type == "VP8L" {
            guard try p.u8(0) == 0x2F else { throw Invalid("VP8L header") }
            let bits = try p.le(1, 4)
            guard bits >> 29 == 0 else { throw Invalid("VP8L version") }
            return ((bits & 0x3FFF) + 1, (bits >> 14 & 0x3FFF) + 1)
        }
        let tag = try p.le(0, 3)
        guard tag & 1 == 0, tag >> 1 & 7 <= 3, tag >> 4 & 1 == 1, tag >> 5 <= p.count - 10, p.has([0x9D, 0x01, 0x2A], at: 3)
        else { throw Invalid("VP8 header") }
        return (try p.le(6, 2) & 0x3FFF, try p.le(8, 2) & 0x3FFF)
    }
}
