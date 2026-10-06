import Foundation

/// What Google's XMP in a JPEG's first image says about the file. A
/// container directory (Ultra HDR, motion photos; Dynamic Depth in Pixel
/// portraits) lists every item of the file in order — the primary image
/// first, then gain maps, depth maps or a video — each with its MIME type,
/// its role (Semantic), its Length and the Padding after it; the items after
/// the primary image are counted from the end of the file (Dynamic Depth:
/// from the end of the photo). A motion photo is marked with
/// GCamera:MotionPhoto or MicroVideo set to 1; older ones have no directory,
/// only GCamera:MicroVideoOffset, the video's distance from the end.
///
/// Properties are found as attributes or as elements, by namespace URI,
/// never by prefix. Reads the main packets and the extended one (Dynamic
/// Depth puts its directory there); XMP that names neither a container nor
/// the camera namespace isn't parsed at all.
struct GoogleXMP: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var semantic: String?, mime: String?
        /// In bytes; 0 where not given (the primary image).
        var length = 0, padding = 0
    }

    /// Each directory's items, the primary image first.
    var directories: [[Item]] = []
    /// Which of them are Dynamic Depth's (its items lie one after another
    /// right after the photo; Google's container counts from the end).
    var depthDirectories: Set<Int> = []
    /// GCamera:MotionPhoto or MicroVideo is 1. Editors that drop the video
    /// often leave the mark.
    var marksMotionPhoto = false
    /// GCamera:MicroVideoOffset: where an older motion photo's video starts,
    /// counted from the end of the file.
    var microVideoOffset: Int?
    /// Images kept in the XMP itself, as Base64 (GImage:Data,
    /// GCamera:RelitInputImageData): no filter reads them.
    var embeddedImages: [Data] = []

    /// A directory lists items after the primary image.
    var listsMoreThanThePhoto: Bool { directories.contains { $0.count > 1 } }
    /// A directory lists a video.
    var listsVideo: Bool { !videos.isEmpty }
    /// A directory lists images (anything but a video) after the primary one.
    var listsImagesAfterThePhoto: Bool { directories.contains { $0.dropFirst().contains { !Self.isVideo($0) } } }

    /// The length of the one video the directories list (or, without one
    /// there, the MicroVideoOffset gives), when `trailer` (the bytes after
    /// the images) ends with it: an MP4 file, its ftyp box first, exactly
    /// that long — counted from the end of the file, as both count. nil for
    /// none, several, or one that isn't there.
    func video(endingAt trailer: ByteView) -> Int? {
        let listed = videos.map(\.length)
        let lengths = listed.isEmpty ? microVideoOffset.map { [$0] } ?? [] : listed
        guard lengths.count == 1, let length = lengths.first, length >= 16, length <= trailer.count,
              trailer.has("ftyp", at: trailer.count - length + 4) else { return nil }
        return length
    }

    /// The one directory that lists more than the photo, and whether it is
    /// Dynamic Depth's. nil for none, or several.
    var listing: (items: [Item], fromPhoto: Bool)? {
        let more = directories.indices.filter { directories[$0].count > 1 }
        guard more.count == 1, let n = more.first else { return nil }
        return (directories[n], depthDirectories.contains(n))
    }

    /// Where the listing's items after the photo lie in the `trailerLength`
    /// bytes after it, each with its range there: Google's container counts
    /// them from the end of the file (Ultra HDR, motion photos), Dynamic
    /// Depth lays them one after another right after the photo (its camera
    /// data may follow). nil when there's no listing, or the items don't fit.
    func arrangement(in trailerLength: Int) -> [(item: Item, range: Range<Int>)]? {
        guard let listing, let primary = listing.items.first else { return nil }
        let items = listing.items.dropFirst()
        // Lengths come from the file: anything longer than the bytes there can't fit.
        guard (items + [primary]).allSatisfy({ $0.length <= trailerLength && $0.padding <= trailerLength }) else { return nil }
        var placed: [(item: Item, range: Range<Int>)] = []
        if listing.fromPhoto {
            var start = primary.padding
            for item in items {
                guard start + item.length <= trailerLength else { return nil }
                placed.append((item, start..<start + item.length))
                start += item.length + item.padding
            }
        } else {
            var end = trailerLength
            for item in items.reversed() {
                end -= item.padding + item.length
                guard end >= 0 else { return nil }
                placed.append((item, end..<end + item.length))
            }
            placed.reverse()
        }
        return placed
    }

    private var videos: [Item] { directories.joined().filter(Self.isVideo) }
    static func isVideo(_ item: Item) -> Bool { item.mime?.lowercased().hasPrefix("video/") == true }

    static let containerNamespaces = [MetadataPolicy.NS.googleContainer, MetadataPolicy.NS.depthContainer]
    static let itemNamespaces = [MetadataPolicy.NS.googleItem, MetadataPolicy.NS.depthItem]
    static let cameraNamespace = MetadataPolicy.NS.googleCamera
    static let imageNamespace = MetadataPolicy.NS.googleImage
    /// Only XMP that names one of these is parsed; items exist only in a container.
    private static let wanted = (containerNamespaces + [cameraNamespace, imageNamespace]).map { Data($0.utf8) }

    /// From the first image's segments (`headers`). Empty when no XMP names
    /// those namespaces; nil when one does but can't be read — not
    /// well-formed, its extended packet incomplete, or a length that isn't a
    /// number of bytes.
    static func read(_ headers: [JPEGMarkers.Segment]) -> GoogleXMP? {
        var main: [Data] = [], extended: [Data] = []
        for s in headers {
            switch JPEGMarkers.part(s.marker, payload: s.payload.bytes) {
            case .xmp: main.append(s.payload.bytes.dropFirst(JPEGMarkers.xmpHeader.count))
            case .extendedXMP: extended.append(s.payload.bytes.dropFirst(JPEGMarkers.extendedXMPHeader.count))
            default: break
            }
        }
        func named(_ packet: Data) -> Bool { wanted.contains { packet.range(of: $0) != nil } }
        var packets = main.filter(named)
        if extended.contains(where: named) {
            guard let first = main.first, let whole = JPEGMarkers.extendedXMP(extended, for: first) else { return nil }
            packets.append(whole)
        }
        var result = GoogleXMP()
        for packet in packets {
            // The parser's strings go with each packet, not when the caller's pool drains.
            let reader: Reader? = autoreleasepool {
                let reader = Reader()
                return XML.parse(XML.document(ofPacket: packet), delegate: reader, namespaces: true) && !reader.failed ? reader : nil
            }
            guard let reader else { return nil }
            result.depthDirectories.formUnion(reader.depthDirectories.map { $0 + result.directories.count })
            result.directories += reader.directories
            result.marksMotionPhoto = result.marksMotionPhoto || reader.marksMotionPhoto
            result.embeddedImages += reader.embeddedImages
            if let offset = reader.microVideoOffset {
                // Two packets that disagree say nothing certain.
                guard result.microVideoOffset == nil || result.microVideoOffset == offset else { return nil }
                result.microVideoOffset = offset
            }
        }
        return result
    }

    /// Walks one packet. Inside a container's Directory each outermost
    /// rdf:li — or a Container:Item outside one — is an item; any item
    /// property within it counts, whether an attribute (Container:Item
    /// Item:Mime="…") or an element (Dynamic Depth's rdf:value with
    /// Item:Mime inside). A Directory with no item in it can't be read.
    private final class Reader: NSObject, XMLParserDelegate {
        var directories: [[Item]] = []
        var depthDirectories: Set<Int> = []
        var marksMotionPhoto = false
        var microVideoOffset: Int?
        var embeddedImages: [Data] = []
        var failed = false

        private var prefixes: [String: [String]] = [:]
        private var depth = 0
        /// The depth of the Directory element and of the item being read.
        private var directory: Int?, itemDepth: Int?
        private var item = Item()
        /// The property element whose text is being read.
        private var property: (ns: String, name: String, depth: Int)?, text = ""

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            prefixes[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            _ = prefixes[prefix]?.popLast()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            depth += 1
            property = nil // a property's value is its text alone
            let ns = namespaceURI ?? ""
            if directory == nil, GoogleXMP.containerNamespaces.contains(ns), name == "Directory" {
                directory = depth
                if ns == GoogleXMP.containerNamespaces[1] { depthDirectories.insert(directories.count) }
                directories.append([])
            } else if directory != nil, itemDepth == nil,
                      ns == MetadataPolicy.NS.rdf && name == "li" || GoogleXMP.containerNamespaces.contains(ns) && name == "Item" {
                itemDepth = depth
                item = Item()
            }
            for (qualified, value) in attributes {
                // Unprefixed attributes are in no namespace.
                guard let colon = qualified.firstIndex(of: ":"),
                      let uri = prefixes[String(qualified[..<colon])]?.last else { continue }
                found(uri, String(qualified[qualified.index(after: colon)...]), value)
            }
            if GoogleXMP.itemNamespaces.contains(ns) || ns == GoogleXMP.cameraNamespace || ns == GoogleXMP.imageNamespace { property = (ns, name, depth) }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if property != nil { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if let p = property, p.depth == depth { found(p.ns, p.name, text) }
            property = nil
            if depth == itemDepth {
                directories[directories.count - 1].append(item)
                itemDepth = nil
            }
            if depth == directory {
                if directories[directories.count - 1].isEmpty { failed = true }
                directory = nil
            }
            depth -= 1
        }

        private func found(_ ns: String, _ name: String, _ value: String) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            func bytes() -> Int {
                guard let n = Int(value), n >= 0 else { failed = true; return 0 }
                return n
            }
            if ns == GoogleXMP.cameraNamespace && name == "RelitInputImageData" || ns == GoogleXMP.imageNamespace && name == "Data" {
                // Unreadable Base64 can't be shown to hold nothing: an empty image fails the check.
                embeddedImages.append(Data(base64Encoded: value, options: .ignoreUnknownCharacters) ?? Data())
                return
            }
            if ns == GoogleXMP.cameraNamespace {
                if ["MotionPhoto", "MicroVideo"].contains(name), value == "1" { marksMotionPhoto = true }
                if name == "MicroVideoOffset" { microVideoOffset = bytes() }
                return
            }
            guard GoogleXMP.itemNamespaces.contains(ns), itemDepth != nil else { return }
            switch name {
            case "Semantic": item.semantic = value
            case "Mime": item.mime = value
            case "Length": item.length = bytes()
            case "Padding": item.padding = bytes()
            default: break
            }
        }
    }
}
