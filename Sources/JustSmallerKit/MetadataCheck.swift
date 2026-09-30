import Foundation
import ImageIO

/// Checks a metadata filter's result independently of the filter: ImageIO
/// reads EXIF, IPTC and XMP of both files into one XMP view, and
///  - the result holds nothing the level doesn't keep,
///  - every value in the result is one the original holds, unchanged,
///  - every rights field of the original is still there,
///  - at `.keep`, nothing at all is missing.
///
/// Many files hold a field twice with different values (EXIF and XMP
/// written by different programs, MakerNotes); ImageIO shows one of them.
/// When filtering removes the one it showed, the other appears — a value the
/// original held all along. So a result's value may come from any of the
/// original's sources: the merged view, EXIF and IPTC alone, or XMP alone —
/// or, for fields ImageIO couldn't read in the original (broken IIM from old
/// programs), text that stands in the original file as it is.
///
/// A JPEG that holds several images is checked image by image: a gain map
/// or a depth image can carry EXIF with the location too.
enum MetadataCheck {
    static func verify(original: URL, result: URL, level: MetadataHandling) throws {
        let a = try Data(contentsOf: original, options: .alwaysMapped), b = try Data(contentsOf: result, options: .alwaysMapped)
        try verify(a, b, level: level)
        let pairs: [(original: Data, result: Data)]?
        do { pairs = try JPEGStructure.imagePairs(a, b) } catch {
            throw VerificationError(reason: String(localized: "animation or second image lost", bundle: .module))
        }
        for pair in pairs?.dropFirst() ?? [] { try verify(pair.original, pair.result, level: level) }
    }

    private static func verify(_ original: Data, _ result: Data, level: MetadataHandling) throws {
        let merged = fields(original), after = fields(result)
        var sources: [[Key: Value]]?
        for (key, value) in after {
            if level != .keep, !MetadataPolicy.keeps(MetadataPolicy.group(xmpNamespace: key.ns, name: key.name), at: level) {
                throw VerificationError(reason: String(localized: "metadata that should have been removed is still there", bundle: .module))
            }
            // The IIM digest is updated together with the IIM block.
            if merged[key] == value || key.name == "LegacyIPTCDigest" { continue }
            if sources == nil { sources = [fields(original, excludingXMP: true), xmpFields(original)] }
            guard sources?.contains(where: { $0[key] == value }) == true || standsIn(original, value) else {
                throw VerificationError(reason: String(localized: "metadata changed", bundle: .module))
            }
        }
        for (key, _) in merged where after[key] == nil {
            let group = MetadataPolicy.group(xmpNamespace: key.ns, name: key.name)
            if level == .keep || level != .removeAll && group == .rights {
                throw VerificationError(reason: String(localized: "copyright or creator information lost", bundle: .module))
            }
        }
    }

    /// Whether the file holds anything the level removes.
    static func hasFieldsToRemove(_ url: URL, level: MetadataHandling) -> Bool {
        guard level != .keep, let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return fields(data).keys.contains {
            !MetadataPolicy.keeps(MetadataPolicy.group(xmpNamespace: $0.ns, name: $0.name), at: level)
        }
    }

    /// ImageIO's own bookkeeping (e.g. whether the file had IIM data).
    private static let imageIONamespace = "http://ns.apple.com/ImageIO/1.0/"

    struct Key: Hashable {
        var ns: String
        var name: String
    }

    /// A value flattened to text, and the single texts it is made of.
    struct Value: Equatable {
        var text = ""
        var leaves: [String] = []
        static func == (a: Value, b: Value) -> Bool { a.text == b.text }
    }

    /// Top-level properties with their values flattened to text.
    static func fields(_ data: Data, excludingXMP: Bool = false) -> [Key: Value] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, [kCGImageMetadataShouldExcludeXMP: excludingXMP] as CFDictionary)
        else { return [:] }
        return fields(metadata)
    }

    /// Every piece of text in the value occurs in the original's bytes. Short
    /// texts ("art", "1") occur by chance in any file, so they must stand
    /// there as a whole field: an IIM dataset (length first), an XML element
    /// or an attribute value.
    private static func standsIn(_ data: Data, _ value: Value) -> Bool {
        guard !value.leaves.isEmpty else { return false }
        return value.leaves.allSatisfy { leaf in
            let bytes = Array(leaf.utf8)
            if bytes.count >= 8 { return data.range(of: Data(bytes)) != nil }
            let forms: [[UInt8]] = [[0x00, UInt8(bytes.count)] + bytes, Array(">".utf8) + bytes + Array("<".utf8),
                                    Array("\"".utf8) + bytes + Array("\"".utf8)]
            return forms.contains { data.range(of: Data($0)) != nil }
        }
    }

    /// The file's XMP packet alone.
    private static func xmpFields(_ data: Data) -> [Key: Value] {
        guard let start = data.range(of: Data("<x:xmpmeta".utf8)),
              let end = data.range(of: Data("</x:xmpmeta>".utf8), in: start.upperBound..<data.endIndex),
              let metadata = CGImageMetadataCreateFromXMPData(data[start.lowerBound..<end.upperBound] as CFData)
        else { return [:] }
        return fields(metadata)
    }

    private static func fields(_ metadata: CGImageMetadata) -> [Key: Value] {
        var out: [Key: Value] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            if let ns = CGImageMetadataTagCopyNamespace(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String?,
               ns != imageIONamespace {
                var value = Value()
                flatten(CGImageMetadataTagCopyValue(tag), into: &value)
                out[Key(ns: ns, name: name)] = value
            }
            return true
        }
        return out
    }

    private static func flatten(_ value: CFTypeRef?, into out: inout Value) {
        switch value {
        case let array as [CFTypeRef]:
            out.text += "["
            for element in array { flatten(element, into: &out); out.text += "," }
            out.text += "]"
        case let dictionary as [String: CFTypeRef]:
            out.text += "{"
            for key in dictionary.keys.sorted() { out.text += "\(key)="; flatten(dictionary[key], into: &out); out.text += "," }
            out.text += "}"
        case let value? where CFGetTypeID(value) == CGImageMetadataTagGetTypeID():
            flatten(CGImageMetadataTagCopyValue(value as! CGImageMetadataTag), into: &out)
        case let value?:
            let text = "\(value)"
            out.text += reduced(text) ?? text
            out.leaves.append(text)
        case nil:
            break
        }
    }

    /// A rational in lowest terms: ImageIO writes -5253/1280 for a file's
    /// -10506/2560. The same value either way.
    private static func reduced(_ text: String) -> String? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), d != 0 else { return nil }
        var a = abs(n), b = abs(d)
        while b != 0 { (a, b) = (b, a % b) }
        return a > 1 ? "\(n / a)/\(d / a)" : nil
    }
}
