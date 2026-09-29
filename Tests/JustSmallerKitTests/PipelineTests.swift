import Foundation
import Testing
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

    @Test func preciseSVGConfigurationKeepsDigitsAndTransforms() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = try jobsIn(Pipeline.configuration(lossless: true, omitting: ["removeTitle"], precise: true,
                                                   preservingIDs: ["logo"], in: dir))
        #expect(jobs["applyTransforms"] == nil && jobs["removeTitle"] == nil)
        #expect((jobs["convertTransform"] as? [String: Any])?["transformPrecision"] as? Int == 9)
        #expect(((jobs["convertPathData"] as? [String: Any])?["tolerance"] as? [String: Any])?["precision"] as? Int == 7)
        let ids = try #require(jobs["cleanupIds"] as? [String: Any])
        #expect(ids["remove"] as? Bool == true && ids["minify"] as? Bool == true && ids["preserve"] as? [String] == ["logo"])
        // Without a list every id stays, as bundled.
        let plain = try jobsIn(Pipeline.configuration(lossless: true, omitting: [], precise: false, preservingIDs: nil, in: dir))
        #expect((plain["cleanupIds"] as? [String: Any])?["remove"] as? Bool == false)
        #expect(plain["applyTransforms"] != nil)
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
