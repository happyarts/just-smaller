import Foundation

/// Filters the metadata of a PNG by `MetadataPolicy` without touching the
/// image data.
///
/// Always kept: the chunks a decoder needs (including unknown critical ones),
/// the animation chunks of an APNG, and everything that changes how the image
/// looks — transparency, colour profile, gamma, chromaticities, significant
/// bits, CICP and the HDR mastering data. A standard sRGB profile becomes the
/// `sRGB` chunk, which says the same (at every level: the profile's own
/// texts say nothing about the image); any other profile stays byte for byte,
/// recompressed where that is smaller. EXIF (eXIf), XMP and text chunks
/// are filtered field by field; the physical size stays with the image info;
/// time and every other ancillary chunk go. At `.keep` only the XMP padding
/// and the sRGB profile go. EXIF goes right after IHDR, where the
/// specification wants it; if the image is rotated and no EXIF is left, a
/// minimal eXIf chunk holding only the orientation is written there.
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
        let hasSRGB = chunks.contains { $0.type == "sRGB" }
        if level == .keep {
            for c in chunks[1...end] {
                if c.type == "iCCP", let profile = colourProfile(c, hasSRGB: hasSRGB) {
                    out.append(profile)
                } else if c.type == "iTXt", let text = try? PNGChunks.text(c), text.keyword == PNGChunks.xmpKeyword {
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
            } else if c.type == "iCCP", let profile = colourProfile(c, hasSRGB: hasSRGB) {
                out.append(profile)
            } else if PNGChunks.isCritical(c) || kept.contains(c.type) || c.type == "pHYs" && MetadataPolicy.keeps(.imageInfo, at: level) {
                out.append(c.whole.bytes)
            }
        }
        return out
    }

    /// What goes out for an iCCP chunk, nil for the chunk as it is: a
    /// standard sRGB profile as the sRGB chunk (nothing where there is one
    /// already); any other profile, name and profile unchanged, recompressed
    /// where that is smaller.
    private static func colourProfile(_ chunk: Chunk, hasSRGB: Bool) -> Data? {
        guard let profile = try? PNGChunks.text(chunk).content else { return nil }
        if let intent = SRGBProfile.renderingIntent(profile) { return hasSRGB ? Data() : PNGChunks.write("sRGB", [intent]) }
        guard let k = chunk.data.index(of: 0, from: 0), let name = try? chunk.data.view(0, k).bytes,
              let packed = Zlib.deflate(profile) else { return nil }
        let smaller = PNGChunks.write("iCCP", [UInt8](name) + [0, 0] + [UInt8](packed))
        return smaller.count < chunk.whole.count ? smaller : nil
    }

    /// XMP in an uncompressed iTXt chunk.
    private static func xmpChunk(_ packet: [UInt8]) -> Data {
        PNGChunks.write("iTXt", Array(PNGChunks.xmpKeyword.utf8) + [0, 0, 0, 0, 0] + packet)
    }
}
