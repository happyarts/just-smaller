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
        _ = JPEGStructure.hasSecondaryImage(ByteView(jpeg))
        let webp = Data(Array("RIFF".utf8) + [0xFF, 0xFF, 0xFF, 0xFF] + Array("WEBPEXIF".utf8) + [0xFF, 0xFF, 0xFF, 0x7F, 0x4D])
        _ = try? WebPMetadataFilter.filter(webp, level: .removePrivate)
        let png = png([PNGChunks.write("IHDR", [UInt8](repeating: 1, count: 13)), Data([0x7F, 0xFF, 0xFF, 0xFF]) + Data("eXIf".utf8)])
        _ = try? PNGMetadataFilter.filter(png, level: .removePrivate, orientation: 1)
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
        #expect(JPEGMetadataFilter.reassembleExtendedXMP([part], for: Array("xmpNote:HasExtendedXMP=\"".utf8) + guid) == nil)
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
