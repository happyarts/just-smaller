import Foundation

/// What an MP4 file — a motion photo's video — holds besides pictures and
/// sound: metadata boxes anywhere in its movie (user data with a location,
/// the camera or the maker's own fields; meta with keys and values; uuid
/// boxes with XMP). Read through BMFFBoxes; nothing in it is ever changed.
enum MP4Metadata {
    private static let metadata: Set<String> = ["udta", "meta", "uuid", "XMP_"]
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "edts"]

    /// Whether it holds any metadata box; nil when it can't be read.
    static func holdsMetadata(_ b: ByteView) -> Bool? {
        guard let top = try? BMFFBoxes.boxes(b, topLevel: true), top.first?.type == "ftyp" else { return nil }
        return holds(top)
    }

    private static func holds(_ boxes: [BMFFBoxes.Box]) -> Bool? {
        for box in boxes {
            if metadata.contains(box.type) { return true }
            guard containers.contains(box.type) else { continue }
            guard let children = try? BMFFBoxes.boxes(box.payload), let found = holds(children) else { return nil }
            if found { return true }
        }
        return false
    }
}
