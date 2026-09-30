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
        return Result(resources: IPTCRecords.write(kept.map { (Int($0.id), $0.name, $0.data) }), digest: digest)
    }

    private static func parse(_ b: [UInt8]) -> [(id: UInt16, name: [UInt8], data: [UInt8])]? {
        (try? IPTCRecords.resources(ByteView(b), strict: false))?.map { (UInt16($0.id), [UInt8]($0.name.bytes), [UInt8]($0.data.bytes)) }
    }

    /// The IIM datasets the level keeps, in their original order; nil when
    /// nothing but the record versions and the character set is left.
    static func filterIIM(_ b: [UInt8], level: MetadataHandling) -> [UInt8]? {
        guard let datasets = try? IPTCRecords.datasets(ByteView(b), strict: false) else { return nil }
        var out: [UInt8] = []
        var meaningful = false
        for d in datasets where MetadataPolicy.keeps(MetadataPolicy.group(iimRecord: UInt8(d.record), dataset: UInt8(d.dataset)), at: level) {
            out += d.whole.bytes
            if !(d.dataset == 0 || (d.record, d.dataset) == (1, 90)) { meaningful = true }
        }
        return meaningful ? out : nil
    }

    private static func md5(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: bytes)) }
    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }
}
