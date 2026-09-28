import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

/// The metadata levels: what each keeps and removes, in every place a field
/// can live (EXIF, IPTC-IIM, XMP), and that the filters never invent or change
/// a value.
@Suite(.serialized)
final class MetadataTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "JustSmallerMetadataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ToolRunner.directory = toolsDirectory
        Trash.testFolder = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-Trash")
    }
    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<48 {
            for x in 0..<64 {
                ctx.setFillColor(red: CGFloat(x) / 64, green: CGFloat(y) / 48, blue: (x / 8 + y / 8) % 2 == 0 ? 0.9 : 0.1, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    /// A photographer's JPEG: rights, description and camera data, plus
    /// location, serial number and editing software.
    private func photo(_ name: String, orientation: Int = 1) -> URL {
        let url = dir.appending(path: name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(), [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Doe", kCGImagePropertyTIFFCopyright: "© Jane Doe",
                                             kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5",
                                             kCGImagePropertyTIFFSoftware: "SecretEditor 1.0"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "SN12345",
                                             kCGImagePropertyExifFNumber: 2.8,
                                             kCGImagePropertyExifDateTimeOriginal: "2026:09:01 10:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.1, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline: ["Jane Doe"], kCGImagePropertyIPTCCopyrightNotice: "© Jane Doe",
                                             kCGImagePropertyIPTCCredit: "Doe Photo", kCGImagePropertyIPTCKeywords: ["harbour", "boat"],
                                             kCGImagePropertyIPTCCity: "Hamburg", kCGImagePropertyIPTCCaptionAbstract: "Boats at dawn"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private func props(_ url: URL) -> [CFString: Any] {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    private func filtered(_ url: URL, _ level: MetadataHandling, orientation: Int = 1) throws -> URL {
        let out = dir.appending(path: "\(level.rawValue)-\(url.lastPathComponent)")
        try JPEGMetadataFilter.filter(Data(contentsOf: url), level: level, orientation: orientation).write(to: out)
        try MetadataCheck.verify(original: url, result: out, level: level)
        return out
    }

    // MARK: - Levels

    @Test func removingPrivateDataKeepsWhatPhotographersNeed() throws {
        let url = photo("private.jpg")
        let p = props(try filtered(url, .removePrivate))
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        #expect(exif?[kCGImagePropertyExifBodySerialNumber] == nil)
        #expect(tiff?[kCGImagePropertyTIFFSoftware] == nil)
        #expect(iptc?[kCGImagePropertyIPTCCity] == nil)

        #expect(tiff?[kCGImagePropertyTIFFArtist] as? String == "Jane Doe")
        #expect(tiff?[kCGImagePropertyTIFFCopyright] as? String == "© Jane Doe")
        #expect(tiff?[kCGImagePropertyTIFFModel] as? String == "EOS R5")
        #expect(exif?[kCGImagePropertyExifFNumber] as? Double == 2.8)
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:09:01 10:00:00")
        #expect(iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String == "© Jane Doe")
        #expect(iptc?[kCGImagePropertyIPTCCredit] as? String == "Doe Photo")
        #expect(iptc?[kCGImagePropertyIPTCKeywords] as? [String] == ["harbour", "boat"])
        #expect(iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String == "Boats at dawn")
    }

    @Test func copyrightOnlyKeepsCreatorAndRights() throws {
        let p = props(try filtered(photo("rights.jpg"), .copyrightOnly))
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFArtist] as? String == "Jane Doe")
        #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
        #expect(iptc?[kCGImagePropertyIPTCByline] as? [String] == ["Jane Doe"])
        #expect(iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String == "© Jane Doe")
        #expect(iptc?[kCGImagePropertyIPTCKeywords] == nil)
        #expect(iptc?[kCGImagePropertyIPTCCaptionAbstract] == nil)
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test(arguments: [1, 6])
    func removingEverythingKeepsOnlyTheOrientation(orientation: Int) throws {
        let url = try filtered(photo("none-\(orientation).jpg", orientation: orientation), .removeAll, orientation: orientation)
        let p = props(url)
        #expect(p[kCGImagePropertyIPTCDictionary] == nil)
        #expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] == nil)
        #expect(p[kCGImagePropertyOrientation] as? Int ?? 1 == orientation)
        #expect(!(try Data(contentsOf: url)).contains(Data("Jane".utf8)))
    }

    @Test func keepLeavesEveryField() throws {
        let url = photo("keep.jpg")
        let kept = try filtered(url, .keep)
        #expect(MetadataCheck.fields(kept) == MetadataCheck.fields(url))
        #expect(props(kept)[kCGImagePropertyGPSDictionary] != nil)
    }

    /// Cameras set to Adobe RGB say so only in EXIF: colour space
    /// "uncalibrated" and the interoperability index "R03".
    @Test func colourSpaceInEXIFSurvivesEveryLevel() throws {
        let tiff = exifBlock(main: [(0x010F, 2, Array("Canon\0".utf8))],
                             exif: [(0xA001, 3, [0xFF, 0xFF]), (0x927C, 7, Array(repeating: 7, count: 40))],
                             interop: [(0x0001, 2, Array("R03\0".utf8))])
        let out = try #require(EXIFFilter.filter(tiff, level: .removeAll))
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("R03"))
        #expect(!text.contains("Canon"))
        #expect(out.count < tiff.count) // the MakerNote went
        // An sRGB camera file with nothing else to keep loses its EXIF.
        let plain = exifBlock(main: [(0x010F, 2, Array("Canon\0".utf8))], exif: [(0xA001, 3, [0x00, 0x01])], interop: [])
        #expect(EXIFFilter.filter(plain, level: .removeAll) == nil)
    }

    // MARK: - XMP

    @Test func xmpIsFilteredByNamespaceAndWrittenCompactly() throws {
        let packet = Array("""
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xap="http://ns.adobe.com/xap/1.0/"
                xmlns:dc="http://purl.org/dc/elements/1.1/"
                xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
                xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
                xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
                xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
                xap:Rating="5" crs:Exposure="+0.50" xmpMM:DocumentID="xmp.did:123">
               <dc:creator><rdf:Seq><rdf:li>Jane  Doe</rdf:li></rdf:Seq></dc:creator>
               <dc:subject><rdf:Bag><rdf:li>boat</rdf:li></rdf:Bag></dc:subject>
               <Iptc4xmpCore:CreatorContactInfo rdf:parseType="Resource">
                <Iptc4xmpCore:CiEmailWork>jane@example.com</Iptc4xmpCore:CiEmailWork>
               </Iptc4xmpCore:CreatorContactInfo>
               <Iptc4xmpExt:LocationShown><rdf:Bag><rdf:li rdf:parseType="Resource">
                <Iptc4xmpExt:City>Hamburg</Iptc4xmpExt:City></rdf:li></rdf:Bag></Iptc4xmpExt:LocationShown>
               <xmpMM:History><rdf:Seq><rdf:li>edited</rdf:li></rdf:Seq></xmpMM:History>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            \(String(repeating: " ", count: 2000))
            <?xpacket end="w"?>
            """.utf8)
        let privateOut = String(decoding: try #require(XMPFilter.filter(packet, level: .removePrivate)), as: UTF8.self)
        #expect(privateOut.contains("xap:Rating=\"5\"")) // "xap:" is the old prefix of "xmp:"
        #expect(privateOut.contains("<rdf:li>Jane  Doe</rdf:li>")) // values keep their spaces
        #expect(privateOut.contains("jane@example.com"))
        #expect(privateOut.contains("boat"))
        for gone in ["crs:", "xmpMM", "Hamburg", "LocationShown", "Iptc4xmpExt", "   "] {
            #expect(!privateOut.contains(gone), "\(gone)")
        }
        #expect(privateOut.hasSuffix("<?xpacket end=\"w\"?>"))
        #expect(privateOut.utf8.count < 1200)

        let rightsOut = String(decoding: try #require(XMPFilter.filter(packet, level: .copyrightOnly)), as: UTF8.self)
        #expect(rightsOut.contains("Jane  Doe") && rightsOut.contains("jane@example.com"))
        #expect(!rightsOut.contains("boat") && !rightsOut.contains("Rating"))
        #expect(XMPFilter.filter(packet, level: .removeAll) == nil)

        let unpadded = XMPFilter.withoutPadding(packet)
        #expect(unpadded.count == packet.count - 2001) // one line break stays
        #expect(XMPFilter.filter(Array("<not xml".utf8), level: .removePrivate) == nil)
    }

    // MARK: - IPTC

    @Test func iptcDigestFollowsTheFilteredBlock() {
        func dataset(_ record: UInt8, _ number: UInt8, _ text: String) -> [UInt8] {
            let bytes = Array(text.utf8)
            return [0x1C, record, number, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
        }
        let iim = dataset(2, 0, "\u{0}\u{4}") + dataset(2, 80, "Jane Doe") + dataset(2, 90, "Hamburg") + dataset(2, 25, "boat")
        func resource(_ id: UInt16, _ data: [UInt8]) -> [UInt8] {
            var r = Array("8BIM".utf8) + [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0]
            r += [UInt8(data.count >> 24), UInt8(data.count >> 16 & 0xFF), UInt8(data.count >> 8 & 0xFF), UInt8(data.count & 0xFF)] + data
            return data.count % 2 == 1 ? r + [0] : r
        }
        let digest = Array(Insecure.MD5.hash(data: iim))
        let block = resource(0x0404, iim) + resource(0x0425, digest) + resource(0x040C, Array(repeating: 1, count: 500))
        let result = IPTCFilter.filter(block, level: .removePrivate)
        let out = try? #require(result.resources)
        let text = String(decoding: out ?? [], as: UTF8.self)
        #expect(text.contains("Jane Doe") && text.contains("boat") && !text.contains("Hamburg"))
        #expect((out?.count ?? 0) < 200) // the thumbnail (0x040C) went
        let newIIM = dataset(2, 0, "\u{0}\u{4}") + dataset(2, 80, "Jane Doe") + dataset(2, 25, "boat")
        let expected = Insecure.MD5.hash(data: newIIM).map { String(format: "%02X", $0) }.joined()
        #expect(result.digest?.new == expected)
        #expect(IPTCFilter.filter(block, level: .removeAll).resources == nil)
    }

    // MARK: - WebP and whole files

    @Test func webpLosesLocationEvenWhenLossy() async throws {
        // A lossy WebP with the photo's EXIF in a chunk of its own.
        // cwebp is built to read only WebP and PPM.
        let ppm = dir.appending(path: "for-webp.ppm")
        var pixels: [UInt8] = Array("P6\n64 48\n255\n".utf8)
        for i in 0..<64 * 48 { pixels += [UInt8(i % 64 * 4), UInt8(i / 64 * 5), 128] }
        try Data(pixels).write(to: ppm)
        let plain = dir.appending(path: "plain.webp")
        try await ToolRunner.run("cwebp", ["-quiet", "-q", "80", "-o", plain.path, "--", ppm.path], in: dir)
        let exifSegment = try #require(try JPEGMetadataFilter.segments(Data(contentsOf: photo("for-webp.jpg"))).headers
            .first { $0.marker == 0xE1 && $0.bytes.dropFirst(4).starts(with: Array("Exif".utf8)) })
        let tiff = Array(exifSegment.bytes.dropFirst(4 + 6))
        let vp8 = Array(try Data(contentsOf: plain).dropFirst(12))
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let n = payload.count
            return Array(type.utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), 0] + payload + (n % 2 == 1 ? [0] : [])
        }
        let body = Array("WEBP".utf8) + chunk("VP8X", [0x08, 0, 0, 0, 63, 0, 0, 47, 0, 0]) + vp8 + chunk("EXIF", tiff)
        let url = dir.appending(path: "lossy.webp")
        try Data(Array("RIFF".utf8) + [UInt8(body.count & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count >> 16 & 0xFF), 0] + body)
            .write(to: url)
        #expect(props(url)[kCGImagePropertyGPSDictionary] != nil)
        var settings = OptimizationSettings()
        settings.moveOriginalsToTrash = false
        guard case .optimized = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in }) else {
            Issue.record("not optimized"); return
        }
        #expect(props(url)[kCGImagePropertyGPSDictionary] == nil)
        #expect((props(url)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] as? String == "Jane Doe")
    }

    @Test(arguments: [MetadataHandling.keep, .removePrivate, .copyrightOnly, .removeAll])
    func heicIsReencodedAtEveryLevel(level: MetadataHandling) async throws {
        let url = dir.appending(path: "photo-\(level.rawValue).heic")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(), [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Doe", kCGImagePropertyTIFFModel: "EOS R5"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.1, kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        var settings = OptimizationSettings()
        settings.moveOriginalsToTrash = false
        settings.lossy = true
        settings.quality = 40
        settings.outputLossy = .replace
        settings.metadata = level
        let outcome = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        guard case .optimized = outcome else { Issue.record("not optimized: \(outcome)"); return }
        let p = props(url)
        #expect((p[kCGImagePropertyGPSDictionary] != nil) == (level == .keep))
        let artist = (p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] as? String
        #expect((artist == "Jane Doe") == (level != .removeAll))
    }

    /// Private data goes even where the image itself can't be improved:
    /// HEIC in lossless mode, and a JPEG with an HDR gain map.
    @Test(arguments: [UTType.heic, .jpeg])
    func privateDataGoesWhereTheImageStaysAsItIs(type: UTType) async throws {
        let url = dir.appending(path: "gain-map.\(type.preferredFilenameExtension ?? "img")")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(), [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Doe"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.1, kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        let gainMap = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(gainMap, "http://ns.apple.com/HDRGainMap/1.0/" as CFString, "HDRGainMap" as CFString, nil)
        CGImageMetadataSetValueWithPath(gainMap, nil, "HDRGainMap:HDRGainMapVersion" as CFString, 65536 as CFNumber)
        CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeHDRGainMap, [
            kCGImageAuxiliaryDataInfoData: Data((0..<32 * 24).map { UInt8($0 % 251) }) as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: [kCGImagePropertyWidth: 32, kCGImagePropertyHeight: 24,
                                                       kCGImagePropertyBytesPerRow: 32,
                                                       kCGImagePropertyPixelFormat: 0x4C30_3038], // 'L008'
            kCGImageAuxiliaryDataInfoMetadata: gainMap,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        #expect(ImageIOMetadata.auxiliaryImages(source) == [kCGImageAuxiliaryDataTypeHDRGainMap])
        if type == .jpeg { #expect(JPEGStructure.holdsOnlyIndexedImages([UInt8](try Data(contentsOf: url)))) }

        var settings = OptimizationSettings()
        settings.moveOriginalsToTrash = false
        let outcome = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        guard case .optimized(_, _, _, _, _, let identical) = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(identical)
        let p = props(url)
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        #expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] as? String == "Jane Doe")
        #expect(ImageIOMetadata.auxiliaryImages(CGImageSourceCreateWithURL(url as CFURL, nil)!) == [kCGImageAuxiliaryDataTypeHDRGainMap])

        // Nothing to remove: the file stays as it is.
        settings.metadata = .keep
        let before = try Data(contentsOf: url)
        _ = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func settingsSavedBeforeTheLevelsBecomeTheDefault() throws {
        let decoded = try JSONDecoder().decode([MetadataHandling].self, from: Data(#"["strip","keep","copyright"]"#.utf8))
        #expect(decoded == [.removePrivate, .keep, .copyrightOnly])
    }

    @Test func checkRejectsInventedValues() throws {
        let url = photo("check.jpg")
        let other = dir.appending(path: "other.jpg")
        let dest = CGImageDestinationCreateWithURL(other as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(), [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Someone Else"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        #expect(throws: VerificationError.self) { try MetadataCheck.verify(original: url, result: other, level: .removePrivate) }
    }

    // MARK: -

    /// A big-endian TIFF block with IFD0, an EXIF IFD and an Interop IFD.
    private func exifBlock(main: [(UInt16, UInt16, [UInt8])], exif: [(UInt16, UInt16, [UInt8])],
                           interop: [(UInt16, UInt16, [UInt8])]) -> [UInt8] {
        let sizes: [UInt16: Int] = [2: 1, 3: 2, 4: 4, 7: 1]
        var out: [UInt8] = Array("MM".utf8) + [0, 42, 0, 0, 0, 8]
        func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var pending: [(slot: Int, ifd: [(UInt16, UInt16, [UInt8])])] = []
        func write(_ entries: [(UInt16, UInt16, [UInt8])], pointer: UInt16?) {
            let all = entries + (pointer.map { [($0, UInt16(4), [UInt8](repeating: 0, count: 4))] } ?? [])
            var data: [UInt8] = []
            let start = out.count
            let dataStart = start + 2 + all.count * 12 + 4
            out += u16(all.count)
            for (tag, type, value) in all.sorted(by: { $0.0 < $1.0 }) {
                out += u16(Int(tag)) + u16(Int(type)) + u32(value.count / (sizes[type] ?? 1))
                if tag == pointer { pending.append((out.count, [])) }
                if value.count <= 4 { out += value + [UInt8](repeating: 0, count: 4 - value.count) } else {
                    out += u32(dataStart + data.count); data += value
                }
            }
            out += u32(0) + data
        }
        write(main, pointer: 0x8769)
        let exifSlot = pending.removeLast().slot
        out.replaceSubrange(exifSlot..<exifSlot + 4, with: u32(out.count))
        write(exif, pointer: interop.isEmpty ? nil : 0xA005)
        if !interop.isEmpty {
            let slot = pending.removeLast().slot
            out.replaceSubrange(slot..<slot + 4, with: u32(out.count))
            write(interop, pointer: nil)
        }
        return out
    }
}
