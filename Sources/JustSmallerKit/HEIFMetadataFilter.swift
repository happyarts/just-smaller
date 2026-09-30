import Foundation

/// Filters the EXIF and XMP of a HEIF image by `MetadataPolicy`, without
/// touching anything else: EXIF items and XMP items get new data, everything
/// else — the image, its auxiliary images (HDR gain map, depth, mattes) and
/// their parameters — keeps its bytes. Apple's maker note keeps the HDR
/// headroom (`EXIFFilter`).
enum HEIFMetadataFilter {
    /// `data` with every EXIF item and every XMP item (but those describing
    /// auxiliary images) as the level keeps them. With an `original`, after
    /// a re-encode, the EXIF and XMP of the original go into the result's
    /// items instead, so the values come byte for byte from the original;
    /// that needs one of each at most, and an item in the result for what
    /// the original's metadata keeps.
    static func filter(_ data: Data, level: MetadataHandling, from original: Data? = nil) throws -> Data {
        let file = try HEIFItems.File(ByteView(data))
        var new: [Int: [UInt8]] = [:]
        if let original {
            let source = try HEIFItems.File(ByteView(original))
            let exif = try one(source.items("Exif")).flatMap { try filteredTIFF(split(original, source.range(of: $0)).tiff, level) }
            let xmp = try one(source.metadataXMP).flatMap { try filteredXMP(original, source.range(of: $0), level) }
            if let id = try one(file.items("Exif")) {
                new[id] = try split(data, file.range(of: id)).header + (exif ?? emptyTIFF)
            } else if exif != nil {
                throw FormatError("no EXIF item")
            }
            if let id = try one(file.metadataXMP) {
                new[id] = xmp ?? emptyXMP
            } else if xmp != nil {
                throw FormatError("no XMP item")
            }
        } else {
            for id in file.items("Exif") {
                let item = try split(data, file.range(of: id))
                new[id] = item.header + (filteredTIFF(item.tiff, level) ?? emptyTIFF)
            }
            for id in file.metadataXMP {
                new[id] = try filteredXMP(data, file.range(of: id), level) ?? emptyXMP
            }
        }
        return try HEIFItems.replacingData(new, in: data, file: file)
    }

    /// A TIFF block with an empty first IFD, and an XMP packet without properties.
    private static let emptyTIFF: [UInt8] = Array("MM".utf8) + [0, 42, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0]
    private static let emptyXMP = Array(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#.utf8)

    private static func one(_ ids: [Int]) throws -> Int? {
        guard ids.count <= 1 else { throw FormatError("several metadata items") }
        return ids.first
    }

    private static func filteredTIFF(_ tiff: [UInt8], _ level: MetadataHandling) -> [UInt8]? {
        EXIFFilter.filter(tiff, level: level)
    }

    private static func filteredXMP(_ data: Data, _ item: Range<Int>, _ level: MetadataHandling) throws -> [UInt8]? {
        XMPFilter.filter([UInt8](try ByteView(data).view(item.lowerBound, item.count).bytes), level: level)
    }

    /// An EXIF item: the offset of the TIFF header (and what stands before
    /// it, usually "Exif\0\0"), then the TIFF block.
    private static func split(_ data: Data, _ item: Range<Int>) throws -> (header: [UInt8], tiff: [UInt8]) {
        let view = try ByteView(data).view(item.lowerBound, item.count)
        let offset = try view.be(0, 4)
        guard offset <= view.count - 4 else { throw FormatError("EXIF item") }
        return ([UInt8](try view.view(0, 4 + offset).bytes), [UInt8](try view.view(from: 4 + offset).bytes))
    }
}
