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
        let b = [UInt8](data)
        guard b.count >= 12, b[0..<4].elementsEqual(Array("RIFF".utf8)), b[8..<12].elementsEqual(Array("WEBP".utf8))
        else { throw Malformed() }
        let walk = WebPChunks.walk(b)
        guard walk.complete else { throw Malformed() }
        var chunks: [(type: String, payload: [UInt8])] = []
        for (type, range) in walk.chunks {
            let payload = Array(b[range])
            switch type {
            case "EXIF":
                if level == .keep {
                    chunks.append((type, payload))
                } else {
                    // Some writers put JPEG's "Exif\0\0" in front of the TIFF data.
                    let header = Array("Exif\0\0".utf8)
                    let tiff = payload.starts(with: header) ? Array(payload.dropFirst(header.count)) : payload
                    if let exif = EXIFFilter.filter(tiff, level: level) { chunks.append((type, exif)) }
                }
            case "XMP ":
                let packet = level == .keep ? XMPFilter.withoutPadding(payload) : XMPFilter.filter(payload, level: level)
                if let packet { chunks.append((type, packet)) }
            default:
                if level == .keep || imageChunks.contains(type) { chunks.append((type, payload)) }
            }
        }
        guard !chunks.isEmpty else { throw Malformed() }

        if let vp8x = chunks.firstIndex(where: { $0.type == "VP8X" }), !chunks[vp8x].payload.isEmpty {
            var flags = chunks[vp8x].payload[0] & ~(exifFlag | xmpFlag)
            if chunks.contains(where: { $0.type == "EXIF" }) { flags |= exifFlag }
            if chunks.contains(where: { $0.type == "XMP " }) { flags |= xmpFlag }
            chunks[vp8x].payload[0] = flags
        }
        var body = Array("WEBP".utf8)
        for chunk in chunks {
            let n = chunk.payload.count
            body += Array(chunk.type.utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)]
            body += chunk.payload
            if n % 2 == 1 { body.append(0) }
        }
        let n = body.count
        return Data(Array("RIFF".utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)] + body)
    }
}
