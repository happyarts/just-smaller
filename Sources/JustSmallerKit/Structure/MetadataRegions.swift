import Foundation

/// Where a file keeps its metadata, as its readers find it: a JPEG's APPn
/// and COM segments (of every image), a PNG's or WebP's chunks but the image
/// data, a HEIF's boxes but mdat, and its EXIF and XMP items. Anything that
/// looks for text in a file — a Content Credentials manifest, a value of the
/// original — looks only here: in image or video data any short text turns
/// up by chance.
enum MetadataRegions {
    /// The regions of `data`; a file its reader can't take apart counts whole.
    static func of(_ data: Data) -> [Data] {
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
        } else if b.has("ftyp", at: 4), let boxes = try? BMFFBoxes.boxes(b, topLevel: true) {
            // EXIF and XMP items mostly lie in mdat: those, and the boxes but mdat.
            let file = try? HEIFItems.File(b)
            let ids = (file?.items("Exif") ?? []) + (file?.metadataXMP ?? [])
            let items = ids.compactMap { id in (try? file?.range(of: id)).flatMap { $0 }.flatMap { try? b.view($0) } }
            return boxes.filter { $0.type != "mdat" }.map(\.payload.bytes) + items.map(\.bytes)
        }
        return [data]
    }
}
