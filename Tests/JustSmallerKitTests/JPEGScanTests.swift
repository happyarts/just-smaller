import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

/// Tools/jpeg-scan on the JPEGs that are hard for a scan optimizer: sizes
/// that don't fill the last MCU, grayscale, CMYK, progressive input and
/// damaged data. Every result must hold exactly the input's coefficients.
@Suite(.serialized)
final class JPEGScanTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "JPEGScanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func jpeg(_ name: String, width: Int, height: Int, space: CFString = CGColorSpace.sRGB,
                      properties: [CFString: Any] = [:]) -> URL {
        let cs = CGColorSpace(name: space)!
        let components = cs.numberOfComponents
        let info = components == 4 ? CGImageAlphaInfo.none.rawValue
            : components == 1 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
        for y in 0..<height {
            for x in 0..<width {
                let a = CGFloat((x * 7 + y * 13) % 256) / 255, b = CGFloat((x * y) % 97) / 96
                let values: [CGFloat] = components == 4 ? [a, b, 1 - a, 0.2, 1] : components == 1 ? [a, 1] : [a, b, 1 - a, 1]
                ctx.setFillColor(CGColor(colorSpace: cs, components: values)!)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let url = dir.appending(path: name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// Runs a tool from build/tools and returns its exit status.
    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = toolsDirectory.appending(path: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private var hardCases: [URL] {
        [
            jpeg("tiny.jpg", width: 5, height: 3),
            jpeg("odd.jpg", width: 101, height: 37),
            jpeg("gray.jpg", width: 33, height: 21, space: CGColorSpace.linearGray),
            jpeg("cmyk.jpg", width: 40, height: 24, space: CGColorSpace.genericCMYK),
            jpeg("progressive.jpg", width: 70, height: 50,
                 properties: [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]]),
        ]
    }

    @Test func everyEffortKeepsTheCoefficients() throws {
        for input in hardCases {
            // The model's fast costing matches counting every band on its own,
            // and every plan follows T.81's progression rules.
            #expect(try run("jpeg-scan", ["--selftest", input.path, "unused"]) == 0, "\(input.lastPathComponent)")
            for effort in Effort.allCases {
                let output = dir.appending(path: "\(effort.rawValue)-\(input.lastPathComponent)")
                #expect(try run("jpeg-scan", ["--effort", effort.rawValue, input.path, output.path]) == 0,
                        "\(input.lastPathComponent) \(effort)")
                #expect(try run("jpegcmp", [input.path, output.path]) == 0, "\(input.lastPathComponent) \(effort)")
                // A second, independent decoder reads the whole file too.
                let source = CGImageSourceCreateWithURL(output as CFURL, nil)
                #expect(source.map { CGImageSourceGetStatus($0) == .statusComplete && CGImageSourceCreateImageAtIndex($0, 0, nil) != nil } == true,
                        "\(input.lastPathComponent) \(effort): ImageIO")
            }
        }
    }

    /// The own writer writes what libjpeg writes: without shared tables and
    /// with libjpeg's symbol order, the files are the same byte for byte from
    /// the frame header on.
    @Test func ownWriterMatchesLibjpeg() throws {
        for input in hardCases {
            let own = dir.appending(path: "own-\(input.lastPathComponent)")
            let lib = dir.appending(path: "lib-\(input.lastPathComponent)")
            #expect(try run("jpeg-scan", ["--like-libjpeg", input.path, own.path]) == 0)
            #expect(try run("jpeg-scan", ["--libjpeg", input.path, lib.path]) == 0)
            func fromFrame(_ url: URL) throws -> Data {
                let d = try Data(contentsOf: url)
                let sof = [UInt8(0xC0), 0xC1, 0xC2].compactMap { d.range(of: Data([0xFF, $0]))?.lowerBound }.min() ?? 0
                return d[sof...]
            }
            #expect(try fromFrame(own) == fromFrame(lib), "\(input.lastPathComponent)")
        }
    }

    /// EXIF must stay the first segment after JFIF, also in files whose
    /// Adobe marker libjpeg would otherwise write first (CMYK, RGB).
    @Test func exifStaysInFrontOfTheAdobeMarker() throws {
        let input = jpeg("cmyk-exif.jpg", width: 40, height: 24, space: CGColorSpace.genericCMYK,
                         properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Doe"]])
        let output = dir.appending(path: "out-cmyk-exif.jpg")
        #expect(try run("jpeg-scan", [input.path, output.path]) == 0)
        let markers = try JPEGMetadataFilter.segments(Data(contentsOf: output)).headers.map(\.marker).filter { (0xE0...0xEF).contains($0) }
        #expect(markers.first(where: { $0 != 0xE0 }) == 0xE1, "APP markers: \(markers)")
        #expect(markers.contains(0xEE))
    }

    /// libjpeg fills in what it can't read; a rewrite would make that final.
    @Test func damagedDataIsLeftAlone() throws {
        let good = try Data(contentsOf: jpeg("whole.jpg", width: 120, height: 80))
        let damaged = dir.appending(path: "damaged.jpg")
        try good.prefix(good.count * 2 / 3).write(to: damaged)
        #expect(try run("jpeg-scan", [damaged.path, dir.appending(path: "out-damaged.jpg").path]) == 3)
    }
}
