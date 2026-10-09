import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

/// A chooser plugged into the optimizer: its encodings are the only lossy
/// step, and the finished file passes its check or is thrown away.
@Suite(.serialized)
final class QualityChooserTests {
    let dir: URL
    var settings = OptimizationSettings()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings.moveOriginalsToTrash = false
        settings.lossy = true
        settings.quality = 40
        settings.outputLossy = .replace
        ToolRunner.directory = toolsDirectory
        Trash.testFolder = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-Trash")
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// Tries the qualities in order and keeps the last encoding; records what
    /// it was asked.
    final class Chooser: QualityChooser, @unchecked Sendable {
        let qualities: [Int]
        let passes: Bool
        var otherFormatsLossless = true
        let lock = NSLock()
        var tried: [Int] = []
        /// The size of each finished file checked.
        var verified: [Int] = []
        var formats: Set<ImageFormat> { [.jpeg] }

        let fails: Bool

        init(_ qualities: [Int], passes: Bool = true, fails: Bool = false) {
            self.qualities = qualities
            self.passes = passes
            self.fails = fails
        }

        func choose(image: URL, output: URL, work: URL,
                    encode: @escaping @Sendable (Int, URL) async throws -> Void) async throws -> Bool {
            guard !qualities.isEmpty else { return false }
            if fails { throw Different() }
            for quality in qualities {
                lock.withLock { tried.append(quality) }
                try await encode(quality, output)
            }
            return true
        }

        func verify(original: URL, result: URL, format: ImageFormat, work: URL) async throws {
            let size = try Data(contentsOf: result).count
            lock.withLock { verified.append(size) }
            guard passes else { throw Different() }
        }
    }

    struct Different: LocalizedError { var errorDescription: String? { "looks different" } }

    private func jpeg(_ name: String, quality: Double) -> URL {
        let url = dir.appending(path: name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, TestImages.pattern(width: 400, height: 300),
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func theChosenEncodingIsUsedAndCheckedAsTheFinishedFile() async throws {
        let url = jpeg("photo.jpg", quality: 0.98)
        let chooser = Chooser([90, 75])
        guard case .optimized(let before, let after, let tools, _, _, let fidelity) =
            try await FileOptimizer(settings: settings, chooser: chooser).optimize(url, progress: { _ in })
        else { Issue.record("not optimized"); return }
        #expect(chooser.tried == [90, 75])
        #expect(tools.contains("jpegli") && fidelity == .lossy && after < before)
        #expect(chooser.verified == [Int(after)])
    }

    /// A finished file that fails the check, or a search that fails, leaves
    /// the result without loss.
    @Test(arguments: [false, true])
    func aFailedCheckLeavesTheLosslessResult(searchFails: Bool) async throws {
        let url = jpeg("photo.jpg", quality: 0.98)
        let chooser = Chooser([75], passes: false, fails: searchFails)
        guard case .optimized(_, _, let tools, _, _, let fidelity) =
            try await FileOptimizer(settings: settings, chooser: chooser).optimize(url, progress: { _ in })
        else { Issue.record("not optimized"); return }
        #expect(fidelity == .pixelIdentical && !tools.contains("jpegli"))
        #expect(chooser.verified.count == (searchFails ? 0 : 1))
    }

    /// Nothing passes: the JPEG is optimized as without loss.
    @Test func withoutAChoiceTheJPEGStaysLossless() async throws {
        let url = jpeg("photo.jpg", quality: 0.98)
        let chooser = Chooser([])
        switch try await FileOptimizer(settings: settings, chooser: chooser).optimize(url, progress: { _ in }) {
        case .optimized(_, _, let tools, _, _, let fidelity): #expect(fidelity == .pixelIdentical && !tools.contains("jpegli"))
        case .alreadyOptimal: break
        case let outcome: Issue.record("\(outcome)")
        }
        #expect(chooser.verified.isEmpty)
    }

    /// An encoding larger than the image is never used, whatever the chooser says.
    @Test func aLargerEncodingIsNotUsed() async throws {
        let url = jpeg("small.jpg", quality: 0.3)
        let chooser = Chooser([100])
        switch try await FileOptimizer(settings: settings, chooser: chooser).optimize(url, progress: { _ in }) {
        case .optimized(_, _, let tools, _, _, let fidelity): #expect(fidelity == .pixelIdentical && !tools.contains("jpegli"))
        case .alreadyOptimal: break
        case let outcome: Issue.record("\(outcome)")
        }
        #expect(chooser.tried == [100] && chooser.verified.isEmpty)
    }

    /// A chooser may leave the other formats to the settings' lossy steps;
    /// its check is then only for its own.
    @Test func otherFormatsCanKeepTheirLossySteps() async throws {
        let chooser = Chooser([80])
        chooser.otherFormatsLossless = false
        let png = Pipeline.stages(for: .png, facts: FileFacts(byteSize: 1), settings: settings, chooser: chooser)
        #expect(!png.joined().filter(\.isLossy).isEmpty)
        let jpeg = Pipeline.stages(for: .jpeg, facts: FileFacts(byteSize: 1, jpegQuality: 98), settings: settings, chooser: chooser)
        #expect(jpeg.joined().filter(\.isLossy).count == 1)
        let url = dir.appending(path: "photo.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        // Gradients with grain, many colours: quantizing pays.
        let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in 0..<256 {
            for x in 0..<256 {
                let grain = CGFloat(Int.random(in: -6...6)) / 255
                ctx.setFillColor(red: CGFloat(x) / 256 + grain, green: 0.4 + grain, blue: CGFloat(y) / 256 + grain, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        var settings = self.settings
        settings.quality = 85
        guard case .optimized(_, _, let tools, _, _, let fidelity) =
            try await FileOptimizer(settings: settings, chooser: chooser).optimize(url, progress: { _ in })
        else { Issue.record("not optimized"); return }
        #expect(tools.contains("quantizr") && fidelity == .lossy && chooser.verified.isEmpty, "\(tools) \(fidelity)")
    }

    /// The settings' fixed quality and every other lossy tool stay off; a
    /// format the chooser doesn't handle goes without loss.
    @Test func theChooserIsTheOnlyLossyStep() async throws {
        let chooser = Chooser([80])
        // After the lossless steps, then the scans of the encoding.
        let jpeg = Pipeline.stages(for: .jpeg, facts: FileFacts(byteSize: 1, jpegQuality: 98), settings: settings, chooser: chooser)
        #expect(jpeg.joined().filter(\.isLossy).count == 1)
        #expect(jpeg.map { $0.map(\.isLossy) }.suffix(2) == [[true], [false]] && jpeg.count > 2)
        for format in [ImageFormat.png, .heic, .svg, .webp] {
            let facts = FileFacts(byteSize: 1, isLosslessWebP: true)
            #expect(Pipeline.stages(for: format, facts: facts, settings: settings, chooser: chooser).joined()
                .allSatisfy { !$0.isLossy && !$0.changesHiddenColour })
        }
        // Without loss in the settings, no chooser is asked.
        var lossless = settings
        lossless.lossy = false
        #expect(Pipeline.stages(for: .jpeg, facts: FileFacts(byteSize: 1, jpegQuality: 98), settings: lossless, chooser: chooser)
            .joined().allSatisfy { !$0.isLossy })
    }

    /// An SVG beside a chooser that handles only JPEG: smaller, but without a
    /// lossy step in the result.
    @Test func anSVGBesideTheChooserStaysLossless() async throws {
        let url = dir.appending(path: "drawing.svg")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- Created with an editor -->
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="120" viewBox="0 0 200 120">
          <g id="layer1">
            <rect x="10.000000" y="10.000000" width="80.000000" height="100.000000" style="fill:#ff0000;stroke:none" />
          </g>
        </svg>
        """.utf8).write(to: url)
        guard case .optimized(_, _, _, _, _, let fidelity) =
            try await FileOptimizer(settings: settings, chooser: Chooser([80])).optimize(url, progress: { _ in })
        else { Issue.record("not optimized"); return }
        #expect(fidelity == .lossless)
    }
}
