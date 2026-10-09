import AppKit
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
        #expect(MetadataCheck.fields(try Data(contentsOf: kept)) == MetadataCheck.fields(try Data(contentsOf: url)))
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

    /// A camera set to Adobe RGB, without an ICC profile: colour space
    /// "uncalibrated", interoperability index "R03", and the white point,
    /// primaries and gamma, from which ImageIO shows it in Adobe RGB. The
    /// photo looks the same at every level, and its private data still goes.
    @Test(arguments: MetadataHandling.allCases)
    func adobeRGBWithoutProfileLooksTheSameAtEveryLevel(level: MetadataHandling) async throws {
        func rationals(_ values: [(Int, Int)]) -> [UInt8] {
            values.flatMap { n, d in [n, d].flatMap { v in [24, 16, 8, 0].map { UInt8(v >> $0 & 0xFF) } } }
        }
        let tiff = exifBlock(main: [(0x010F, 2, Array("NIKON\0".utf8)), (0x0131, 2, Array("SecretEditor 1.0\0".utf8)),
                                    (0x013E, 5, rationals([(313, 1000), (329, 1000)])),
                                    (0x013F, 5, rationals([(64, 100), (33, 100), (21, 100), (71, 100), (15, 100), (6, 100)]))],
                             exif: [(0xA001, 3, [0xFF, 0xFF]), (0xA500, 5, rationals([(22, 10)])),
                                    (0xA431, 2, Array("SN12345\0".utf8))],
                             interop: [(0x0001, 2, Array("R03\0".utf8)), (0x0002, 7, Array("0100".utf8))])
        let url = try jpeg("adobe-rgb-\(level.rawValue).jpg", exif: tiff)

        func colourSpace(_ url: URL) -> String? {
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?
                .colorSpace?.name as String?
        }
        try #require(colourSpace(url) == CGColorSpace.adobeRGB1998 as String)
        let p = props(try filtered(url, level))
        #expect(p[kCGImagePropertyProfileName] as? String == "Adobe RGB (1998)")
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifColorSpace] as? Int == 0xFFFF)
        #expect((exif?[kCGImagePropertyExifBodySerialNumber] == nil) == (level != .keep))

        // The whole run: optimized, not left unchanged, and still Adobe RGB.
        var settings = OptimizationSettings()
        settings.metadata = level
        settings.moveOriginalsToTrash = false
        let outcome = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        guard case .optimized = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(colourSpace(url) == CGColorSpace.adobeRGB1998 as String)
        let raw = try Data(contentsOf: url)
        #expect(raw.contains(Data("R03".utf8)))
        #expect(raw.contains(Data("SecretEditor".utf8)) == (level == .keep))
    }

    /// The size an image is shown at stays at every level: apps such as
    /// Preview and Pages take it from the resolution (a Retina screenshot at
    /// half its pixels), browsers from EXIF's resolution and pixel size.
    @Test(arguments: [MetadataHandling.copyrightOnly, .removeAll])
    func resolutionStaysAtEveryLevel(level: MetadataHandling) async throws {
        func rational(_ n: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(n >> $0 & 0xFF) } + [0, 0, 0, 1] }
        func long(_ n: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(n >> $0 & 0xFF) } }
        func size(_ url: URL) -> NSSize? { NSImage(contentsOf: url)?.size }
        func block(dpi: Int) -> [UInt8] {
            exifBlock(main: [(0x010F, 2, Array("Canon\0".utf8)), (0x011A, 5, rational(dpi)), (0x011B, 5, rational(dpi)),
                             (0x0128, 3, [0, 2])],
                      exif: [(0xA001, 3, [0, 1]), (0xA002, 4, long(64 * 72 / dpi)), (0xA003, 4, long(48 * 72 / dpi)),
                             (0xA431, 2, Array("SN12345\0".utf8))],
                      interop: [])
        }

        // A JPEG without JFIF: the size comes from EXIF alone.
        let hiDPI = try jpeg("hidpi-\(level.rawValue).jpg", exif: block(dpi: 144))
        try #require(size(hiDPI) == NSSize(width: 32, height: 24))
        let result = try filtered(hiDPI, level)
        #expect(size(result) == NSSize(width: 32, height: 24))
        let exif = props(result)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifPixelXDimension] as? Int == 32)
        #expect(exif?[kCGImagePropertyExifBodySerialNumber] == nil)

        // At 72 dpi the pixel size says nothing more: no EXIF IFD for it alone.
        let plain = try filtered(try jpeg("72dpi-\(level.rawValue).jpg", exif: block(dpi: 72)), level)
        #expect(props(plain)[kCGImagePropertyDPIWidth] as? Int == 72)
        #expect((props(plain)[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifPixelXDimension] == nil)

        // A PNG's physical size (pHYs).
        let png = dir.appending(path: "retina-\(level.rawValue).png")
        let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(), [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let out = dir.appending(path: "\(level.rawValue)-filtered.png")
        try PNGMetadataFilter.filter(Data(contentsOf: png), level: level, orientation: 1).write(to: out)
        try MetadataCheck.verify(original: png, result: out, level: level)
        #expect(try PNGChunks.read(ByteView(Data(contentsOf: out)), strict: true).contains { $0.type == "pHYs" })
        #expect(size(out) == NSSize(width: 32, height: 24))

        // XMP's copy of the resolution, and Photoshop's.
        let packet = Array(GoogleXMPSamples.packet("""
            <rdf:Description xmlns:tiff="\(MetadataPolicy.NS.tiff)" tiff:XResolution="144/1" tiff:ResolutionUnit="2" \
            tiff:Make="Canon"/>
            """).utf8)
        let xmp = String(decoding: try #require(XMPFilter.filter(packet, level: level)), as: UTF8.self)
        #expect(xmp.contains("XResolution") && xmp.contains("ResolutionUnit") && !xmp.contains("Canon"))
        let resolutionInfo: [UInt8] = [0, 144, 0, 0, 0, 1, 0, 1, 0, 144, 0, 0, 0, 1, 0, 1]
        let resources = Array("8BIM".utf8) + [0x03, 0xED, 0, 0, 0, 0, 0, 16] + resolutionInfo
        #expect(IPTCFilter.filter(resources, level: level).resources == resources)
    }

    /// A result shown at another size is thrown away, whatever made it.
    @Test func verifierRejectsALostResolution() async throws {
        func rational(_ n: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(n >> $0 & 0xFF) } + [0, 0, 0, 1] }
        let pixelSize: [(UInt16, UInt16, [UInt8])] = [(0xA002, 4, [0, 0, 0, 32]), (0xA003, 4, [0, 0, 0, 24])]
        let hiDPI = try jpeg("verify-hidpi.jpg", exif: exifBlock(
            main: [(0x011A, 5, rational(144)), (0x011B, 5, rational(144)), (0x0128, 3, [0, 2])], exif: pixelSize, interop: []))
        let noResolution = try jpeg("verify-plain.jpg", exif: exifBlock(main: [(0x0112, 3, [0, 1])], exif: pixelSize, interop: []))
        // The same coefficients, as the same image is encoded the same way.
        try await Verifier.verify(original: noResolution, result: noResolution, format: .jpeg, pixelsMustMatch: true)
        let error = await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: hiDPI, result: noResolution, format: .jpeg, pixelsMustMatch: true)
        }
        #expect(["resolution changed", "Auflösung geändert"].contains(error?.reason ?? ""))
    }

    // MARK: - XMP

    /// A description named after the document ("uuid:…", as some cameras
    /// write it) reads as its instance id; filtered, it names nothing.
    @Test func xmpDocumentNameGoes() throws {
        let packet = Array("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="uuid:d874e788-25f8-4d1d-947a-6e77822b5d6a" xmlns:xmp="http://ns.adobe.com/xap/1.0/">\
            <xmp:Rating>3</xmp:Rating></rdf:Description></rdf:RDF></x:xmpmeta>
            """.utf8)
        let filtered = String(decoding: try #require(XMPFilter.filter(packet, level: .removePrivate)), as: UTF8.self)
        #expect(!filtered.contains("uuid:") && filtered.contains("rdf:about=\"\"") && filtered.contains("Rating"))
    }

    /// The packet as readers see it: junk after the trailer and closing zero
    /// bytes left out. A packet with no trailer is filtered too, not dropped
    /// as unreadable.
    @Test func xmpPacketWithoutTrailerIsFiltered() throws {
        let body = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:exif="http://ns.adobe.com/exif/1.0/" \
            exif:GPSLatitude="53,33.0N"><dc:creator><rdf:Seq><rdf:li>Jane Doe</rdf:li></rdf:Seq></dc:creator>\
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """
        let begin = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
        #expect(XML.document(ofPacket: Data((begin + body + "<?xpacket end=\"w\"?>junk\0").utf8)) == Data((begin + body + "<?xpacket end=\"w\"?>").utf8))
        #expect(XML.document(ofPacket: Data((body + "\0\0").utf8)) == Data(body.utf8))
        let filtered = String(decoding: try #require(XMPFilter.filter(Array((begin + body + "\0").utf8), level: .removePrivate)), as: UTF8.self)
        #expect(filtered.contains("Jane Doe") && !filtered.contains("GPS"))
    }

    /// New lengths go into the container's directory, as an attribute
    /// (Ultra HDR) or an element (Dynamic Depth); entries without a new
    /// length keep theirs.
    @Test func containerLengthsAreWritten() throws {
        let attributes = Array(GoogleXMPSamples.packet(GoogleXMPSamples.directory(gainMapLength: 1531, videoLength: 900)).utf8)
        let elements = Array(GoogleXMPSamples.packet("""
            <rdf:Description xmlns:Device="\(MetadataPolicy.NS.depthDevice)" xmlns:Container="\(GoogleXMP.containerNamespaces[1])" \
            xmlns:Item="\(GoogleXMP.itemNamespaces[1])"><Device:Container rdf:parseType="Resource"><Container:Directory><rdf:Seq>\
            <rdf:li rdf:parseType="Resource"><rdf:value rdf:parseType="Resource"><Item:Mime>image/jpeg</Item:Mime></rdf:value></rdf:li>\
            <rdf:li rdf:parseType="Resource"><rdf:value rdf:parseType="Resource"><Item:Mime>image/jpeg</Item:Mime>\
            <Item:Length>1531</Item:Length></rdf:value></rdf:li></rdf:Seq></Container:Directory></Device:Container></rdf:Description>
            """).utf8)
        // Items straight in the list, without rdf:li.
        let bare = Array(GoogleXMPSamples.packet(GoogleXMPSamples.directory(gainMapLength: 1531, videoLength: 900)
            .replacingOccurrences(of: "<rdf:li rdf:parseType=\"Resource\">", with: "").replacingOccurrences(of: "</rdf:li>", with: "")).utf8)
        func items(_ filtered: [UInt8]) throws -> [GoogleXMP.Item] {
            let segment = JPEGMarkers.write(0xE1, JPEGMarkers.xmpHeader + filtered)
            let file = Data([0xFF, 0xD8]) + segment + Data([0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9])
            return try #require(GoogleXMP.read(try JPEGMarkers.headers(ByteView(file)).segments)?.directories.first)
        }
        for packet in [attributes, elements, bare] {
            let read = try items(try #require(XMPFilter.filter(packet, level: .removePrivate, itemLengths: [1: 1200])))
            #expect(read[1].length == 1200)
            #expect(read.count < 3 || read[2].length == 900)
        }
        // Only the entries given change: entry 2 here, entry 1 keeps its length.
        let three = Array(GoogleXMPSamples.packet(GoogleXMPSamples.depthDirectory([("image/jpeg", 1531), ("image/jpeg", 900)])).utf8)
        let read = try items(try #require(XMPFilter.filter(three, level: .removePrivate, itemLengths: [2: 77])))
        #expect(read.map(\.length) == [0, 1531, 77])
    }

    /// The extended XMP writer at a part's exact size and around it: as many
    /// parts as needed, each a valid segment, read back to the same packet;
    /// the reader takes no overlapping parts, no parts of another packet's
    /// length, and leaves parts of an earlier packet alone.
    @Test func extendedXMPPartsAtTheirBoundaries() throws {
        let part = 0xFFFF - 2 - JPEGMarkers.extendedXMPHeader.count - 40
        for (size, parts) in [(part, 1), (part + 1, 2), (2 * part, 2), (0, 0)] {
            let packet = (0..<size).map { UInt8(0x41 + $0 % 26) }
            let written = JPEGMarkers.extendedXMPSegments(packet)
            #expect(written.segments.count == parts, "\(size)")
            let payloads = try written.segments.map { try JPEGMarkers.segment(at: 0, in: ByteView($0)).payload }
            #expect(payloads.allSatisfy { $0.count <= 0xFFFF - 2 }, "\(size)")
            for p in payloads { try PayloadCheck.extendedXMP(p.view(from: JPEGMarkers.extendedXMPHeader.count)) }
            let chunks = payloads.map { $0.bytes.dropFirst(JPEGMarkers.extendedXMPHeader.count) }
            if size > 0 { #expect(JPEGMarkers.extendedXMP(chunks, for: Data(written.guid.utf8)) == Data(packet), "\(size)") }
        }
        func chunk(_ guid: String, _ total: Int, _ offset: Int, _ data: String) -> Data {
            func be(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).bigEndian, Array.init) }
            return Data(Array(guid.utf8) + be(total) + be(offset) + Array(data.utf8))
        }
        let guid = "0123456789ABCDEF0123456789ABCDEF", other = "FEDCBA9876543210FEDCBA9876543210", main = Data(guid.utf8)
        #expect(JPEGMarkers.extendedXMP([chunk(guid, 4, 0, "abc"), chunk(guid, 4, 2, "cd")], for: main) == nil) // overlap
        #expect(JPEGMarkers.extendedXMP([chunk(guid, 4, 0, "ab"), chunk(guid, 5, 2, "cd")], for: main) == nil) // lengths differ
        #expect(JPEGMarkers.extendedXMP([chunk(other, 2, 0, "zz"), chunk(guid, 4, 0, "ab"), chunk(guid, 4, 2, "cd")], for: main)
                == Data("abcd".utf8))
    }

    /// Google's camera namespace says how to show the photo (motion photo
    /// marks stay at every level); its HDR+ maker note and shot log are the
    /// camera's own records and go like EXIF's MakerNote.
    @Test func googleCameraRecordsGo() throws {
        let packet = Array(GoogleXMPSamples.packet("""
            <rdf:Description xmlns:GCamera="\(GoogleXMP.cameraNamespace)" GCamera:MotionPhoto="1" GCamera:MotionPhotoVersion="1" \
            GCamera:MicroVideoOffset="1234" GCamera:PortraitNote="x" GCamera:SpecialTypeID="t" \
            GCamera:hdrp_makernote="SERSUALvZDVt" GCamera:HdrPlusMakernote="SERSUALvZDVv" GCamera:shot_log_data="SERSUALvZDVu" \
            GCamera:BurstID="5e4c8a3e-1111" GCamera:SomethingNew="?"/>
            """).utf8)
        for level in [MetadataHandling.removePrivate, .removeAll] {
            let filtered = String(decoding: try #require(XMPFilter.filter(packet, level: level)), as: UTF8.self)
            for kept in ["MotionPhoto=\"1\"", "MotionPhotoVersion", "MicroVideoOffset", "PortraitNote", "SpecialTypeID"] {
                #expect(filtered.contains(kept), "\(level): \(kept)")
            }
            // Maker notes, the shot log, burst ids that link photos, and what isn't known go.
            for gone in ["akernote", "shot_log_data", "BurstID", "SomethingNew"] { #expect(!filtered.contains(gone), "\(level): \(gone)") }
        }
    }

    /// Extended XMP too large to merge into the main packet (Dynamic Depth
    /// in Pixel portraits) is filtered on its own and written as extended
    /// parts again, named by its new GUID: the directory stays, the device's
    /// pose goes. Extended XMP with nothing left is dropped, and so is the
    /// main packet's note of it.
    @Test func largeExtendedXMPIsFilteredAndWrittenAgain() throws {
        let filler = String(repeating: "QUJD", count: 30_000) // display data, Base64 like GDepth:Data
        let depth = """
            <rdf:Description xmlns:Device="\(MetadataPolicy.NS.depthDevice)" xmlns:Container="\(GoogleXMP.containerNamespaces[1])" \
            xmlns:Item="\(GoogleXMP.itemNamespaces[1])" xmlns:Pose="http://ns.google.com/photos/dd/1.0/pose/" \
            xmlns:GDepth="http://ns.google.com/photos/1.0/depthmap/" GDepth:Data="\(filler)">\
            <Device:Pose rdf:parseType="Resource"><Pose:Latitude>53.55</Pose:Latitude></Device:Pose>\
            <Device:Container rdf:parseType="Resource"><Container:Directory><rdf:Seq>\
            <rdf:li rdf:parseType="Resource"><rdf:value rdf:parseType="Resource"><Item:Mime>image/jpeg</Item:Mime></rdf:value></rdf:li>\
            <rdf:li rdf:parseType="Resource"><rdf:value rdf:parseType="Resource"><Item:Mime>image/jpeg</Item:Mime>\
            <Item:Length>42</Item:Length></rdf:value></rdf:li></rdf:Seq></Container:Directory></Device:Container></rdf:Description>
            """
        func file(_ main: String, _ extended: String) throws -> Data {
            let headers = try GoogleXMPSamples.headers(main, extended: extended)
            return Data([0xFF, 0xD8]) + headers.reduce(Data()) { $0 + $1.whole.bytes } + Data([0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9])
        }
        let original = try file("<rdf:Description xmlns:dc=\"http://purl.org/dc/elements/1.1/\" dc:format=\"image/jpeg\"/>", depth)
        let before = try #require(GoogleXMP.read(JPEGMarkers.headers(ByteView(original)).segments))
        #expect(before.listsMoreThanThePhoto)
        // New lengths land in the extended part written again.
        let lengthened = try JPEGMetadataFilter.filter(original, level: .removePrivate, orientation: 1, itemLengths: [1: 4242])
        #expect(GoogleXMP.read(try JPEGMarkers.headers(ByteView(lengthened)).segments)?.directories.first?.last?.length == 4242)
        for level in [MetadataHandling.removePrivate, .removeAll] {
            let result = try JPEGMetadataFilter.filter(original, level: level, orientation: 1)
            let segments = try JPEGMarkers.headers(ByteView(result)).segments
            #expect(GoogleXMP.read(segments) == before, "\(level)")
            let parts = segments.filter { JPEGMarkers.part($0.marker, payload: $0.payload.bytes) == .extendedXMP }
            #expect(parts.count > 1 && !String(decoding: result, as: UTF8.self).contains("Latitude"), "\(level)")
            // The GUID is the MD5 digest of the packet the parts make up.
            let main = try #require(segments.first { JPEGMarkers.part($0.marker, payload: $0.payload.bytes) == .xmp })
            let whole = try #require(JPEGMarkers.extendedXMP(parts.map { $0.payload.bytes.dropFirst(JPEGMarkers.extendedXMPHeader.count) },
                                                              for: main.payload.bytes))
            #expect(JPEGMarkers.extendedXMPSegments(Array(whole)).guid == String(decoding: parts[0].payload.bytes.dropFirst(JPEGMarkers.extendedXMPHeader.count).prefix(32), as: UTF8.self))
        }
        // Only private data in the extended part: it goes, with its note.
        let privateOnly = try file("<rdf:Description xmlns:dc=\"http://purl.org/dc/elements/1.1/\" dc:format=\"image/jpeg\"/>",
            "<rdf:Description xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\" xmpMM:History=\"\(filler)\"/>")
        let result = try JPEGMetadataFilter.filter(privateOnly, level: .removePrivate, orientation: 1)
        let text = String(decoding: result, as: UTF8.self)
        #expect(!text.contains("HasExtendedXMP") && !text.contains(JPEGMarkers.extendedXMPHeader.map { String(UnicodeScalar($0)) }.joined().dropLast()))
    }

    /// The directories the JPEG layout relies on stay at every level:
    /// Google's container and Dynamic Depth's, inside its device — but not
    /// the device's pose, which may be a location.
    @Test func googleDirectoriesStay() throws {
        let depth = """
            <rdf:Description xmlns:Device="\(MetadataPolicy.NS.depthDevice)" xmlns:Container="\(GoogleXMP.containerNamespaces[1])" \
            xmlns:Item="\(GoogleXMP.itemNamespaces[1])" xmlns:Pose="http://ns.google.com/photos/dd/1.0/pose/">\
            <Device:Pose rdf:parseType="Resource"><Pose:Latitude>53.55</Pose:Latitude></Device:Pose>\
            <Device:Container rdf:parseType="Resource"><Container:Directory><rdf:Seq>\
            <rdf:li rdf:parseType="Resource"><rdf:value rdf:parseType="Resource"><Item:Mime>image/jpeg</Item:Mime></rdf:value></rdf:li>\
            <rdf:li rdf:parseType="Resource"><rdf:value rdf:parseType="Resource"><Item:Mime>image/jpeg</Item:Mime>\
            <Item:Length>42</Item:Length></rdf:value></rdf:li></rdf:Seq></Container:Directory></Device:Container></rdf:Description>
            """
        for description in [GoogleXMPSamples.directory(gainMapLength: 1531, videoLength: 99), depth] {
            let packet = Array(GoogleXMPSamples.packet(description).utf8)
            let before = try #require(GoogleXMP.read(GoogleXMPSamples.headers(description)))
            #expect(before.listsMoreThanThePhoto)
            for level in [MetadataHandling.removePrivate, .copyrightOnly, .removeAll] {
                let filtered = try #require(XMPFilter.filter(packet, level: level), "\(level)")
                let segment = JPEGMarkers.write(0xE1, JPEGMarkers.xmpHeader + filtered)
                let file = Data([0xFF, 0xD8]) + segment + Data([0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9])
                #expect(GoogleXMP.read(try JPEGMarkers.headers(ByteView(file)).segments) == before, "\(level)")
                #expect(!String(decoding: filtered, as: UTF8.self).contains("Latitude"), "\(level)")
            }
        }
    }

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
    /// HEIC in lossless mode. (JPEGs with a gain map: MultiImageJPEGTests.)
    @Test func privateDataGoesWhereTheImageStaysAsItIs() async throws {
        let type = UTType.heic
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
        #expect(AuxiliaryImages.all(source) == [kCGImageAuxiliaryDataTypeHDRGainMap])

        var settings = OptimizationSettings()
        settings.moveOriginalsToTrash = false
        let outcome = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        guard case .optimized(_, _, _, _, _, let identical) = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(identical)
        let p = props(url)
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        #expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] as? String == "Jane Doe")
        #expect(AuxiliaryImages.all(CGImageSourceCreateWithURL(url as CFURL, nil)!) == [kCGImageAuxiliaryDataTypeHDRGainMap])

        // Nothing to remove: the file stays as it is.
        settings.metadata = .keep
        let before = try Data(contentsOf: url)
        _ = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        #expect(try Data(contentsOf: url) == before)
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

        var settings = OptimizationSettings()
        settings.moveOriginalsToTrash = false
        settings.metadata = .removeAll
        let outcome = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        guard case .optimized = outcome else { Issue.record("not optimized: \(outcome)"); return }
        let fields = MetadataCheck.fields(try Data(contentsOf: url))
        #expect(fields[MetadataCheck.Key(ns: MetadataPolicy.NS.iptcExt, name: "DigitalSourceType")]?.text == source)
        #expect(!fields.keys.contains { $0.name == "rights" || $0.name == "City" })
    }

    @Test func settingsSavedBeforeTheLevelsBecomeTheDefault() throws {
        let decoded = try JSONDecoder().decode([MetadataHandling].self, from: Data(#"["strip","keep","copyright"]"#.utf8))
        #expect(decoded == [.removePrivate, .keep, .copyrightOnly])
    }

    /// ImageMagick writes eXIf after the image data. Browsers and ImageIO
    /// skip it there, other readers apply its orientation: it is filtered
    /// where it stands, so every reader shows the image as before — and the
    /// check sees it, so what the level removes goes from it too.
    @Test(arguments: [1, 6])
    func exifAfterTheImageData(orientation: Int) async throws {
        let url = dir.appending(path: "late-exif-\(orientation).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(), nil)
        #expect(CGImageDestinationFinalize(dest))
        let rational: [UInt8] = [0, 0, 0, 144, 0, 0, 0, 1]
        let tiff = exifBlock(main: [(0x0112, 3, [0, UInt8(orientation)]), (0x011A, 5, rational), (0x011B, 5, rational), (0x0128, 3, [0, 2])],
                             exif: [(0x9286, 7, Array("ASCII\0\0\0Screenshot".utf8))], interop: [])
        var png = Data(PNGChunks.signature) // ImageIO's own eXIf (before IDAT) goes; ours goes in front of IEND
        for chunk in try PNGChunks.read(ByteView(Data(contentsOf: url)), strict: true) where chunk.type != "eXIf" {
            if chunk.type == "IEND" { png.append(PNGChunks.write("eXIf", tiff)) }
            png.append(chunk.whole.bytes)
        }
        try png.write(to: url)
        #expect(props(url)[kCGImagePropertyOrientation] == nil)
        #expect(MetadataCheck.hasFieldsToRemove(url, level: .removePrivate)) // the comment
        func types(_ url: URL) throws -> [String] { try PNGChunks.read(ByteView(Data(contentsOf: url)), strict: true).map(\.type) }
        let order = try types(url)

        let out = dir.appending(path: "late-exif-\(orientation)-filtered.png")
        try PNGMetadataFilter.filter(Data(contentsOf: url), level: .removePrivate, orientation: 1).write(to: out)
        #expect(try types(out) == order)
        try MetadataCheck.verify(original: url, result: out, level: .removePrivate)

        var settings = OptimizationSettings()
        settings.moveOriginalsToTrash = false
        let outcome = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        guard case .optimized = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(try types(url).last(where: { $0 != "IEND" }) == "eXIf")
        #expect(props(url)[kCGImagePropertyOrientation] == nil)
        #expect(!MetadataCheck.hasFieldsToRemove(url, level: .removePrivate))
        let fields = MetadataCheck.fields(try Data(contentsOf: url))
        #expect(fields[MetadataCheck.Key(ns: MetadataPolicy.NS.tiff, name: "Orientation")]?.text == "\(orientation)")
        #expect(fields[MetadataCheck.Key(ns: MetadataPolicy.NS.tiff, name: "XResolution")]?.text == "144/1")
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

    /// The image data of a JPEG ImageIO writes, with only this EXIF before
    /// it: no JFIF, no ICC profile.
    private func jpeg(_ name: String, exif tiff: [UInt8]) throws -> URL {
        let plain = dir.appending(path: "plain-\(name)")
        let dest = CGImageDestinationCreateWithURL(plain as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(), [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let data = try Data(contentsOf: plain)
        let (segments, scan) = try JPEGMarkers.headers(ByteView(data))
        var jpeg = Data([0xFF, 0xD8]) + JPEGMarkers.write(0xE1, JPEGMarkers.exifHeader + tiff)
        for s in segments where !(0xE0...0xEF).contains(s.marker) { jpeg += s.whole.bytes }
        jpeg += data[scan...]
        let url = dir.appending(path: name)
        try jpeg.write(to: url)
        return url
    }

    /// A big-endian TIFF block with IFD0, an EXIF IFD and an Interop IFD.
    private func exifBlock(main: [(UInt16, UInt16, [UInt8])], exif: [(UInt16, UInt16, [UInt8])],
                           interop: [(UInt16, UInt16, [UInt8])]) -> [UInt8] {
        let sizes: [UInt16: Int] = [2: 1, 3: 2, 4: 4, 5: 8, 7: 1]
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
