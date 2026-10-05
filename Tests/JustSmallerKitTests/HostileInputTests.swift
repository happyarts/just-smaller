import Foundation
import Testing
import zlib
@testable import JustSmallerKit

/// Files built to break a reader: each case once stopped, or could have
/// stopped, the app. Every reader must answer them with "unreadable" or a
/// sound result — never a crash.
struct HostileInputTests {
    private func png(_ chunks: [Data]) -> Data { Data(PNGChunks.signature) + chunks.reduce(Data(), +) }

    /// An IHDR shorter than its 13 bytes, and an orientation to insert
    /// after it.
    @Test func shortPNGHeader() {
        let file = png([PNGChunks.write("IHDR", []), PNGChunks.write("IEND", [])])
        for level in [MetadataHandling.keep, .removePrivate, .removeAll] {
            _ = try? PNGMetadataFilter.filter(file, level: level, orientation: 6)
        }
    }

    /// Lengths pointing past the end in every container.
    @Test func lengthsPastTheEnd() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 0x45, 0x78])
        _ = try? JPEGMetadataFilter.filter(jpeg, level: .removePrivate, orientation: 6)
        _ = JPEGQuality.estimate(Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x01]))
        _ = JPEGLayout.read(ByteView(jpeg))
        let webp = Data(Array("RIFF".utf8) + [0xFF, 0xFF, 0xFF, 0xFF] + Array("WEBPEXIF".utf8) + [0xFF, 0xFF, 0xFF, 0x7F, 0x4D])
        _ = try? WebPMetadataFilter.filter(webp, level: .removePrivate)
        let png = png([PNGChunks.write("IHDR", [UInt8](repeating: 1, count: 13)), Data([0x7F, 0xFF, 0xFF, 0xFF]) + Data("eXIf".utf8)])
        _ = try? PNGMetadataFilter.filter(png, level: .removePrivate, orientation: 1)
    }

    /// Multi-picture indexes listing images past the end, in the middle of
    /// another image, twice, backwards, or millions of them; and an Apple
    /// maker note whose values point past its end.
    @Test func hostileMultiPictureIndex() {
        let image: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]
        func file(_ entries: [(size: UInt32, offset: UInt32)], count: UInt32? = nil) -> Data {
            let n = count ?? UInt32(entries.count * 16)
            var tiff: [UInt8] = Array("MM".utf8) + [0, 42, 0, 0, 0, 8, 0, 1] + [0xB0, 0x02, 0, 7]
            tiff += withUnsafeBytes(of: n.bigEndian, Array.init) + [0, 0, 0, 26] + [0, 0, 0, 0]
            for e in entries {
                tiff += [0, 0, 0, 0] + withUnsafeBytes(of: e.size.bigEndian, Array.init)
                    + withUnsafeBytes(of: e.offset.bigEndian, Array.init) + [0, 0, 0, 0]
            }
            let first = [0xFF, 0xD8] + JPEGMarkers.write(0xE2, Array("MPF\0".utf8) + tiff) + Data(image.dropFirst(2))
            return first + Data(image) + Data(image)
        }
        let cases = [
            file([(0, 0), (10, 0xFFFF_FFF0)]),          // past the end
            file([(0, 0), (10, 3)]),                    // inside the first image
            file([(0, 0), (10, 90), (10, 90)]),         // the same image twice
            file([(0, 0), (10, 100), (10, 90)]),        // backwards
            file([(0, 0)], count: 0xFFFF_FFF0),         // millions of images
            file([]),
        ]
        for data in cases {
            _ = MultiPictureIndex.read(ByteView(data))
            #expect(JPEGLayout.read(ByteView(data))?.problem == .unfittingIndex)
            _ = try? JPEGLayout.joined([data, Data(image)])
        }
        var note: [UInt8] = Array("Apple iOS\0".utf8) + [0, 1] + Array("MM".utf8) + [0xFF, 0xFF]
        note += [0, 33, 0, 10, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF] + [0, 48, 0, 10, 0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0x00]
        #expect(AppleMakerNote.filter(ByteView(note), level: .removePrivate) == nil)
    }

    /// EXIF whose IFDs point at each other, past the end, or at huge counts.
    @Test func hostileEXIF() {
        let loop: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 0x87, 0x69, 0, 4, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 8]
        let huge: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x0F, 0x01, 2, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0, 0xFF, 0xFF, 0xFF]
        let short: [UInt8] = [0x4D, 0x4D, 0, 42, 0xFF, 0xFF, 0xFF, 0xF0]
        for tiff in [loop, huge, short] {
            for level in [MetadataHandling.removePrivate, .copyrightOnly, .removeAll] {
                _ = EXIFFilter.filter(tiff, level: level)
            }
            #expect(throws: FormatError.self) { try PayloadCheck.tiff(ByteView(tiff)) }
        }
    }

    /// Extended XMP claiming a packet of almost 4 GB: nothing may be
    /// reserved for it before its parts add up.
    @Test func extendedXMPClaimingGigabytes() {
        let guid = Array("0123456789ABCDEF0123456789ABCDEF".utf8)
        let part = guid + [0xFF, 0xFF, 0xFF, 0xF0, 0, 0, 0, 0] + Array("<x/>".utf8)
        #expect(JPEGMarkers.extendedXMP([Data(part)], for: Data("xmpNote:HasExtendedXMP=\"".utf8 + guid)) == nil)
    }

    /// Google's XMP with lengths that aren't byte counts, entities that
    /// expand a billion times, nesting thousands deep, a hundred thousand
    /// items, unclosed elements: unreadable or read, never a crash.
    @Test func hostileGoogleXMP() throws {
        func directory(_ length: String) -> String {
            GoogleXMPSamples.directory(gainMapLength: 0).replacingOccurrences(of: "Item:Length=\"0\"", with: "Item:Length=\"\(length)\"")
        }
        for length in ["-1", "12a", "", "0x10", "99999999999999999999999"] {
            #expect(GoogleXMP.read(try GoogleXMPSamples.headers(directory(length))) == nil, "\(length)")
            let offset = "<rdf:Description xmlns:GCamera=\"\(GoogleXMP.camera)\" GCamera:MicroVideoOffset=\"\(length)\"/>"
            #expect(GoogleXMP.read(try GoogleXMPSamples.headers(offset)) == nil, "offset \(length)")
        }
        let ns = "xmlns:Container=\"\(GoogleXMP.container[0])\" xmlns:Item=\"\(GoogleXMP.item[0])\""
        let laughs = "<!DOCTYPE x [<!ENTITY a \"aaaaaaaaaa\">" + (1...9).map { n in
            "<!ENTITY \(Character(UnicodeScalar(97 + n)!)) \"" + String(repeating: "&\(Character(UnicodeScalar(96 + n)!));", count: 10) + "\">"
        }.joined() + "]>"
        let bomb = JPEGMarkers.write(0xE1, JPEGMarkers.xmpHeader + Array((laughs + GoogleXMPSamples.packet(
            "<rdf:Description \(ns)><Container:Directory><rdf:Seq><rdf:li><Item:Mime>&j;</Item:Mime></rdf:li></rdf:Seq></Container:Directory></rdf:Description>")).utf8))
        let deep = String(repeating: "<rdf:li>", count: 50_000) + String(repeating: "</rdf:li>", count: 50_000)
        let many = String(repeating: "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Length=\"7\"/></rdf:li>", count: 100_000)
        let descriptions = [
            "<rdf:Description \(ns)><Container:Directory><rdf:Seq>\(deep)</rdf:Seq></Container:Directory></rdf:Description>",
            "<rdf:Description \(ns)><Container:Directory><rdf:Seq>\(many)</rdf:Seq></Container:Directory></rdf:Description>",
            "<rdf:Description \(ns)><Container:Directory><rdf:Seq><rdf:li>",
        ]
        for description in descriptions {
            _ = GoogleXMP.read(try GoogleXMPSamples.headers(nil, extended: description))
        }
        #expect(GoogleXMP.read(try GoogleXMPSamples.headers(nil, extended: descriptions[1]))?.directories.first?.count == 100_000)
        let file = Data([0xFF, 0xD8]) + bomb + Data([0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9])
        #expect(GoogleXMP.read(try JPEGMarkers.headers(ByteView(file)).segments) == nil)
        #expect(GoogleXMP.read(try GoogleXMPSamples.headers(descriptions[2])) == nil)
        // An extended packet whose parts don't add up.
        var headers = try GoogleXMPSamples.headers(nil, extended: GoogleXMPSamples.directory(gainMapLength: 1))
        headers.removeLast()
        #expect(GoogleXMP.read(headers) == nil)
    }

    /// Compressed text that inflates to more than 64 MB (a zip bomb) is
    /// refused, not inflated.
    @Test func compressedTextBomb() throws {
        let zeros = [UInt8](repeating: 0, count: 70 << 20)
        var size = compressBound(uLong(zeros.count))
        var packed = [UInt8](repeating: 0, count: Int(size))
        #expect(compress2(&packed, &size, zeros, uLong(zeros.count), 9) == Z_OK)
        let itxt = Array(PNGChunks.xmpKeyword.utf8) + [0, 1, 0, 0, 0] + packed.prefix(Int(size))
        let chunk = PNGChunks.write("iTXt", itxt)
        let file = png([PNGChunks.write("IHDR", [UInt8](repeating: 1, count: 13)), chunk, PNGChunks.write("IEND", [])])
        let parsed = try PNGChunks.read(ByteView(file), strict: false)
        #expect(throws: FormatError.self) { try PNGChunks.text(parsed[1]) }
        _ = try? PNGMetadataFilter.filter(file, level: .removePrivate, orientation: 1)
    }

    /// Photoshop resources and IIM datasets with lengths that don't fit.
    @Test func hostileIPTC() {
        let resource: [UInt8] = Array("8BIM".utf8) + [0x04, 0x04, 0xFF] + [UInt8](repeating: 0x41, count: 5)
        let dataset: [UInt8] = Array("8BIM".utf8) + [0x04, 0x04, 0, 0, 0, 0, 0, 7, 0x1C, 2, 80, 0x80, 0x09, 0, 0]
        for block in [resource, dataset] {
            _ = IPTCFilter.filter(block, level: .removePrivate)
        }
    }

    /// What the writers write, the strict readers read back unchanged.
    @Test func writersAndReadersAgree() throws {
        let png = Data(PNGChunks.signature) + PNGChunks.write("IHDR", [UInt8](repeating: 1, count: 13))
            + PNGChunks.write("tEXt", Array("Ü\0text".utf8.dropFirst(0))) + PNGChunks.write("IEND", [])
        #expect(try PNGChunks.read(ByteView(png), strict: true).map(\.type) == ["IHDR", "tEXt", "IEND"])

        let webp = RIFFChunks.write(form: "WEBP", [("VP8X", Data(count: 10)), ("EXIF", Data([1, 2, 3])), ("XMP ", Data(count: 4))])
        let read = try RIFFChunks.read(ByteView(webp).view(from: 12), strict: true)
        #expect(read.complete && read.chunks.map(\.type) == ["VP8X", "EXIF", "XMP "])
        #expect(read.chunks[1].data.bytes == Data([1, 2, 3]))
        #expect(try ByteView(webp).le(4, 4) == webp.count - 8)

        let iptc = IPTCRecords.write([(0x0404, [], [0x1C, 2, 80, 0, 3] + Array("Ann".utf8)), (0x0425, Array("n".utf8), [UInt8](repeating: 7, count: 16))])
        let resources = try IPTCRecords.resources(ByteView(iptc), strict: true)
        #expect(resources.map(\.id) == [0x0404, 0x0425])
        #expect(try IPTCRecords.datasets(resources[0].data, strict: true).map(\.dataset) == [80])

        let segment = JPEGMarkers.write(0xE1, JPEGMarkers.exifHeader + [1, 2])
        let parsed = try JPEGMarkers.segment(at: 0, in: ByteView(segment))
        #expect(parsed.marker == 0xE1 && parsed.payload.bytes == Data(JPEGMarkers.exifHeader + [1, 2]))
    }
}
