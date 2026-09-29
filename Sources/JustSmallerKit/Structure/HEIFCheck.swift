import Foundation

/// HEIF (ISO 23008-12 on ISO BMFF): boxes that fill the file exactly, the
/// original's brand, one meta box with handler, primary item, item infos
/// and locations — every item's data inside the file's mdat or idat — and
/// property associations and item references that point at what exists.
enum HEIFCheck {
    typealias Invalid = StructureCheck.Invalid

    /// What the original contributes: its major brand.
    struct Reference {
        let brand: Data?
        init(_ a: ByteView) { brand = try? a.view(8, 4).bytes }
    }

    private struct Box {
        let type: String
        let payload: ByteView
        /// Where the payload starts in the view the box was read from.
        let offset: Int
    }

    /// The boxes in `b`, which they must fill exactly.
    private static func boxes(_ b: ByteView, topLevel: Bool = false) throws -> [Box] {
        var out: [Box] = [], i = 0
        while i < b.count {
            var size = try b.be(i, 4), header = 8
            let type = String(decoding: try b.view(i + 4, 4).bytes, as: UTF8.self)
            if size == 1 {
                size = try b.be(i + 8, 8); header = 16
            } else if size == 0 {
                guard topLevel else { throw Invalid("\(type) size") }
                size = b.count - i
            }
            if type == "uuid" { header += 16 }
            guard size >= header, size <= b.count - i else { throw Invalid("\(type) size") }
            out.append(Box(type: type, payload: try b.view(i + header, size - header), offset: i + header))
            i += size
        }
        return out
    }

    /// A full box's children, after its version and flags and `extra` bytes.
    private static func children(_ box: Box, skipping extra: Int = 0) throws -> [Box] {
        try boxes(box.payload.view(from: 4 + extra))
    }

    private static func one(_ type: String, in boxes: [Box]) throws -> Box {
        let found = boxes.filter { $0.type == type }
        guard found.count == 1 else { throw Invalid(type) }
        return found[0]
    }

    static func check(_ b: ByteView, against reference: Reference) throws {
        let top = try boxes(b, topLevel: true)
        guard let ftyp = top.first, ftyp.type == "ftyp", ftyp.payload.count >= 8, (ftyp.payload.count - 8) % 4 == 0 else { throw Invalid("ftyp") }
        guard try ftyp.payload.view(0, 4).bytes == reference.brand else { throw Invalid("brand changed") }
        let meta = try children(one("meta", in: top))
        let hdlr = try one("hdlr", in: meta)
        guard hdlr.payload.has("pict", at: 8) else { throw Invalid("hdlr") }

        // Items
        let iinf = try one("iinf", in: meta)
        let wide = try iinf.payload.u8(0) != 0
        let entries = try iinf.payload.be(4, wide ? 4 : 2)
        let infes = try children(iinf, skipping: wide ? 4 : 2)
        guard infes.count == entries, infes.allSatisfy({ $0.type == "infe" }) else { throw Invalid("iinf") }
        let ids = Set(try infes.map { box in try box.payload.u8(0) >= 3 ? box.payload.be(4, 4) : box.payload.be(4, 2) })
        let pitm = try one("pitm", in: meta).payload
        guard ids.contains(try pitm.u8(0) == 0 ? pitm.be(4, 2) : pitm.be(4, 4)) else { throw Invalid("pitm") }

        try locations(one("iloc", in: meta).payload, ids: ids,
                      mdat: top.filter { $0.type == "mdat" }.map { $0.offset..<$0.offset + $0.payload.count },
                      idat: meta.first { $0.type == "idat" }?.payload.count)

        // Properties: every association points at an existing property.
        if let iprp = meta.first(where: { $0.type == "iprp" }) {
            let inner = try boxes(iprp.payload)
            let properties = try boxes(one("ipco", in: inner).payload).count
            for ipma in inner where ipma.type == "ipma" {
                try associations(ipma.payload, ids: ids, properties: properties)
            }
        }
        // References: from and to existing items.
        if let iref = meta.first(where: { $0.type == "iref" }) {
            let wideIDs = try iref.payload.u8(0) != 0
            for reference in try children(iref) {
                let p = reference.payload, size = wideIDs ? 4 : 2
                guard ids.contains(try p.be(0, size)) else { throw Invalid("item reference") }
                let count = try p.be(size, 2)
                guard p.count == size + 2 + count * size else { throw Invalid("item reference") }
                for k in 0..<count where !ids.contains(try p.be(size + 2 + k * size, size)) {
                    throw Invalid("item reference")
                }
            }
        }
    }

    /// iloc: every extent inside an mdat box (construction method 0), the
    /// idat box (1), or another item (2).
    private static func locations(_ p: ByteView, ids: Set<Int>, mdat: [Range<Int>], idat: Int?) throws {
        var k = 0
        func read(_ bytes: Int) throws -> Int {
            defer { k += bytes }
            return try p.be(k, bytes)
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
                let start = try base + read(offsetSize), length = try read(lengthSize)
                let inside = switch method {
                case 0: mdat.contains { $0.contains(start) && start + length <= $0.upperBound }
                case 1: idat.map { start + length <= $0 } ?? false
                default: true // points into another item
                }
                guard inside else { throw Invalid("item data outside the file") }
            }
        }
        guard k == p.count else { throw Invalid("iloc") }
    }

    /// ipma: items and 1-based property indices (0 means none).
    private static func associations(_ p: ByteView, ids: Set<Int>, properties: Int) throws {
        let version = try p.u8(0), large = try p.be(1, 3) & 1 == 1
        var k = 4
        let entries = try p.be(k, 4); k += 4
        for _ in 0..<entries {
            let idSize = version < 1 ? 2 : 4
            guard ids.contains(try p.be(k, idSize)) else { throw Invalid("property association") }
            k += idSize
            let count = try p.u8(k); k += 1
            for _ in 0..<count {
                let index = large ? try p.be(k, 2) & 0x7FFF : try p.u8(k) & 0x7F
                guard index <= properties else { throw Invalid("property association") }
                k += large ? 2 : 1
            }
        }
        guard k == p.count else { throw Invalid("ipma") }
    }
}
