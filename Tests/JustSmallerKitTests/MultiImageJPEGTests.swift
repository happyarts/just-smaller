import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

/// JPEGs that hold several images (HDR gain map, depth, stereo): taken apart,
/// optimized and checked image by image, joined again with the index
/// rewritten — and left alone when anything else follows the images.
@Suite(.serialized)
final class MultiImageJPEGTests {
    let dir: URL
    var settings = OptimizationSettings()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings.moveOriginalsToTrash = false
        ToolRunner.directory = toolsDirectory
        Trash.testFolder = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-Trash")
    }
    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func image(width: Int = 160, height: Int = 120) -> CGImage { TestImages.pattern(width: width, height: height) }
    private var gps: [CFString: Any] { TestImages.gps }
    private func gainMapPhoto(_ name: String) -> URL { TestImages.gainMapPhoto(at: dir.appending(path: name)) }

    /// The images of a file, each on its own.
    private func images(_ data: Data) -> [Data] {
        (JPEGLayout.read(ByteView(data))?.images ?? []).map { data.subdata(in: $0) }
    }

    /// `image` with a segment inserted right after its SOI.
    private func inserting(_ segment: Data, into image: Data) -> Data {
        image.prefix(2) + segment + image.dropFirst(2)
    }

    /// An EXIF segment with a location, as ImageIO writes it.
    private func exifWithLocation() throws -> Data {
        let url = dir.appending(path: "exif-\(UUID().uuidString).jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(width: 8, height: 8), [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let segments = try JPEGMarkers.headers(ByteView(try Data(contentsOf: url))).segments
        return try #require(segments.first { JPEGMarkers.part($0.marker, payload: $0.payload.bytes) == .exif }).whole.bytes
    }

    private func props(_ data: Data) -> [CFString: Any] { TestImages.properties(data) }
    private func headroom(_ url: URL) -> Float? { TestImages.headroom(url) }

    private func optimize(_ url: URL) async throws -> Outcome {
        try await FileOptimizer(settings: settings).optimize(url) { _ in }
    }

    // MARK: - Reading and writing the index

    @Test func imagesAreFoundAndJoinedAgain() throws {
        let data = try Data(contentsOf: gainMapPhoto("round-trip.jpg"))
        let ranges = try #require(JPEGLayout.read(ByteView(data))?.images)
        #expect(ranges.count == 2)
        #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == data.count)
        // ImageIO writes the index exactly; joining the same images gives the same file.
        #expect(try JPEGLayout.joined(images(data)) == data)

        // Another size for the first image: the index follows it.
        var parts = images(data)
        parts[0] = inserting(JPEGMarkers.write(0xFE, Array("a comment".utf8)), into: parts[0])
        let joined = try JPEGLayout.joined(parts)
        let index = try #require(MultiPictureIndex.read(ByteView(joined)))
        #expect(index == [MultiPictureIndex.Entry(start: 0, size: parts[0].count),
                          MultiPictureIndex.Entry(start: parts[0].count, size: parts[1].count)])
        #expect(images(joined).map(\.count) == parts.map(\.count) && images(joined)[1] == parts[1])
    }

    /// Old cameras and stereo (MPO) files write the index little-endian.
    @Test func littleEndianIndexIsRewritten() throws {
        let image: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]
        func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        // One IFD with MPEntry (UNDEFINED, 32 bytes at 26): stale sizes and offsets, image 2 depends on nothing.
        var tiff: [UInt8] = Array("II".utf8) + [42, 0] + le(8) + [1, 0] + [0x02, 0xB0, 7, 0] + le(32) + le(26) + le(0)
        tiff += le(0x2003_0000) + le(999) + le(0) + [1, 0, 0, 0] + le(0) + le(999) + le(999) + [0, 0, 0, 0]
        let first = Data([0xFF, 0xD8]) + JPEGMarkers.write(0xE2, Array("MPF\0".utf8) + tiff) + Data(image.dropFirst(2))
        let joined = try JPEGLayout.joined([first, Data(image)])
        #expect(MultiPictureIndex.read(ByteView(joined)) == [MultiPictureIndex.Entry(start: 0, size: first.count),
                                                               MultiPictureIndex.Entry(start: first.count, size: image.count)])
        #expect(JPEGLayout.read(ByteView(joined))?.images == [0..<first.count, first.count..<joined.count])
        // Attributes and dependent-image entries stay as they were.
        #expect(MultiPictureIndex.withoutPositions(ByteView(joined)) == MultiPictureIndex.withoutPositions(ByteView(first + Data(image))))
    }

    @Test func wrongSizesInTheIndexAreRejected() throws {
        let url = gainMapPhoto("sizes.jpg")
        let data = try Data(contentsOf: url)
        var parts = images(data)
        // The second image grew by a fill byte before a marker; the index
        // still has its old size.
        parts[1] = inserting(Data([0xFF]), into: parts[1])
        let stale = parts[0] + parts[1]
        let result = dir.appending(path: "stale.jpg")
        try stale.write(to: result)
        #expect(throws: VerificationError.self) {
            try StructureCheck.verify(result: result, against: StructureCheck.Reference(original: url, format: .jpeg))
        }
        var joined = try JPEGLayout.joined(parts)
        try joined.write(to: result)
        try StructureCheck.verify(result: result, against: StructureCheck.Reference(original: url, format: .jpeg))

        // Anything else in the index (here: image 1's attributes) must stay.
        let at = try #require(joined.range(of: Data("MPF\0".utf8))).upperBound
        let attributes = try #require(joined.range(of: Data([0x00, 0x03, 0x00, 0x00]), in: at..<joined.count)).lowerBound
        joined[attributes + 1] = 0x02
        try joined.write(to: result)
        #expect(throws: VerificationError.self) {
            try StructureCheck.verify(result: result, against: StructureCheck.Reference(original: url, format: .jpeg))
        }
    }

    // MARK: - Optimizing

    @Test(arguments: [MetadataHandling.keep, .removePrivate, .copyrightOnly, .removeAll])
    func gainMapPhotoIsOptimizedImageByImage(level: MetadataHandling) async throws {
        let url = gainMapPhoto("gain-map-\(level.rawValue).jpg")
        // The gain map carries a location of its own.
        var parts = images(try Data(contentsOf: url))
        parts[1] = inserting(try exifWithLocation(), into: parts[1])
        try JPEGLayout.joined(parts).write(to: url)
        let before = try Data(contentsOf: url), headroomBefore = headroom(url)
        #expect(props(parts[1])[kCGImagePropertyGPSDictionary] != nil)

        settings.metadata = level
        guard case .optimized(let from, let to, _, _, _, let identical) = try await optimize(url) else {
            Issue.record("not optimized"); return
        }
        #expect(identical && to < from)
        let after = try Data(contentsOf: url)
        let result = images(after)
        #expect(result.count == 2)
        for image in result {
            #expect((props(image)[kCGImagePropertyGPSDictionary] != nil) == (level == .keep))
        }
        let artist = (props(after)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] as? String
        #expect((artist == "Jane Doe") == (level != .removeAll))

        // Apple's maker note keeps only the HDR headroom and the Live Photo's
        // identifier, unchanged; the photo is as bright as before.
        let maker = props(after)[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        #expect(Set((maker ?? [:]).keys) == (level == .keep ? ["17", "33", "43", "48"] : ["17", "33", "48"]))
        #expect(maker?["17"] as? String == (props(before)[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?["17"] as? String)
        #expect(headroom(url) == headroomBefore)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        #expect(AuxiliaryImages.all(source) == [kCGImageAuxiliaryDataTypeHDRGainMap])
        #expect(before.count > after.count)
    }

    /// Google's container lists the lengths of the other images in the
    /// first one's XMP: only the first image changes.
    @Test func imagesListedInXMPStayAsTheyAre() async throws {
        let url = gainMapPhoto("container.jpg")
        var parts = images(try Data(contentsOf: url))
        parts[0] = inserting(GoogleXMPSamples.segment(GoogleXMPSamples.directory(gainMapLength: parts[1].count)), into: parts[0])
        try JPEGLayout.joined(parts).write(to: url)

        let original = dir.appending(path: "container-original.jpg")
        try FileManager.default.copyItem(at: url, to: original)
        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        let result = images(try Data(contentsOf: url))
        #expect(result.count == 2 && result[1] == parts[1])
        #expect(result[0].count < parts[0].count)

        // The check holds it too: a changed second image is rejected.
        let changed = dir.appending(path: "container-changed.jpg")
        try JPEGLayout.joined([result[0], inserting(Data([0xFF]), into: result[1])]).write(to: changed)
        #expect(throws: VerificationError.self) {
            try StructureCheck.verify(result: changed, against: StructureCheck.Reference(original: original, format: .jpeg))
        }
    }

    /// A video or other data after the images (motion photos), or an index
    /// that doesn't fit the file: left exactly as it is.
    @Test func motionPhotoIsLeftAlone() async throws {
        let url = gainMapPhoto("motion.jpg")
        // An MP4 file starts with its ftyp box: size, type, brand.
        try (try Data(contentsOf: url) + Data([0, 0, 0, 0x18]) + Data("ftypmp42".utf8) + Data(repeating: 0x42, count: 5000)).write(to: url)
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: url)))?.problem == .video)
        let before = try Data(contentsOf: url)
        guard case .skipped = try await optimize(url) else { Issue.record("not skipped"); return }
        #expect(try Data(contentsOf: url) == before)
    }

    /// A motion photo as Pixel and Samsung write it: the photo, camera data,
    /// then the video, which the container's directory counts from the end.
    /// `videoLength` is what the directory says (the video's length unless
    /// a test wants it wrong). The video's data holds what looks like a JPEG.
    private func motionPhoto(_ name: String, old: Bool = false, videoLength: ((Int) -> Int)? = nil) throws -> (url: URL, photo: Data, after: Data) {
        let first = images(try Data(contentsOf: gainMapPhoto(name)))[0]
        let index = try #require(try JPEGMarkers.headers(ByteView(first)).segments.first(where: MultiPictureIndex.isIndex))
        var video = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(count: 12)
        video += Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) }) + Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(count: 100)
        let length = videoLength?(video.count) ?? video.count
        // Older ones (Pixel 2 and 3): no directory, only the video's offset from the end.
        let description = old
            ? "<rdf:Description xmlns:GCamera=\"\(GoogleXMP.camera)\" GCamera:MicroVideo=\"1\" GCamera:MicroVideoVersion=\"1\" GCamera:MicroVideoOffset=\"\(length)\"/>"
            : GoogleXMPSamples.directory(gainMapLength: nil, videoLength: length)
                .replacingOccurrences(of: "<rdf:Description ", with: "<rdf:Description xmlns:GCamera=\"\(GoogleXMP.camera)\" GCamera:MotionPhoto=\"1\" ")
        let photo = inserting(GoogleXMPSamples.segment(description), into: first.prefix(index.offset) + first.dropFirst(index.end))
        let after = Data("aecDebug camera tuning data".utf8) + video
        let url = dir.appending(path: name)
        try (photo + after).write(to: url)
        return (url, photo, after)
    }

    /// A motion photo whose video the directory places at the end: only the
    /// photo changes, everything after it stays byte for byte — also below
    /// "keep everything", since the video is counted from the end.
    @Test(arguments: [MetadataHandling.keep, .removePrivate], [false, true])
    func motionPhotoWithPlacedVideoIsOptimized(level: MetadataHandling, old: Bool) async throws {
        let file = try motionPhoto("motion-\(level.rawValue)-\(old).jpg", old: old)
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: file.url)))?.problem == nil)
        settings.metadata = level
        guard case .optimized = try await optimize(file.url) else { Issue.record("not optimized"); return }
        let result = try Data(contentsOf: file.url)
        let layout = try #require(JPEGLayout.read(ByteView(result)))
        #expect(layout.problem == nil && layout.images.count == 1)
        #expect(result.suffix(file.after.count) == file.after)
        #expect(result.count - file.after.count < file.photo.count)
        let read = try #require(GoogleXMP.read(try JPEGMarkers.headers(ByteView(result)).segments))
        let trailer = try ByteView(result).view(from: layout.gaps[0].lowerBound)
        #expect(read.marksMotionPhoto && read.video(endingAt: trailer) != nil)
    }

    /// A video the directory doesn't place (wrong length), and a result
    /// whose video changed: left alone, and rejected.
    @Test func motionPhotoWithMisplacedVideoStays() async throws {
        let wrong = try motionPhoto("misplaced.jpg") { $0 + 1 }
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: wrong.url)))?.problem == .video)
        let oldWrong = try motionPhoto("misplaced-old.jpg", old: true) { $0 - 1 }
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: oldWrong.url)))?.problem == .video)
        let before = try Data(contentsOf: wrong.url)
        guard case .skipped = try await optimize(wrong.url) else { Issue.record("not skipped"); return }
        #expect(try Data(contentsOf: wrong.url) == before)

        // Placed means: exactly one video, an MP4 that ends the file at its length.
        let mp4 = ByteView(Data("camera data".utf8) + Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(count: 20))
        func xmp(_ videos: [Int]) -> GoogleXMP {
            GoogleXMP(directories: [[GoogleXMP.Item(mime: "image/jpeg")] + videos.map { GoogleXMP.Item(mime: "video/mp4", length: $0) }])
        }
        #expect(xmp([32]).video(endingAt: mp4) == 32)
        #expect(xmp([32, 32]).video(endingAt: mp4) == nil && xmp([31]).video(endingAt: mp4) == nil)
        #expect(xmp([]).video(endingAt: mp4) == nil && xmp([500]).video(endingAt: mp4) == nil)
        // An older motion photo's offset counts the same; a directory's video comes first.
        var old = xmp([]); old.microVideoOffset = 32
        #expect(old.video(endingAt: mp4) == 32)
        var both = xmp([31]); both.microVideoOffset = 32
        #expect(both.video(endingAt: mp4) == nil)

        let placed = try motionPhoto("placed.jpg")
        var changed = try Data(contentsOf: placed.url)
        changed[changed.count - 50] ^= 1
        let result = dir.appending(path: "video-changed.jpg")
        try changed.write(to: result)
        #expect(throws: VerificationError.self) {
            try StructureCheck.verify(result: result, against: StructureCheck.Reference(original: placed.url, format: .jpeg))
        }
    }

    /// The photo with the container's directory in its XMP and no
    /// multi-picture index, then `between`, the gain map, `after`.
    private func containerOnly(_ name: String, gainMap: (Data) throws -> Data = { $0 }, between: Data = Data(), after: Data = Data(),
                               listedLength: ((Int) -> Int)? = nil) throws -> (url: URL, photo: Data, rest: Data) {
        let parts = images(try Data(contentsOf: gainMapPhoto(name)))
        let segments = try JPEGMarkers.headers(ByteView(parts[0])).segments
        let index = try #require(segments.first(where: MultiPictureIndex.isIndex))
        let second = try gainMap(parts[1])
        let directory = GoogleXMPSamples.directory(gainMapLength: listedLength?(second.count) ?? second.count)
        let photo = inserting(GoogleXMPSamples.segment(directory), into: parts[0].prefix(index.offset) + parts[0].dropFirst(index.end))
        let url = dir.appending(path: name)
        try (photo + between + second + after).write(to: url)
        return (url, photo, between + second + after)
    }

    /// Images only Google's container lists (Pixel portraits, Ultra HDR
    /// without an index) are found where its directory says — counted from
    /// the end, or right after the photo with camera data behind them
    /// (Dynamic Depth): only the photo changes, the rest stays byte for byte.
    @Test(arguments: [(Data(), Data()), (Data(), Data("aecDebug camera data".utf8)), (Data("aecDebug camera data".utf8), Data())])
    func imagesOnlyTheContainerListsAreFound(between: Data, after: Data) async throws {
        let file = try containerOnly("container-only-\(between.count)-\(after.count).jpg", between: between, after: after)
        let layout = try #require(JPEGLayout.read(ByteView(try Data(contentsOf: file.url))))
        #expect(layout.problem == nil && layout.index == .container && layout.images.count == 2)
        #expect(!layout.mayChange(image: 1))
        settings.metadata = .removePrivate
        guard case .optimized = try await optimize(file.url) else { Issue.record("not optimized"); return }
        let result = try Data(contentsOf: file.url)
        #expect(result.suffix(file.rest.count) == file.rest && result.count - file.rest.count < file.photo.count)
        #expect(JPEGLayout.read(ByteView(result))?.images.count == 2)
    }

    /// A length the images aren't at, and a location in the second image
    /// (it may not change, so the level's promise can't be kept): the file
    /// stays as it is.
    @Test func imagesTheContainerListsWronglyOrPrivatelyStay() async throws {
        let wrong = try containerOnly("container-wrong.jpg", listedLength: { $0 + 1 })
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: wrong.url)))?.problem == .unlistedImages)
        // One byte short: it starts where it should, but doesn't end there.
        let short = try containerOnly("container-short.jpg", listedLength: { $0 - 1 })
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: short.url)))?.problem == .unlistedImages)
        let located = try containerOnly("container-gps.jpg", gainMap: { self.inserting(try self.exifWithLocation(), into: $0) })
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: located.url)))?.problem == nil)
        settings.metadata = .removePrivate
        for url in [wrong.url, located.url] {
            let before = try Data(contentsOf: url)
            let outcome = try await optimize(url)
            if case .optimized = outcome { Issue.record("\(url.lastPathComponent) changed") }
            #expect(try Data(contentsOf: url) == before)
            // The reason says where the data is that can't go.
            if url == located.url, case .unchanged(let reason, _, _) = outcome { #expect(reason.contains("must stay as it is")) }
        }
        // At "keep everything" the located one is optimized: nothing has to go.
        settings.metadata = .keep
        guard case .optimized = try await optimize(located.url) else { Issue.record("not optimized at keep"); return }
    }

    /// A single photo that the container lists alone, with padding after it:
    /// nothing counts from the end, so it is an ordinary JPEG.
    @Test func containerWithOnlyThePhotoIsPlain() async throws {
        let first = images(try Data(contentsOf: gainMapPhoto("alone.jpg")))[0]
        let segments = try JPEGMarkers.headers(ByteView(first)).segments
        let index = try #require(segments.first(where: MultiPictureIndex.isIndex))
        let photo = inserting(GoogleXMPSamples.segment(GoogleXMPSamples.directory(gainMapLength: nil)),
                              into: first.prefix(index.offset) + first.dropFirst(index.end))
        let url = dir.appending(path: "alone-padded.jpg")
        try (photo + Data(count: 300)).write(to: url)
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: url)))?.isPlain == true)
        settings.metadata = .keep // the container's mark stays
        guard case .optimized(_, _, let tools, _, _, _) = try await optimize(url) else { Issue.record("not optimized"); return }
        #expect(tools.contains("jpeg-scan"))
    }

    /// Another JPEG after the photo that no index lists, and a photo cut off
    /// before its end: both stay exactly as they are.
    @Test func unlistedOrCutOffJPEGsStay() async throws {
        let parts = images(try Data(contentsOf: gainMapPhoto("unlisted.jpg")))
        let segments = try JPEGMarkers.headers(ByteView(parts[0])).segments
        let index = try #require(segments.first(where: MultiPictureIndex.isIndex))
        let unlisted = dir.appending(path: "appended.jpg"), cut = dir.appending(path: "cut.jpg")
        try (parts[0].prefix(index.offset) + parts[0].dropFirst(index.end) + parts[1]).write(to: unlisted)
        try parts[0].prefix(parts[0].count - 200).write(to: cut)
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: unlisted)))?.problem == .unlistedImages)
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: cut))) == nil)
        // The three bytes of an SOI by chance, with no JPEG behind them: leftover bytes.
        let chance = parts[0].prefix(index.offset) + parts[0].dropFirst(index.end) + Data("camera".utf8)
            + Data([0xFF, 0xD8, 0xFF, 0x00, 0x00]) + Data("buffer".utf8)
        #expect(JPEGLayout.read(ByteView(chance))?.problem == nil)
        for url in [unlisted, cut] {
            let before = try Data(contentsOf: url)
            guard case .skipped = try await optimize(url) else { Issue.record("\(url.lastPathComponent) not skipped"); continue }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    /// Google marks a motion photo in the XMP (1, not 0; an attribute or an
    /// element, by namespace, whatever the prefix), or its directory lists
    /// a video; Samsung's trailer has its own signature.
    @Test func motionPhotoMarks() throws {
        let parts = images(try Data(contentsOf: gainMapPhoto("marks.jpg")))
        func file(_ description: String?, trailer: String = "") throws -> ByteView {
            var first = parts[0]
            if let description { first = inserting(GoogleXMPSamples.segment(description), into: first) }
            return ByteView(try JPEGLayout.joined([first, parts[1]], gaps: [Data(), Data(trailer.utf8)]))
        }
        func video(_ b: ByteView) throws -> Bool { try #require(JPEGLayout.read(b)).problem == .video }
        let camera = "xmlns:GCamera=\"\(GoogleXMP.camera)\""
        #expect(try video(file("<rdf:Description \(camera) GCamera:MotionPhoto=\"1\"/>", trailer: "video")))
        #expect(try video(file("<rdf:Description xmlns:Cam=\"\(GoogleXMP.camera)\"><Cam:MicroVideo> 1 </Cam:MicroVideo></rdf:Description>",
                               trailer: "video")))
        #expect(try !video(file("<rdf:Description \(camera) GCamera:MotionPhoto=\"0\"/>", trailer: "video")))
        // The prefix alone says nothing.
        #expect(try !video(file("<rdf:Description xmlns:GCamera=\"http://example.com/\" GCamera:MotionPhoto=\"1\"/>", trailer: "video")))
        // The mark without anything after the images: an editor dropped the video.
        #expect(try !video(file("<rdf:Description \(camera) GCamera:MotionPhoto=\"1\"/>")))
        #expect(try video(file(GoogleXMPSamples.directory(gainMapLength: parts[1].count, videoLength: 5), trailer: "video")))
        #expect(try video(file(nil, trailer: "...video...MotionPhoto_Data")))
        #expect(try !video(file(nil, trailer: "camera buffer")))
        // Samsung's trailer ends the file with SEFT; the four bytes elsewhere are chance.
        #expect(try video(file(nil, trailer: "...SEFH...SEFT")))
        #expect(try !video(file(nil, trailer: "camera SEFT buffer")))
    }

    // MARK: - Google's XMP

    /// The directory as Ultra HDR writes it (attributes), as elements, and
    /// as Dynamic Depth writes it in the extended XMP (rdf:value) — read by
    /// namespace, whatever the prefixes.
    @Test func googleDirectoryIsReadInEveryForm() throws {
        let gainMap = GoogleXMP.Item(semantic: "GainMap", mime: "image/jpeg", length: 1531)
        let attributes = try #require(GoogleXMP.read(GoogleXMPSamples.headers(GoogleXMPSamples.directory(gainMapLength: 1531))))
        #expect(attributes == GoogleXMP(directories: [[GoogleXMP.Item(semantic: "Primary", mime: "image/jpeg"), gainMap]]))
        #expect(attributes.listsMoreThanThePhoto && !attributes.listsVideo && !attributes.marksMotionPhoto)

        let elements = """
            <rdf:Description xmlns:C="\(GoogleXMP.container[0])" xmlns:I="\(GoogleXMP.item[0])"><C:Directory><rdf:Seq>\
            <rdf:li rdf:parseType="Resource"><C:Item><I:Mime>image/jpeg</I:Mime><I:Semantic>Primary</I:Semantic>\
            <I:Padding>59</I:Padding></C:Item></rdf:li>\
            <rdf:li rdf:parseType="Resource"><C:Item><I:Mime>video/mp4</I:Mime><I:Semantic>MotionPhoto</I:Semantic>\
            <I:Length> 4708929 </I:Length></C:Item></rdf:li></rdf:Seq></C:Directory></rdf:Description>
            """
        let read = try #require(GoogleXMP.read(GoogleXMPSamples.headers(elements)))
        #expect(read.directories == [[GoogleXMP.Item(semantic: "Primary", mime: "image/jpeg", padding: 59),
                                      GoogleXMP.Item(semantic: "MotionPhoto", mime: "video/mp4", length: 4708929)]])
        #expect(read.listsVideo)

        let depth = """
            <rdf:Description xmlns:Device="http://ns.google.com/photos/dd/1.0/device/" \
            xmlns:Container="\(GoogleXMP.container[1])" xmlns:Item="\(GoogleXMP.item[1])"><Device:Container rdf:parseType="Resource">\
            <Container:Directory><rdf:Seq>\
            <rdf:li rdf:parseType="Resource"><rdf:value rdf:parseType="Resource"><Item:Mime>image/jpeg</Item:Mime>\
            <Item:Length>0</Item:Length><Item:DataURI>primary_image</Item:DataURI></rdf:value></rdf:li>\
            <rdf:li rdf:parseType="Resource"><rdf:value rdf:parseType="Resource"><Item:Mime>image/jpeg</Item:Mime>\
            <Item:Length>179722</Item:Length><Item:DataURI>android/depthmap</Item:DataURI></rdf:value></rdf:li>\
            </rdf:Seq></Container:Directory></Device:Container></rdf:Description>
            """
        let extended = try #require(GoogleXMP.read(GoogleXMPSamples.headers(nil, extended: depth)))
        #expect(extended.directories == [[GoogleXMP.Item(mime: "image/jpeg"), GoogleXMP.Item(mime: "image/jpeg", length: 179722)]])

        // Items straight in the list, without rdf:li: the same; a directory with no item: unreadable.
        let bare = GoogleXMPSamples.directory(gainMapLength: 1531).replacingOccurrences(of: "<rdf:li rdf:parseType=\"Resource\">", with: "")
            .replacingOccurrences(of: "</rdf:li>", with: "")
        #expect(GoogleXMP.read(try GoogleXMPSamples.headers(bare)) == attributes)
        let empty = "<rdf:Description xmlns:Container=\"\(GoogleXMP.container[0])\"><Container:Directory><rdf:Seq/></Container:Directory></rdf:Description>"
        #expect(GoogleXMP.read(try GoogleXMPSamples.headers(empty)) == nil)
        // Other prefixes for the same namespaces: the same.
        let renamed = GoogleXMPSamples.directory(gainMapLength: 1531).replacingOccurrences(of: "Item:", with: "i:")
            .replacingOccurrences(of: "xmlns:Item=", with: "xmlns:i=")
        #expect(GoogleXMP.read(try GoogleXMPSamples.headers(renamed)) == attributes)
        // The item prefix bound to another namespace: items without properties.
        let foreign = GoogleXMPSamples.directory(gainMapLength: 1531).replacingOccurrences(of: GoogleXMP.item[0], with: "http://example.com/")
        #expect(GoogleXMP.read(try GoogleXMPSamples.headers(foreign)) == GoogleXMP(directories: [[GoogleXMP.Item(), GoogleXMP.Item()]]))
        // Another namespace under the same prefixes: nothing; no Google namespace at all: not even parsed.
        let other = GoogleXMPSamples.directory(gainMapLength: 1531).replacingOccurrences(of: GoogleXMP.container[0], with: "http://example.com/")
        #expect(GoogleXMP.read(try GoogleXMPSamples.headers(other)) == GoogleXMP())
        #expect(GoogleXMP.read(try GoogleXMPSamples.headers("<rdf:Description xmlns:a=\"http://example.com/\" a:x=\"<\"/>")) == GoogleXMP())
    }

    /// Google's XMP that can't be read stops a file only where something
    /// follows the photo; then it is left as it is.
    @Test func unreadableGoogleXMP() throws {
        let parts = images(try Data(contentsOf: gainMapPhoto("unreadable-xmp.jpg")))
        let broken = GoogleXMPSamples.directory(gainMapLength: -1)
        let first = inserting(GoogleXMPSamples.segment(broken), into: parts[0])
        #expect(JPEGLayout.read(ByteView(try JPEGLayout.joined([first, parts[1]])))?.problem == .unreadableXMP)
        let segments = try JPEGMarkers.headers(ByteView(first)).segments
        let index = try #require(segments.first(where: MultiPictureIndex.isIndex))
        let alone = try #require(JPEGLayout.read(ByteView(first.prefix(index.offset) + first.dropFirst(index.end))))
        #expect(alone.isPlain && alone.problem == nil)
    }

    /// Only a plain JPEG's photo may be encoded anew: a photo with a gain
    /// map gets no lossy step, and stays lossless in lossy mode.
    @Test func onlyAPlainPhotoIsReencoded() async throws {
        let url = gainMapPhoto("lossy.jpg")
        let layout = try #require(JPEGLayout.read(ByteView(try Data(contentsOf: url))))
        let first = images(try Data(contentsOf: url))[0]
        let index = try #require(try JPEGMarkers.headers(ByteView(first)).segments.first(where: MultiPictureIndex.isIndex))
        let plain = try #require(JPEGLayout.read(ByteView(first.prefix(index.offset) + first.dropFirst(index.end))))
        #expect(!layout.mayChange(image: 0, withLoss: true) && !layout.mayChange(image: 1, withLoss: true))
        #expect(plain.mayChange(image: 0, withLoss: true))
        settings.lossy = true
        settings.quality = 50
        func lossy(_ layout: JPEGLayout) -> Bool {
            Pipeline.stages(for: .jpeg, facts: FileFacts(byteSize: 1, jpegQuality: 90, jpegLayout: layout), settings: settings)
                .joined().contains(where: \.isLossy)
        }
        #expect(!lossy(layout) && lossy(plain))
        guard case .optimized(_, _, let tools, _, _, let identical) = try await optimize(url) else { Issue.record("not optimized"); return }
        #expect(identical && !tools.contains("jpegli"))
    }

    /// Leftover bytes may stay only as they were, and only when everything is kept.
    @Test func changedOrKeptLeftoversAreCaught() throws {
        let url = gainMapPhoto("leftover-check.jpg")
        let parts = images(try Data(contentsOf: url))
        try JPEGLayout.joined(parts, gaps: [Data("leftover".utf8), Data()]).write(to: url)
        let result = dir.appending(path: "leftover-result.jpg")
        let reference = StructureCheck.Reference(original: url, format: .jpeg)
        try JPEGLayout.joined(parts, gaps: [Data("leftovex".utf8), Data()]).write(to: result)
        #expect(throws: VerificationError.self) { try StructureCheck.verify(result: result, against: reference) }
        try JPEGLayout.joined(parts, gaps: [Data("leftover".utf8), Data()]).write(to: result)
        try StructureCheck.verify(result: result, against: reference)
        // Below "keep everything" they may only go.
        let removing = StructureCheck.Reference(original: url, format: .jpeg, level: .removeAll)
        #expect(throws: VerificationError.self) { try StructureCheck.verify(result: result, against: removing) }
        try JPEGLayout.joined(parts).write(to: result)
        try StructureCheck.verify(result: result, against: removing)
    }

    /// Cameras leave leftover bytes between and after the images. Everything
    /// kept: they stay byte for byte where they were; otherwise they go, like
    /// unknown metadata.
    @Test(arguments: [MetadataHandling.keep, .removePrivate])
    func leftoverBytesBetweenImages(level: MetadataHandling) async throws {
        let url = gainMapPhoto("leftovers-\(level.rawValue).jpg")
        let parts = images(try Data(contentsOf: url))
        let gaps = [Data((0..<340).map { UInt8($0 % 251) }), Data("camera buffer".utf8)]
        try JPEGLayout.joined(parts, gaps: gaps).write(to: url)
        let bytes = ByteView(try Data(contentsOf: url))
        #expect(try #require(JPEGLayout.read(bytes)).problem == nil)

        settings.metadata = level
        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        let data = try Data(contentsOf: url)
        let kept = try #require(JPEGLayout.read(ByteView(data))).gaps.map { data.subdata(in: $0) }
        #expect(kept == (level == .keep ? gaps : [Data(), Data()]))
    }

    /// Stereo cameras name their files .mpo; they are JPEGs and are found in folders.
    @Test func mpoFilesAreFoundInFolders() {
        #expect(FolderScanner.isCandidate(dir.appending(path: "DSCF0001.MPO")))
    }

    // MARK: - Checking

    /// Coefficients the same, but the gain map lost the XMP that makes it
    /// one: ImageIO's view of the auxiliary images catches it. (That view
    /// stays even for steps that copy every segment: whether ImageIO applies
    /// a gain map can depend on how the main image is coded — a Commons
    /// photo shows HDR only after jpeg-scan.)
    @Test func gainMapWithoutItsMetadataIsRejected() async throws {
        let url = gainMapPhoto("bare.jpg")
        var parts = images(try Data(contentsOf: url))
        let segments = try JPEGMarkers.headers(ByteView(parts[1])).segments
        let xmp = try #require(segments.first { JPEGMarkers.part($0.marker, payload: $0.payload.bytes) == .xmp })
        parts[1] = parts[1].prefix(xmp.offset) + parts[1].dropFirst(xmp.end)
        let result = dir.appending(path: "bare-result.jpg")
        try JPEGLayout.joined(parts).write(to: result)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: url, result: result, format: .jpeg, pixelsMustMatch: true)
        }
        try await Verifier.verify(original: url, result: url, format: .jpeg, pixelsMustMatch: true)
    }

    /// Another second image (different coefficients) is caught, even though
    /// jpegcmp alone reads only the first.
    @Test func changedSecondImageIsRejected() async throws {
        let url = gainMapPhoto("original.jpg")
        var parts = images(try Data(contentsOf: url))
        let other = dir.appending(path: "other.jpg")
        let dest = CGImageDestinationCreateWithURL(other as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(width: 80, height: 60), [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        parts[1] = try Data(contentsOf: other)
        let result = dir.appending(path: "result.jpg")
        try JPEGLayout.joined(parts).write(to: result)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: url, result: result, format: .jpeg, pixelsMustMatch: true)
        }
    }

    /// Private data left in the second image is caught by the metadata check.
    @Test func locationInSecondImageIsCaught() throws {
        let url = gainMapPhoto("private.jpg")
        var parts = images(try Data(contentsOf: url))
        parts[1] = inserting(try exifWithLocation(), into: parts[1])
        try JPEGLayout.joined(parts).write(to: url)
        let result = dir.appending(path: "leaky.jpg")
        parts[0] = try JPEGMetadataFilter.filter(parts[0], level: .removePrivate, orientation: 1)
        try JPEGLayout.joined(parts).write(to: result)
        #expect(throws: VerificationError.self) { try MetadataCheck.verify(original: url, result: result, level: .removePrivate) }
    }

    @Test func appleMakerNoteKeepsOnlyTheHeadroom() throws {
        // "Apple iOS", version 1, big-endian; tags 8 (three rationals), 33, 48.
        var note: [UInt8] = Array("Apple iOS\0".utf8) + [0, 1] + Array("MM".utf8) + [0, 3]
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) -> [UInt8] {
            [UInt8(tag >> 8), UInt8(tag & 0xFF), UInt8(type >> 8), UInt8(type & 0xFF)]
                + withUnsafeBytes(of: count.bigEndian, Array.init) + withUnsafeBytes(of: value.bigEndian, Array.init)
        }
        let values = 16 + 3 * 12 + 4
        note += entry(8, 10, 3, UInt32(values)) + entry(33, 10, 1, UInt32(values + 24)) + entry(48, 10, 1, UInt32(values + 32))
        note += [0, 0, 0, 0] + [UInt8](repeating: 7, count: 24) + [0, 0, 0, 1, 0, 0, 0, 2] + [0, 0, 0, 3, 0, 0, 0, 4]
        let hdr = try #require(AppleMakerNote.filter(ByteView(note), level: .removePrivate))
        #expect(Array(hdr.prefix(16)) == Array(note.prefix(14)) + [0, 2])
        #expect(Array(hdr.suffix(16)) == [0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4])
        #expect(!hdr.contains(7))
        #expect(AppleMakerNote.filter(ByteView(Array("Nikon\0".utf8) + note), level: .removePrivate) == nil)
    }
}
