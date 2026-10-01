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
        var headerSize: Int { size - payload.count }
        /// Where the box (its header) starts in the view it was read from.
        var start: Int { offset - headerSize }
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
/// replaces the data of items and adds metadata items, for the HEIC
/// metadata filter.
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

    /// pitm: the primary image's id.
    static func primary(_ pitm: BMFFBoxes.Box) throws -> Int {
        let p = pitm.payload
        return try p.u8(0) == 0 ? p.be(4, 2) : p.be(4, 4)
    }

    /// grpl: the ids of its entity groups (e.g. an image with and without its
    /// gain map), which share one space with the item ids. Each group:
    /// version and flags, then its id.
    static func groupIDs(_ grpl: BMFFBoxes.Box) throws -> [Int] {
        try BMFFBoxes.boxes(grpl.payload).map { try $0.payload.be(4, 4) }
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
        /// The meta box's version and flags, and its children, which start
        /// at `metaStart` in the file.
        let metaHeader: ByteView
        let meta: [BMFFBoxes.Box]
        let metaStart: Int
        let infos: [Info]
        let references: [(type: String, from: Int, to: [Int])]
        let primary: Int
        let locations: Locations
        /// Where the iloc payload starts in the file.
        let ilocStart: Int
        /// The boxes whose size changes with data inside them, as where
        /// their header starts and where their payload lies in the file:
        /// the top-level boxes, and the idat box inside meta.
        let containers: [(header: Int, payload: Range<Int>)]
        /// Where the idat payload lies in the file (item data of construction method 1).
        let idat: Range<Int>?

        init(_ b: ByteView) throws {
            top = try BMFFBoxes.boxes(b, topLevel: true)
            // Image sequences keep sample offsets of their own.
            guard !top.contains(where: { $0.type == "moov" }) else { throw FormatError("image sequence") }
            let found = top.filter { $0.type == "meta" }
            guard found.count == 1 else { throw FormatError("meta") }
            let metaStart = found[0].offset + 4
            self.metaStart = metaStart
            metaHeader = try found[0].payload.view(0, 4)
            let meta = try BMFFBoxes.boxes(found[0].payload.view(from: 4))
            self.meta = meta
            func one(_ type: String) throws -> BMFFBoxes.Box {
                let found = meta.filter { $0.type == type }
                guard found.count == 1 else { throw FormatError(type) }
                return found[0]
            }
            infos = try HEIFItems.infos(one("iinf"))
            references = try meta.first { $0.type == "iref" }.map(HEIFItems.references) ?? []
            primary = try HEIFItems.primary(one("pitm"))
            let iloc = try one("iloc")
            locations = try HEIFItems.locations(iloc.payload)
            ilocStart = metaStart + iloc.offset
            let idats = meta.filter { $0.type == "idat" }
            guard idats.count <= 1 else { throw FormatError("idat") }
            idat = idats.first.map { metaStart + $0.offset..<metaStart + $0.offset + $0.payload.count }
            func header(_ box: BMFFBoxes.Box, at shift: Int) -> (header: Int, payload: Range<Int>) {
                (shift + box.start, shift + box.offset..<shift + box.offset + box.payload.count)
            }
            containers = top.map { header($0, at: 0) } + idats.map { header($0, at: metaStart) }
        }

        /// The items of `type`.
        func items(_ type: String) -> [Int] { infos.filter { $0.type == type }.map(\.id) }

        func groupIDs() throws -> [Int] { try meta.first { $0.type == "grpl" }.map(HEIFItems.groupIDs) ?? [] }

        /// Where a child of the meta box lies in the file, header included.
        func range(of child: BMFFBoxes.Box) -> Range<Int> { metaStart + child.start..<metaStart + child.start + child.size }

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

        /// Where in the file an extent's data starts for construction method
        /// 0 (the file) and 1 (idat); nil for data in another item.
        func origin(_ method: Int) throws -> Int? {
            switch method {
            case 0: return 0
            case 1: guard let idat else { throw FormatError("idat") }; return idat.lowerBound
            default: return nil
            }
        }

        /// Where an extent's data lies in the file; a length of 0 means up
        /// to the end of the file or of idat.
        func range(of extent: Extent, method: Int) throws -> Range<Int>? {
            guard let origin = try origin(method) else { return nil }
            let end = method == 0 ? top.last.map { $0.offset + $0.payload.count } ?? 0 : idat?.upperBound ?? 0
            let start = origin + extent.start
            guard start <= end, extent.length <= end - start else { throw FormatError("item location") }
            return start..<(extent.length == 0 ? end : start + extent.length)
        }

        /// Where the data of an item lies: one piece, inside an mdat box or idat.
        func range(of id: Int) throws -> Range<Int> {
            guard let location = locations.items.first(where: { $0.id == id }), location.extents.count == 1, location.extents[0].length > 0,
                  let range = try range(of: location.extents[0], method: location.method)
            else { throw FormatError("item location") }
            // Method 1 lies in idat by construction; method 0 must lie in an mdat box.
            guard location.method == 1 || top.contains(where: {
                $0.type == "mdat" && range.lowerBound >= $0.offset && range.upperBound <= $0.offset + $0.payload.count
            }) else { throw FormatError("item location") }
            return range
        }
    }

    /// Whether `b` holds the same image as `a`, down to the byte: the same
    /// boxes, the same items with the same properties and references, and
    /// every item's data unchanged — all but the EXIF and XMP items the
    /// metadata filter rewrites. Only where item data lies (iloc) may differ.
    static func sameImage(_ a: ByteView, _ b: ByteView) throws -> Bool {
        let x = try File(a), y = try File(b)
        guard x.top.map(\.type) == y.top.map(\.type), x.meta.map(\.type) == y.meta.map(\.type),
              x.metaHeader.bytes == y.metaHeader.bytes else { return false }
        for (p, q) in zip(x.top, y.top) where p.type != "mdat" && p.type != "meta" && p.payload.bytes != q.payload.bytes { return false }
        for (p, q) in zip(x.meta, y.meta) where p.type != "iloc" && p.type != "idat" && p.payload.bytes != q.payload.bytes { return false }

        let metadata = Set(x.items("Exif") + x.metadataXMP)
        // One location per item, in both.
        guard Set(x.locations.items.map(\.id)).count == x.locations.items.count, x.locations.items.count == y.locations.items.count
        else { return false }
        let items = Dictionary(y.locations.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard items.count == y.locations.items.count else { return false }
        for p in x.locations.items {
            guard let q = items[p.id], p.method == q.method, p.extents.count == q.extents.count else { return false }
            guard !metadata.contains(p.id) else { continue }
            if p.method == 2 {
                // Data taken from another item: the same part of it.
                guard p.base == q.base, zip(p.extents, q.extents).allSatisfy({ $0.start == $1.start && $0.length == $1.length }) else { return false }
                continue
            }
            for (e, f) in zip(p.extents, q.extents) {
                guard let r = try x.range(of: e, method: p.method), let t = try y.range(of: f, method: q.method),
                      r.count == t.count, try a.view(r.lowerBound, r.count).bytes == b.view(t.lowerBound, t.count).bytes
                else { return false }
            }
        }
        return true
    }

    /// Big-endian bytes of `value` in a field of `size` bytes.
    static func be(_ value: Int, _ size: Int) throws -> [UInt8] {
        guard value >= 0, size == 8 || value >> (8 * size) == 0 else { throw FormatError("field too small") }
        return (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * (size - 1 - $0))) }
    }

    /// A box with a 32-bit size.
    static func box(_ type: String, _ payload: [UInt8]) throws -> [UInt8] {
        try be(8 + payload.count, 4) + Array(type.utf8) + payload
    }

    /// A metadata item to add: "Exif", or "mime" with its content type.
    struct NewItem {
        let type: String
        let contentType: String?
        let data: [UInt8]
    }

    /// The file with the data of some items replaced (`replacing`, each
    /// stored in one piece inside an mdat box or idat) and metadata items
    /// added that describe the primary image (`adding`: entries in iinf,
    /// iref and iloc, data at the end of the last mdat box or in one of its
    /// own). Everything else keeps its bytes; what follows a change moves,
    /// and the item locations (iloc) and the sizes of the boxes around a
    /// change (mdat; idat and meta) follow. Fields keep their widths.
    /// `file` is `data` read already, if at hand.
    static func rewrite(_ data: Data, replacing new: [Int: [UInt8]] = [:], adding added: [NewItem] = [], file: File? = nil) throws -> Data {
        // Positions below count from the start of the file.
        let data = data.startIndex == 0 ? data : Data(data)
        guard !new.isEmpty || !added.isEmpty else { return data }
        let file = try file ?? File(ByteView(data))
        let l = file.locations
        // Bytes in place of a range of the old file; `grows`: the boxes
        // around it change size with it.
        var changes = try new.map { (range: try file.range(of: $0.key), bytes: $0.value, grows: true) }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        // Every other item's data lies outside what changes; no item takes
        // its data from a changed one.
        for (a, b) in zip(changes, changes.dropFirst()) where a.range.upperBound > b.range.lowerBound { throw FormatError("item location") }
        for item in l.items where new[item.id] == nil {
            for extent in item.extents {
                guard let range = try file.range(of: extent, method: item.method) else {
                    let sources = file.references.filter { $0.type == "iloc" && $0.from == item.id }.flatMap(\.to)
                    if sources.contains(where: { new[$0] != nil }) { throw FormatError("item location") }
                    continue
                }
                if changes.contains(where: { $0.range.overlaps(range) }) { throw FormatError("item location") }
            }
        }

        var newOffsetFields: [Int] = [], appendAt = 0
        if !added.isEmpty {
            // New data goes after everything: nothing may run to the end of the file.
            guard l.offsetSize > 0, l.lengthSize > 0, !l.items.contains(where: { $0.method == 0 && $0.extents.contains { $0.length == 0 } }),
                  file.top.last.map({ ByteView(data).has([0, 0, 0, 0], at: $0.start) }) != true
            else { throw FormatError("item location") }
            func child(_ type: String) throws -> BMFFBoxes.Box {
                guard let found = file.meta.first(where: { $0.type == type }) else { throw FormatError(type) }
                return found
            }
            // New ids after every item and entity group id.
            let first = try (file.infos.map(\.id) + file.groupIDs()).max().map { $0 + 1 } ?? 1
            let ids = added.indices.map { first + $0 }

            // iinf: the count, the old entries, the new ones (version 2, or 3 for wide ids).
            let iinfBox = try child("iinf"), iinf = [UInt8](iinfBox.payload.bytes)
            let countSize = iinf[0] != 0 ? 4 : 2
            var infes: [UInt8] = []
            for (id, item) in zip(ids, added) {
                let wide = id > 0xFFFF
                infes += try box("infe", [wide ? 3 : 2, 0, 0, 0] + be(id, wide ? 4 : 2) + be(0, 2) + Array(item.type.utf8) + [0]
                                 + (item.contentType.map { Array($0.utf8) + [0] } ?? []))
            }
            changes.append((file.range(of: iinfBox),
                            try box("iinf", Array(iinf[..<4]) + be(file.infos.count + added.count, countSize) + Array(iinf[(4 + countSize)...]) + infes), true))

            // iref: a cdsc reference from each new item to the primary image;
            // a new iref box follows iinf.
            let irefBox = file.meta.first { $0.type == "iref" }
            let iref = irefBox.map { [UInt8]($0.payload.bytes) } ?? [max(ids.last ?? 0, file.primary) > 0xFFFF ? 1 : 0, 0, 0, 0]
            let idSize = iref[0] != 0 ? 4 : 2
            var cdsc: [UInt8] = []
            for id in ids { cdsc += try box("cdsc", be(id, idSize) + be(1, 2) + be(file.primary, idSize)) }
            let iinfEnd = file.range(of: iinfBox).upperBound
            changes.append((irefBox.map(file.range) ?? iinfEnd..<iinfEnd, try box("iref", iref + cdsc), true))

            // iloc: the old entries, the count, one entry per new item; the
            // offsets are written below, once everything has its place.
            let ilocBox = try child("iloc")
            guard ilocBox.headerSize == 8 else { throw FormatError("iloc") }
            var iloc = [UInt8](ilocBox.payload.bytes)
            let version = Int(iloc[0]), itemIDSize = version < 2 ? 2 : 4, indexSize = version > 0 ? Int(iloc[5] & 15) : 0
            iloc.replaceSubrange(6..<6 + itemIDSize, with: try be(l.items.count + added.count, itemIDSize))
            for (id, item) in zip(ids, added) {
                iloc += try be(id, itemIDSize) + (version > 0 ? [0, 0] : []) + [0, 0] + be(0, l.baseSize) + be(1, 2) + be(0, indexSize)
                newOffsetFields.append(iloc.count)
                iloc += try be(0, l.offsetSize) + be(item.data.count, l.lengthSize)
            }
            changes.append((file.range(of: ilocBox), try box("iloc", iloc), true))

            // The data: at the end of the last mdat box when it ends the file
            // (one mdat, as writers make it), in an mdat box of its own otherwise.
            let bytes = added.flatMap(\.data)
            if let last = file.top.last, last.type == "mdat", [8, 16].contains(last.headerSize) {
                appendAt = last.offset + last.payload.count
                changes.append((appendAt..<appendAt, bytes, true))
            } else {
                appendAt = data.count
                changes.append((appendAt..<appendAt, try box("mdat", bytes), false))
            }
            // An insertion goes before what starts where it is.
            changes.sort { ($0.range.lowerBound, $0.range.isEmpty ? 0 : 1) < ($1.range.lowerBound, $1.range.isEmpty ? 0 : 1) }
        }

        /// Where a position of the old file is in the new one.
        func moved(_ at: Int) -> Int {
            at + changes.filter { $0.range.upperBound <= at }.reduce(0) { $0 + $1.bytes.count - $1.range.count }
        }
        var out = Data(capacity: data.count + changes.reduce(0) { $0 + $1.bytes.count })
        var at = 0
        for change in changes {
            out += data[at..<change.range.lowerBound]
            out += change.bytes
            at = change.range.upperBound
        }
        out += data[at...]

        func write(_ value: Int, size: Int, at position: Int) throws {
            out.replaceSubrange(position..<position + size, with: try be(value, size))
        }
        // Boxes around a change grow or shrink with it (meta around idat too);
        // an insertion at the end of a box's payload is inside it.
        for box in file.containers {
            let delta = changes.filter {
                $0.grows && (box.payload.contains($0.range.lowerBound) || $0.range.isEmpty && $0.range.lowerBound == box.payload.upperBound)
            }.reduce(0) { $0 + $1.bytes.count - $1.range.count }
            guard delta != 0 else { continue }
            let size = box.payload.upperBound - box.header
            switch try ByteView(data).be(box.header, 4) {
            case 0: break // to the end of the file
            case 1: try write(size + delta, size: 8, at: moved(box.header) + 8)
            default: try write(size + delta, size: 4, at: moved(box.header))
            }
        }
        for item in l.items {
            guard let origin = try file.origin(item.method) else { continue }
            let base = l.baseSize > 0 ? moved(origin + item.base) - moved(origin) : 0
            if l.baseSize > 0 { try write(base, size: l.baseSize, at: moved(file.ilocStart + item.baseField)) }
            for extent in item.extents {
                let offset = moved(origin + extent.start) - moved(origin) - base
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
        // The new items' data starts where the insertion ends minus its length.
        var start = moved(appendAt) - added.reduce(0) { $0 + $1.data.count }
        for (field, item) in zip(newOffsetFields, added) {
            try write(start, size: l.offsetSize, at: moved(file.ilocStart) + field)
            start += item.data.count
        }
        return out
    }
}
