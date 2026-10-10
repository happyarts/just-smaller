import Foundation
import Testing
@testable import JustSmallerKit

/// SVG in UTF-16 becomes the same text in UTF-8 — proven on the text, since
/// the renderer can't read the original.
@Suite(.serialized)
final class SVGTextTests {
    let dir: URL
    let svg = """
    <?xml version="1.0" encoding="UTF-16"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="40" height="30"><title>Grüße 👋</title>
      <rect x="5" y="5" width="30" height="20" fill="#3060c0"/>
    </svg>

    """

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "SVGTextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ToolRunner.directory = toolsDirectory
        Trash.testFolder = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-Trash")
    }
    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func encoded(_ text: String, bigEndian: Bool, bom: Bool) -> Data {
        (bom ? Data(bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) : Data()) + text.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian)!
    }

    @Test func everyByteOrderBecomesTheSameUTF8() throws {
        let expected = Data(svg.replacingOccurrences(of: "UTF-16", with: "UTF-8").utf8)
        for bigEndian in [false, true] {
            for bom in [false, true] {
                let data = encoded(svg, bigEndian: bigEndian, bom: bom)
                #expect(SVGText.encoding(data) == .utf16(bigEndian: bigEndian, bom: bom))
                #expect(ImageFormat.detect(header: data, pathExtension: "svg") == .svg)
                let converted = try #require(SVGText.utf8(data))
                #expect(converted == expected)
                #expect(SVGText.isSameText(original: data, result: converted))
            }
        }
    }

    @Test func anyOtherChangeIsCaught() throws {
        let data = encoded(svg, bigEndian: false, bom: true)
        let converted = try #require(SVGText.utf8(data))
        // The same letter, composed differently: equal as Swift strings, not as text.
        let decomposed = Data(String(decoding: converted, as: UTF8.self).replacingOccurrences(of: "ü", with: "u\u{0308}").utf8)
        #expect(!SVGText.isSameText(original: data, result: decomposed))
        #expect(!SVGText.isSameText(original: data, result: converted.dropLast()))
        // Without byte order mark and declaration it's no XML browsers read.
        let bare = encoded(String(svg.drop { $0 != "\n" }.dropFirst()), bigEndian: true, bom: false)
        #expect(SVGText.encoding(bare) == .utf8)
        // A lone surrogate can't be decoded without loss.
        #expect(SVGText.utf8(data + Data([0x00, 0xD8])) == nil)
    }

    @Test func contentCredentialsAreFoundInUTF16() throws {
        let url = dir.appending(path: "signed.svg")
        try encoded(svg.replacingOccurrences(of: "</svg>", with: "<c2pa:manifest>AAAA</c2pa:manifest></svg>"), bigEndian: false, bom: true)
            .write(to: url)
        #expect(FileOptimizer.hasContentCredentials(url, format: .svg))
    }

    @Test func optimizerConvertsAndKeepsTheFile() async throws {
        let url = dir.appending(path: "logo.svg")
        let original = encoded(svg, bigEndian: true, bom: false)
        try original.write(to: url)
        var settings = OptimizationSettings()
        settings.moveOriginalsToTrash = false
        let outcome = try await FileOptimizer(settings: settings).optimize(url) { _ in }
        guard case .optimized(_, let size, let tools, _, _, _, _) = outcome else {
            Issue.record("not optimized: \(outcome)")
            return
        }
        #expect(tools.first == "UTF-8")
        #expect(size < Int64(original.count) * 6 / 10)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("UTF-16"))
        #expect(text.contains("Grüße 👋") || !text.contains("<title>"))
    }
}
