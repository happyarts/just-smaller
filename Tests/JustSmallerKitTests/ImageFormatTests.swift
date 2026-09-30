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
        let lossless = RIFFChunks.write(form: "WEBP", [("VP8X", Data(count: 10)), ("ICCP", Data(count: 3)), ("VP8L", Data(count: 5))])
        let chunks = Set(RIFFChunks.webp(ByteView(lossless)).chunks.map(\.type))
        #expect(chunks.contains("VP8L"))
        #expect(chunks.contains("ICCP"))
        #expect(!chunks.contains("VP8 "))
    }
}
