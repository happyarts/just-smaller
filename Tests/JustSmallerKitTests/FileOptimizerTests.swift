import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

/// Runs the real optimizers (built by Tools/build.sh into build/tools) on
/// generated images and checks the promises Just Smaller makes about every file.
let toolsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "build/tools")

@Suite(.serialized)
struct FileOptimizerTests {
    let dir: URL
    var settings = OptimizationSettings()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings.moveOriginalsToTrash = false
        ToolRunner.directory = toolsDirectory
    }

    // MARK: - Fixtures

    private func image(width: Int = 96, height: Int = 64, space: CFString = CGColorSpace.sRGB) -> CGImage {
        let cs = CGColorSpace(name: space)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                ctx.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                                 blue: (x / 8 + y / 8) % 2 == 0 ? 0.9 : 0.1, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    private func write(_ image: CGImage, _ name: String, type: UTType, properties: [CFString: Any] = [:]) -> URL {
        let url = dir.appending(path: name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private func props(_ url: URL) -> [CFString: Any] {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    private func iccName(_ url: URL) -> String? {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        // A palette image's colour space is indexed; its profile is the base.
        let space = CGImageSourceCreateImageAtIndex(src, 0, nil)?.colorSpace
        return (space?.name ?? space?.baseColorSpace?.name) as String?
    }

    private func optimize(_ url: URL) async throws -> Outcome {
        try await FileOptimizer(settings: settings).optimize(url) { _ in }
    }

    // MARK: - Tests

    @Test func pngGetsSmallerWithIdenticalPixels() async throws {
        let url = write(image(), "gradient.png", type: .png)
        let copy = dir.appending(path: "reference.png")
        try FileManager.default.copyItem(at: url, to: copy)

        guard case .optimized(let before, let after, let tools, _, _, let identical) = try await optimize(url) else {
            Issue.record("not optimized"); return
        }
        #expect(after < before)
        #expect(tools.contains("ECT") || tools.contains("OxiPNG"))
        #expect(identical)
        try await Verifier.verify(original: copy, result: url, format: .png, pixelsMustMatch: true)
    }

    @Test func jpegKeepsDisplayP3Profile() async throws {
        let url = write(image(space: CGColorSpace.displayP3), "p3.jpg", type: .jpeg,
                        properties: [kCGImageDestinationLossyCompressionQuality: 0.95])
        #expect(iccName(url) == CGColorSpace.displayP3 as String)
        _ = try await optimize(url)
        #expect(iccName(url) == CGColorSpace.displayP3 as String)
    }

    @Test(arguments: [1, 6, 8])
    func strippingRemovesPrivateDataButKeepsOrientationAndProfile(orientation: Int) async throws {
        #expect(settings.metadata == .strip)
        let url = write(image(space: CGColorSpace.displayP3), "photo-\(orientation).jpg", type: .jpeg,
                        properties: [kCGImagePropertyOrientation: orientation,
                                     kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.1,
                                                                     kCGImagePropertyGPSLatitudeRef: "N"],
                                     kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "SN12345"],
                                     kCGImageDestinationLossyCompressionQuality: 0.95])
        #expect(props(url)[kCGImagePropertyGPSDictionary] != nil)
        let reference = dir.appending(path: "reference-\(orientation).jpg")
        try FileManager.default.copyItem(at: url, to: reference)

        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        let after = props(url)
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        #expect((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifBodySerialNumber] == nil)
        #expect(after[kCGImagePropertyOrientation] as? Int ?? 1 == orientation)
        #expect(iccName(url) == CGColorSpace.displayP3 as String)
        try await Verifier.verify(original: reference, result: url, format: .jpeg, pixelsMustMatch: true)
    }

    @Test(arguments: [1, 6])
    func pngStrippingKeepsProfileAndOrientation(orientation: Int) async throws {
        let url = write(image(space: CGColorSpace.displayP3), "p3-\(orientation).png", type: .png,
                        properties: [kCGImagePropertyOrientation: orientation,
                                     kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "private note"]])
        let reference = dir.appending(path: "reference-\(orientation).png")
        try FileManager.default.copyItem(at: url, to: reference)

        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        let png = props(url)[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        #expect(png?[kCGImagePropertyPNGDescription] == nil)
        #expect(props(url)[kCGImagePropertyOrientation] as? Int ?? 1 == orientation)
        #expect(iccName(url) == CGColorSpace.displayP3 as String)
        try await Verifier.verify(original: reference, result: url, format: .png, pixelsMustMatch: true)
    }

    @Test func animatedPNGGoesToOxiPNG() async throws {
        let url = dir.appending(path: "animated.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 3, nil)!
        for _ in 0..<3 {
            CGImageDestinationAddImage(dest, image(), [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.2]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
        let reference = dir.appending(path: "reference-animated.png")
        try FileManager.default.copyItem(at: url, to: reference)

        if case .optimized(_, _, let tools, _, _, _) = try await optimize(url) {
            #expect(!tools.contains("ECT"))
        }
        try await Verifier.verify(original: reference, result: url, format: .png, pixelsMustMatch: true)
    }

    @Test func svgGetsSmallerAndLooksTheSame() async throws {
        let url = dir.appending(path: "editor.svg")
        let svg = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <!-- Created with an editor -->
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"
             width="200" height="120" viewBox="0 0 200 120" inkscape:version="1.3">
          <metadata><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/></metadata>
          <g id="layer1" inkscape:label="Layer 1">
            <rect x="10.000000" y="10.000000" width="80.000000" height="100.000000" style="fill:#ff0000;fill-opacity:1;stroke:none" />
            <circle cx="140.000000" cy="60.000000" r="40.000000" style="fill:#0000ff;stroke:#000000;stroke-width:2.000000" />
          </g>
        </svg>
        """
        try Data(svg.utf8).write(to: url)
        guard case .optimized(let before, let after, _, _, _, _) = try await optimize(url) else {
            Issue.record("not optimized"); return
        }
        #expect(after < before / 2)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("<svg"))
    }

    @Test func readOnlyFilesAndFoldersAreLeftAlone() async throws {
        let fm = FileManager.default
        let file = write(image(), "readonly.png", type: .png)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        let folder = dir.appending(path: "locked-folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let inFolder = folder.appending(path: "inside.png")
        try fm.copyItem(at: write(image(), "inside-src.png", type: .png), to: inFolder)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        for url in [file, inFolder] {
            let before = try Data(contentsOf: url)
            guard case .skipped = try await optimize(url) else { Issue.record("\(url.lastPathComponent) not skipped"); continue }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func suffixModeLeavesTheOriginalAlone() async throws {
        var settings = self.settings
        settings.outputLossless = .suffix
        settings.suffix = "-opt"
        let url = write(image(), "photo.png", type: .png)
        let original = try Data(contentsOf: url)
        let destination = OutputPlanner.destination(for: url, root: nil, settings: settings)
        #expect(destination == .newFile(dir.appending(path: "photo-opt.png"), includeUnchanged: false))

        guard case .optimized(_, let after, _, let result, nil, _) = try await FileOptimizer(settings: settings)
            .optimize(url, to: destination, progress: { _ in }) else { Issue.record("not optimized"); return }
        #expect(try Data(contentsOf: url) == original)
        #expect(result.lastPathComponent == "photo-opt.png")
        #expect(Int64(try Data(contentsOf: result).count) == after)
        try await Verifier.verify(original: url, result: result, format: .png, pixelsMustMatch: true)

        // Running again replaces the earlier result; the old one goes to the Trash.
        _ = try await FileOptimizer(settings: settings).optimize(url, to: destination, progress: { _ in })
        #expect(FileManager.default.fileExists(atPath: result.path))
        // Just Smaller's own results are not picked up again when scanning the folder.
        #expect(OutputPlanner.isOwnOutput(result, settings: settings))
        #expect(!OutputPlanner.isOwnOutput(url, settings: settings))
    }

    @Test func folderModeMirrorsSubfoldersAndCopiesUnchangedFiles() async throws {
        let fm = FileManager.default
        var settings = self.settings
        settings.outputLossless = .folder
        settings.outputFolder = dir.appending(path: "out").path
        let root = dir.appending(path: "Shoot")
        try fm.createDirectory(at: root.appending(path: "day1"), withIntermediateDirectories: true)
        let png = root.appending(path: "day1/a.png")
        try fm.moveItem(at: write(image(), "a.png", type: .png), to: png)
        // Already as small as it gets: copied unchanged so the folder is complete.
        let svg = root.appending(path: "tiny.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8).write(to: svg)

        for file in [png, svg] {
            let destination = OutputPlanner.destination(for: file, root: root, settings: settings)
            _ = try await FileOptimizer(settings: settings).optimize(file, to: destination, progress: { _ in })
        }
        #expect(fm.fileExists(atPath: dir.appending(path: "out/Shoot/day1/a.png").path))
        #expect(fm.fileExists(atPath: dir.appending(path: "out/Shoot/tiny.svg").path))
        #expect(fm.fileExists(atPath: png.path) && fm.fileExists(atPath: svg.path))
    }

    /// oxvg drops the quotes and comma from font-family lists, so text falls
    /// back to the default serif font. The rendering check must notice.
    @Test func svgWithChangedFontIsRejected() async throws {
        func svg(_ family: String) -> String {
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="400" height="200" viewBox="0 0 400 200">
              <rect width="400" height="200" fill="#fff"/>
              <text x="20" y="120" font-family="\(family)" font-size="72">Just Smaller 1200</text>
            </svg>
            """
        }
        let a = dir.appending(path: "font-a.svg"), b = dir.appending(path: "font-b.svg")
        try Data(svg("'No Such Font', sans-serif").utf8).write(to: a)
        try Data(svg("No Such Font sans-serif").utf8).write(to: b)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: a, result: b, format: .svg, pixelsMustMatch: true)
        }
    }

    /// A small detail vanishing (like a tiny island on a map) is lost
    /// content, even though it changes far fewer pixels than antialiasing.
    @Test func svgWithMissingDetailIsRejected() async throws {
        func svg(island: Bool) -> String {
            let dot = island ? "<circle cx=\"380\" cy=\"30\" r=\"2.5\" fill=\"#135\"/>" : ""
            return """
            <svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" viewBox="0 0 400 400">
              <rect width="400" height="400" fill="#bde"/>
              <path d="M40 200 C 80 60, 320 60, 360 200 S 80 340, 40 200 Z" fill="#ffe"/>
              \(dot)
            </svg>
            """
        }
        let a = dir.appending(path: "island-a.svg"), b = dir.appending(path: "island-b.svg")
        try Data(svg(island: true).utf8).write(to: a)
        try Data(svg(island: false).utf8).write(to: b)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: a, result: b, format: .svg, pixelsMustMatch: true)
        }
        // The same file against itself passes.
        try await Verifier.verify(original: a, result: a, format: .svg, pixelsMustMatch: true)
    }

    @Test func jpegCoefficientsAreCompared() async throws {
        let a = write(image(), "coef-a.jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
        let b = write(image(), "coef-b.jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.6])
        // A re-encode at another quality is a different image, whatever a viewer shows.
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: a, result: b, format: .jpeg, pixelsMustMatch: true)
        }
        // jpegtran's output carries the same coefficients and earns the seal.
        guard case .optimized(_, _, let tools, _, _, let identical) = try await optimize(a) else {
            Issue.record("not optimized"); return
        }
        #expect(tools.contains("jpegtran"))
        #expect(identical)
    }

    /// 16 bits per channel and the alpha channel must survive untouched.
    @Test func sixteenBitWithAlphaStaysExact() async throws {
        let w = 64, h = 48
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        for y in 0..<h {
            for x in 0..<w {
                // Values a 8-bit image can't hold, and a soft alpha ramp.
                ctx.setFillColor(red: CGFloat(x * 997 % 65_535) / 65_535, green: CGFloat(y) / CGFloat(h * 3),
                                 blue: 0.3337, alpha: CGFloat(x) / CGFloat(w))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let url = write(ctx.makeImage()!, "deep.png", type: .png)
        let reference = dir.appending(path: "deep-reference.png")
        try FileManager.default.copyItem(at: url, to: reference)
        #expect(props(url)[kCGImagePropertyDepth] as? Int == 16)

        _ = try await optimize(url)
        #expect(props(url)[kCGImagePropertyDepth] as? Int == 16)
        #expect(props(url)[kCGImagePropertyHasAlpha] as? Bool == true)
        try await Verifier.verify(original: reference, result: url, format: .png, pixelsMustMatch: true)
    }

    @Test func lossyJPEGReencodesWithJpegliAndKeepsMetadata() async throws {
        var settings = self.settings
        settings.lossy = true
        settings.quality = 70
        settings.metadata = .keep
        let url = write(image(width: 400, height: 300, space: CGColorSpace.displayP3), "lossy.jpg", type: .jpeg,
                        properties: [kCGImagePropertyOrientation: 6,
                                     kCGImageDestinationLossyCompressionQuality: 0.97])
        guard case .optimized(let before, let after, let tools, _, _, let identical) =
            try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        else { Issue.record("not optimized"); return }
        #expect(tools.contains("jpegli"))
        #expect(after < before)
        #expect(!identical)
        #expect(props(url)[kCGImagePropertyOrientation] as? Int == 6)
        #expect(iccName(url) == CGColorSpace.displayP3 as String)
    }

    @Test mutating func lossyPNGIsQuantizedWithoutLosingItsProfile() async throws {
        settings.lossy = true
        // Photo-like: gradients with grain, which a palette stores in a third of the bytes
        let cs = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var rng = SystemRandomNumberGenerator()
        for y in 0..<256 {
            for x in 0..<256 {
                let grain = CGFloat(Int.random(in: -6...6, using: &rng)) / 255
                ctx.setFillColor(red: CGFloat(x) / 256 + grain, green: 0.4 + grain, blue: CGFloat(y) / 256 + grain, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let url = write(ctx.makeImage()!, "quantize.png", type: .png)
        let before = try Data(contentsOf: url).count
        let outcome = try await optimize(url)
        guard case .optimized(_, _, let tools, _, _, _) = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(tools.contains("quantizr"), "\(tools)")
        #expect(try Data(contentsOf: url).count < before)
        #expect(iccName(url) == CGColorSpace.displayP3 as String)
    }

    @Test func lowQualityJPEGIsNotReencoded() async throws {
        var settings = self.settings
        settings.lossy = true
        settings.quality = 90
        let url = write(image(width: 400, height: 300), "already-small.jpg", type: .jpeg,
                        properties: [kCGImageDestinationLossyCompressionQuality: 0.4])
        #expect((JPEGQuality.estimate(try Data(contentsOf: url)) ?? 100) < 90)
        guard case .optimized(_, _, let tools, _, _, let identical) =
            try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        else { Issue.record("not optimized"); return }
        #expect(!tools.contains("jpegli"))
        #expect(identical)
    }

    @Test func jpegQualityEstimateRisesWithQuality() throws {
        let estimates = try [0.3, 0.6, 0.9].map { q in
            let url = write(image(), "q\(q).jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: q])
            return try #require(JPEGQuality.estimate(try Data(contentsOf: url)))
        }
        #expect(estimates[0] < estimates[1] && estimates[1] < estimates[2])
    }

    @Test func contentCredentialsAreLeftIntact() async throws {
        let plain = write(image(), "c2pa-source.jpg", type: .jpeg,
                          properties: [kCGImageDestinationLossyCompressionQuality: 0.95])
        var bytes = [UInt8](try Data(contentsOf: plain))
        // A minimal APP11 segment with a JUMBF superbox labelled "c2pa".
        let payload: [UInt8] = Array("JP".utf8) + [0, 1, 0, 0, 0, 1] + [0, 0, 0, 24] + Array("jumb".utf8)
            + [0, 0, 0, 16] + Array("jumd".utf8) + Array("c2pa".utf8) + [0, 0, 0, 0]
        let length = payload.count + 2
        bytes.insert(contentsOf: [0xFF, 0xEB, UInt8(length >> 8), UInt8(length & 0xFF)] + payload, at: 2)
        let url = dir.appending(path: "c2pa.jpg")
        try Data(bytes).write(to: url)

        guard case .skipped = try await optimize(url) else { Issue.record("must be skipped"); return }
        #expect(try Data(contentsOf: url) == Data(bytes))
    }

    @Test func appleCgBIPNGIsRecognised() throws {
        let url = dir.appending(path: "cgbi.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 4] + Array("CgBI".utf8) + [0x50, 0, 0x20, 0x06]).write(to: url)
        #expect(FileOptimizer.isAppleCgBI(url))
        #expect(!FileOptimizer.isAppleCgBI(write(image(), "plain.png", type: .png)))
    }

    @Test func metadataFilterRejectsGarbage() {
        #expect(throws: JPEGMetadataFilter.Malformed.self) {
            try JPEGMetadataFilter.strip(Data([0xFF, 0xD8, 0x00, 0x01, 0x02]), orientation: 1)
        }
        #expect(throws: JPEGMetadataFilter.Malformed.self) {
            try JPEGMetadataFilter.strip(Data("not a jpeg".utf8), orientation: 1)
        }
    }

    @Test func keepsPermissionsTagsAndCreationDate() async throws {
        let url = write(image(), "attrs.png", type: .png)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        var tagged = url
        var values = URLResourceValues()
        values.tagNames = ["Just Smaller"]
        values.creationDate = Date(timeIntervalSince1970: 1_000_000_000)
        try tagged.setResourceValues(values)

        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        #expect(attrs[.posixPermissions] as? Int == 0o640)
        let after = try url.resourceValues(forKeys: [.tagNamesKey, .creationDateKey])
        #expect(after.tagNames == ["Just Smaller"])
        #expect(after.creationDate == Date(timeIntervalSince1970: 1_000_000_000))
    }

    @Test func brokenFilesAreLeftAlone() async throws {
        let good = write(image(), "source.png", type: .png)
        let data = try Data(contentsOf: good)
        let truncated = dir.appending(path: "truncated.png")
        try data.prefix(data.count / 2).write(to: truncated)
        let text = dir.appending(path: "text.gif")
        try Data("not a gif at all".utf8).write(to: text)

        for url in [truncated, text] {
            let before = try Data(contentsOf: url)
            _ = try? await optimize(url)
            #expect(try Data(contentsOf: url) == before, "\(url.lastPathComponent) was modified")
        }
        guard case .skipped = try await optimize(truncated) else {
            Issue.record("a truncated PNG must be skipped, not attempted"); return
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(leftovers == ["source.png", "text.gif", "truncated.png"])
    }

    @Test func originalGoesToTrashAndCanBeFound() async throws {
        var settings = self.settings
        settings.moveOriginalsToTrash = true
        let url = write(image(), "trash me.png", type: .png)
        guard case .optimized(_, _, _, _, let trashed?, _) = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        else { Issue.record("no trashed original"); return }
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(trashed.lastPathComponent.hasPrefix("trash me ("))
        try? FileManager.default.removeItem(at: trashed)
    }
}
