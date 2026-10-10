import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import zlib
@testable import JustSmallerKit

/// The strict structure check: sound files pass, and each kind of damage a
/// careless rewrite could cause is caught — also where a lenient decoder
/// would still show the picture.
@Suite(.serialized)
final class StructureCheckTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "StructureCheckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ToolRunner.directory = toolsDirectory
    }
    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func image(width: Int = 64, height: Int = 48) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                ctx.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: CGFloat((x * y) % 7) / 7, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    private func write(_ name: String, _ type: UTType, _ properties: [CFString: Any] = [:]) -> URL {
        let url = dir.appending(path: name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// Whether the check rejects `bytes` as the result of optimizing `original`.
    private func rejects(_ bytes: [UInt8], original: URL, _ format: ImageFormat) throws -> Bool {
        do {
            try StructureCheck.verify(ByteView(bytes), against: StructureCheck.Reference(original: original, format: format))
            return false
        } catch is VerificationError {
            return true
        }
    }

    private func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

    private func webp() async throws -> URL {
        let ppm = dir.appending(path: "in.ppm")
        var pixels: [UInt8] = Array("P6\n64 48\n255\n".utf8)
        for i in 0..<64 * 48 { pixels += [UInt8(i % 64 * 4), UInt8(i / 64 * 5), UInt8(i % 7 * 30)] }
        try Data(pixels).write(to: ppm)
        let url = dir.appending(path: "in.webp")
        try await ToolRunner.run("cwebp", ["-quiet", "-lossless", "-o", url.path, "--", ppm.path], in: dir)
        return url
    }

    @Test func soundFilesPass() async throws {
        let files: [(URL, ImageFormat)] = [
            (write("a.jpg", .jpeg), .jpeg),
            (write("p.jpg", .jpeg, [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]]), .jpeg),
            (write("a.png", .png), .png),
            (write("a.heic", .heic), .heic),
            (try await webp(), .webp),
        ]
        // Sound originals don't count as damaged either, a JPEG with a gain map included.
        let gainMap = TestImages.gainMapPhoto(at: dir.appending(path: "gain-map.jpg"))
        for (url, format) in files + [(gainMap, .jpeg)] {
            #expect(try !rejects(bytes(url), original: url, format), "\(url.lastPathComponent)")
            #expect(StructureCheck.damage(of: url, format: format) == nil, "\(url.lastPathComponent)")
        }
        // An index whose first size runs past the photo, as cameras write it:
        // read as it means, so sound, though a result must have it exact.
        let photo = try Data(contentsOf: gainMap)
        func be32(_ v: Int) -> Data { Data(withUnsafeBytes(of: UInt32(v).bigEndian, Array.init)) }
        let size = try #require(JPEGLayout.read(ByteView(photo))?.images.first?.count)
        let mpf = try #require(try JPEGMarkers.headers(ByteView(photo)).segments.first { $0.marker == 0xE2 && $0.payload.bytes.starts(with: Data("MPF\0".utf8)) })
        let at = try #require(photo.range(of: be32(size) + be32(0), in: mpf.offset..<mpf.end)).lowerBound
        let camera = dir.appending(path: "camera-index.jpg")
        try (photo[..<at] + be32(size + 70) + photo[(at + 4)...]).write(to: camera)
        #expect(JPEGLayout.read(ByteView(try Data(contentsOf: camera)))?.problem == nil)
        #expect(try rejects(bytes(camera), original: camera, .jpeg))
        #expect(StructureCheck.damage(of: camera, format: .jpeg) == nil)
        // jpeg-scan's rewrite of both JPEGs.
        for (url, _) in files.prefix(2) {
            let out = dir.appending(path: "scan-\(url.lastPathComponent)")
            try await ToolRunner.run("jpeg-scan", [url.path, out.path], in: dir)
            #expect(try !rejects(bytes(out), original: url, .jpeg), "\(url.lastPathComponent)")
        }
    }

    // MARK: - JPEG

    /// Where the first segment with `marker` starts.
    private func segment(_ b: [UInt8], _ marker: UInt8) -> Int {
        let found = try! JPEGMarkers.headers(ByteView(b))
        return marker == 0xDA ? found.scan : found.segments.first { $0.marker == marker }!.offset
    }

    @Test func damagedJPEGsAreRejected() throws {
        let url = write("a.jpg", .jpeg)
        let b = try bytes(url)
        #expect(try rejects(Array(b.dropLast(2)), original: url, .jpeg), "no EOI")
        #expect(try rejects(b + Array("trailing data".utf8), original: url, .jpeg), "data after EOI")

        var badClass = b
        badClass[segment(b, 0xC4) + 4] = 0x05 // Huffman table class/id
        #expect(try rejects(badClass, original: url, .jpeg), "DHT")

        var undefinedTable = b
        let sos = segment(b, 0xDA)
        undefinedTable[sos + 6] = 0x33 // first component: DC/AC table 3
        #expect(try rejects(undefinedTable, original: url, .jpeg), "table not defined")

        var profile = b
        let icc = segment(b, 0xE2)
        profile[icc + 40] ^= 1
        #expect(try rejects(profile, original: url, .jpeg), "ICC profile changed")

        let sof = segment(b, 0xC0)
        let length = Int(b[sof + 2]) << 8 | Int(b[sof + 3])
        let secondFrame = Array(b[..<sos]) + Array(b[sof..<sof + 2 + length]) + Array(b[sos...])
        #expect(try rejects(secondFrame, original: url, .jpeg), "second frame")

        let junk = Array(b[..<sos]) + [0x12, 0x34] + Array(b[sos...])
        #expect(try rejects(junk, original: url, .jpeg), "bytes between segments")
    }

    @Test func progressionRulesAreChecked() throws {
        let url = write("p.jpg", .jpeg, [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]])
        let b = try bytes(url)
        // Swap the first two scans: an AC scan (or refinement) before its DC scan.
        var starts: [Int] = []
        var i = segment(b, 0xDA)
        while i + 1 < b.count {
            if b[i] == 0xFF, b[i + 1] == 0xDA { starts.append(i) }
            if b[i] == 0xFF, b[i + 1] == 0xD9 { break }
            i += 1
        }
        let ends = Array(starts.dropFirst()) + [b.count - 2]
        guard starts.count > 2 else { Issue.record("not progressive"); return }
        // The first scan is DC; drop it, so every AC scan comes first.
        let withoutDC = Array(b[..<starts[0]]) + Array(b[ends[0]...])
        #expect(try rejects(withoutDC, original: url, .jpeg))
    }

    /// A lossless JPEG is sound without quantization tables, and not
    /// damaged; a result of one still can't be proven (jpegcmp reads DCT
    /// coefficients, which it has none of), so it is rejected.
    @Test func losslessJPEGIsSoundButNotProven() async throws {
        let url = dir.appending(path: "lossless.jpg")
        try TestImages.losslessJPEG.write(to: url)
        #expect(try JPEGMarkers.frame(JPEGMarkers.headers(ByteView(TestImages.losslessJPEG)).segments)?.marker == 0xC3)
        #expect(try !rejects(bytes(url), original: url, .jpeg))
        #expect(StructureCheck.damage(of: url, format: .jpeg) == nil)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: url, result: url, format: .jpeg, pixelsMustMatch: true)
        }
        // A DCT JPEG still needs the table its components name.
        let dct = write("dct.jpg", .jpeg)
        var undefined = try bytes(dct)
        undefined[segment(undefined, 0xC0) + 4 + 8] = 3 // first component: quantization table 3
        #expect(try rejects(undefined, original: dct, .jpeg))
    }

    @Test func libjpegWarningsCount() async throws {
        let url = write("a.jpg", .jpeg)
        let b = try bytes(url)
        let truncated = dir.appending(path: "truncated.jpg")
        try Data(b.prefix(b.count * 2 / 3) + [0xFF, 0xD9]).write(to: truncated)
        await #expect(throws: ToolError.self) { try await ToolRunner.run("jpegcmp", ["--check", truncated.path], in: self.dir) }
        try await ToolRunner.run("jpegcmp", ["--check", url.path], in: dir)
    }

    // MARK: - PNG

    /// Each chunk's type and where it and its payload are in `b`.
    private func chunks(_ b: [UInt8]) -> [(type: String, whole: Range<Int>, data: Range<Int>)] {
        ((try? PNGChunks.read(ByteView(b), strict: false)) ?? []).map { ($0.type, $0.whole.bytes.indices, $0.data.bytes.indices) }
    }

    private func replacing(_ b: [UInt8], _ type: String, with payload: [UInt8]) -> [UInt8] {
        let c = chunks(b).first { $0.type == type }!
        return Array(b[..<c.whole.lowerBound]) + [UInt8](PNGChunks.write(type, payload)) + Array(b[c.whole.upperBound...])
    }

    private func zlibCompress(_ raw: [UInt8]) -> [UInt8] {
        var size = compressBound(uLong(raw.count))
        var out = [UInt8](repeating: 0, count: Int(size))
        #expect(compress(&out, &size, raw, uLong(raw.count)) == Z_OK)
        return Array(out.prefix(Int(size)))
    }

    private func zlibInflate(_ data: [UInt8], size: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size)
        var length = uLong(size)
        #expect(uncompress(&out, &length, data, uLong(data.count)) == Z_OK)
        return Array(out.prefix(Int(length)))
    }

    @Test func damagedPNGsAreRejected() throws {
        let url = write("a.png", .png)
        // A pixel density (pHYs) right after IHDR.
        let plain = try bytes(url)
        try Data(Array(plain[..<33]) + [UInt8](PNGChunks.write("pHYs", [0, 0, 11, 19, 0, 0, 11, 19, 1])) + Array(plain[33...]))
            .write(to: url)
        let b = try bytes(url)
        let idat = chunks(b).first { $0.type == "IDAT" }!

        var crc = b
        crc[idat.whole.upperBound - 1] ^= 1
        #expect(try rejects(crc, original: url, .png), "CRC")
        #expect(try rejects(b + [0], original: url, .png), "data after IEND")

        let pHYs = chunks(b).first { $0.type == "pHYs" }!
        var density = Array(b[pHYs.data])
        density[3] ^= 1
        #expect(try rejects(replacing(b, "pHYs", with: density), original: url, .png), "pHYs changed")

        let raw = zlibInflate(Array(b[idat.data]), size: 64 * 48 * 4 + 48 + 1024)
        var badFilter = raw
        badFilter[0] = 7
        #expect(try rejects(replacing(b, "IDAT", with: zlibCompress(badFilter)), original: url, .png), "filter byte")
        #expect(try rejects(replacing(b, "IDAT", with: zlibCompress(Array(raw.dropLast()))), original: url, .png), "row missing")
        #expect(try rejects(replacing(b, "IDAT", with: Array(b[idat.data].dropLast(4))), original: url, .png), "no Adler-32")
        #expect(try !rejects(replacing(b, "IDAT", with: zlibCompress(raw)), original: url, .png), "recompressed")

        // IDAT before PLTE-dependent chunks: move pHYs behind the image data.
        let moved = chunks(b).filter { $0.type != "pHYs" }.flatMap { c in
            Array(b[c.whole]) + (c.type == "IDAT" ? Array(b[pHYs.whole]) : [])
        }
        #expect(try rejects(Array(b[..<8]) + moved, original: url, .png), "pHYs after IDAT")
    }

    /// The original is read leniently: data after its IEND doesn't make
    /// every chunk of the result count as changed.
    @Test func unusualOriginalsStillCount() throws {
        let url = write("a.png", .png)
        let plain = try bytes(url)
        let withDensity = Array(plain[..<33]) + [UInt8](PNGChunks.write("pHYs", [0, 0, 11, 19, 0, 0, 11, 19, 1])) + Array(plain[33...])
        let original = dir.appending(path: "trailing.png")
        try Data(withDensity + Array("trailing".utf8)).write(to: original)
        #expect(try !rejects(withDensity, original: original, .png))
    }

    // MARK: - WebP

    private func riff(_ chunks: [UInt8]) -> [UInt8] {
        let n = chunks.count + 4
        return Array("RIFF".utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)] + Array("WEBP".utf8) + chunks
    }

    @Test func damagedWebPsAreRejected() async throws {
        let url = try await webp()
        let b = try bytes(url)
        let image = Array(b[12...])
        var size = b
        size[4] &+= 2
        #expect(try rejects(size, original: url, .webp), "RIFF size")

        func vp8x(_ flags: UInt8) -> [UInt8] { Array("VP8X".utf8) + [10, 0, 0, 0, flags, 0, 0, 0, 63, 0, 0, 47, 0, 0] }
        #expect(try !rejects(riff(vp8x(0) + image), original: url, .webp), "extended, no flags")
        #expect(try rejects(riff(vp8x(0x20) + image), original: url, .webp), "ICC flag without ICCP")
        #expect(try rejects(riff(vp8x(0x08) + image), original: url, .webp), "EXIF flag without EXIF")
        var canvas = vp8x(0)
        canvas[12] = 62
        #expect(try rejects(riff(canvas + image), original: url, .webp), "canvas size")
        #expect(try rejects(riff(image + Array("EXIF".utf8) + [2, 0, 0, 0, 1, 2]), original: url, .webp), "chunk after a simple image")
    }

    // MARK: - Metadata a step wrote

    private func appSegment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] { [UInt8](JPEGMarkers.write(marker, payload)) }

    /// The file with `segment` right after SOI.
    private func inserting(_ segment: [UInt8], into b: [UInt8]) -> [UInt8] { Array(b[..<2]) + segment + Array(b[2...]) }

    @Test func rewrittenMetadataIsCheckedToo() throws {
        let url = write("a.jpg", .jpeg)
        let b = try bytes(url)
        let exif = JPEGMarkers.exifHeader
        // TIFF header, IFD0 with one entry: Artist (ASCII, 20 bytes) at an offset past the end.
        let tiff: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x3B, 0, 2, 0, 0, 0, 20, 0, 0, 0x10, 0, 0, 0, 0, 0]
        #expect(try rejects(inserting(appSegment(0xE1, exif + tiff), into: b), original: url, .jpeg), "EXIF value outside")
        var sound = tiff
        sound[21] = 26; sound[20] = 0 // the value right after the IFD
        #expect(try !rejects(inserting(appSegment(0xE1, exif + sound + Array(repeating: 0x41, count: 20)), into: b), original: url, .jpeg),
                "sound EXIF")
        let xmp = JPEGMarkers.xmpHeader
        #expect(try rejects(inserting(appSegment(0xE1, xmp + Array("<x:xmpmeta><rdf".utf8)), into: b), original: url, .jpeg), "XMP")
        let photoshop = JPEGMarkers.photoshopHeader
        let resource = Array("8BIM".utf8) + [0x04, 0x04, 0, 0, 0, 0, 0, 12] + [0x1C, 2, 80, 0, 20] + Array("Jane".utf8) + [0, 0, 0]
        #expect(try rejects(inserting(appSegment(0xED, photoshop + resource), into: b), original: url, .jpeg), "IPTC length")

        // A broken segment the original already had is the original's, not ours.
        let broken = dir.appending(path: "broken-exif.jpg")
        let withBrokenEXIF = inserting(appSegment(0xE1, exif + tiff), into: b)
        try Data(withBrokenEXIF).write(to: broken)
        #expect(try !rejects(withBrokenEXIF, original: broken, .jpeg))
    }

    /// What we write follows the specification even where the original
    /// didn't: EXIF in front of the image data moves behind it.
    @Test func writtenWebPIsInOrder() async throws {
        let url = try await webp()
        let image = Array(try bytes(url)[12...])
        let tiff = JPEGMetadataFilter.minimalTIFF(orientation: 1)
        let exif = Array("EXIF".utf8) + [UInt8(tiff.count), 0, 0, 0] + tiff
        let vp8x = Array("VP8X".utf8) + [10, 0, 0, 0, 0x08, 0, 0, 0, 63, 0, 0, 47, 0, 0]
        let original = dir.appending(path: "exif-first.webp")
        try Data(riff(vp8x + exif + image)).write(to: original)
        #expect(try rejects(bytes(original), original: original, .webp), "the original's order is wrong")
        let written = try WebPMetadataFilter.filter(Data(contentsOf: original), level: .keep)
        #expect(try !rejects([UInt8](written), original: original, .webp))
    }

    // MARK: - HEIF

    @Test func damagedHEIFsAreRejected() throws {
        let url = write("a.heic", .heic)
        let b = try bytes(url)
        let pitm = (0..<b.count - 4).first { b[$0..<$0 + 4].elementsEqual("pitm".utf8) }!
        var missingItem = b
        missingItem[pitm + 8] = 0x77; missingItem[pitm + 9] = 0x77
        #expect(try rejects(missingItem, original: url, .heic), "primary item missing")
        #expect(try rejects(Array(b.dropLast(1)), original: url, .heic), "truncated")
        #expect(try rejects(b + [0, 0, 0], original: url, .heic), "trailing bytes")
        var brand = b
        brand[8] = UInt8(ascii: "a")
        #expect(try rejects(brand, original: url, .heic), "brand changed")
    }

    // MARK: - Fuzzing

    /// Thousands of damaged versions of sound files: the check must never
    /// stop the app, and must reject every truncated file.
    @Test func damageNeverCrashesTheCheck() async throws {
        var seed: UInt64 = 0x5EED
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(n, 1)))
        }
        let files: [(URL, ImageFormat)] = [
            (write("f.jpg", .jpeg), .jpeg),
            (write("fp.jpg", .jpeg, [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]]), .jpeg),
            (write("f.png", .png), .png),
            (write("f.heic", .heic), .heic),
            (try await webp(), .webp),
        ]
        for (url, format) in files {
            let b = try bytes(url)
            let reference = StructureCheck.Reference(original: url, format: format)
            for _ in 0..<4000 {
                var m = b
                switch random(4) {
                case 0: m[random(m.count)] = UInt8(random(256))
                case 1: m.insert(contentsOf: (0..<1 + random(8)).map { _ in UInt8(random(256)) }, at: random(m.count))
                case 2: m.removeSubrange(random(m.count / 2)..<m.count / 2 + random(m.count / 2))
                default:
                    let cut = random(m.count - 1)
                    // A sound file cut short is never sound.
                    #expect(throws: VerificationError.self, "\(url.lastPathComponent) cut at \(cut)") {
                        try StructureCheck.verify(ByteView(Array(m.prefix(cut))), against: reference)
                    }
                    continue
                }
                _ = try? StructureCheck.verify(ByteView(m), against: reference)
            }
        }
    }
}
