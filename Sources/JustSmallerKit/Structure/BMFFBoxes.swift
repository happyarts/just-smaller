import Foundation

/// The one way the engine reads ISO base media file boxes (HEIF): format
/// detection, the structure check and the HEIC metadata filter.
enum BMFFBoxes {
    struct Box {
        let type: String
        let payload: ByteView
        /// Where the payload starts in the view the box was read from.
        let offset: Int
        /// The whole box, header included.
        let size: Int
    }

    /// The box at `i`: 32-bit size (1: a 64-bit size follows; 0: to the end,
    /// top level only), type, and 16 more bytes of type for "uuid".
    static func box(at i: Int, in b: ByteView, topLevel: Bool = false) throws -> Box {
        var size = try b.be(i, 4), header = 8
        let type = String(decoding: try b.view(i + 4, 4).bytes, as: UTF8.self)
        if size == 1 {
            size = try b.be(i + 8, 8); header = 16
        } else if size == 0 {
            guard topLevel else { throw FormatError("\(type) size") }
            size = b.count - i
        }
        if type == "uuid" { header += 16 }
        guard size >= header, size <= b.count - i else { throw FormatError("\(type) size") }
        return Box(type: type, payload: try b.view(i + header, size - header), offset: i + header, size: size)
    }

    /// The boxes in `b`, which they must fill exactly.
    static func boxes(_ b: ByteView, topLevel: Bool = false) throws -> [Box] {
        var out: [Box] = [], i = 0
        while i < b.count {
            let box = try box(at: i, in: b, topLevel: topLevel)
            out.append(box)
            i += box.size
        }
        return out
    }
}

/// HEIF items (ISO 23008-12): what they are (iinf), how they refer to each
/// other (iref) and where their data lies (iloc) — and a writer that
/// replaces the data of some items, for the HEIC metadata filter.
enum HEIFItems {
    struct Extent {
        let start: Int, length: Int
        /// Where the extent's offset and length fields are in the iloc payload.
        let offsetField: Int, lengthField: Int
    }

    struct Location {
        let id: Int
        /// 0: in the file (an mdat box), 1: in the idat box, 2: in another item.
        let method: Int
        let base: Int
        /// Where the base offset field is in the iloc payload.
        let baseField: Int
        let extents: [Extent]
    }

    /// iloc: the size of its offset, length and base offset fields, and the items.
    struct Locations {
        let offsetSize: Int, lengthSize: Int, baseSize: Int
        let items: [Location]
    }

    struct Info {
        let id: Int
        /// "" for item info entries before version 2.
        let type: String
        /// For "mime" items, e.g. "application/rdf+xml" (XMP).
        let contentType: String?
    }

    /// iinf: what each item is (item info entries of version 2 and 3 carry
    /// a type; older ones read as "").
    static func infos(_ iinf: BMFFBoxes.Box) throws -> [Info] {
        let wide = try iinf.payload.u8(0) != 0
        return try BMFFBoxes.boxes(iinf.payload.view(from: 4 + (wide ? 4 : 2))).map { infe in
            guard infe.type == "infe" else { throw FormatError("iinf") }
            let p = infe.payload, version = try p.u8(0)
            let id = try version >= 3 ? p.be(4, 4) : p.be(4, 2)
            guard version >= 2 else { return Info(id: id, type: "", contentType: nil) }
            let at = version >= 3 ? 10 : 8
            let type = String(decoding: try p.view(at, 4).bytes, as: UTF8.self)
            guard type == "mime" else { return Info(id: id, type: type, contentType: nil) }
            // The item's name, then its content type, each ending in a zero.
            guard let nameEnd = p.index(of: 0, from: at + 4), let typeEnd = p.index(of: 0, from: nameEnd + 1) else { throw FormatError("infe") }
            return Info(id: id, type: type, contentType: String(decoding: try p.view(nameEnd + 1, typeEnd - nameEnd - 1).bytes, as: UTF8.self))
        }
    }

    /// iref: each reference's type, the item it is from and the items it points to.
    static func references(_ iref: BMFFBoxes.Box) throws -> [(type: String, from: Int, to: [Int])] {
        let size = try iref.payload.u8(0) != 0 ? 4 : 2
        return try BMFFBoxes.boxes(iref.payload.view(from: 4)).map { reference in
            let p = reference.payload, count = try p.be(size, 2)
            guard p.count == size + 2 + count * size else { throw FormatError("item reference") }
            return (reference.type, try p.be(0, size), try (0..<count).map { try p.be(size + 2 + $0 * size, size) })
        }
    }

    /// iloc, read to its exact end.
    static func locations(_ p: ByteView) throws -> Locations {
        var k = 0
        func read(_ bytes: Int) throws -> Int {
            defer { k += bytes }
            return try p.be(k, bytes)
        }
        let version = try read(1); _ = try read(3)
        let sizes = try read(1), more = try read(1)
        let offsetSize = sizes >> 4, lengthSize = sizes & 15, baseSize = more >> 4, indexSize = version > 0 ? more & 15 : 0
        guard version <= 2, [offsetSize, lengthSize, baseSize, indexSize].allSatisfy({ [0, 4, 8].contains($0) }) else { throw FormatError("iloc") }
        var items: [Location] = []
        for _ in 0..<(try read(version < 2 ? 2 : 4)) {
            let id = try read(version < 2 ? 2 : 4)
            let method = try version > 0 ? read(2) & 15 : 0
            let reference = try read(2), baseField = k, base = try read(baseSize)
            guard reference == 0, base >= 0 else { throw FormatError("iloc item") }
            var extents: [Extent] = []
            for _ in 0..<(try read(2)) {
                _ = try read(indexSize)
                let offsetField = k, offset = try read(offsetSize), lengthField = k, length = try read(lengthSize)
                // Eight-byte fields can read as negative numbers.
                let (start, overflow) = base.addingReportingOverflow(offset)
                guard !overflow, start >= 0, length >= 0 else { throw FormatError("iloc item") }
                extents.append(Extent(start: start, length: length, offsetField: offsetField, lengthField: lengthField))
            }
            items.append(Location(id: id, method: method, base: base, baseField: baseField, extents: extents))
        }
        guard k == p.count else { throw FormatError("iloc") }
        return Locations(offsetSize: offsetSize, lengthSize: lengthSize, baseSize: baseSize, items: items)
    }

    /// A still image file's items, read for finding and replacing their data.
    struct File {
        let top: [BMFFBoxes.Box]
        let infos: [Info]
        let references: [(type: String, from: Int, to: [Int])]
        let primary: Int
        let locations: Locations
        /// Where the iloc payload starts in the file.
        let ilocStart: Int

        init(_ b: ByteView) throws {
            top = try BMFFBoxes.boxes(b, topLevel: true)
            // Image sequences keep sample offsets of their own.
            guard !top.contains(where: { $0.type == "moov" }) else { throw FormatError("image sequence") }
            let found = top.filter { $0.type == "meta" }
            guard found.count == 1 else { throw FormatError("meta") }
            let metaStart = found[0].offset + 4
            let meta = try BMFFBoxes.boxes(found[0].payload.view(from: 4))
            func one(_ type: String) throws -> BMFFBoxes.Box {
                let found = meta.filter { $0.type == type }
                guard found.count == 1 else { throw FormatError(type) }
                return found[0]
            }
            infos = try HEIFItems.infos(one("iinf"))
            references = try meta.first { $0.type == "iref" }.map(HEIFItems.references) ?? []
            let pitm = try one("pitm").payload
            primary = try pitm.u8(0) == 0 ? pitm.be(4, 2) : pitm.be(4, 4)
            let iloc = try one("iloc")
            locations = try HEIFItems.locations(iloc.payload)
            ilocStart = metaStart + iloc.offset
        }

        /// The items of `type`.
        func items(_ type: String) -> [Int] { infos.filter { $0.type == type }.map(\.id) }

        /// XMP items but those that describe auxiliary images only (a gain
        /// map's parameters, a matte's version): the primary image's, a
        /// thumbnail's, or no image's in particular.
        var metadataXMP: [Int] {
            let auxiliary = Set(references.filter { $0.type == "auxl" }.map(\.from))
            return infos.filter { info in
                let described = references.filter { $0.type == "cdsc" && $0.from == info.id }.flatMap(\.to)
                return info.type == "mime" && info.contentType == "application/rdf+xml"
                    && (described.isEmpty || !described.allSatisfy(auxiliary.contains))
            }.map(\.id)
        }

        /// Where the data of an item lies: one piece inside an mdat box.
        func range(of id: Int) throws -> Range<Int> {
            guard let location = locations.items.first(where: { $0.id == id }), location.method == 0, location.extents.count == 1,
                  case let extent = location.extents[0], extent.length > 0,
                  top.contains(where: { $0.type == "mdat" && extent.start >= $0.offset && extent.length <= $0.offset + $0.payload.count - extent.start })
            else { throw FormatError("item location") }
            return extent.start..<extent.start + extent.length
        }
    }

    /// The file with the data of some items replaced by `new`, each stored
    /// in one piece inside an mdat box. Everything else keeps its bytes;
    /// what follows a replaced item moves, and the item locations (iloc)
    /// and the sizes of the mdat boxes follow. Fields keep their widths.
    static func replacingData(_ new: [Int: [UInt8]], in data: Data) throws -> Data {
        // Positions below count from the start of the file.
        let data = data.startIndex == 0 ? data : Data(data)
        let file = try File(ByteView(data))
        let changes = try new.map { (range: try file.range(of: $0.key), bytes: $0.value) }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        // Every other item's data lies outside what changes, and ends where it says.
        for (a, b) in zip(changes, changes.dropFirst()) where a.range.upperBound > b.range.lowerBound { throw FormatError("item location") }
        for item in file.locations.items where item.method == 0 && new[item.id] == nil {
            for extent in item.extents {
                guard extent.length > 0 else { throw FormatError("item location") }
                let range = extent.start..<extent.start + extent.length
                if changes.contains(where: { $0.range.overlaps(range) }) { throw FormatError("item location") }
            }
        }
        /// Where a position of the old file is in the new one.
        func moved(_ at: Int) -> Int {
            at + changes.filter { $0.range.upperBound <= at }.reduce(0) { $0 + $1.bytes.count - $1.range.count }
        }

        var out = Data(capacity: data.count)
        var at = data.startIndex
        for change in changes {
            out += data[at..<change.range.lowerBound]
            out += change.bytes
            at = change.range.upperBound
        }
        out += data[at...]

        func write(_ value: Int, size: Int, at position: Int) throws {
            guard value >= 0, size == 8 || value >> (8 * size) == 0 else { throw FormatError("field too small") }
            out.replaceSubrange(position..<position + size, with: (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * (size - 1 - $0))) })
        }
        for box in file.top where box.type == "mdat" {
            let delta = changes.filter { $0.range.lowerBound >= box.offset && $0.range.upperBound <= box.offset + box.payload.count }
                .reduce(0) { $0 + $1.bytes.count - $1.range.count }
            guard delta != 0 else { continue }
            let start = box.offset - (box.size - box.payload.count)
            switch try ByteView(data).be(start, 4) {
            case 0: break // to the end of the file
            case 1: try write(box.size + delta, size: 8, at: moved(start) + 8)
            default: try write(box.size + delta, size: 4, at: moved(start))
            }
        }
        let l = file.locations
        for item in l.items where item.method == 0 {
            let base = l.baseSize > 0 ? moved(item.base) : 0
            if l.baseSize > 0 { try write(base, size: l.baseSize, at: moved(file.ilocStart + item.baseField)) }
            for extent in item.extents {
                let offset = moved(extent.start) - base
                if l.offsetSize > 0 {
                    try write(offset, size: l.offsetSize, at: moved(file.ilocStart + extent.offsetField))
                } else if offset != 0 {
                    throw FormatError("field too small")
                }
                if let bytes = new[item.id] {
                    guard l.lengthSize > 0 else { throw FormatError("field too small") }
                    try write(bytes.count, size: l.lengthSize, at: moved(file.ilocStart + extent.lengthField))
                }
            }
        }
        return out
    }
}
