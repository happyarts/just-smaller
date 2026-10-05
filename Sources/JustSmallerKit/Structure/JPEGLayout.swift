import Foundation

/// A JPEG file as it lies on disk: its images, each from SOI to EOI, the
/// bytes between and after them, and what other readers expect of them.
///
/// The one place that knows which parts of a JPEG may change. The optimizer
/// decides with it which files stay as they are (`problem`), the pipeline
/// changes files part by part along it (`mayChange`, `keepsGaps`,
/// `assembled`), and the structure check holds every result to the same
/// rules (`check`).
///
/// Most JPEGs are one image (`isPlain`). Others hold more: HDR gain maps,
/// depth and mattes of portraits, stereo pairs and previews, listed by a
/// multi-picture index; motion photos have a video after the images; and
/// cameras leave leftover bytes between and after them. What Google's XMP
/// says about them (container directory, motion photo mark) comes from
/// `GoogleXMP`. Reads through ByteView; `read` is nil when not even the
/// first image reads to its end — then what follows it can't be told apart,
/// and the file stays as it is.
///
/// To come (the users stay as they are): Google's container as a second
/// `Index` (Pixel portraits, whose images only the XMP lists); each image's
/// role from the index (gain map, depth, preview) with how far it may
/// change.
struct JPEGLayout: Sendable {
    /// How the images after the first are found: a multi-picture index, or
    /// Google's container directory alone (Pixel portraits, Ultra HDR
    /// without one), where each JPEG it lists lies exactly at its length.
    enum Index: Sendable {
        case none, multiPicture, container
    }

    /// Why a file must stay as it is (besides `read` being nil).
    enum Problem: Sendable {
        /// A motion photo whose video the container doesn't place (see
        /// `problem`): it lies after the images, where nothing may move.
        case video
        /// A multi-picture index that doesn't fit the file.
        case unfittingIndex
        /// Google's XMP names its photo namespaces but can't be read, and
        /// something follows the photo: what it counts is unknown.
        case unreadableXMP
        /// Images no index lists, or not where Google's container says —
        /// this reader doesn't take them apart, and won't drop them as
        /// leftover bytes.
        case unlistedImages
    }

    /// Each image; the first is the photo itself.
    let images: [Range<Int>]
    /// After each image up to the next one; after the last one up to the
    /// end of the file.
    let gaps: [Range<Int>]
    let index: Index
    let problem: Problem?
    /// One image, and nothing but padding after it.
    let isPlain: Bool
    /// Google's container directory lists what follows the photo (images, a
    /// motion photo's video) by length — counted from the end of the file,
    /// or (Dynamic Depth) from the end of the photo — or an older motion
    /// photo's MicroVideoOffset places its video: all of it, and the bytes
    /// between, must stay where it is. Only the rules below read it.
    private let listedByContainer: Bool

    /// `firstEnd`: where the first image ends, when a parse already found it.
    static func read(_ b: ByteView, firstEnd: Int? = nil) -> JPEGLayout? {
        guard let headers = try? JPEGMarkers.headers(b).segments,
              let firstEnd = firstEnd ?? (try? JPEGMarkers.imageEnd(from: 0, in: b)) else { return nil }
        var images = [0..<firstEnd], index = Index.none, indexFits = true
        switch MultiPictureIndex.read(b, headers: headers) {
        case nil: break
        case let entries? where entries.count == 1: break // lists only the image itself
        case let entries?:
            if entries.count > 1, let rest = try? following(entries.dropFirst(), after: firstEnd, in: b) {
                images += rest
                index = .multiPicture
            } else {
                indexFits = false
            }
        }
        func gaps(_ images: [Range<Int>]) -> [Range<Int>] {
            images.indices.map { images[$0].upperBound..<(images.indices.contains($0 + 1) ? images[$0 + 1].lowerBound : b.count) }
        }
        var trailer = (try? b.view(gaps(images)[images.count - 1])) ?? ByteView(Data())
        // Nothing follows a plain JPEG's photo: whatever its XMP says counts nothing.
        if images.count == 1, trailer.isPadding {
            return JPEGLayout(images: images, gaps: gaps(images), index: index, problem: indexFits ? nil : .unfittingIndex,
                              isPlain: true, listedByContainer: false)
        }
        let xmp = GoogleXMP.read(headers)
        if index == .none, indexFits, let xmp, let rest = listed(by: xmp, after: firstEnd, trailer: trailer.count, in: b) {
            images += rest
            index = .container
            trailer = (try? b.view(gaps(images)[images.count - 1])) ?? ByteView(Data())
        }
        return JPEGLayout(images: images, gaps: gaps(images), index: index,
                          problem: problem(index: index, indexFits: indexFits, xmp: xmp, trailer: trailer),
                          isPlain: false, listedByContainer: xmp?.listsMoreThanThePhoto == true || xmp?.video(endingAt: trailer) != nil)
    }

    /// Why the file must stay as it is, asked in this order:
    /// 1. A video after the images that the container doesn't place: Google's
    ///    XMP marks a motion photo or lists a video, or the bytes after the
    ///    images hold one — but neither the container's directory nor an
    ///    older MicroVideoOffset places exactly one video that ends the file
    ///    at its length. One they place is counted from the end like the
    ///    images after the first: it stays byte for byte, and only the photo
    ///    changes. A mark with nothing after the images counts for nothing
    ///    (editors drop the video and leave the mark).
    /// 2. A multi-picture index that doesn't fit the file.
    /// 3. Google's XMP that can't be read.
    /// 4. Without a multi-picture index, images after the photo: the
    ///    container lists some, or another JPEG starts in the bytes after it
    ///    (outside a placed video, whose data may hold anything).
    /// Asked only where something follows the photo.
    private static func problem(index: Index, indexFits: Bool, xmp: GoogleXMP?, trailer: ByteView) -> Problem? {
        let somethingAfter = !trailer.isPadding
        let video = xmp?.video(endingAt: trailer)
        if somethingAfter, video == nil,
           xmp?.marksMotionPhoto == true || xmp?.listsVideo == true || holdsVideo(trailer) { return .video }
        if !indexFits { return .unfittingIndex }
        guard let xmp else { return .unreadableXMP }
        let beforeVideo = ByteView(trailer.bytes.dropLast(video ?? 0))
        if index == .none, somethingAfter, xmp.listsImagesAfterThePhoto || startsJPEG(beforeVideo) { return .unlistedImages }
        return nil
    }

    /// The JPEGs Google's container lists after the photo, where it says
    /// they are: in one of its arrangements, each exactly from its SOI to
    /// its EOI. nil when it lists none, or they aren't there.
    private static func listed(by xmp: GoogleXMP, after photo: Int, trailer: Int, in b: ByteView) -> [Range<Int>]? {
        for arrangement in xmp.arrangements(in: trailer) {
            let jpegs = arrangement.filter { $0.item.mime?.lowercased() == "image/jpeg" }
                .map { $0.range.lowerBound + photo..<$0.range.upperBound + photo }
            guard !jpegs.isEmpty else { return nil }
            if jpegs.allSatisfy({ (try? JPEGMarkers.imageEnd(from: $0.lowerBound, in: b)) == $0.upperBound }) { return jpegs }
        }
        return nil
    }

    /// The images the index lists after the first, each read to its EOI, in
    /// the index's order. The sizes the index gives are not needed (some
    /// writers get the first one wrong).
    private static func following(_ entries: ArraySlice<MultiPictureIndex.Entry>, after end: Int, in b: ByteView) throws -> [Range<Int>] {
        var images: [Range<Int>] = [], end = end
        for entry in entries {
            guard entry.start >= end else { throw FormatError("images overlap") }
            images.append(entry.start..<(try JPEGMarkers.imageEnd(from: entry.start, in: b)))
            end = images[images.count - 1].upperBound
        }
        return images
    }

    // MARK: - Rules

    /// Whether image n may change. Without loss, every image but those the
    /// container counts from the end of the file. With loss (encoded anew),
    /// only a plain JPEG's photo for now: a gain map or a depth image is
    /// made for its photo, and neither may simply change with it.
    func mayChange(image n: Int, withLoss lossy: Bool = false) -> Bool {
        lossy ? isPlain && n == 0 : n == 0 || !listedByContainer
    }

    /// Whether any image may change with loss: a lossy step is worth trying.
    var mayChangeWithLoss: Bool { images.indices.contains { mayChange(image: $0, withLoss: true) } }

    /// Leftover bytes could hold anything: like unknown metadata they go
    /// unless everything stays — or the container lists what follows the
    /// photo, and counts across them.
    func keepsGaps(at level: MetadataHandling) -> Bool {
        level == .keep || listedByContainer
    }

    /// Holds `result` (laid out as `after`), made from the original `a` this
    /// layout was read from, to the rules: as many images, none that can't
    /// be read safely; those that may not change unchanged; the index, if
    /// any, still the original's but for exact sizes and starts; between and
    /// after the images the original's bytes where they stay at `level`, or
    /// nothing but padding where they may go.
    func check(_ after: JPEGLayout, in result: ByteView, original a: ByteView, level: MetadataHandling) throws {
        guard after.images.count == images.count else { throw FormatError("images lost or added") }
        guard after.problem == nil else { throw FormatError("images can't be read safely") }
        for n in images.indices where !mayChange(image: n) {
            guard try result.view(after.images[n]).bytes == a.view(images[n]).bytes else { throw FormatError("image \(n + 1) changed") }
        }
        for (gap, original) in zip(after.gaps, gaps) {
            let bytes = try result.view(gap), before = try a.view(original)
            let kept = bytes.bytes == before.bytes
            guard listedByContainer ? kept : kept && keepsGaps(at: level) || bytes.isPadding else {
                throw FormatError("data between or after the images changed")
            }
        }
        guard index == .multiPicture else { return }
        // Only the sizes and starts in the index may change, and they are exact.
        guard after.index == .multiPicture, MultiPictureIndex.withoutPositions(result) == MultiPictureIndex.withoutPositions(a),
              let entries = MultiPictureIndex.read(result),
              entries == after.images.map({ MultiPictureIndex.Entry(start: $0.lowerBound, size: $0.count) })
        else { throw FormatError("multi-picture index") }
    }

    // MARK: - Writer

    /// The file `data` (which this layout was read from) with its images
    /// replaced by `new`, and its gaps kept or left out.
    func assembled(_ new: [Data], from data: Data, keepingGaps: Bool) throws -> Data {
        try Self.joined(new, gaps: keepingGaps ? gaps.map { data.subdata(in: $0) } : [], rewritingIndex: index == .multiPicture)
    }

    /// `images` one after another, each followed by its gap (none when
    /// `gaps` is empty); with more than one and `rewritingIndex`, the
    /// multi-picture index in the first is rewritten to their sizes and
    /// starts (Google's container needs nothing: what follows the photo
    /// stays as it was).
    static func joined(_ images: [Data], gaps: [Data] = [], rewritingIndex: Bool = true) throws -> Data {
        let gaps = gaps.isEmpty ? images.map { _ in Data() } : gaps
        guard var first = images.first, gaps.count == images.count else { throw FormatError("number of images") }
        if images.count > 1, rewritingIndex {
            first = try MultiPictureIndex.rewritten(first, sizes: images.map(\.count), gaps: gaps.map(\.count))
        }
        var out = Data()
        out.reserveCapacity(images.reduce(0) { $0 + $1.count } + gaps.reduce(0) { $0 + $1.count })
        for (n, (image, gap)) in zip(images, gaps).enumerated() {
            out.append(n == 0 ? first : image)
            out.append(gap)
        }
        return out
    }

    // MARK: - Pairs for the checks

    /// The images after the first of an original and its result, pair by
    /// pair; none unless one of them has a multi-picture index or Google's
    /// container (read from the headers alone: plain JPEGs pay nothing).
    /// Throws when they don't hold as many.
    static func imagePairs(_ original: Data, _ result: Data) throws -> [(original: Data, result: Data)] {
        let a = ByteView(original), b = ByteView(result)
        guard mayList(a) || mayList(b), let x = read(a), let y = read(b) else { return [] }
        guard x.images.count == y.images.count else { throw FormatError("images lost") }
        return zip(x.images, y.images).dropFirst().map { (original[$0], result[$1]) }
    }

    // MARK: - Recognising

    /// The first image's headers hold a multi-picture index, or XMP that
    /// names Google's container.
    private static func mayList(_ b: ByteView) -> Bool {
        guard let headers = try? JPEGMarkers.headers(b).segments else { return false }
        let container = GoogleXMP.container.map { Data($0.utf8) }
        return headers.contains { s in
            MultiPictureIndex.isIndex(s) || [.xmp, .extendedXMP].contains(JPEGMarkers.part(s.marker, payload: s.payload.bytes))
                && container.contains { s.payload.bytes.range(of: $0) != nil }
        }
    }

    /// Another JPEG starts somewhere in `b`: an SOI whose headers read up to
    /// a scan. Three bytes alone turn up by chance in any data.
    private static func startsJPEG(_ b: ByteView) -> Bool {
        var from = 0
        while let at = b.index(of: 0xFF, from: from) {
            if b.has([0xFF, 0xD8, 0xFF], at: at), let rest = try? b.view(from: at), (try? JPEGMarkers.headers(rest)) != nil { return true }
            from = at + 1
        }
        return false
    }

    /// A video after the images: Samsung's trailer with its signatures, or
    /// an MP4 file's ftyp box, recognised by the box size before the type.
    private static func holdsVideo(_ trailer: ByteView) -> Bool {
        let t = trailer.bytes
        // Samsung's trailer ends the file with "SEFT"; four bytes elsewhere are chance.
        if t.range(of: Data("MotionPhoto_Data".utf8)) != nil || t.suffix(4) == Data("SEFT".utf8) { return true }
        var from = t.startIndex
        while let box = t.range(of: Data("ftyp".utf8), in: from..<t.endIndex) {
            if let size = try? trailer.be(box.lowerBound - t.startIndex - 4, 4), (16...256).contains(size), size % 4 == 0 { return true }
            from = box.upperBound
        }
        return false
    }
}
