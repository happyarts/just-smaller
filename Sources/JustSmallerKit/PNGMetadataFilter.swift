import Foundation

/// Filters the metadata of a PNG by `MetadataPolicy` without touching the
/// image data.
///
/// Always kept: the chunks a decoder needs (including unknown critical ones),
/// the animation chunks of an APNG, and everything that changes how the image
/// looks — transparency, colour profile, gamma, chromaticities, significant
/// bits, CICP and the HDR mastering data. EXIF (eXIf), XMP and text chunks
/// are filtered field by field; the physical size stays with the image info;
/// time and every other ancillary chunk go. At `.keep` only the XMP padding
/// goes. EXIF goes right after IHDR, where the specification wants it; if the
/// image is rotated and no EXIF is left, a minimal eXIf chunk holding only
/// the orientation is written there.
enum PNGMetadataFilter {
    struct Malformed: Error {}

    /// Ancillary chunks that are always kept.
    static let kept: Set<String> = ["tRNS", "iCCP", "sRGB", "gAMA", "cHRM", "sBIT", "cICP", "mDCV", "cLLI",
                                    "acTL", "fcTL", "fdAT"]

    static func filter(_ data: Data, level: MetadataHandling, orientation: Int) throws -> Data {
        guard let chunks = try? PNGChunks.read(ByteView(data), strict: false),
              let header = chunks.first, header.type == "IHDR", let end = chunks.firstIndex(where: { $0.type == "IEND" })
        else { throw Malformed() }
        var out = Data(PNGChunks.signature)
        out.append(header.whole.bytes)
        if level == .keep {
            for c in chunks[1...end] {
                if c.type == "iTXt", let text = try? PNGChunks.text(c), text.keyword == PNGChunks.xmpKeyword {
                    out.append(xmpChunk(XMPFilter.withoutPadding([UInt8](text.content))))
                } else {
                    out.append(c.whole.bytes)
                }
            }
            return out
        }
        let exif = chunks.first { $0.type == "eXIf" }.flatMap { EXIFFilter.filter([UInt8]($0.data.bytes), level: level) }
        if let exif {
            out.append(PNGChunks.write("eXIf", exif))
        } else if orientation != 1 {
            out.append(PNGChunks.write("eXIf", JPEGMetadataFilter.minimalTIFF(orientation: orientation)))
        }
        for c in chunks[1...end] where c.type != "eXIf" {
            if ["tEXt", "zTXt", "iTXt"].contains(c.type) {
                guard let keyword = try? PNGChunks.keyword(c) else { continue } // no readable keyword: it goes
                if c.type == "iTXt", keyword == PNGChunks.xmpKeyword {
                    if let text = try? PNGChunks.text(c), let packet = XMPFilter.filter([UInt8](text.content), level: level) {
                        out.append(xmpChunk(packet))
                    }
                } else if MetadataPolicy.keeps(MetadataPolicy.group(pngTextKeyword: keyword), at: level) {
                    out.append(c.whole.bytes) // as it is, by its keyword
                }
            } else if PNGChunks.isCritical(c) || kept.contains(c.type) || c.type == "pHYs" && MetadataPolicy.keeps(.imageInfo, at: level) {
                out.append(c.whole.bytes)
            }
        }
        return out
    }

    /// XMP in an uncompressed iTXt chunk.
    private static func xmpChunk(_ packet: [UInt8]) -> Data {
        PNGChunks.write("iTXt", Array(PNGChunks.xmpKeyword.utf8) + [0, 0, 0, 0, 0] + packet)
    }
}
