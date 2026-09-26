import Foundation
import Testing
@testable import JustSmallerKit

struct ImageFormatTests {
    private func header(_ bytes: [UInt8], padTo count: Int = 32) -> Data {
        Data(bytes + [UInt8](repeating: 0, count: max(0, count - bytes.count)))
    }

    @Test func detectsByContentNotExtension() {
        let png = header([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(ImageFormat.detect(header: png, pathExtension: "jpg") == .png)
        #expect(ImageFormat.detect(header: header([0xFF, 0xD8, 0xFF, 0xE0]), pathExtension: "png") == .jpeg)
        #expect(ImageFormat.detect(header: header(Array("GIF89a".utf8)), pathExtension: "") == .gif)
        #expect(ImageFormat.detect(header: header(Array("RIFF\0\0\0\0WEBPVP8L".utf8)), pathExtension: "webp") == .webp)
    }

    @Test func tellsHEICFromAVIF() {
        func ftyp(_ major: String, _ compatible: [String]) -> Data {
            let brands = Array(major.utf8) + [0, 0, 0, 0] + compatible.flatMap { Array($0.utf8) }
            let size = 8 + brands.count
            return header([0, 0, 0, UInt8(size)] + Array("ftyp".utf8) + brands)
        }
        #expect(ImageFormat.detect(header: ftyp("heic", ["mif1", "heic"]), pathExtension: "heic") == .heic)
        #expect(ImageFormat.detect(header: ftyp("mif1", ["heic"]), pathExtension: "heif") == .heic)
        #expect(ImageFormat.detect(header: ftyp("avif", ["mif1", "avif"]), pathExtension: "heic") == nil)
    }

    @Test func svgNeedsExtensionAndElement() {
        let svg = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)
        #expect(ImageFormat.detect(header: svg, pathExtension: "svg") == .svg)
        #expect(ImageFormat.detect(header: svg, pathExtension: "txt") == nil)
        #expect(ImageFormat.detect(header: Data("hello world, not an image".utf8), pathExtension: "svg") == nil)
    }

    @Test func webPChunks() {
        func chunk(_ type: String, _ size: Int) -> [UInt8] {
            Array(type.utf8) + [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), 0, 0] + [UInt8](repeating: 0, count: size + (size & 1))
        }
        let lossless = Data(Array("RIFF\0\0\0\0WEBP".utf8) + chunk("VP8X", 10) + chunk("ICCP", 3) + chunk("VP8L", 5))
        let chunks = WebPChunks(lossless)
        #expect(chunks.contains("VP8L"))
        #expect(chunks.contains("ICCP"))
        #expect(!chunks.contains("VP8 "))
    }
}
