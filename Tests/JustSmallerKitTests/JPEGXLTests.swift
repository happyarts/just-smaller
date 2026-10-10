import Compression
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

/// Converting JPEG to JPEG XL and back, with the real tools from build/tools.
@Suite(.serialized)
final class JPEGXLTests {
    let dir: URL
    var settings = OptimizationSettings()
    var volumes: [DiskImage] = []

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings.moveOriginalsToTrash = false
        ToolRunner.directory = toolsDirectory
        // Never the user's Trash.
        Trash.testFolder = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-Trash")
    }
    deinit {
        for volume in volumes { volume.eject() }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func jpeg(_ name: String, properties: [CFString: Any] = [:], width: Int = 96, height: Int = 64) -> URL {
        let url = dir.appending(path: name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var all = properties
        all[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(dest, TestImages.pattern(width: width, height: height), all as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private func convert(_ url: URL, to target: ConversionTarget, settings: OptimizationSettings? = nil) async throws -> Outcome {
        let s = settings ?? self.settings
        let (destination, replaces) = OutputPlanner.conversion(for: url, root: nil, settings: s, to: target)
        return try await FileConverter(settings: s).convert(url, to: target, destination: destination, replacesOriginal: replaces) { _ in }
    }

    private func result(_ outcome: Outcome) -> URL? {
        if case .optimized(_, _, _, let result, _, let fidelity) = outcome, fidelity == .pixelIdentical { return result }
        return nil
    }

    private func reason(_ outcome: Outcome) -> String? {
        switch outcome {
        case .skipped(let reason, _), .unchanged(let reason, _, _): reason
        default: nil
        }
    }

    private func gps(_ url: URL) -> Any? {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyGPSDictionary]
    }

    // MARK: - JPEG → JPEG XL → JPEG

    @Test func convertsAndRebuildsByteForByte() async throws {
        settings.metadata = .keep
        let original = jpeg("photo.jpg", properties: [kCGImagePropertyGPSDictionary: TestImages.gps])
        let before = try Data(contentsOf: original)

        let jxl = try #require(result(try await convert(original, to: .jxl)))
        #expect(jxl.lastPathComponent == "photo.jxl")
        #expect(!FileManager.default.fileExists(atPath: original.path)) // replaced: the original went
        #expect(try Data(contentsOf: jxl).count < before.count)
        #expect(gps(jxl) != nil) // everything kept

        let back = try #require(result(try await convert(jxl, to: .jpeg)))
        #expect(back.lastPathComponent == "photo.jpg")
        // Keep everything filters nothing in a file ImageIO wrote: the very same bytes.
        #expect(try Data(contentsOf: back) == before)
    }

    @Test func appliesTheMetadataLevel() async throws {
        settings.outputLossless = .suffix
        let original = jpeg("located.jpg", properties: [kCGImagePropertyGPSDictionary: TestImages.gps,
                                                       kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Ada"]])
        let jxl = try #require(result(try await convert(original, to: .jxl)))
        #expect(jxl.lastPathComponent == "located\(settings.suffix).jxl")
        #expect(FileManager.default.fileExists(atPath: original.path)) // suffix: the original stays
        #expect(gps(jxl) == nil)
        let source = CGImageSourceCreateWithURL(jxl as CFURL, nil)!
        let tiff = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFArtist] as? String == "Ada")
    }

    @Test func movesTheOriginalToTheTrash() async throws {
        settings.moveOriginalsToTrash = true
        let original = jpeg("trashed.jpg")
        let outcome = try await convert(original, to: .jxl)
        guard case .optimized(_, _, _, let jxl, let trashed?, _) = outcome else { Issue.record("not converted"); return }
        #expect(trashed.path.hasPrefix(Trash.testFolder!.path))
        #expect(FileManager.default.fileExists(atPath: jxl.path))
    }

    @Test func keepsTheOrientation() async throws {
        let original = jpeg("turned.jpg", properties: [kCGImagePropertyOrientation: 6])
        let jxl = try #require(result(try await convert(original, to: .jxl)))
        let source = CGImageSourceCreateWithURL(jxl as CFURL, nil)!
        #expect((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int == 6)
    }

    @Test func maximumKeepsTheSmallerResult() async throws {
        settings.effort = .maximum
        let original = jpeg("max.jpg", width: 320, height: 240)
        let size = try Data(contentsOf: original).count
        let outcome = try await convert(original, to: .jxl)
        guard case .optimized(_, let newSize, _, _, _, .pixelIdentical) = outcome else { Issue.record("not converted"); return }
        #expect(newSize < size)
    }

    @Test func neverTakesAnotherFilesName() async throws {
        let original = jpeg("same.jpg")
        let other = dir.appending(path: "same.jxl")
        try Data("another picture".utf8).write(to: other)
        let jxl = try #require(result(try await convert(original, to: .jxl)))
        #expect(jxl.lastPathComponent == "same 2.jxl")
        #expect(try Data(contentsOf: other) == Data("another picture".utf8))
    }

    @Test func keepsTheSpellingOfTheName() async throws {
        // "ä" precomposed (NFC) on disk, as most names typed or downloaded
        // are spelled; a URL spells it decomposed (NFD).
        #expect(rename(jpeg("bear.jpg").path, dir.path + "/B\u{E4}r.jpg") == 0)
        let original = dir.appending(path: "B\u{E4}r.jpg")
        let spelled = { (name: String) in
            try FileManager.default.contentsOfDirectory(atPath: self.dir.path).contains { $0.utf8.elementsEqual(name.utf8) }
        }
        let jxl = try #require(result(try await convert(original, to: .jxl)))
        #expect(try spelled("B\u{E4}r.jxl"))
        _ = try #require(result(try await convert(jxl, to: .jpeg)))
        #expect(try spelled("B\u{E4}r.jpg"))
    }

    // MARK: - Other volumes

    /// A disk image, ejected when the test ends.
    private func volume(_ fileSystem: String) throws -> DiskImage {
        let volume = try DiskImage(fileSystem, in: dir)
        volumes.append(volume)
        return volume
    }

    /// A JPEG whose pixels, unpacked for the check, take 9 MB.
    private func large(on volume: DiskImage) throws -> URL {
        let url = volume.mount.appending(path: "large.jpg")
        try FileManager.default.moveItem(at: jpeg("large.jpg", width: 2000, height: 1500), to: url)
        return url
    }

    @Test func convertsOnAMemoryCardTooSmallForTheCheck() async throws {
        let card = try volume("MS-DOS")
        let original = try large(on: card)
        let jxl = try #require(result(try await convert(original, to: .jxl)))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: jxl.path))
    }

    @Test func aFullDiskIsSaidToBeFull() async throws {
        let disk = try volume("APFS")
        let original = try large(on: disk)
        let before = try Data(contentsOf: original)
        await #expect { try await self.convert(original, to: .jxl) } throws: { FileOptimizer.isOutOfSpace($0) }
        #expect(try Data(contentsOf: original) == before)
    }

    @Test func deletesAPrecomposedNameOnExFAT() async throws {
        let card = try volume("ExFAT")
        // Written by path, so "ä" stays precomposed (NFC); exFAT lists it decomposed.
        let name = card.mount.path + "/B\u{E4}r.jpg"
        #expect(copyfile(jpeg("bear.jpg").path, name, nil, copyfile_flags_t(COPYFILE_DATA)) == 0)
        // An extended attribute, which exFAT keeps in an AppleDouble file.
        #expect(setxattr(name, "com.apple.metadata:kMDItemFinderComment", "bear", 4, 0, 0) == 0)
        #expect(FileManager.default.fileExists(atPath: card.mount.path + "/._B\u{E4}r.jpg"))
        let original = try #require(FileManager.default.contentsOfDirectory(at: card.mount, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "jpg" })
        _ = try #require(result(try await convert(original, to: .jxl)))
        // Its AppleDouble file ("._Bär.jpg") goes with it.
        let left = try FileManager.default.contentsOfDirectory(atPath: card.mount.path)
        #expect(left.filter { $0.hasSuffix(".jpg") }.isEmpty)
        #expect(left.map { $0.precomposedStringWithCanonicalMapping }.contains("B\u{E4}r.jxl"))
    }

    @Test func keepsThePermissions() async throws {
        let original = jpeg("private.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        let jxl = try #require(result(try await convert(original, to: .jxl)))
        #expect(try FileManager.default.attributesOfItem(atPath: jxl.path)[.posixPermissions] as? Int == 0o600)
    }

    // MARK: - Optimizing a JPEG XL

    /// A JPEG XL made from a JPEG with everything kept: optimizing it at the
    /// default level takes the location out, stays JPEG XL, and still holds
    /// the very same image.
    @Test func optimizingAJPEGXLRemovesPrivateData() async throws {
        settings.metadata = .keep
        settings.outputLossless = .suffix
        let original = jpeg("located.jpg", properties: [kCGImagePropertyGPSDictionary: TestImages.gps,
                                                       kCGImagePropertyOrientation: 6])
        let jxl = try #require(result(try await convert(original, to: .jxl)))
        #expect(gps(jxl) != nil)

        var optimizing = OptimizationSettings()
        optimizing.moveOriginalsToTrash = false
        let outcome = try await FileOptimizer(settings: optimizing).optimize(jxl, to: .replace) { _ in }
        guard case .optimized(_, _, let tools, _, _, .pixelIdentical) = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(tools == ["jxl-transcode"])
        #expect(ImageFormat.detect(at: jxl) == .jxl)
        #expect(gps(jxl) == nil)
        let source = CGImageSourceCreateWithURL(jxl as CFURL, nil)!
        #expect((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int == 6)
        let rebuilt = dir.appending(path: "rebuilt.jpg")
        try await ToolRunner.run("jxl-transcode", ["decode", jxl.path, rebuilt.path], in: dir)
        try await ToolRunner.run("jpegcmp", [original.path, rebuilt.path], in: dir)
    }

    @Test func aJPEGXLWithNothingToGainIsAlreadyOptimal() async throws {
        settings.outputLossless = .suffix
        let jxl = try #require(result(try await convert(jpeg("plain.jpg"), to: .jxl)))
        var optimizing = OptimizationSettings()
        optimizing.moveOriginalsToTrash = false
        let outcome = try await FileOptimizer(settings: optimizing).optimize(jxl, to: .replace) { _ in }
        guard case .alreadyOptimal = outcome else {
            Issue.record("expected already optimal"); return
        }
    }

    // MARK: - What stays as it is

    @Test func onlyJPEGsBecomeJPEGXL() async throws {
        let png = dir.appending(path: "image.jpg") // a PNG under a JPEG's name
        let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, TestImages.pattern(), nil)
        #expect(CGImageDestinationFinalize(dest))
        #expect(reason(try await convert(png, to: .jxl)) != nil)
        #expect(FileManager.default.fileExists(atPath: png.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "image.jxl").path))
    }

    @Test func anHDRPhotoStaysJPEG() async throws {
        let photo = TestImages.gainMapPhoto(at: dir.appending(path: "hdr.jpg"))
        let reason = try #require(reason(try await convert(photo, to: .jxl)))
        #expect(reason.contains("more than one image"))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "hdr.jxl").path))
    }

    /// JPEG XL has no JFIF: a resolution only JFIF states is lost. It only
    /// sets the size apps print at by default, so the JPEG still converts.
    @Test func aJPEGWithItsResolutionOnlyInJFIFConverts() async throws {
        let url = jpeg("jfif-300dpi.jpg")
        var data = try Data(contentsOf: url)
        let jfif = try #require(data.range(of: Data("JFIF\0".utf8)))
        data.replaceSubrange(jfif.upperBound + 2..<jfif.upperBound + 7, with: [1, 0x01, 0x2C, 0x01, 0x2C]) // dpi, 300 × 300
        try data.write(to: url)
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [CFString: Any]
        try #require(properties?[kCGImagePropertyDPIWidth] as? Int == 300)
        #expect(result(try await convert(url, to: .jxl)) != nil)
    }

    /// Browsers show a JPEG at the size its EXIF resolution and pixel size
    /// give, but not a JPEG XL: it would be shown larger, so it stays JPEG.
    @Test func aJPEGBrowsersShowSmallerStaysJPEG() async throws {
        let url = try densityJPEG("density.jpg")
        #expect(reason(try await convert(url, to: .jxl))?.contains("at another size") == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "density.jxl").path))
    }

    /// A JPEG XL another program made from such a JPEG may be stored anew:
    /// it shows as it did before.
    @Test func aJPEGXLMadeElsewhereFromSuchAJPEGIsOptimized() async throws {
        let url = try densityJPEG("density-located.jpg", properties: [kCGImagePropertyGPSDictionary: TestImages.gps])
        let jxl = dir.appending(path: "density-located.jxl")
        try await ToolRunner.run("jxl-transcode", ["encode", url.path, jxl.path], in: dir)
        var optimizing = OptimizationSettings()
        optimizing.moveOriginalsToTrash = false
        let outcome = try await FileOptimizer(settings: optimizing).optimize(jxl, to: .replace) { _ in }
        guard case .optimized = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(gps(jxl) == nil)
    }

    /// A JPEG that browsers show at half its pixels: 144 dpi in EXIF and the
    /// pixel size that matches it at 72 dpi.
    private func densityJPEG(_ name: String, properties: [CFString: Any] = [:]) throws -> URL {
        var all = properties
        all[kCGImagePropertyDPIWidth] = 144
        all[kCGImagePropertyDPIHeight] = 144
        let url = jpeg(name, properties: all)
        // ImageIO writes the real pixel size; at 144 dpi browsers show half of it.
        var data = try Data(contentsOf: url)
        let app1 = try #require(try JPEGMarkers.headers(ByteView(data)).segments.first {
            $0.marker == 0xE1 && $0.payload.has(JPEGMarkers.exifHeader)
        })
        let base = app1.offset + 4 + JPEGMarkers.exifHeader.count
        let reader = try TIFFReader(ByteView(data[base...]))
        let exifIFD = try #require(try reader.ifd(at: reader.firstIFD).entries.first { $0.tag == TIFFReader.exifPointer }.flatMap(reader.pointer))
        for entry in try reader.ifd(at: exifIFD).entries where [0xA002, 0xA003].contains(entry.tag) {
            let size = try #require(TIFFReader.sizes[entry.type]), at = base + (try #require(entry.valueOffset))
            let value = entry.tag == 0xA002 ? 48 : 32
            let bytes = (0..<size).map { UInt8(value >> (8 * (reader.bigEndian ? size - 1 - $0 : $0)) & 0xFF) }
            data.replaceSubrange(at..<at + size, with: bytes)
        }
        try data.write(to: url)
        let written = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [CFString: Any]
        try #require((written?[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifPixelXDimension] as? Int == 48)
        return url
    }

    @Test func aTinyJPEGStaysWhenJPEGXLIsLarger() async throws {
        settings.metadata = .keep
        let tiny = jpeg("tiny.jpg", width: 1, height: 1)
        // Nothing but the image: a few hundred bytes JPEG XL can't beat.
        try JPEGMetadataFilter.filter(Data(contentsOf: tiny), level: .removeAll, orientation: 1, itemLengths: [:]).write(to: tiny)
        #expect(reason(try await convert(tiny, to: .jxl)) == "As JPEG XL it wouldn’t be smaller")
        #expect(FileManager.default.fileExists(atPath: tiny.path))
    }

    @Test func aJPEGXLNotMadeFromAJPEGHasNoWayBack() async throws {
        let bare = dir.appending(path: "pixels.jxl")
        try Data([0xFF, 0x0A, 0xFA, 0x7F, 0x01]).write(to: bare)
        #expect(reason(try await convert(bare, to: .jpeg)) == FileConverter.notFromJPEG)
    }

    @Test func aDamagedJPEGXLStaysAsItIs() async throws {
        settings.outputLossless = .suffix
        let jxl = try #require(result(try await convert(jpeg("cut.jpg", width: 256, height: 192), to: .jxl)))
        let data = try Data(contentsOf: jxl)
        try data.prefix(data.count - 200).write(to: jxl)
        #expect(reason(try await convert(jxl, to: .jpeg)) != nil)
    }

    // MARK: - The checks

    /// A JPEG XL whose image no longer matches the JPEG — a changed byte in
    /// the codestream — never passes, whether the rebuilt JPEG or the
    /// pixels give it away.
    @Test func aDamagedJPEGXLIsRejected() async throws {
        settings.metadata = .keep
        settings.outputLossless = .suffix
        let original = jpeg("checked.jpg", width: 256, height: 192)
        let jxl = try #require(result(try await convert(original, to: .jxl)))
        let data = try Data(contentsOf: jxl)
        let file = try JXLContainer.read(ByteView(data))
        let codestream = try #require(file.boxes.last { $0.type == "jxlc" || $0.type == "jxlp" })
        for offset in [codestream.offset + codestream.payload.count / 2, codestream.offset + codestream.payload.count - 8] {
            var damaged = data
            damaged[offset] ^= 0x55
            let url = dir.appending(path: "damaged-\(offset).jxl")
            try damaged.write(to: url)
            await #expect(throws: VerificationError.self) {
                try await Verifier.verifyConversion(jpeg: original, jxl: url, tolerance: .converted)
            }
        }
    }

    // MARK: - The container reader

    private func box(_ type: String, _ payload: Data) -> Data {
        Data(withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian, Array.init)) + Data(type.utf8) + payload
    }

    private func container(_ boxes: Data...) -> Data {
        Data(JXLContainer.signature) + box("ftyp", Data("jxl ".utf8) + Data(count: 4) + Data("jxl ".utf8)) + boxes.reduce(Data(), +)
    }

    private let codestream = Data([0xFF, 0x0A, 0x00, 0x00])

    @Test func readsMetadataBoxesAlsoCompressed() throws {
        let exif = Data("MM\u{0}*TIFF".utf8)
        let xmp = Data("<x:xmpmeta/>".utf8)
        let compressed = try #require(brotli(xmp))
        let file = try JXLContainer.read(ByteView(container(box("jbrd", Data([1])), box("Exif", Data(count: 4) + exif),
                                                           box("brob", Data("xml ".utf8) + compressed), box("jxlc", codestream))))
        #expect(file.hasReconstructionData)
        #expect(file.exif == [exif])
        #expect(file.xmp == [xmp])
    }

    @Test(arguments: [
        "two codestreams", "jxlp out of order", "no last jxlp", "jbrd in brob", "two jbrd", "Exif offset past its end",
        "level after the codestream", "truncated box", "Brotli bomb", "broken Brotli",
    ])
    func rejectsBrokenContainers(_ name: String) throws {
        func part(_ n: UInt32, _ last: Bool) -> Data {
            box("jxlp", Data(withUnsafeBytes(of: (n | (last ? 0x8000_0000 : 0)).bigEndian, Array.init)) + codestream)
        }
        let file: Data
        switch name {
        case "two codestreams": file = container(box("jxlc", codestream), box("jxlc", codestream))
        case "jxlp out of order": file = container(part(1, false), part(0, true))
        case "no last jxlp": file = container(part(0, false), part(1, false))
        case "jbrd in brob": file = container(box("brob", Data("jbrd".utf8) + brotli(Data([1]))!), box("jxlc", codestream))
        case "two jbrd": file = container(box("jbrd", Data([1])), box("jbrd", Data([1])), box("jxlc", codestream))
        case "Exif offset past its end": file = container(box("Exif", Data([0, 0, 0x10, 0])), box("jxlc", codestream))
        case "level after the codestream": file = container(box("jxlc", codestream), box("jxll", Data([5])))
        case "truncated box": file = container(box("jxlc", codestream)).dropLast(2)
        case "Brotli bomb": file = container(box("brob", Data("xml ".utf8) + brotli(Data(count: JXLContainer.metadataLimit + 1))!),
                                             box("jxlc", codestream))
        default: file = container(box("brob", Data("xml ".utf8) + Data([0x1B, 0xFF, 0xFF, 0x00])), box("jxlc", codestream))
        }
        #expect(throws: FormatError.self) { try JXLContainer.read(ByteView(file)) }
    }

    private func brotli(_ data: Data) -> Data? {
        var out = [UInt8](repeating: 0, count: data.count + 1024)
        let n = data.withUnsafeBytes {
            compression_encode_buffer(&out, out.count, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_BROTLI)
        }
        return n > 0 ? Data(out.prefix(n)) : nil
    }
}
