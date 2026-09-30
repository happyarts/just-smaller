import Foundation

/// Filters the EXIF and XMP chunks of a WebP by `MetadataPolicy`, without
/// touching the image data. Works for lossy, lossless and animated files
/// alike: metadata lives in chunks of its own. The VP8X flags and the RIFF
/// size are updated to match.
enum WebPMetadataFilter {
    struct Malformed: Error {}

    /// Chunks that belong to the image; everything else is metadata.
    private static let imageChunks: Set<String> = ["VP8X", "ICCP", "ANIM", "ANMF", "ALPH", "VP8 ", "VP8L"]
    private static let exifFlag: UInt8 = 0x08, xmpFlag: UInt8 = 0x04

    static func filter(_ data: Data, level: MetadataHandling) throws -> Data {
        let walk = RIFFChunks.webp(ByteView(data))
        guard walk.complete else { throw Malformed() }
        var chunks: [(type: String, payload: Data)] = []
        for chunk in walk.chunks {
            let type = chunk.type, payload = chunk.data.bytes
            switch type {
            case "EXIF":
                if level == .keep {
                    chunks.append((type, payload))
                } else {
                    let tiff = [UInt8](payload.dropFirst(RIFFChunks.tiffOffset(payload)))
                    if let exif = EXIFFilter.filter(tiff, level: level) { chunks.append((type, Data(exif))) }
                }
            case "XMP ":
                let packet = level == .keep ? XMPFilter.withoutPadding([UInt8](payload)) : XMPFilter.filter([UInt8](payload), level: level)
                if let packet { chunks.append((type, Data(packet))) }
            default:
                if level == .keep || imageChunks.contains(type) { chunks.append((type, payload)) }
            }
        }
        guard !chunks.isEmpty else { throw Malformed() }
        if chunks[0].type == "VP8X", var vp8x = chunks.first?.payload, !vp8x.isEmpty {
            // The flags match the chunks, which go in the order the
            // specification gives, whatever order they came in.
            vp8x = Data(vp8x) // its own copy, not a slice of the file
            var flags = vp8x[0] & ~(exifFlag | xmpFlag)
            if chunks.contains(where: { $0.type == "EXIF" }) { flags |= exifFlag }
            if chunks.contains(where: { $0.type == "XMP " }) { flags |= xmpFlag }
            vp8x[0] = flags
            chunks[0].payload = vp8x
            chunks = chunks.enumerated().sorted {
                (RIFFChunks.webpOrder($0.element.type), $0.offset) < (RIFFChunks.webpOrder($1.element.type), $1.offset)
            }.map(\.element)
        }
        return RIFFChunks.write(form: "WEBP", chunks)
    }
}
