import Foundation

/// Filters the metadata of a PNG by `MetadataPolicy` without touching the
/// image data.
///
/// Always kept: the chunks a decoder needs (including unknown critical ones),
/// the animation chunks of an APNG, and everything that changes how the image
/// looks — transparency, colour profile, gamma, chromaticities, significant
/// bits, CICP, the HDR mastering data and the physical size (`pHYs`: apps
/// that size images by their resolution show a Retina screenshot at half its
/// pixels). A standard sRGB profile becomes the `sRGB` chunk, which says the
/// same (at every level: the profile's own texts say nothing about the
/// image); any other profile stays byte for byte, recompressed where that is
/// smaller. EXIF (eXIf), XMP and text chunks are filtered field by field;
/// time and every other ancillary chunk go. At `.keep` only the XMP padding
/// and the sRGB profile go. EXIF stays where it stands: readers disagree
/// about an eXIf after the image data (some skip it, some apply its
/// orientation), so moving it could turn the image for some of them. If the
/// image is rotated and no EXIF is left, a minimal eXIf chunk holding only
/// the orientation is written right after IHDR, where the specification
/// wants it.
enum PNGMetadataFilter {
    struct Malformed: Error {}

    /// Ancillary chunks that are always kept.
    static let kept: Set<String> = ["tRNS", "iCCP", "sRGB", "gAMA", "cHRM", "sBIT", "cICP", "mDCV", "cLLI", "pHYs",
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
        let exifIndex = chunks[...end].firstIndex { $0.type == "eXIf" }
        let exif = exifIndex.flatMap { EXIFFilter.filter([UInt8](chunks[$0].data.bytes), level: level) }
        if exif == nil, orientation != 1 {
            out.append(PNGChunks.write("eXIf", JPEGMetadataFilter.minimalTIFF(orientation: orientation)))
        }
        for i in 1...end {
            let c = chunks[i]
            if c.type == "eXIf" {
                if i == exifIndex, let exif { out.append(PNGChunks.write("eXIf", exif)) } // only the first, filtered
            } else if ["tEXt", "zTXt", "iTXt"].contains(c.type) {
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
            } else if PNGChunks.isCritical(c) || kept.contains(c.type) {
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
