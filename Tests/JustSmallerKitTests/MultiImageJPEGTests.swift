import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

/// JPEGs that hold several images (HDR gain map, depth, stereo): taken apart,
/// optimized and checked image by image, joined again with the index
/// rewritten — and left alone when anything else follows the images.
/// HEICs with a gain map keep their HDR headroom the same way.
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

    private func image(width: Int = 160, height: Int = 120) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                ctx.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                                 blue: (x / 8 + y / 8) % 2 == 0 ? 0.9 : 0.1, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return ctx.makeImage()!
    }

    private var gps: [CFString: Any] { [kCGImagePropertyGPSLatitude: 48.1, kCGImagePropertyGPSLatitudeRef: "N"] }

    /// A photo with an Apple HDR gain map as ImageIO writes it: the main
    /// image with EXIF (creator, location, Apple's maker note with the HDR
    /// headroom and an identifier), a gain map after it, indexed by MPF.
    private func gainMapPhoto(_ name: String, type: UTType = .jpeg, location: Bool = true) -> URL {
        let url = dir.appending(path: name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(), [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Doe", kCGImagePropertyTIFFMake: "Apple"],
            kCGImagePropertyGPSDictionary: location ? gps : [:],
            kCGImagePropertyMakerAppleDictionary: ["33": 0.5, "48": 0.001, "43": "0F1E2D3C-UUID"],
        ] as CFDictionary)
        let gainMap = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(gainMap, "http://ns.apple.com/HDRGainMap/1.0/" as CFString, "HDRGainMap" as CFString, nil)
        CGImageMetadataSetValueWithPath(gainMap, nil, "HDRGainMap:HDRGainMapVersion" as CFString, 65536 as CFNumber)
        CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeHDRGainMap, [
            kCGImageAuxiliaryDataInfoData: Data((0..<80 * 60).map { UInt8($0 % 251) }) as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: [kCGImagePropertyWidth: 80, kCGImagePropertyHeight: 60,
                                                       kCGImagePropertyBytesPerRow: 80,
                                                       kCGImagePropertyPixelFormat: 0x4C30_3038], // 'L008'
            kCGImageAuxiliaryDataInfoMetadata: gainMap,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// The images of a file, each on its own.
    private func images(_ data: Data) -> [Data] {
        (JPEGStructure.images(ByteView(data)) ?? []).map { data.subdata(in: $0) }
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

    private func props(_ data: Data) -> [CFString: Any] {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any] ?? [:]
    }

    private func headroom(_ url: URL) -> Float? {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)?.contentHeadroom
    }

    private func optimize(_ url: URL) async throws -> Outcome {
        try await FileOptimizer(settings: settings).optimize(url) { _ in }
    }

    // MARK: - Reading and writing the index

    @Test func imagesAreFoundAndJoinedAgain() throws {
        let data = try Data(contentsOf: gainMapPhoto("round-trip.jpg"))
        let ranges = try #require(JPEGStructure.images(ByteView(data)))
        #expect(ranges.count == 2)
        #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == data.count)
        // ImageIO writes the index exactly; joining the same images gives the same file.
        #expect(try JPEGStructure.joined(images(data)) == data)

        // Another size for the first image: the index follows it.
        var parts = images(data)
        parts[0] = inserting(JPEGMarkers.write(0xFE, Array("a comment".utf8)), into: parts[0])
        let joined = try JPEGStructure.joined(parts)
        let index = try #require(JPEGStructure.imageIndex(ByteView(joined)))
        #expect(index == [JPEGStructure.IndexEntry(start: 0, size: parts[0].count),
                          JPEGStructure.IndexEntry(start: parts[0].count, size: parts[1].count)])
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
        let joined = try JPEGStructure.joined([first, Data(image)])
        #expect(JPEGStructure.imageIndex(ByteView(joined)) == [JPEGStructure.IndexEntry(start: 0, size: first.count),
                                                               JPEGStructure.IndexEntry(start: first.count, size: image.count)])
        #expect(JPEGStructure.images(ByteView(joined)) == [0..<first.count, first.count..<joined.count])
        // Attributes and dependent-image entries stay as they were.
        #expect(JPEGStructure.indexWithoutPositions(ByteView(joined)) == JPEGStructure.indexWithoutPositions(ByteView(first + Data(image))))
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
        var joined = try JPEGStructure.joined(parts)
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
        try JPEGStructure.joined(parts).write(to: url)
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

        // Apple's maker note keeps only the HDR headroom; the photo is as bright as before.
        let maker = props(after)[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        #expect(Set((maker ?? [:]).keys) == (level == .keep ? ["33", "43", "48"] : ["33", "48"]))
        #expect(headroom(url) == headroomBefore)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        #expect(ImageIOMetadata.auxiliaryImages(source) == [kCGImageAuxiliaryDataTypeHDRGainMap])
        #expect(before.count > after.count)
    }

    /// HEIC, with the metadata filtered around the image as it is (lossless)
    /// and re-encoded (lossy): Apple's maker note keeps the HDR headroom.
    @Test(arguments: [(MetadataHandling.keep, false), (.removePrivate, false), (.copyrightOnly, false), (.removeAll, false),
                      (.keep, true), (.removePrivate, true), (.copyrightOnly, true), (.removeAll, true)])
    func heicKeepsTheHDRHeadroom(level: MetadataHandling, lossy: Bool) async throws {
        let url = gainMapPhoto("gain-map-\(level.rawValue)-\(lossy).heic", type: .heic)
        let headroomBefore = try #require(headroom(url))
        #expect(headroomBefore > 1)

        settings.metadata = level
        settings.lossy = lossy
        settings.quality = 40
        settings.outputLossy = .replace
        let outcome = try await optimize(url)
        guard case .optimized(_, _, _, _, _, let identical) = outcome else {
            // Lossless with nothing to remove: the file stays as it is.
            #expect(!lossy && level == .keep, "not optimized: \(outcome)"); return
        }
        #expect(identical == !lossy)
        let after = try Data(contentsOf: url)
        #expect((props(after)[kCGImagePropertyGPSDictionary] != nil) == (level == .keep))
        let maker = props(after)[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        #expect(Set((maker ?? [:]).keys) == (level == .keep ? ["33", "43", "48"] : ["33", "48"]))
        #expect(headroom(url) == headroomBefore)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        #expect(ImageIOMetadata.auxiliaryImages(source) == [kCGImageAuxiliaryDataTypeHDRGainMap])
    }

    /// Google's container lists the lengths of the other images in the
    /// first one's XMP: only the first image changes.
    @Test func imagesListedInXMPStayAsTheyAre() async throws {
        let url = gainMapPhoto("container.jpg")
        var parts = images(try Data(contentsOf: url))
        let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description xmlns:Container="http://ns.google.com/photos/1.0/container/" \
            xmlns:Item="http://ns.google.com/photos/1.0/container/item/"><Container:Directory><rdf:Seq>\
            <rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/></rdf:li>\
            <rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="GainMap" Item:Mime="image/jpeg" \
            Item:Length="\(parts[1].count)"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>
            """
        parts[0] = inserting(JPEGMarkers.write(0xE1, JPEGMarkers.xmpHeader + Array(xmp.utf8)), into: parts[0])
        try JPEGStructure.joined(parts).write(to: url)

        let original = dir.appending(path: "container-original.jpg")
        try FileManager.default.copyItem(at: url, to: original)
        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        let result = images(try Data(contentsOf: url))
        #expect(result.count == 2 && result[1] == parts[1])
        #expect(result[0].count < parts[0].count)

        // The check holds it too: a changed second image is rejected.
        let changed = dir.appending(path: "container-changed.jpg")
        try JPEGStructure.joined([result[0], inserting(Data([0xFF]), into: result[1])]).write(to: changed)
        #expect(throws: VerificationError.self) {
            try StructureCheck.verify(result: changed, against: StructureCheck.Reference(original: original, format: .jpeg))
        }
    }

    /// A video or other data after the images (motion photos), or an index
    /// that doesn't fit the file: left exactly as it is.
    @Test func motionPhotoIsLeftAlone() async throws {
        let url = gainMapPhoto("motion.jpg")
        try (try Data(contentsOf: url) + Data("....ftypmp42".utf8) + Data(repeating: 0x42, count: 5000)).write(to: url)
        let bytes = ByteView(try Data(contentsOf: url))
        #expect(JPEGStructure.hasSecondaryImage(bytes))
        #expect(JPEGStructure.holdsVideo(bytes, images: try #require(JPEGStructure.images(bytes))))
        let before = try Data(contentsOf: url)
        guard case .skipped = try await optimize(url) else { Issue.record("not skipped"); return }
        #expect(try Data(contentsOf: url) == before)
    }

    /// Google marks a motion photo in the XMP (1, not 0); Samsung's trailer
    /// has its own signature.
    @Test func motionPhotoMarks() throws {
        let parts = images(try Data(contentsOf: gainMapPhoto("marks.jpg")))
        func file(xmp: String?, trailer: String = "") throws -> ByteView {
            var first = parts[0]
            if let xmp {
                let packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
                    + "<rdf:Description xmlns:GCamera=\"http://ns.google.com/photos/1.0/camera/\" \(xmp)/></rdf:RDF></x:xmpmeta>"
                first = inserting(JPEGMarkers.write(0xE1, JPEGMarkers.xmpHeader + Array(packet.utf8)), into: first)
            }
            return ByteView(try JPEGStructure.joined([first, parts[1]], gaps: [Data(), Data(trailer.utf8)]))
        }
        func video(_ b: ByteView) throws -> Bool { JPEGStructure.holdsVideo(b, images: try #require(JPEGStructure.images(b))) }
        #expect(try video(file(xmp: "GCamera:MotionPhoto=\"1\"")))
        #expect(try !video(file(xmp: "GCamera:MotionPhoto=\"0\"")))
        #expect(try video(file(xmp: nil, trailer: "...video...MotionPhoto_Data")))
        #expect(try !video(file(xmp: nil, trailer: "camera buffer")))
    }

    /// Leftover bytes may stay only as they were, and only when everything is kept.
    @Test func changedOrKeptLeftoversAreCaught() throws {
        let url = gainMapPhoto("leftover-check.jpg")
        let parts = images(try Data(contentsOf: url))
        try JPEGStructure.joined(parts, gaps: [Data("leftover".utf8), Data()]).write(to: url)
        let result = dir.appending(path: "leftover-result.jpg")
        let reference = StructureCheck.Reference(original: url, format: .jpeg)
        try JPEGStructure.joined(parts, gaps: [Data("leftovex".utf8), Data()]).write(to: result)
        #expect(throws: VerificationError.self) { try StructureCheck.verify(result: result, against: reference) }
        try JPEGStructure.joined(parts, gaps: [Data("leftover".utf8), Data()]).write(to: result)
        try StructureCheck.verify(result: result, against: reference)
        try MetadataCheck.verify(original: url, result: result, level: .keep)
        // Filtered images: only the leftover bytes make the difference.
        let filtered = try parts.map { try JPEGMetadataFilter.filter($0, level: .removeAll, orientation: 1) }
        try JPEGStructure.joined(filtered, gaps: [Data("leftover".utf8), Data()]).write(to: result)
        #expect(throws: VerificationError.self) { try MetadataCheck.verify(original: url, result: result, level: .removeAll) }
        try JPEGStructure.joined(filtered).write(to: result)
        try MetadataCheck.verify(original: url, result: result, level: .removeAll)
    }

    /// Cameras leave leftover bytes between and after the images. Everything
    /// kept: they stay byte for byte where they were; otherwise they go, like
    /// unknown metadata.
    @Test(arguments: [MetadataHandling.keep, .removePrivate])
    func leftoverBytesBetweenImages(level: MetadataHandling) async throws {
        let url = gainMapPhoto("leftovers-\(level.rawValue).jpg")
        let parts = images(try Data(contentsOf: url))
        let gaps = [Data((0..<340).map { UInt8($0 % 251) }), Data("camera buffer".utf8)]
        try JPEGStructure.joined(parts, gaps: gaps).write(to: url)
        let bytes = ByteView(try Data(contentsOf: url))
        let ranges = try #require(JPEGStructure.images(bytes))
        #expect(!JPEGStructure.holdsVideo(bytes, images: ranges))

        settings.metadata = level
        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        let data = try Data(contentsOf: url)
        let after = try #require(JPEGStructure.images(ByteView(data)))
        let kept = JPEGStructure.gaps(after, count: data.count).map { data.subdata(in: $0) }
        #expect(kept == (level == .keep ? gaps : [Data(), Data()]))
    }

    /// Stereo cameras name their files .mpo; they are JPEGs and are found in folders.
    @Test func mpoFilesAreFoundInFolders() {
        #expect(FolderScanner.isCandidate(dir.appending(path: "DSCF0001.MPO")))
    }

    // MARK: - Checking

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
        try JPEGStructure.joined(parts).write(to: result)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: url, result: result, format: .jpeg, pixelsMustMatch: true)
        }
    }

    /// Private data left in the second image is caught by the metadata check.
    @Test func locationInSecondImageIsCaught() throws {
        let url = gainMapPhoto("private.jpg")
        var parts = images(try Data(contentsOf: url))
        parts[1] = inserting(try exifWithLocation(), into: parts[1])
        try JPEGStructure.joined(parts).write(to: url)
        let result = dir.appending(path: "leaky.jpg")
        parts[0] = try JPEGMetadataFilter.filter(parts[0], level: .removePrivate, orientation: 1)
        try JPEGStructure.joined(parts).write(to: result)
        #expect(throws: VerificationError.self) { try MetadataCheck.verify(original: url, result: result, level: .removePrivate) }
    }

    /// The maker note's identifier alone is enough to filter a photo.
    @Test func heicWithOnlyAnIdentifierToRemove() async throws {
        let url = gainMapPhoto("no-location.heic", type: .heic, location: false)
        #expect(props(try Data(contentsOf: url))[kCGImagePropertyGPSDictionary] == nil)
        let headroomBefore = headroom(url)
        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        #expect(Set((props(try Data(contentsOf: url))[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]).keys) == ["33", "48"])
        #expect(headroom(url) == headroomBefore)
    }

    /// A 10-bit HEIC (ImageIO decodes it packed, as iPhone screenshots) is
    /// filtered losslessly; another image in its place is caught.
    @Test func tenBitHEIC() async throws {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 16, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        for x in 0..<64 {
            context.setFillColor(red: CGFloat(x) / 64, green: 0.5, blue: 0.3, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 48))
        }
        func write(_ name: String, _ image: CGImage) -> URL {
            let url = dir.appending(path: name)
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9,
                                                     kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Doe"],
                                                     kCGImagePropertyGPSDictionary: gps] as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
            return url
        }
        let url = write("ten.heic", context.makeImage()!)
        #expect(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)?.bitsPerComponent == 10)
        context.fill(CGRect(x: 10, y: 10, width: 8, height: 8))
        let other = write("ten-other.heic", context.makeImage()!)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: url, result: other, format: .heic, pixelsMustMatch: true)
        }
        guard case .optimized(_, _, _, _, _, let identical) = try await optimize(url) else { Issue.record("not optimized"); return }
        #expect(identical)
        let p = props(try Data(contentsOf: url))
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        #expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] as? String == "Jane Doe")
    }

    /// A HEIC with XMP of its own (rights, the program that wrote it): the
    /// rights stay, what the level removes goes.
    @Test func heicWithItsOwnXMP() async throws {
        let url = dir.appending(path: "own-xmp.heic")
        let metadata = CGImageMetadataCreateMutable()
        for (path, value) in [("dc:rights", "© Jane Doe"), ("xmp:CreatorTool", "Some Editor 1.0"), ("photoshop:City", "Berlin")] {
            #expect(CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(dest, image(), metadata, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        #expect(try HEIFItems.File(ByteView(Data(contentsOf: url))).metadataXMP.count == 1)
        #expect(MetadataCheck.fields(try Data(contentsOf: url)).keys.contains { $0.name == "City" })

        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        let fields = MetadataCheck.fields(try Data(contentsOf: url))
        #expect(fields.keys.contains { $0.name == "rights" })
        #expect(!fields.keys.contains { $0.name == "City" })
    }

    /// Whether an image was made or changed by AI stays, even when all
    /// other metadata goes.
    @Test(arguments: [UTType.jpeg, .png, .heic])
    func aiDisclosureStaysAtEveryLevel(type: UTType) async throws {
        let url = dir.appending(path: "ai.\(type.preferredFilenameExtension ?? "img")")
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, MetadataPolicy.NS.iptcExt as CFString, "Iptc4xmpExt" as CFString, nil)
        let source = "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"
        for (path, value) in [("Iptc4xmpExt:DigitalSourceType", source), ("dc:rights", "© Jane Doe"), ("photoshop:City", "Berlin")] {
            #expect(CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(dest, image(), metadata, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        settings.metadata = .removeAll
        let outcome = try await optimize(url)
        guard case .optimized = outcome else { Issue.record("not optimized: \(outcome)"); return }
        let fields = MetadataCheck.fields(try Data(contentsOf: url))
        #expect(fields[MetadataCheck.Key(ns: MetadataPolicy.NS.iptcExt, name: "DigitalSourceType")]?.text == source)
        #expect(!fields.keys.contains { $0.name == "rights" || $0.name == "City" })
    }

    /// A HEIC re-encoded without Apple's maker note is shown dimmer.
    @Test func dimmerHEICIsRejected() async throws {
        let url = gainMapPhoto("bright.heic", type: .heic)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let result = dir.appending(path: "dim.heic")
        let dest = CGImageDestinationCreateWithURL(result as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(source, 0, nil)!, nil)
        CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeHDRGainMap,
                                               CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)!)
        #expect(CGImageDestinationFinalize(dest))
        #expect(try #require(headroom(result)) < headroom(url)!)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: url, result: result, format: .heic, pixelsMustMatch: false)
        }
    }

    /// Every item's data, by id (items stored in the file).
    private func itemData(_ data: Data) throws -> [Int: Data] {
        let file = try HEIFItems.File(ByteView(data))
        var out: [Int: Data] = [:]
        for item in file.locations.items where item.method == 0 {
            out[item.id] = try item.extents.reduce(Data()) { try $0 + ByteView(data).view($1.start, $1.length).bytes }
        }
        return out
    }

    /// Whether `b` holds the same items as `a`, with the same data in all
    /// but the EXIF and XMP items the filter rewrites.
    private func changedOnlyInMetadataItems(_ a: Data, _ b: Data) throws -> Bool {
        let file = try HEIFItems.File(ByteView(a))
        let metadata = Set(file.items("Exif") + file.metadataXMP)
        let before = try itemData(a), after = try itemData(b)
        return before.keys == after.keys && before.allSatisfy { metadata.contains($0.key) || after[$0.key] == $0.value }
    }

    /// Apple's maker note copied whole by ImageIO (with its identifier) is
    /// caught by the metadata check; with the original's EXIF and XMP
    /// filtered in, it passes, and nothing else changed.
    @Test func wholeAppleMakerNoteIsCaught() throws {
        let url = gainMapPhoto("maker.heic", type: .heic)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let result = dir.appending(path: "maker-whole.heic")
        let dest = CGImageDestinationCreateWithURL(result as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        let options = [kCGImageDestinationMetadata: ImageIOMetadata.filtered(CGImageSourceCopyMetadataAtIndex(source, 0, nil), .removePrivate),
                       kCGImageDestinationMergeMetadata: false] as CFDictionary
        #expect(CGImageDestinationCopyImageSource(dest, source, options, nil))
        #expect(Set((props(try Data(contentsOf: result))[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]).keys) == ["33", "43", "48"])
        #expect(throws: VerificationError.self) { try MetadataCheck.verify(original: url, result: result, level: .removePrivate) }

        let whole = try Data(contentsOf: result)
        let filtered = try HEIFMetadataFilter.filter(whole, level: .removePrivate, from: try Data(contentsOf: url))
        #expect(try changedOnlyInMetadataItems(whole, filtered))
        #expect(Set((props(filtered)[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]).keys) == ["33", "48"])
        try filtered.write(to: result)
        try MetadataCheck.verify(original: url, result: result, level: .removePrivate)
        #expect(headroom(result) == headroom(url))
    }

    /// Damaged HEIC: filtering never crashes and never changes anything but
    /// the EXIF and XMP items.
    @Test func damagedHEICNeverCrashesTheMetadataFilter() throws {
        let original = [UInt8](try Data(contentsOf: gainMapPhoto("damaged.heic", type: .heic)))
        var state: UInt64 = 0x5EED
        func random(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % n
        }
        for round in 0..<3000 {
            var m = original
            let at = random(min(m.count, 4096))
            switch round % 4 {
            case 0: m[at] ^= UInt8(1 << random(8))
            case 1: m[at] = [0x00, 0xFF, 0x7F, 0x80][random(4)]
            case 2: m.removeSubrange(at..<min(m.count, at + 1 + random(64)))
            default: m.replaceSubrange(at..<min(m.count, at + 4), with: [0xFF, 0xFF, 0xFF, 0xF0])
            }
            // Items whose data lies outside the damaged file can't be compared.
            if let filtered = try? HEIFMetadataFilter.filter(Data(m), level: .removePrivate), (try? itemData(Data(m))) != nil {
                #expect(try changedOnlyInMetadataItems(Data(m), filtered))
            }
        }
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
