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
        let result = dir.appending(path: "result-\(UUID().uuidString).\(original.pathExtension)")
        try Data(bytes).write(to: result)
        do {
            try StructureCheck.verify(original: original, result: result, format: format)
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
        for (url, format) in files {
            #expect(try !rejects(bytes(url), original: url, format), "\(url.lastPathComponent)")
        }
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
        (2..<b.count - 1).first { b[$0] == 0xFF && b[$0 + 1] == marker }!
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

    @Test func libjpegWarningsCount() async throws {
        let url = write("a.jpg", .jpeg)
        let b = try bytes(url)
        let truncated = dir.appending(path: "truncated.jpg")
        try Data(b.prefix(b.count * 2 / 3) + [0xFF, 0xD9]).write(to: truncated)
        await #expect(throws: ToolError.self) { try await ToolRunner.run("jpegcmp", ["--check", truncated.path], in: self.dir) }
        try await ToolRunner.run("jpegcmp", ["--check", url.path], in: dir)
    }

    // MARK: - PNG

    private func chunks(_ b: [UInt8]) -> [(type: String, whole: Range<Int>, data: Range<Int>)] {
        var out: [(String, Range<Int>, Range<Int>)] = [], i = 8
        while i + 12 <= b.count {
            let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            out.append((String(decoding: b[i + 4..<i + 8], as: UTF8.self), i..<i + 12 + n, i + 8..<i + 8 + n))
            i += 12 + n
        }
        return out
    }

    private func replacing(_ b: [UInt8], _ type: String, with payload: [UInt8]) -> [UInt8] {
        let c = chunks(b).first { $0.type == type }!
        return Array(b[..<c.whole.lowerBound]) + [UInt8](PNGMetadataFilter.chunk(type, payload)) + Array(b[c.whole.upperBound...])
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
        try Data(Array(plain[..<33]) + [UInt8](PNGMetadataFilter.chunk("pHYs", [0, 0, 11, 19, 0, 0, 11, 19, 1])) + Array(plain[33...]))
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

    // MARK: - HEIF

    @Test func damagedHEIFsAreRejected() throws {
        let url = write("a.heic", .heic)
        let b = try bytes(url)
        #expect(try rejects(Array(b.dropLast(1)), original: url, .heic), "truncated")
        #expect(try rejects(b + [0, 0, 0], original: url, .heic), "trailing bytes")
        var brand = b
        brand[8] = UInt8(ascii: "a")
        #expect(try rejects(brand, original: url, .heic), "brand changed")
    }
}
