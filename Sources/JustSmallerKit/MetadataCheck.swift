import Foundation
import ImageIO

/// Checks a metadata filter's result independently of the filter: ImageIO
/// reads EXIF, IPTC and XMP of both files into one XMP view, and
///  - the result holds nothing the level doesn't keep,
///  - every value in the result is one the original holds, unchanged,
///  - every rights field of the original is still there,
///  - at `.keep`, nothing at all is missing.
/// Maker notes are not part of that view: at every level but `.keep`, only
/// Apple's may stay, with only the tags the level keeps (the HDR headroom, a
/// Live Photo's identifier).
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
        let pairs: [(original: Data, result: Data)]
        do { pairs = try JPEGLayout.imagePairs(a, b) } catch {
            throw VerificationError(reason: String(localized: "animation or second image lost", bundle: .module))
        }
        for pair in pairs {
            do { try verify(pair.original, pair.result, level: level) } catch is VerificationError where pair.original == pair.result {
                // An image that may not change (Google's container counts on it) can't lose what it holds.
                throw VerificationError(reason: String(localized: "an image that must stay as it is (depth map, gain map) holds metadata this level removes",
                                                       bundle: .module))
            }
        }
        let bytes = ByteView(b)
        // A HEIF can hold XMP ImageIO doesn't show as the image's (a
        // thumbnail's, or one describing no image): it may hold only what
        // the level keeps as well.
        if level != .keep, let file = try? HEIFItems.File(bytes) {
            // XMP that can't be read can't be shown to hold only what stays;
            // ImageIO reads none from a packet without properties, so the
            // empty one the filter writes is known by its bytes.
            for id in file.metadataXMP {
                guard let item = try? file.range(of: id), let packet = try? bytes.view(item.lowerBound, item.count) else { throw leftover }
                if packet.bytes == Data(HEIFMetadataFilter.emptyXMP) { continue }
                guard let metadata = CGImageMetadataCreateFromXMPData(packet.bytes as CFData),
                      !fields(metadata).keys.contains(where: { removes($0, at: level) })
                else { throw leftover }
            }
        }
    }

    private static func verify(_ original: Data, _ result: Data, level: MetadataHandling) throws {
        if level != .keep, hasMakerNotesToRemove(result, level: level) { throw leftover }
        let merged = fields(original), after = fields(result)
        var sources: [[Key: Value]]?, regions: [Data]?
        for (key, value) in after {
            if level != .keep, removes(key, at: level) {
                throw leftover
            }
            // The IIM digest is updated together with the IIM block; the
            // lengths in Google's container directory with the images it
            // lists — the structure check reads the result along them.
            if merged[key] == value || key.name == "LegacyIPTCDigest" || isContainerDirectory(key) { continue }
            if sources == nil { sources = [fields(original, excludingXMP: true), xmpFields(original)] }
            if sources?.contains(where: { $0[key] == value }) == true { continue }
            if regions == nil { regions = metadataRegions(original) }
            guard standsIn(regions ?? [], value) else {
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

    private static func isContainerDirectory(_ key: Key) -> Bool {
        key.ns == MetadataPolicy.NS.googleContainer && key.name == "Directory"
            || key.ns == MetadataPolicy.NS.depthDevice && key.name == "Container"
    }

    private static var leftover: VerificationError {
        VerificationError(reason: String(localized: "metadata that should have been removed is still there", bundle: .module))
    }

    /// Whether the level removes this field.
    private static func removes(_ key: Key, at level: MetadataHandling) -> Bool {
        !MetadataPolicy.keeps(MetadataPolicy.group(xmpNamespace: key.ns, name: key.name), at: level)
    }

    /// Whether the file holds a maker note, or tags of Apple's, the level removes.
    private static func hasMakerNotesToRemove(_ data: Data, level: MetadataHandling) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return false }
        return properties.contains { key, value in
            guard key.hasPrefix("{Maker") else { return false }
            guard key == kCGImagePropertyMakerAppleDictionary as String, let tags = value as? [String: Any] else { return true }
            return !tags.keys.allSatisfy { Int($0).map { MetadataPolicy.keeps(MetadataPolicy.group(appleMakerNoteTag: $0), at: level) } ?? false }
        }
    }

    /// Whether the file holds anything the level removes.
    static func hasFieldsToRemove(_ url: URL, level: MetadataHandling) -> Bool {
        guard level != .keep, let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return fields(data).keys.contains {
            removes($0, at: level)
        } || hasMakerNotesToRemove(data, level: level)
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

    /// Every piece of text in the value occurs in the original's metadata
    /// (`regions`). Short texts ("art", "1") occur by chance in any data, so
    /// they must stand there as a whole field: an IIM dataset (length
    /// first), an XML element or an attribute value.
    private static func standsIn(_ regions: [Data], _ value: Value) -> Bool {
        guard !value.leaves.isEmpty else { return false }
        return value.leaves.allSatisfy { leaf in
            let bytes = Array(leaf.utf8)
            let forms: [[UInt8]] = bytes.count >= 8 ? [bytes]
                : [[0x00, UInt8(bytes.count)] + bytes, Array(">".utf8) + bytes + Array("<".utf8), Array("\"".utf8) + bytes + Array("\"".utf8)]
            return forms.contains { form in regions.contains { $0.range(of: Data(form)) != nil } }
        }
    }

    /// Where a file keeps its metadata — never its image data, where any text
    /// turns up by chance: a JPEG's APPn and COM segments (of every image), a
    /// PNG's or WebP's chunks but the image data, a HEIF's boxes but mdat and
    /// its EXIF and XMP items. A file its reader can't take apart counts whole.
    static func metadataRegions(_ data: Data) -> [Data] {
        let b = ByteView(data)
        if b.has([0xFF, 0xD8, 0xFF]) {
            let images = JPEGLayout.read(b)?.images ?? [0..<data.count]
            let segments = images.compactMap { try? JPEGMarkers.headers(b.view($0)).segments }
            if segments.count == images.count {
                return segments.joined().filter { JPEGCheck.isMetadata($0.marker) }.map(\.payload.bytes)
            }
        } else if b.has(PNGChunks.signature), let chunks = try? PNGChunks.read(b, strict: false) {
            return chunks.filter { !["IDAT", "fdAT"].contains($0.type) }.map(\.data.bytes)
        } else if b.has("RIFF"), b.has("WEBP", at: 8), case let riff = RIFFChunks.webp(b), riff.complete {
            return riff.chunks.filter { !["VP8 ", "VP8L", "ALPH", "ANMF"].contains($0.type) }.map(\.data.bytes)
        } else if b.has("ftyp", at: 4), let file = try? HEIFItems.File(b), let boxes = try? BMFFBoxes.boxes(b, topLevel: true) {
            // EXIF and XMP items mostly lie in mdat: those, and the boxes but mdat.
            let items = (file.items("Exif") + file.metadataXMP).compactMap { id in (try? file.range(of: id)).flatMap { try? b.view($0) } }
            return boxes.filter { $0.type != "mdat" }.map(\.payload.bytes) + items.map(\.bytes)
        }
        return [data]
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
