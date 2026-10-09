import Foundation

/// A JPEG file as it lies on disk: its images, each from SOI to EOI, the
/// bytes between and after them, and what other readers expect of them.
///
/// The one place that knows which parts of a JPEG may change. The optimizer
/// decides with it which files stay as they are (`problem`), the pipeline
/// changes files part by part along it (`mayChange`, `assembled`), the
/// structure check holds every result to the same rules (`check`), and the
/// metadata check looks into what must stay unread (`keptData`).
///
/// Most JPEGs are one image (`isPlain`). Others hold more: HDR gain maps,
/// depth and mattes of portraits, stereo pairs and previews, listed by a
/// multi-picture index or only by Google's container; motion photos have a
/// video after the images; and cameras leave leftover bytes between and
/// after them. What Google's XMP says about them (container directory,
/// motion photo marks) comes from `GoogleXMP`. Reads through ByteView;
/// `read` is nil when not even the first image reads to its end — then what
/// follows it can't be told apart, and the file stays as it is.
///
/// To come: each image's role from the index (gain map, depth, preview),
/// with how far it may change (a gain map with loss).
struct JPEGLayout: Sendable {
    /// How the images after the first are found: a multi-picture index, or
    /// Google's container directory alone (Pixel portraits, Ultra HDR
    /// without an index), where each JPEG it lists lies exactly at its
    /// length.
    enum Index: Sendable {
        case none, multiPicture, container
    }

    /// Why a file must stay as it is (besides `read` being nil).
    enum Problem: Sendable {
        /// A video after the images that neither the container's directory
        /// nor a MicroVideoOffset places at the end of the file.
        case video
        /// A multi-picture index that doesn't fit the file.
        case unfittingIndex
        /// Google's XMP names its photo namespaces but can't be read, and
        /// something follows the photo: what it counts is unknown.
        case unreadableXMP
        /// Images no index lists, or not where Google's container says, or
        /// another JPEG in bytes that would go as leftover — this reader
        /// doesn't take them apart, and won't drop them.
        case unlistedImages
    }

    /// What stays byte for byte that no filter reads: for the metadata check.
    enum KeptData: Sendable {
        /// A motion photo's video, placed at the end of the file. (Samsung's
        /// trailer with its own metadata follows the MP4 inside that length,
        /// so the video doesn't read as a clean MP4.)
        case video
        /// An entry of the container that is neither one of the images nor
        /// the video, or bytes the container counts across.
        case other
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
    /// With `index == .container`: for each image after the first, its
    /// entry in the container's directory (the photo is entry 0).
    let containerEntries: [Int]
    /// What stays byte for byte that no filter reads, with where it lies.
    let keptData: [(kind: KeptData, range: Range<Int>)]
    /// For each gap, the part of it (counted from the gap's start) that must
    /// stay at every level: what Google's container or a MicroVideoOffset
    /// counts across. The bytes before and after it are leftover bytes.
    private let kept: [Range<Int>]
    /// Google's container lists the images after the first: they change
    /// only with their lengths in its directory.
    private let imagesListed: Bool
    /// Every directory of Google's container, for the structure check.
    private let directories: [[GoogleXMP.Item]]
    /// The photo is coded in a way the lossy encoder reads (`readsForEncoding`).
    private let photoReadsForEncoding: Bool

    /// `firstEnd`: where the first image ends, when a parse already found it.
    static func read(_ b: ByteView, firstEnd: Int? = nil) -> JPEGLayout? {
        guard let headers = try? JPEGMarkers.headers(b).segments,
              let firstEnd = firstEnd ?? (try? JPEGMarkers.imageEnd(from: 0, in: b)) else { return nil }
        var images = [0..<firstEnd], index = Index.none, indexFits = true
        let encodable = readsForEncoding(JPEGMarkers.frame(headers))
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
        let afterPhoto = (try? b.view(from: firstEnd)) ?? ByteView(Data())
        // Nothing follows a plain JPEG's photo: whatever its XMP says counts nothing.
        if images.count == 1, afterPhoto.isPadding {
            return JPEGLayout(images: images, gaps: gaps(images), index: index, problem: indexFits ? nil : .unfittingIndex,
                              isPlain: true, containerEntries: [], keptData: [], kept: [0..<0], imagesListed: false, directories: [],
                              photoReadsForEncoding: encodable)
        }
        let xmp = GoogleXMP.read(headers)
        // Google's container lays the parts out after the photo (`placed`,
        // counted from the photo's end).
        let placed = xmp?.arrangement(in: afterPhoto.count)
        var entries: [Int] = []
        if index == .none, indexFits, let placed, let found = jpegs(in: placed, after: firstEnd, in: b) {
            images += found.map(\.range)
            entries = found.map(\.entry)
            index = .container
        }
        let gapRanges = gaps(images)
        let trailer = (try? b.view(gapRanges[gapRanges.count - 1])) ?? ByteView(Data())
        let video = xmp?.video(endingAt: trailer)
        let kept = keptParts(of: gapRanges, xmp: xmp, placed: placed, video: video, photoEnd: firstEnd, fileEnd: b.count)
        var keptData: [(kind: KeptData, range: Range<Int>)] = []
        if let video { keptData.append((.video, b.count - video..<b.count)) }
        for item in placed ?? [] where item.item.mime?.lowercased() != "image/jpeg" && !GoogleXMP.isVideo(item.item) {
            keptData.append((.other, item.range.lowerBound + firstEnd..<item.range.upperBound + firstEnd))
        }
        // Bytes the container counts across that are none of the above.
        let known = keptData.map(\.range).sorted { $0.lowerBound < $1.lowerBound }
        for (gap, part) in zip(gapRanges, kept) where !part.isEmpty {
            var from = gap.lowerBound + part.lowerBound
            for range in known + [gap.lowerBound + part.upperBound..<Int.max] where range.upperBound > from {
                let unknown = from..<max(from, min(range.lowerBound, gap.lowerBound + part.upperBound))
                if let bytes = try? b.view(unknown), !bytes.isPadding { keptData.append((.other, unknown)) }
                from = max(from, range.upperBound)
                if from >= gap.lowerBound + part.upperBound { break }
            }
        }
        // Another JPEG in bytes that would go: it isn't leftover.
        let droppable = zip(gapRanges, kept).flatMap { gap, part in
            [gap.lowerBound..<gap.lowerBound + part.lowerBound, gap.lowerBound + part.upperBound..<gap.upperBound]
        }
        let jpegInLeftover = droppable.contains { range in (try? b.view(range)).map(startsJPEG) ?? false }
        return JPEGLayout(images: images, gaps: gapRanges, index: index,
                          problem: problem(index: index, indexFits: indexFits, xmp: xmp, trailer: trailer, video: video,
                                           jpegInLeftover: jpegInLeftover),
                          isPlain: false, containerEntries: entries, keptData: keptData, kept: kept,
                          imagesListed: xmp?.listing != nil, directories: xmp?.directories ?? [],
                          photoReadsForEncoding: encodable)
    }

    /// Which part of each gap must stay (see `kept`). Without Google's
    /// container or a MicroVideoOffset: none of it. With one: everything it
    /// counts across — but not what comes before the first part it places
    /// when it counts from the end of the file and gives the photo no
    /// padding, and not what comes after the last one when it counts from
    /// the photo and places no video: there nothing counts.
    private static func keptParts(of gaps: [Range<Int>], xmp: GoogleXMP?, placed: [(item: GoogleXMP.Item, range: Range<Int>)]?,
                                  video: Int?, photoEnd: Int, fileEnd: Int) -> [Range<Int>] {
        guard xmp?.listing != nil || video != nil else { return gaps.map { _ in 0..<0 } }
        var kept = gaps.map { 0..<$0.count }
        let fromPhoto = xmp?.listing?.fromPhoto == true
        // The parts' extent, counted from the photo's end.
        let starts = (placed ?? []).map(\.range.lowerBound) + (video.map { [fileEnd - $0 - photoEnd] } ?? [])
        if !fromPhoto, xmp?.listing?.items.first?.padding ?? 0 == 0, let first = starts.min(), first <= gaps[0].count {
            kept[0] = first..<gaps[0].count
        }
        if fromPhoto, video == nil, let last = placed?.last, let k = gaps.indices.last {
            let end = last.range.upperBound + last.item.padding + photoEnd - gaps[k].lowerBound
            if end >= 0, end <= gaps[k].count { kept[k] = kept[k].lowerBound..<max(kept[k].lowerBound, end) }
        }
        return kept
    }

    /// Why the file must stay as it is, asked in this order:
    /// 1. A video after the images that neither the container's directory
    ///    nor a MicroVideoOffset places: Google's XMP marks a motion photo or
    ///    lists a video, or the bytes after the images hold one. A placed
    ///    video stays byte for byte at the end of the file; a mark with
    ///    nothing after the images counts for nothing (editors drop the
    ///    video and leave the mark).
    /// 2. A multi-picture index that doesn't fit the file.
    /// 3. Google's XMP that can't be read.
    /// 4. Images no index finds: the container lists some it doesn't place
    ///    (without a multi-picture index), or another JPEG starts in bytes
    ///    that would go as leftover.
    /// Asked only where something follows the photo.
    private static func problem(index: Index, indexFits: Bool, xmp: GoogleXMP?, trailer: ByteView, video: Int?,
                                jpegInLeftover: Bool) -> Problem? {
        if !trailer.isPadding, video == nil,
           xmp?.marksMotionPhoto == true || xmp?.listsVideo == true || holdsVideo(trailer) { return .video }
        if !indexFits { return .unfittingIndex }
        guard let xmp else { return .unreadableXMP }
        if jpegInLeftover || index == .none && xmp.listsImagesAfterThePhoto { return .unlistedImages }
        return nil
    }

    /// The JPEGs among the container's placed parts (counted from the photo's
    /// end at `photo`), each exactly from its SOI to its EOI, with its entry
    /// in the directory. nil when it lists none, or they aren't there.
    private static func jpegs(in placed: [(item: GoogleXMP.Item, range: Range<Int>)], after photo: Int, in b: ByteView)
        -> [(range: Range<Int>, entry: Int)]? {
        let jpegs = placed.enumerated().filter { $0.element.item.mime?.lowercased() == "image/jpeg" }
            .map { (range: $0.element.range.lowerBound + photo..<$0.element.range.upperBound + photo, entry: $0.offset + 1) }
        guard !jpegs.isEmpty, jpegs.allSatisfy({ (try? JPEGMarkers.imageEnd(from: $0.range.lowerBound, in: b)) == $0.range.upperBound })
        else { return nil }
        return jpegs
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

    /// Whether image n may change. Without loss, every image but those
    /// Google's container lists (it counts their bytes) — those too when the
    /// step writes their new lengths into its directory (`writingLengths`:
    /// the metadata step below "keep everything"), unless a multi-picture
    /// index lists them as well. With loss (encoded anew), only a plain
    /// JPEG's photo for now: a gain map or a depth image is made for its
    /// photo, and neither may simply change with it. And only a photo the
    /// encoder can read (`readsForEncoding`); any other stays as it is, and
    /// is optimized without loss.
    func mayChange(image n: Int, withLoss lossy: Bool = false, writingLengths: Bool = false) -> Bool {
        if lossy { return isPlain && n == 0 && photoReadsForEncoding }
        return n == 0 || !imagesListed || index == .container && writingLengths
    }

    /// Whether jpegli (cjpegli, through libjpeg-turbo) can read an image
    /// with this frame header to encode it anew: Huffman-coded, baseline,
    /// extended, progressive or lossless, 8 bits, grey or three components.
    /// Not arithmetic coding, 12 bits, CMYK, or hierarchical frames.
    static func readsForEncoding(_ frame: JPEGMarkers.Frame?) -> Bool {
        guard let frame, [0xC0, 0xC1, 0xC2, 0xC3].contains(frame.marker), frame.precision == 8 else { return false }
        return frame.components == 1 || frame.components == 3
    }

    /// Whether a step at `level` writes the new lengths of the images
    /// Google's container lists into its directory: the metadata step does
    /// below "keep everything", where it rewrites the XMP anyway.
    static func writesLengths(at level: MetadataHandling) -> Bool { level != .keep }

    /// Why the file can't become a JPEG XL that shows all of it. A JPEG XL
    /// made from a JPEG keeps whatever follows the photo, so the JPEG can be
    /// rebuilt from it byte for byte; but a JPEG XL viewer shows only the
    /// photo. So only a plain JPEG is converted: without a gain map, depth
    /// map or second view, without a motion photo's video, without data
    /// after the image.
    enum JXLObstacle: Sendable { case moreImages, video, otherData }

    var jxlObstacle: JXLObstacle? {
        if isPlain, problem == nil { return nil }
        if problem == .video || keptData.contains(where: { $0.kind == .video }) { return .video }
        if images.count > 1 || problem == .unlistedImages { return .moreImages }
        return .otherData
    }

    /// Whether any image may change with loss: a lossy step is worth trying.
    /// (Kept general for the rule by role still to come.)
    var mayChangeWithLoss: Bool { images.indices.contains { mayChange(image: $0, withLoss: true) } }

    /// What of gap `k` (as bytes of `data`, which this layout was read from)
    /// stays at `level`: all of it when everything stays; below that, what
    /// the container counts across. Leftover bytes could hold anything, so
    /// like unknown metadata they go.
    private func keptBytes(_ k: Int, of data: Data, at level: MetadataHandling) -> Data {
        let gap = gaps[k]
        if level == .keep { return data.subdata(in: gap) }
        return data.subdata(in: gap.lowerBound + kept[k].lowerBound..<gap.lowerBound + kept[k].upperBound)
    }

    /// Holds `result` (laid out as `after`), made from the original `a` this
    /// layout was read from, to the rules: as many images, none that can't
    /// be read safely; those that may not change unchanged; between and
    /// after the images the original's bytes as they stay at `level` (where
    /// all may go: nothing but padding); Google's directories as they were
    /// but for the new lengths of the images only it lists; the
    /// multi-picture index, if any, the original's but for exact sizes and
    /// starts.
    func check(_ after: JPEGLayout, in result: ByteView, original a: ByteView, level: MetadataHandling) throws {
        guard after.images.count == images.count else { throw FormatError("images lost or added") }
        guard after.problem == nil else { throw FormatError("images can't be read safely") }
        for n in images.indices where !mayChange(image: n, writingLengths: Self.writesLengths(at: level)) {
            guard try result.view(after.images[n]).bytes == a.view(images[n]).bytes else { throw FormatError("image \(n + 1) changed") }
        }
        for k in gaps.indices {
            let bytes = try result.view(after.gaps[k]), original = try a.view(gaps[k])
            let stays = keptBytes(k, of: a.bytes, at: level)
            // Leftover padding (after a plain JPEG) may go at any level.
            let ok = bytes.bytes == stays || (level == .keep ? kept[k].isEmpty && original.isPadding : stays.isEmpty) && bytes.isPadding
            guard ok else { throw FormatError("data between or after the images changed") }
        }
        var expected = directories
        if index == .container, let listing = directories.indices.first(where: { directories[$0].count > 1 }) {
            for (entry, image) in zip(containerEntries, after.images.dropFirst()) where expected[listing].indices.contains(entry) {
                expected[listing][entry].length = image.count
            }
        }
        guard after.index == index, after.containerEntries == containerEntries, after.directories == expected
        else { throw FormatError("container directory") }
        guard index == .multiPicture else { return }
        // Only the sizes and starts in the index may change, and they are exact.
        guard MultiPictureIndex.withoutPositions(result) == MultiPictureIndex.withoutPositions(a),
              let entries = MultiPictureIndex.read(result),
              entries == after.images.map({ MultiPictureIndex.Entry(start: $0.lowerBound, size: $0.count) })
        else { throw FormatError("multi-picture index") }
    }

    // MARK: - Writer

    /// The file `data` (which this layout was read from) with its images
    /// replaced by `new`, and of its gaps what stays at `level`.
    func assembled(_ new: [Data], from data: Data, level: MetadataHandling) throws -> Data {
        try Self.joined(new, gaps: gaps.indices.map { keptBytes($0, of: data, at: level) }, rewritingIndex: index == .multiPicture)
    }

    /// `images` one after another, each followed by its gap (none when
    /// `gaps` is empty); with more than one and `rewritingIndex`, the
    /// multi-picture index in the first is rewritten to their sizes and
    /// starts. (The lengths in Google's container are written by the
    /// metadata step, into the photo's XMP.)
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
        let container = GoogleXMP.containerNamespaces.map { Data($0.utf8) }
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
