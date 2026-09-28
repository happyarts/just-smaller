import CryptoKit
import Foundation

/// Filters Photoshop's image resources (JPEG APP13), which hold the IPTC-IIM
/// block and, next to it, an MD5 digest of that block. Photoshop, Bridge and
/// Lightroom compare the digest to tell whether another program changed the
/// IIM data, so a digest that matched before is updated to the new block.
enum IPTCFilter {
    struct Result {
        var resources: [UInt8]?
        /// Old and new digest as upper-case hex, for photoshop:LegacyIPTCDigest in XMP.
        var digest: (old: String, new: String)?
    }

    /// `resources` is the APP13 payload after "Photoshop 3.0\0". Unreadable
    /// data is dropped as a whole.
    static func filter(_ resources: [UInt8], level: MetadataHandling) -> Result {
        guard let parsed = parse(resources) else { return Result() }
        var kept: [(id: UInt16, name: [UInt8], data: [UInt8])] = []
        var digest: (old: String, new: String)?
        let oldIIM = parsed.first { $0.id == 0x0404 }?.data
        let newIIM = oldIIM.flatMap { filterIIM($0, level: level) }
        for resource in parsed where MetadataPolicy.keeps(MetadataPolicy.group(photoshopResource: resource.id), at: level) {
            switch resource.id {
            case 0x0404:
                if let newIIM { kept.append((resource.id, resource.name, newIIM)) }
            case 0x0425:
                guard let oldIIM, let newIIM else { continue }
                let old = md5(oldIIM), new = md5(newIIM)
                // A digest that no longer matched stays as it was: it tells
                // readers that another program changed the IIM data.
                if resource.data == old {
                    kept.append((resource.id, resource.name, new))
                    digest = (hex(old), hex(new))
                } else {
                    kept.append(resource)
                }
            default:
                kept.append(resource)
            }
        }
        // A digest without its data means nothing.
        if !kept.contains(where: { $0.id != 0x0425 }) { return Result() }
        var out: [UInt8] = []
        for r in kept {
            out += Array("8BIM".utf8) + [UInt8(r.id >> 8), UInt8(r.id & 0xFF)]
            out += [UInt8(r.name.count)] + r.name
            if (r.name.count + 1) % 2 == 1 { out.append(0) } // the name is padded to an even length
            let n = r.data.count
            out += [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            out += r.data
            if n % 2 == 1 { out.append(0) }
        }
        return Result(resources: out, digest: digest)
    }

    private static func parse(_ b: [UInt8]) -> [(id: UInt16, name: [UInt8], data: [UInt8])]? {
        var out: [(id: UInt16, name: [UInt8], data: [UInt8])] = []
        var i = 0
        while i + 12 <= b.count {
            guard b[i..<i + 4].elementsEqual(Array("8BIM".utf8)) else {
                // Trailing zero padding is fine; anything else is not.
                return b[i...].allSatisfy { $0 == 0 } ? out : nil
            }
            let id = UInt16(b[i + 4]) << 8 | UInt16(b[i + 5])
            let nameLength = Int(b[i + 6])
            var j = i + 7 + nameLength
            if (nameLength + 1) % 2 == 1 { j += 1 }
            guard j + 4 <= b.count else { return nil }
            let size = Int(b[j]) << 24 | Int(b[j + 1]) << 16 | Int(b[j + 2]) << 8 | Int(b[j + 3])
            guard size >= 0, j + 4 + size <= b.count else { return nil }
            out.append((id, Array(b[i + 7..<i + 7 + nameLength]), Array(b[j + 4..<j + 4 + size])))
            i = j + 4 + size + (size & 1)
        }
        return out
    }

    /// The IIM datasets the level keeps, in their original order; nil when
    /// nothing but the record versions and the character set is left.
    static func filterIIM(_ b: [UInt8], level: MetadataHandling) -> [UInt8]? {
        var out: [UInt8] = []
        var meaningful = false
        var i = 0
        while i + 5 <= b.count, b[i] == 0x1C {
            let record = b[i + 1], dataset = b[i + 2]
            var length = Int(b[i + 3]) << 8 | Int(b[i + 4])
            var start = i + 5
            if length & 0x8000 != 0 { // extended length: the next n bytes hold it
                let n = length & 0x7FFF
                guard n <= 4, start + n <= b.count else { return nil }
                length = b[start..<start + n].reduce(0) { $0 << 8 | Int($1) }
                start += n
            }
            guard start + length <= b.count else { return nil }
            if MetadataPolicy.keeps(MetadataPolicy.group(iimRecord: record, dataset: dataset), at: level) {
                out += b[i..<start + length]
                if !(dataset == 0 || (record, dataset) == (1, 90)) { meaningful = true }
            }
            i = start + length
        }
        return meaningful ? out : nil
    }

    private static func md5(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: bytes)) }
    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }
}
