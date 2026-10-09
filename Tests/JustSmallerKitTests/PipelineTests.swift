import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

struct PipelineTests {
    @Test func losslessUsesNoLossyTools() {
        let settings = OptimizationSettings()
        for format in ImageFormat.allCases {
            let facts = FileFacts(byteSize: 100_000, isLosslessWebP: true)
            for stage in Pipeline.stages(for: format, facts: facts, settings: settings) {
                #expect(stage.allSatisfy { !$0.isLossy }, "\(format) uses a lossy tool in lossless mode")
            }
        }
    }

    @Test func heicIsReencodedOnlyInLossyMode() {
        var settings = OptimizationSettings()
        settings.metadata = .keep
        let facts = FileFacts(byteSize: 1_000_000)
        #expect(Pipeline.stages(for: .heic, facts: facts, settings: settings).isEmpty)
        // Metadata is filtered without touching the image.
        settings.metadata = .removePrivate
        #expect(Pipeline.stages(for: .heic, facts: facts, settings: settings).flatMap { $0 }.map(\.isLossy) == [false])
        settings.lossy = true
        #expect(Pipeline.stages(for: .heic, facts: facts, settings: settings).flatMap { $0 }.map(\.isLossy) == [false, true])
        // 10-bit HDR photos would lose depth
        #expect(Pipeline.stages(for: .heic, facts: FileFacts(byteSize: 1, bitsPerComponent: 10), settings: settings)
            .flatMap { $0 }.map(\.isLossy) == [false])
    }

    @Test func lossyWebPAndAnimationsAreLeftAlone() {
        let settings = OptimizationSettings()
        #expect(Pipeline.stages(for: .webp, facts: FileFacts(byteSize: 1), settings: settings).isEmpty)
        #expect(Pipeline.stages(for: .webp, facts: FileFacts(byteSize: 1, isLosslessWebP: true, isAnimated: true), settings: settings).isEmpty)
    }

    @Test func gifIsLeftForALaterVersion() {
        #expect(Pipeline.stages(for: .gif, facts: FileFacts(byteSize: 100_000), settings: OptimizationSettings()).isEmpty)
    }

    @Test func svgIDsThatEditorsNumberAreGenerated() {
        for id in ["path1234", "g12-3", "layer1", "linearGradient4601", "feGaussianBlur88", "path-effect12", "path-1",
                   "svg2", "SVGID_1_", "SVGID_2_1_", "XMLID_7_", "Layer_1", "_Radial1", "clip0_12_34",
                   "paint0_linear_1_2", "filter0_d_3_4", "svg_1"] {
            #expect(SVGIDs.isGenerated(id), "\(id)")
        }
        for id in ["icon-home", "logo", "a", "a1", "p0", "path", "g", "Arrow2Send", "main-1", "costruttivo", "rect12x"] {
            #expect(!SVGIDs.isGenerated(id), "\(id)")
        }
    }

    @Test func svgIDsInSpritesAndViewsAllStay() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        func ids(_ body: String) throws -> [String]? {
            let url = dir.appending(path: "\(UUID().uuidString).svg")
            try Data("<svg xmlns=\"http://www.w3.org/2000/svg\">\(body)</svg>".utf8).write(to: url)
            return SVGIDs.toPreserve(in: url)
        }
        #expect(try ids(#"<g id="layer1"><path id="path12" d="M0 0h1"/><path id="arrow" d="M0 0h1"/></g>"#) == ["arrow"])
        #expect(try ids(#"<path id="arrow" d="M0 0h1"/>"#) == nil) // nothing generated
        #expect(try ids(#"<symbol id="symbol1"><path d="M0 0h1"/></symbol>"#) == nil)
        #expect(try ids(#"<view id="view1" viewBox="0 0 1 1"/><path id="path1" d="M0 0h1"/>"#) == nil)
        #expect(try ids(#"<path id="path1" d="M0 0h1">"#) == nil) // unreadable
        // Ids reached through a file name, maybe this file's own.
        #expect(try ids(#"<defs><path id="path5" d="M0 0h1"/></defs><use href="self.svg#path5"/>"#) == nil)
        #expect(try ids(#"<path id="path5" d="M0 0h1" fill="url(other.svg#linearGradient2)"/>"#) == nil)
        #expect(try ids(#"<path id="path5" d="M0 0h1" fill="url(#linearGradient2)"/><a href="https://example.com/"/>"#) == [])
    }

    @Test func svgConfigurationOmitsJobsAndPreservesIDs() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = try jobsIn(Pipeline.configuration(lossless: true, omitting: ["removeTitle"],
                                                   preservingIDs: ["logo"], in: dir))
        #expect(jobs["removeTitle"] == nil && jobs["applyTransforms"] != nil)
        // Matrix factors keep enough digits that large drawings don't move.
        #expect((jobs["convertTransform"] as? [String: Any])?["transformPrecision"] as? Int == 7)
        let ids = try #require(jobs["cleanupIds"] as? [String: Any])
        #expect(ids["remove"] as? Bool == true && ids["minify"] as? Bool == true && ids["preserve"] as? [String] == ["logo"])
        // Without a list every id stays, as bundled.
        let plain = try jobsIn(Pipeline.configuration(lossless: true, omitting: [], preservingIDs: nil, in: dir))
        #expect((plain["cleanupIds"] as? [String: Any])?["remove"] as? Bool == false)
    }

    /// Maximum runs OxiPNG twice, with Zopfli and as Thorough; animated PNGs
    /// get one run.
    @Test func pngCompressorsPerEffort() {
        func names(_ effort: Effort, animated: Bool = false) -> [String] {
            var settings = OptimizationSettings()
            settings.effort = effort
            var facts = FileFacts(byteSize: 1_000)
            facts.isAnimated = animated
            return Pipeline.stages(for: .png, facts: facts, settings: settings).last?.map(\.name) ?? []
        }
        #expect(names(.fast) == ["OxiPNG"])
        #expect(names(.balanced) == ["OxiPNG"])
        #expect(names(.thorough) == ["OxiPNG"])
        #expect(names(.maximum) == ["OxiPNG", "OxiPNG"])
        #expect(names(.maximum, animated: true) == ["OxiPNG"])
        #expect(Pipeline.oxipngZopfliOptions == ["-o", "max", "-f", "0-10", "--fast", "--zopfli", "--zi", "60", "--ziwi", "10"])
        // Section-wise filters from Balanced on; libdeflate 13, then 14.
        #expect(Pipeline.oxipngOptions(.fast) == ["-o", "2"])
        #expect(Pipeline.oxipngOptions(.balanced) == ["-o", "2", "-f", "0-9", "--zc", "13"])
        #expect(Pipeline.oxipngOptions(.thorough) == ["-o", "2", "-f", "0-9", "--zc", "14"])
        #expect(Pipeline.oxipngOptions(.maximum) == Pipeline.oxipngOptions(.thorough))
        // Every level's libdeflate run for still and animated PNGs; Zopfli
        // only next to it, for still PNGs at Maximum.
        for effort in Effort.allCases {
            let libdeflate = Pipeline.oxipngOptions(effort)
            #expect(Pipeline.oxipngRuns(effort, animated: true) == [libdeflate])
            #expect(Pipeline.oxipngRuns(effort, animated: false) == (effort == .maximum ? [Pipeline.oxipngZopfliOptions, libdeflate] : [libdeflate]))
        }
    }

    /// Lossy: the palette image is made from the file compressed without
    /// loss, compressed the same way and judged as the finished file against
    /// it. Animations get no palette.
    @Test func lossyPNGPaletteIsJudgedAgainstTheLosslessFile() throws {
        var settings = OptimizationSettings()
        settings.lossy = true
        func stages(animated: Bool) -> [[Candidate]] {
            var facts = FileFacts(byteSize: 1_000)
            facts.isAnimated = animated
            return Pipeline.stages(for: .png, facts: facts, settings: settings)
        }
        let metadata = Pipeline.pngMetadata(.keep, orientation: 1).name
        let still = stages(animated: false)
        #expect(still.map { $0.map(\.name) } == [[metadata], ["OxiPNG"], ["quantizr"], ["OxiPNG"]])
        let quantize = try #require(still[2].first)
        #expect(quantize.isLossy && quantize.judgedFinished && quantize.minimumGain == Pipeline.pngPaletteMinimumGain)
        #expect(Pipeline.pngPaletteMinimumGain > 0)
        #expect(stages(animated: true).map { $0.map(\.name) } == [[metadata], ["OxiPNG"]])
    }

    @Test func factsAboutAPNG() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "still.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, TestImages.pattern(width: 30, height: 20), nil)
        #expect(CGImageDestinationFinalize(dest))
        let facts = FileOptimizer.facts(about: url, format: .png, size: 1)
        #expect(!facts.isAnimated && facts.bitsPerComponent == 8)
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "PipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func jobsIn(_ configuration: URL) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: Any]
        return try #require((root?["optimise"] as? [String: Any])?["jobs"] as? [String: Any])
    }
}
