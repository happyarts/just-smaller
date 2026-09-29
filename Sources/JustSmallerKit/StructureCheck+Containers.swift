import Foundation

extension StructureCheck {
    // MARK: - WebP

    private static func le(_ b: ArraySlice<UInt8>, _ at: Int, _ bytes: Int) -> Int {
        (0..<bytes).reduce(0) { $0 | Int(b[at + $1]) << (8 * $1) }
    }

    /// The RIFF size and every chunk size, the chunk order and VP8X flags of
    /// the WebP container specification, and the bitstream headers with the
    /// dimensions the container states. The colour profile and unknown
    /// chunks must be the original's.
    static func webp(_ b: [UInt8], original a: [UInt8]) throws {
        let all = b[...]
        guard b.count >= 20, all.starts(with: Array("RIFF".utf8)), b[8..<12].elementsEqual("WEBP".utf8) else { throw Invalid("RIFF header") }
        guard le(all, 4, 4) == b.count - 8 else { throw Invalid("RIFF size") }
        let chunks = try riffChunks(all, from: 12)
        let before = (try? riffChunks(a[...], from: 12)) ?? []
        guard let first = chunks.first else { throw Invalid("no image") }

        switch first.type {
        case "VP8 ", "VP8L":
            guard chunks.count == 1 else { throw Invalid("chunks after a simple image") }
            _ = try bitstreamSize(first.type, first.data)
        case "VP8X":
            let p = first.data, s = p.startIndex
            guard p.count == 10, p[s] & 0b1100_0001 == 0, p[s + 1] == 0, p[s + 2] == 0, p[s + 3] == 0 else { throw Invalid("VP8X") }
            let flags = p[s]
            let canvas = (le(p, s + 4, 3) + 1, le(p, s + 7, 3) + 1)
            guard canvas.0 * canvas.1 <= 0xFFFF_FFFF else { throw Invalid("VP8X canvas") }
            let rest = Array(chunks.dropFirst())
            let types = rest.map(\.type)
            func has(_ t: String) -> Bool { types.contains(t) }
            guard (flags & 0x20 != 0) == has("ICCP"), (flags & 0x08 != 0) == has("EXIF"),
                  (flags & 0x04 != 0) == has("XMP "), (flags & 0x02 != 0) == has("ANIM")
            else { throw Invalid("VP8X flags don’t match the chunks") }
            // ICCP, ANIM, image data, EXIF, XMP, then unknown chunks.
            let rank: [String: Int] = ["ICCP": 1, "ANIM": 2, "ALPH": 3, "VP8 ": 3, "VP8L": 3, "ANMF": 3, "EXIF": 4, "XMP ": 5]
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
                guard let anim = rest.first(where: { $0.type == "ANIM" }), anim.data.count == 6 else { throw Invalid("ANIM") }
                for frame in rest where frame.type == "ANMF" {
                    try animationFrame(frame.data, canvas: canvas)
                }
            } else {
                guard !has("ANMF"), let image = rest.first(where: { $0.type == "VP8 " || $0.type == "VP8L" }) else { throw Invalid("no image") }
                guard try bitstreamSize(image.type, image.data) == canvas else { throw Invalid("canvas size") }
                if let alpha = rest.first(where: { $0.type == "ALPH" }) {
                    guard flags & 0x10 != 0 else { throw Invalid("alpha flag missing") }
                    try alphaHeader(alpha.data)
                }
            }
            for chunk in rest where rank[chunk.type] == nil || chunk.type == "ICCP" {
                guard before.contains(where: { $0.type == chunk.type && $0.data.elementsEqual(chunk.data) }) else {
                    throw Invalid("\(chunk.type) changed")
                }
            }
        default:
            throw Invalid("unknown first chunk")
        }
    }

    private static func riffChunks(_ b: ArraySlice<UInt8>, from start: Int) throws -> [(type: String, data: ArraySlice<UInt8>)] {
        var out: [(type: String, data: ArraySlice<UInt8>)] = [], i = start
        while i < b.endIndex {
            guard i + 8 <= b.endIndex else { throw Invalid("truncated chunk") }
            let size = le(b, i + 4, 4)
            guard size <= b.endIndex - i - 8 else { throw Invalid("chunk size") }
            out.append((String(decoding: b[i..<i + 4], as: UTF8.self), b[i + 8..<i + 8 + size]))
            i += 8 + size
            if size & 1 == 1 {
                guard i < b.endIndex, b[i] == 0 else { throw Invalid("chunk padding") }
                i += 1
            }
        }
        return out
    }

    private static func animationFrame(_ p: ArraySlice<UInt8>, canvas: (Int, Int)) throws {
        let s = p.startIndex
        guard p.count >= 16 + 8 else { throw Invalid("ANMF") }
        let x = 2 * le(p, s, 3), y = 2 * le(p, s + 3, 3), w = le(p, s + 6, 3) + 1, h = le(p, s + 9, 3) + 1
        guard x + w <= canvas.0, y + h <= canvas.1, p[s + 15] & 0b1111_1100 == 0 else { throw Invalid("ANMF") }
        let inner = try riffChunks(p, from: s + 16)
        guard let image = inner.first(where: { $0.type == "VP8 " || $0.type == "VP8L" }),
              try bitstreamSize(image.type, image.data) == (w, h)
        else { throw Invalid("ANMF image") }
        if let k = inner.firstIndex(where: { $0.type == "ALPH" }) {
            guard k == 0, inner.count > 1, inner[1].type == "VP8 " else { throw Invalid("ANMF alpha") }
            try alphaHeader(inner[0].data)
        }
    }

    private static func alphaHeader(_ p: ArraySlice<UInt8>) throws {
        guard let h = p.first, h & 0b1100_0000 == 0, h & 0b11 <= 1, (h >> 4) & 0b11 <= 1 else { throw Invalid("ALPH") }
    }

    /// Width and height from a VP8 key frame or VP8L header.
    private static func bitstreamSize(_ type: String, _ p: ArraySlice<UInt8>) throws -> (Int, Int) {
        let s = p.startIndex
        if type == "VP8L" {
            guard p.count >= 5, p[s] == 0x2F else { throw Invalid("VP8L header") }
            let bits = le(p, s + 1, 4)
            guard bits >> 29 == 0 else { throw Invalid("VP8L version") }
            return ((bits & 0x3FFF) + 1, (bits >> 14 & 0x3FFF) + 1)
        }
        guard p.count >= 10 else { throw Invalid("VP8 header") }
        let tag = le(p, s, 3)
        guard tag & 1 == 0, tag >> 1 & 7 <= 3, tag >> 4 & 1 == 1, tag >> 5 <= p.count - 10,
              p[s + 3] == 0x9D, p[s + 4] == 0x01, p[s + 5] == 0x2A
        else { throw Invalid("VP8 header") }
        return (le(p, s + 6, 2) & 0x3FFF, le(p, s + 8, 2) & 0x3FFF)
    }

    // MARK: - HEIF

    private struct Box {
        let type: String
        let payload: Range<Int>
    }

    private static func be(_ b: [UInt8], _ at: Int, _ bytes: Int) -> Int {
        (0..<bytes).reduce(0) { $0 << 8 | Int(b[at + $1]) }
    }

    /// The boxes in `range`, which they must fill exactly.
    private static func boxes(_ b: [UInt8], _ range: Range<Int>, topLevel: Bool = false) throws -> [Box] {
        var out: [Box] = [], i = range.lowerBound
        while i < range.upperBound {
            guard i + 8 <= range.upperBound else { throw Invalid("truncated box") }
            var size = be(b, i, 4), header = 8
            let type = String(decoding: b[i + 4..<i + 8], as: UTF8.self)
            if size == 1 {
                guard i + 16 <= range.upperBound else { throw Invalid("truncated box") }
                size = be(b, i + 8, 8); header = 16
            } else if size == 0 {
                guard topLevel else { throw Invalid("\(type) size") }
                size = range.upperBound - i
            }
            if type == "uuid" { header += 16 }
            guard size >= header, size <= range.upperBound - i else { throw Invalid("\(type) size") }
            out.append(Box(type: type, payload: i + header..<i + size))
            i += size
        }
        return out
    }

    /// The box structure of the whole file, the brand of the original, and
    /// the item locations: every item's data inside the file's mdat or idat.
    static func heif(_ b: [UInt8], original a: [UInt8]) throws {
        let top = try boxes(b, 0..<b.count, topLevel: true)
        guard let ftyp = top.first, ftyp.type == "ftyp", ftyp.payload.count >= 8, (ftyp.payload.count - 8) % 4 == 0 else { throw Invalid("ftyp") }
        guard a.count >= 12, b[ftyp.payload.prefix(4)].elementsEqual(a[8..<12]) else { throw Invalid("brand changed") }
        let metas = top.filter { $0.type == "meta" }
        guard metas.count == 1, let meta = metas.first, meta.payload.count >= 4 else { throw Invalid("meta") }
        let children = try boxes(b, meta.payload.lowerBound + 4..<meta.payload.upperBound)
        func one(_ type: String) throws -> Box {
            let found = children.filter { $0.type == type }
            guard found.count == 1 else { throw Invalid(type) }
            return found[0]
        }
        let hdlr = try one("hdlr")
        guard hdlr.payload.count >= 12, b[hdlr.payload.lowerBound + 8..<hdlr.payload.lowerBound + 12].elementsEqual("pict".utf8)
        else { throw Invalid("hdlr") }
        for container in children where ["iprp", "dinf"].contains(container.type) {
            for inner in try boxes(b, container.payload) where inner.type == "ipco" {
                _ = try boxes(b, inner.payload)
            }
        }

        // Items
        let iinf = try one("iinf"), ip = iinf.payload.lowerBound
        let wide = iinf.payload.count >= 1 && b[ip] != 0
        guard iinf.payload.count >= (wide ? 8 : 6) else { throw Invalid("iinf") }
        let entries = be(b, ip + 4, wide ? 4 : 2)
        let infes = try boxes(b, ip + 4 + (wide ? 4 : 2)..<iinf.payload.upperBound)
        guard infes.count == entries, infes.allSatisfy({ $0.type == "infe" && $0.payload.count >= 8 }) else { throw Invalid("iinf") }
        let ids = Set(infes.map { box in
            let p = box.payload.lowerBound
            return b[p] >= 3 ? be(b, p + 4, 4) : be(b, p + 4, 2)
        })
        let pitm = try one("pitm"), pp = pitm.payload.lowerBound
        guard pitm.payload.count >= 6, pitm.payload.count >= (b[pp] == 0 ? 6 : 8), ids.contains(b[pp] == 0 ? be(b, pp + 4, 2) : be(b, pp + 4, 4)) else { throw Invalid("pitm") }

        let data = top.filter { $0.type == "mdat" }.map(\.payload)
        let idat = children.first { $0.type == "idat" }?.payload
        let iloc = try one("iloc")
        var k = iloc.payload.lowerBound
        let end = iloc.payload.upperBound
        func read(_ bytes: Int) throws -> Int {
            guard k + bytes <= end else { throw Invalid("iloc") }
            defer { k += bytes }
            return be(b, k, bytes)
        }
        let version = try read(1); _ = try read(3)
        let sizes = try read(1), more = try read(1)
        let offsetSize = sizes >> 4, lengthSize = sizes & 15, baseSize = more >> 4, indexSize = version > 0 ? more & 15 : 0
        guard version <= 2, [offsetSize, lengthSize, baseSize, indexSize].allSatisfy({ [0, 4, 8].contains($0) }) else { throw Invalid("iloc") }
        let items = try read(version < 2 ? 2 : 4)
        for _ in 0..<items {
            let id = try read(version < 2 ? 2 : 4)
            let method = try version > 0 ? read(2) & 15 : 0
            let reference = try read(2), base = try read(baseSize), extents = try read(2)
            guard ids.contains(id), reference == 0, method <= 2 else { throw Invalid("iloc item") }
            for _ in 0..<extents {
                _ = try read(indexSize)
                let offset = try read(offsetSize), length = try read(lengthSize)
                let start = base + offset
                let inside: Bool
                switch method {
                case 0: inside = data.contains { $0.contains(start) && start + length <= $0.upperBound }
                case 1: inside = idat.map { start + length <= $0.count } ?? false
                default: inside = true // points into another item
                }
                guard inside else { throw Invalid("item data outside the file") }
            }
        }
    }

    // MARK: - SVG

    /// Well-formed XML with an svg root, if the original was.
    static func svg(_ b: [UInt8], original a: [UInt8]) throws {
        guard let root = rootElement(a) else { return }
        guard String(bytes: b, encoding: .utf8) != nil || String(bytes: a, encoding: .utf8) == nil else { throw Invalid("not UTF-8") }
        guard rootElement(b) == root else { throw Invalid("not well-formed XML") }
    }

    private final class RootFinder: NSObject, XMLParserDelegate {
        var root: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if root == nil { root = name }
        }
    }

    /// The root element's name, nil if the document isn't well-formed.
    private static func rootElement(_ b: [UInt8]) -> String? {
        XMPFilter.lock.withLock {
            let parser = XMLParser(data: Data(b)), finder = RootFinder()
            parser.delegate = finder
            parser.shouldResolveExternalEntities = false
            return parser.parse() ? finder.root : nil
        }
    }
}
