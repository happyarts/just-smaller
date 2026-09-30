import Foundation

/// The one way the engine reads Photoshop image resources (JPEG APP13) and
/// the IPTC-IIM datasets inside them: the metadata filter leniently, the
/// structure check strictly.
enum IPTCRecords {
    struct Resource {
        let id: Int
        let name: ByteView
        let data: ByteView
    }

    struct Dataset {
        let record: Int, dataset: Int
        /// Tag, record, dataset, length and data.
        let whole: ByteView
    }

    /// "8BIM", id, padded Pascal name, size, data padded to an even length.
    /// Zero padding may follow the last. Leniently, a tail too short for a
    /// resource is ignored too; strictly, 0xFF padding is allowed and
    /// nothing else.
    static func resources(_ r: ByteView, strict: Bool) throws -> [Resource] {
        var out: [Resource] = [], k = 0
        while k < r.count {
            let rest = try r.view(from: k)
            if strict ? rest.isPadding : (rest.bytes.allSatisfy { $0 == 0 } || rest.count < 12) { break }
            guard r.has("8BIM", at: k) else { throw FormatError("resource") }
            let nameLength = try r.u8(k + 6)
            let sizeAt = k + 6 + ((1 + nameLength + 1) & ~1)
            let size = try r.be(sizeAt, 4)
            out.append(Resource(id: try r.be(k + 4, 2), name: try r.view(k + 7, nameLength), data: try r.view(sizeAt + 4, size)))
            k = sizeAt + 4 + size + (size & 1)
        }
        return out
    }

    /// Resources as `resources` reads them, names and data padded to even lengths.
    static func write(_ resources: [(id: Int, name: [UInt8], data: [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        for r in resources {
            out += Array("8BIM".utf8) + [UInt8(r.id >> 8 & 0xFF), UInt8(r.id & 0xFF)]
            out += [UInt8(r.name.count)] + r.name
            if (r.name.count + 1) % 2 == 1 { out.append(0) }
            let n = r.data.count
            out += [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + r.data
            if n % 2 == 1 { out.append(0) }
        }
        return out
    }

    /// Tag 0x1C, record, dataset, length (extended when its top bit is set:
    /// the next 1–4 bytes hold it), data. Leniently, reading stops at the
    /// first byte that isn't a tag; strictly, only padding may follow.
    static func datasets(_ d: ByteView, strict: Bool) throws -> [Dataset] {
        var out: [Dataset] = [], k = 0
        while k < d.count, try d.u8(k) == 0x1C {
            // A few stray bytes at the end are no dataset; readers skip them.
            if !strict, d.count - k < 5 { break }
            var length = try d.be(k + 3, 2), header = 5
            if length & 0x8000 != 0 {
                let bytes = length & 0x7FFF
                guard (1...4).contains(bytes) else { throw FormatError("dataset length") }
                length = try d.be(k + 5, bytes)
                header += bytes
            }
            out.append(Dataset(record: try d.u8(k + 1), dataset: try d.u8(k + 2), whole: try d.view(k, header + length)))
            k += header + length
        }
        if strict, k < d.count, !(try d.view(from: k).isPadding) { throw FormatError("dataset") }
        return out
    }
}
