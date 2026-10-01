import Foundation

/// HEIF (ISO 23008-12 on ISO BMFF): boxes that fill the file exactly, the
/// original's brand, one meta box with handler, primary item, item infos
/// and locations — every item's data inside the file's mdat or idat — and
/// property associations and item references that point at what exists.
enum HEIFCheck {
    typealias Invalid = FormatError

    /// What the original contributes: its major brand.
    struct Reference {
        let brand: Data?
        init(_ a: ByteView) { brand = try? a.view(8, 4).bytes }
    }

    private typealias Box = BMFFBoxes.Box

    private static func boxes(_ b: ByteView, topLevel: Bool = false) throws -> [Box] {
        try BMFFBoxes.boxes(b, topLevel: topLevel)
    }

    /// A full box's children, after its version and flags.
    private static func children(_ box: Box) throws -> [Box] {
        try boxes(box.payload.view(from: 4))
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
        let infos = try HEIFItems.infos(iinf)
        guard infos.count == (try iinf.payload.be(4, wide ? 4 : 2)) else { throw Invalid("iinf") }
        let ids = Set(infos.map(\.id))
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
        // Entity groups (e.g. an image with and without its gain map): ids
        // of their own, shared with no item and no other group.
        if let grpl = meta.first(where: { $0.type == "grpl" }) {
            let groups = try boxes(grpl.payload).map { try $0.payload.be(4, 4) }
            guard Set(groups).count == groups.count, Set(groups).isDisjoint(with: ids) else { throw Invalid("entity group") }
        }
        // References: from and to existing items.
        if let iref = meta.first(where: { $0.type == "iref" }) {
            guard try HEIFItems.references(iref).allSatisfy({ ids.contains($0.from) && $0.to.allSatisfy(ids.contains) }) else {
                throw Invalid("item reference")
            }
        }
    }

    /// iloc: every extent inside an mdat box (construction method 0), the
    /// idat box (1), or another item (2).
    private static func locations(_ p: ByteView, ids: Set<Int>, mdat: [Range<Int>], idat: Int?) throws {
        for location in try HEIFItems.locations(p).items {
            guard ids.contains(location.id), location.method <= 2 else { throw Invalid("iloc item") }
            for extent in location.extents {
                let start = extent.start, length = extent.length
                let inside = switch location.method {
                case 0: mdat.contains { $0.contains(start) && length <= $0.upperBound - start }
                case 1: idat.map { length <= $0 - start } ?? false
                default: true // points into another item
                }
                guard inside else { throw Invalid("item data outside the file") }
            }
        }
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
