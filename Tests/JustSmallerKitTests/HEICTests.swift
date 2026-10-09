import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

/// HEIC: EXIF and XMP filtered in their items (`HEIFMetadataFilter`), the
/// HDR headroom in Apple's maker note kept, auxiliary images and headroom
/// checked, lossless and after a lossy re-encode.
@Suite(.serialized)
final class HEICTests {
    let dir: URL
    var settings = OptimizationSettings()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "JustSmallerHEICTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings.moveOriginalsToTrash = false
        ToolRunner.directory = toolsDirectory
        Trash.testFolder = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-Trash")
    }
    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func image() -> CGImage { TestImages.pattern() }
    private var gps: [CFString: Any] { TestImages.gps }
    private func photo(_ name: String, location: Bool = true) -> URL {
        TestImages.gainMapPhoto(at: dir.appending(path: name), type: .heic, location: location)
    }
    private func props(_ data: Data) -> [CFString: Any] { TestImages.properties(data) }
    private func headroom(_ url: URL) -> Float? { TestImages.headroom(url) }

    private func optimize(_ url: URL) async throws -> Outcome {
        try await FileOptimizer(settings: settings).optimize(url) { _ in }
    }

    /// Every item's data, by id (stored in the file or in idat).
    private func itemData(_ data: Data) throws -> [Int: Data] {
        let file = try HEIFItems.File(ByteView(data))
        var out: [Int: Data] = [:]
        for item in file.locations.items where item.method < 2 {
            out[item.id] = try item.extents.reduce(Data()) { joined, extent in
                let range = try #require(try file.range(of: extent, method: item.method))
                return try joined + ByteView(data).view(range.lowerBound, range.count).bytes
            }
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

    // MARK: - Optimizing and checking

    /// HEIC, with the metadata filtered around the image as it is (lossless)
    /// and re-encoded (lossy): Apple's maker note keeps the HDR headroom.
    @Test(arguments: [(MetadataHandling.keep, false), (.removePrivate, false), (.copyrightOnly, false), (.removeAll, false),
                      (.keep, true), (.removePrivate, true), (.copyrightOnly, true), (.removeAll, true)])
    func heicKeepsTheHDRHeadroom(level: MetadataHandling, lossy: Bool) async throws {
        let url = photo("gain-map-\(level.rawValue)-\(lossy).heic")
        let headroomBefore = try #require(headroom(url))
        #expect(headroomBefore > 1)
        let live = (props(try Data(contentsOf: url))[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?["17"] as? String
        #expect(live?.hasPrefix("89175B33-LIVE") == true)

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
        #expect(Set((maker ?? [:]).keys) == (level == .keep ? ["17", "33", "43", "48"] : ["17", "33", "48"]))
        // The Live Photo stays one: photo and video share this id.
        #expect(maker?["17"] as? String == live)
        #expect(headroom(url) == headroomBefore)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        #expect(AuxiliaryImages.all(source) == [kCGImageAuxiliaryDataTypeHDRGainMap])
    }

    /// A HEIC another program wrote with tiles of its own size (Photoshop:
    /// 384) keeps them when re-encoded at every level that filters: ImageIO
    /// shows the grid's tile size as metadata, and one of its own choosing
    /// would read as changed metadata.
    @Test(arguments: [MetadataHandling.removePrivate, .copyrightOnly, .removeAll])
    func lossyReencodeKeepsTheTileSize(level: MetadataHandling) async throws {
        let url = dir.appending(path: "tiles-\(level.rawValue).heic")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, TestImages.pattern(width: 1024, height: 1024), [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFTileWidth: 384, kCGImagePropertyTIFFTileLength: 384,
                                             kCGImagePropertyTIFFArtist: "Jane Doe"],
            kCGImagePropertyGPSDictionary: gps,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        func tiles(_ url: URL) throws -> [Int?] {
            let tiff = props(try Data(contentsOf: url))[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            return [tiff?[kCGImagePropertyTIFFTileWidth] as? Int, tiff?[kCGImagePropertyTIFFTileLength] as? Int]
        }
        #expect(try tiles(url) == [384, 384])
        settings.metadata = level
        settings.lossy = true
        settings.quality = 50
        settings.outputLossy = .replace
        guard case .optimized(_, _, let tools, _, _, let identical) = try await optimize(url) else { Issue.record("not optimized"); return }
        #expect(tools.contains("ImageIO") && !identical)
        #expect(try tiles(url) == [384, 384])
        #expect(props(try Data(contentsOf: url))[kCGImagePropertyGPSDictionary] == nil)
    }

    /// The maker note's identifier alone is enough to filter a photo.
    @Test func heicWithOnlyAnIdentifierToRemove() async throws {
        let url = photo("no-location.heic", location: false)
        #expect(props(try Data(contentsOf: url))[kCGImagePropertyGPSDictionary] == nil)
        let headroomBefore = headroom(url)
        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        #expect(Set((props(try Data(contentsOf: url))[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]).keys) == ["17", "33", "48"])
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

    /// Lossless filtering is proven on the file itself, without decoding:
    /// the same image data and properties. One byte of either is caught.
    @Test func sameImageIsProvenOnTheBytes() async throws {
        let data = try Data(contentsOf: photo("same.heic"))
        let filtered = try HEIFMetadataFilter.filter(data, level: .removePrivate)
        #expect(filtered != data)
        #expect(try HEIFItems.sameImage(ByteView(data), ByteView(filtered)))

        let file = try HEIFItems.File(ByteView(filtered))
        let image = try file.range(of: file.primary)
        var changed = filtered
        changed[image.lowerBound + image.count / 2] ^= 1
        #expect(try !HEIFItems.sameImage(ByteView(data), ByteView(changed)))

        // The verifier proves the filtered file on its bytes, and a changed
        // image still doesn't pass.
        let original = dir.appending(path: "same-original.heic"), result = dir.appending(path: "same-result.heic")
        try data.write(to: original)
        try filtered.write(to: result)
        try await Verifier.verify(original: original, result: result, format: .heic, pixelsMustMatch: true)
        try changed.write(to: result)
        await #expect(throws: (any Error).self) {
            try await Verifier.verify(original: original, result: result, format: .heic, pixelsMustMatch: true)
        }

        // The image's width (ispe: version and flags, width, height).
        let ispe = try #require(filtered.range(of: Data("ispe".utf8)))
        var resized = filtered
        resized[ispe.upperBound + 7] ^= 1
        #expect(try !HEIFItems.sameImage(ByteView(data), ByteView(resized)))
    }

    /// XMP that describes no image in particular (here: its link to the
    /// image renamed) isn't the image's for ImageIO, but is checked too.
    @Test func xmpBesideTheImageIsChecked() throws {
        let url = dir.appending(path: "loose-xmp.heic")
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "photoshop:City" as CFString, "Berlin" as CFString))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(dest, image(), metadata, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        var data = try Data(contentsOf: url)
        let cdsc = try #require(data.range(of: Data("cdsc".utf8)))
        data.replaceSubrange(cdsc, with: Data("xxxx".utf8))
        let loose = dir.appending(path: "loose-result.heic")
        try data.write(to: loose)
        #expect(!MetadataCheck.fields(data).keys.contains { $0.name == "City" })
        #expect(throws: VerificationError.self) { try MetadataCheck.verify(original: url, result: loose, level: .removePrivate) }
    }

    /// A HEIC re-encoded without Apple's maker note is shown dimmer.
    @Test func dimmerHEICIsRejected() async throws {
        let url = photo("bright.heic")
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

    /// After a lossy re-encode the auxiliary images may differ a little,
    /// but not be other ones: a gain map swapped for another is caught.
    @Test func swappedGainMapIsRejected() async throws {
        let url = photo("gain.heic")
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        func reencode(_ name: String, _ change: (inout Data) -> Void) -> URL {
            let result = dir.appending(path: name)
            let dest = CGImageDestinationCreateWithURL(result as CFURL, UTType.heic.identifier as CFString, 1, nil)!
            CGImageDestinationAddImageFromSource(dest, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
            var info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as! [CFString: Any]
            var data = info[kCGImageAuxiliaryDataInfoData] as! Data
            change(&data)
            info[kCGImageAuxiliaryDataInfoData] = data
            CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeHDRGainMap, info as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
            return result
        }
        let same = reencode("same.heic") { _ in }
        try await Verifier.verify(original: url, result: same, format: .heic, pixelsMustMatch: false)
        let swapped = reencode("swapped.heic") { data in data = Data(data.reversed()) }
        // As bright as before: only the gain map itself can be what is caught.
        #expect(headroom(swapped) == headroom(url))
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: url, result: swapped, format: .heic, pixelsMustMatch: false)
        }
    }

    /// After a re-encode without metadata, the original's EXIF and XMP go
    /// into new items: ImageIO reads them as the image's, and every other
    /// item keeps its data.
    @Test func metadataItemsAreAdded() throws {
        let url = photo("source.heic")
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "dc:rights" as CFString, "© Jane Doe" as CFString))
        let withXMP = dir.appending(path: "source-xmp.heic")
        let copy = CGImageDestinationCreateWithURL(withXMP as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationCopyImageSource(copy, CGImageSourceCreateWithURL(url as CFURL, nil)!,
                                          [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary, nil)
        let original = try Data(contentsOf: withXMP)
        #expect(try HEIFItems.File(ByteView(original)).metadataXMP.count == 1)

        let bare = dir.appending(path: "bare.heic")
        let dest = CGImageDestinationCreateWithURL(bare as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(), nil)
        #expect(CGImageDestinationFinalize(dest))
        let target = try Data(contentsOf: bare)
        let before = try HEIFItems.File(ByteView(target))
        try #require(before.items("Exif").isEmpty && before.metadataXMP.isEmpty)

        let result = try HEIFMetadataFilter.filter(target, level: .removePrivate, from: original)
        try HEIFCheck.check(ByteView(result), against: HEIFCheck.Reference(ByteView(target)))
        let after = try HEIFItems.File(ByteView(result))
        #expect(after.items("Exif").count == 1 && after.metadataXMP.count == 1)
        let old = try itemData(target), new = try itemData(result)
        #expect(old.allSatisfy { new[$0.key] == $0.value })

        let p = props(result)
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        #expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] as? String == "Jane Doe")
        #expect(Set((p[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]).keys) == ["17", "33", "48"])
        #expect(MetadataCheck.fields(result).keys.contains { $0.name == "rights" })
    }

    /// Apple's maker note copied whole by ImageIO (with its identifier) is
    /// caught by the metadata check; with the original's EXIF and XMP
    /// filtered in, it passes, and nothing else changed.
    @Test func wholeAppleMakerNoteIsCaught() throws {
        let url = photo("maker.heic")
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let result = dir.appending(path: "maker-whole.heic")
        let dest = CGImageDestinationCreateWithURL(result as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        // A copy of the original's metadata carries the maker note along whole.
        let options = [kCGImageDestinationMetadata: CGImageMetadataCreateMutableCopy(CGImageSourceCopyMetadataAtIndex(source, 0, nil)!)!,
                       kCGImageDestinationMergeMetadata: false] as CFDictionary
        #expect(CGImageDestinationCopyImageSource(dest, source, options, nil))
        #expect(Set((props(try Data(contentsOf: result))[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]).keys) == ["17", "33", "43", "48"])
        #expect(throws: VerificationError.self) { try MetadataCheck.verify(original: url, result: result, level: .removePrivate) }

        let whole = try Data(contentsOf: result)
        let filtered = try HEIFMetadataFilter.filter(whole, level: .removePrivate, from: try Data(contentsOf: url))
        #expect(try changedOnlyInMetadataItems(whole, filtered))
        #expect(Set((props(filtered)[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]).keys) == ["17", "33", "48"])
        try filtered.write(to: result)
        try MetadataCheck.verify(original: url, result: result, level: .removePrivate)
        #expect(headroom(result) == headroom(url))
    }

    /// Damaged HEIC: filtering never crashes and never changes anything but
    /// the EXIF and XMP items.
    @Test func damagedHEICNeverCrashesTheMetadataFilter() throws {
        let original = [UInt8](try Data(contentsOf: photo("damaged.heic")))
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

    // MARK: - Other layouts

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be(8 + payload.count, 4) + Array(type.utf8) + payload }
    private func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * (n - 1 - $0))) } }

    /// A HEIF written by hand as other programs may: the EXIF (artist and a
    /// location) in idat, an image in mdat, and a last item that runs to
    /// the end of the file (length 0).
    /// `overlapping`: the last item starts inside the image's data. `group`:
    /// an entity group (grpl) with this id, holding items 1 and 3. `toTheEnd`
    /// false: the last item has its length. `wideMdat`: the mdat box with a
    /// 64-bit size; `metaLast`: the meta box after it. `bareMeta`: no iref,
    /// and meta ends with iinf directly before iloc (`true`) or with iinf
    /// (`false`).
    private func handMadeHEIF(overlapping: Bool = false, group: Int? = nil, toTheEnd: Bool = true, wideMdat: Bool = false,
                              metaLast: Bool = false, bareMeta: Bool? = nil) -> (data: Data, image: [UInt8], last: [UInt8]) {
        var tiff: [UInt8] = Array("MM".utf8) + [0, 42] + be(8, 4) + be(2, 2)
        tiff += be(0x013B, 2) + be(2, 2) + be(5, 4) + be(38, 4) // Artist → 38
        tiff += be(0x8825, 2) + be(4, 2) + be(1, 4) + be(44, 4) // GPS IFD → 44
        tiff += be(0, 4) + Array("Jane\0".utf8) + [0] // next IFD, "Jane", padding
        tiff += be(1, 2) + be(1, 2) + be(2, 2) + be(2, 4) + Array("N\0".utf8) + [0, 0] + be(0, 4) // LatitudeRef "N"
        let exif = be(6, 4) + Array("Exif\0\0".utf8) + tiff
        let image = [UInt8]((0..<300).map { UInt8($0 % 256) }), last = [UInt8](repeating: 0x5A, count: 40)
        func infe(_ id: Int, _ type: String) -> [UInt8] { box("infe", [2, 0, 0, 0] + be(id, 2) + be(0, 2) + Array(type.utf8) + [0]) }
        func iloc(mdat: Int) -> [UInt8] {
            // Version 1: offsets and lengths of 4 bytes, no base offset.
            var p: [UInt8] = [1, 0, 0, 0, 0x44, 0x00] + be(3, 2)
            p += be(1, 2) + be(0, 2) + be(0, 2) + be(1, 2) + be(mdat, 4) + be(image.count, 4)
            p += be(2, 2) + be(1, 2) + be(0, 2) + be(1, 2) + be(0, 4) + be(exif.count, 4)
            p += be(3, 2) + be(0, 2) + be(0, 2) + be(1, 2) + be(mdat + (overlapping ? 100 : image.count), 4) + be(toTheEnd ? 0 : last.count, 4)
            return box("iloc", p)
        }
        let ftyp = box("ftyp", Array("heic".utf8) + be(0, 4) + Array("mif1heic".utf8))
        func meta(mdat: Int) -> [UInt8] {
            let hdlr = box("hdlr", [0, 0, 0, 0] + be(0, 4) + Array("pict".utf8) + [UInt8](repeating: 0, count: 13))
            let pitm = box("pitm", [0, 0, 0, 0] + be(1, 2))
            let iinf = box("iinf", [0, 0, 0, 0] + be(3, 2) + infe(1, "hvc1") + infe(2, "Exif") + infe(3, "hvc1"))
            if let ilocLast = bareMeta {
                let children = hdlr + pitm + box("idat", exif)
                return box("meta", [0, 0, 0, 0] + children + (ilocLast ? iinf + iloc(mdat: mdat) : iloc(mdat: mdat) + iinf))
            }
            return box("meta", [0, 0, 0, 0]
                + box("hdlr", [0, 0, 0, 0] + be(0, 4) + Array("pict".utf8) + [UInt8](repeating: 0, count: 13))
                + box("pitm", [0, 0, 0, 0] + be(1, 2))
                + iloc(mdat: mdat)
                + box("iinf", [0, 0, 0, 0] + be(3, 2) + infe(1, "hvc1") + infe(2, "Exif") + infe(3, "hvc1"))
                + box("iref", [0, 0, 0, 0] + box("cdsc", be(2, 2) + be(1, 2) + be(1, 2)))
                + (group.map { box("grpl", box("altr", [0, 0, 0, 0] + be($0, 4) + be(2, 4) + be(1, 4) + be(3, 4))) } ?? [])
                + box("idat", exif))
        }
        let mdat = wideMdat ? be(1, 4) + Array("mdat".utf8) + be(16 + image.count + last.count, 8) + image + last : box("mdat", image + last)
        let header = wideMdat ? 16 : 8
        if metaLast { return (Data(ftyp + mdat + meta(mdat: ftyp.count + header)), image, last) }
        let mdatStart = ftyp.count + meta(mdat: 0).count + header
        return (Data(ftyp + meta(mdat: mdatStart) + mdat), image, last)
    }

    /// EXIF in idat is filtered too: idat and meta change size, the image
    /// data after them moves, and every other item keeps its data — also
    /// one that runs to the end of the file.
    @Test func exifInIdat() throws {
        let (data, image, last) = handMadeHEIF()
        try HEIFCheck.check(ByteView(data), against: HEIFCheck.Reference(ByteView(data)))
        let filtered = try HEIFMetadataFilter.filter(data, level: .removePrivate)
        try HEIFCheck.check(ByteView(filtered), against: HEIFCheck.Reference(ByteView(data)))
        #expect(filtered.count < data.count)

        let file = try HEIFItems.File(ByteView(filtered))
        #expect([UInt8](filtered[try file.range(of: 1)]) == image)
        let item3 = try #require(file.locations.items.first { $0.id == 3 })
        #expect([UInt8](filtered[try #require(try file.range(of: item3.extents[0], method: 0))]) == last)
        let exif = [UInt8](filtered[try file.range(of: 2)])
        let reader = try TIFFReader(ByteView(Array(exif.dropFirst(10))))
        #expect(try reader.ifd(at: reader.firstIFD).entries.map(\.tag) == [0x013B])
    }

    /// Data that another item shares, or that lies inside an item running to
    /// the end of the file, is never replaced.
    @Test func sharedDataIsNotReplaced() throws {
        let (data, _, _) = handMadeHEIF(overlapping: true)
        #expect(throws: FormatError.self) { try HEIFItems.rewrite(data, replacing: [1: [1, 2, 3]]) }
        // The EXIF in idat lies apart from both and may change.
        let changed = try HEIFItems.rewrite(data, replacing: [2: [1, 2, 3]])
        try HEIFCheck.check(ByteView(changed), against: HEIFCheck.Reference(ByteView(data)))
    }

    /// New items take ids no item and no entity group has; a result where
    /// they collide doesn't pass the structure check.
    @Test func newItemsAvoidGroupIDs() throws {
        let (data, _, _) = handMadeHEIF(group: 4, toTheEnd: false)
        try HEIFCheck.check(ByteView(data), against: HEIFCheck.Reference(ByteView(data)))
        let added = try HEIFItems.rewrite(data, adding: [HEIFItems.NewItem(type: "mime", contentType: "application/rdf+xml", data: Array("<x/>".utf8))])
        try HEIFCheck.check(ByteView(added), against: HEIFCheck.Reference(ByteView(data)))
        let file = try HEIFItems.File(ByteView(added))
        #expect(file.infos.map(\.id) == [1, 2, 3, 5])
        #expect([UInt8](added[try file.range(of: 5)]) == Array("<x/>".utf8))

        let (clash, _, _) = handMadeHEIF(group: 3)
        #expect(throws: FormatError.self) { try HEIFCheck.check(ByteView(clash), against: HEIFCheck.Reference(ByteView(clash))) }
    }

    /// New items' data goes at the end of a last mdat box, also one with a
    /// 64-bit size, or into an mdat box of its own when meta comes last —
    /// in the same pass as the EXIF in idat is replaced.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func newItemsInEveryLayout(wideMdat: Bool, metaLast: Bool) throws {
        let (data, image, last) = handMadeHEIF(toTheEnd: false, wideMdat: wideMdat, metaLast: metaLast)
        try HEIFCheck.check(ByteView(data), against: HEIFCheck.Reference(ByteView(data)))
        let xmp = Array("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)
        let exif: [UInt8] = [0, 0, 0, 0] + Array("MM".utf8) + [0, 42, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0]
        let added = try HEIFItems.rewrite(data, replacing: [2: exif],
                                          adding: [HEIFItems.NewItem(type: "mime", contentType: "application/rdf+xml", data: xmp)])
        try HEIFCheck.check(ByteView(added), against: HEIFCheck.Reference(ByteView(data)))
        let file = try HEIFItems.File(ByteView(added))
        #expect(file.top.filter { $0.type == "mdat" }.count == (metaLast ? 2 : 1))
        #expect([UInt8](added[try file.range(of: 1)]) == image)
        #expect([UInt8](added[try file.range(of: 3)]) == last)
        #expect([UInt8](added[try file.range(of: 4)]) == xmp)
        #expect([UInt8](added[try file.range(of: 2)]) == exif)
        #expect(file.metadataXMP == [4])
    }

    /// Without an iref box, a new one goes right after iinf — before an
    /// iloc that follows it, or at the very end of meta, which then grows
    /// by it too.
    @Test(arguments: [true, false])
    func newIrefAfterIinf(ilocLast: Bool) throws {
        let (data, image, last) = handMadeHEIF(toTheEnd: false, bareMeta: ilocLast)
        try HEIFCheck.check(ByteView(data), against: HEIFCheck.Reference(ByteView(data)))
        #expect(try HEIFItems.File(ByteView(data)).references.isEmpty)
        let xmp = Array("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)
        let added = try HEIFItems.rewrite(data, adding: [HEIFItems.NewItem(type: "mime", contentType: "application/rdf+xml", data: xmp)])
        try HEIFCheck.check(ByteView(added), against: HEIFCheck.Reference(ByteView(data)))
        let file = try HEIFItems.File(ByteView(added))
        #expect(file.meta.map(\.type).suffix(ilocLast ? 3 : 2) == (ilocLast ? ["iinf", "iref", "iloc"] : ["iinf", "iref"]))
        #expect(file.references.map { "\($0.type) \($0.from) \($0.to)" } == ["cdsc 4 [1]"])
        #expect([UInt8](added[try file.range(of: 1)]) == image)
        #expect([UInt8](added[try file.range(of: 3)]) == last)
        #expect([UInt8](added[try file.range(of: 4)]) == xmp)
    }
}
