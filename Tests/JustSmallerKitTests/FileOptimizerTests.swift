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
final class FileOptimizerTests {
    let dir: URL
    var settings = OptimizationSettings()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings.moveOriginalsToTrash = false
        ToolRunner.directory = toolsDirectory
        // Never the user's Trash, also where a test uses the Trash on purpose.
        Trash.testFolder = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-Trash")
    }
    deinit {
        try? FileManager.default.removeItem(at: dir)
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
        guard case .optimized = try await optimize(url) else { Issue.record("not optimized, nothing checked"); return }
        #expect(iccName(url) == CGColorSpace.displayP3 as String)
    }

    @Test(arguments: [1, 6, 8])
    func removingPrivateDataKeepsOrientationAndProfile(orientation: Int) async throws {
        #expect(settings.metadata == .removePrivate)
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
    func pngFilteringKeepsProfileAndOrientation(orientation: Int) async throws {
        let url = write(image(space: CGColorSpace.displayP3), "p3-\(orientation).png", type: .png,
                        properties: [kCGImagePropertyOrientation: orientation,
                                     kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGSoftware: "SecretApp",
                                                                     kCGImagePropertyPNGCopyright: "© Me"]])
        let reference = dir.appending(path: "reference-\(orientation).png")
        try FileManager.default.copyItem(at: url, to: reference)

        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        let png = props(url)[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        #expect(png?[kCGImagePropertyPNGSoftware] == nil)
        #expect(png?[kCGImagePropertyPNGCopyright] as? String == "© Me")
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

        guard case .optimized(_, _, let tools, _, _, _) = try await optimize(url) else {
            Issue.record("not optimized, nothing checked"); return
        }
        #expect(!tools.contains("ECT"))
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

    @Test(arguments: [
        "<script>alert(1)</script>",
        "<circle cx=\"50\" cy=\"50\" r=\"20\"><animate attributeName=\"r\" values=\"20;40\" dur=\"1s\"/></circle>",
        "<foreignObject width=\"100\" height=\"50\"><div xmlns=\"http://www.w3.org/1999/xhtml\">Hi</div></foreignObject>",
        "<style>@media (prefers-color-scheme: dark) { rect { fill: #000 } }</style><rect width=\"10\" height=\"10\"/>",
        "<rect width=\"10\" height=\"10\" onclick=\"go()\"/>",
    ])
    func svgThatCantBeCheckedIsLeftAlone(content: String) async throws {
        let url = dir.appending(path: "dynamic.svg")
        let svg = "<?xml version=\"1.0\"?>\n<!-- comment -->\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">  \(content)  </svg>\n"
        try Data(svg.utf8).write(to: url)
        guard case .skipped = try await optimize(url) else { Issue.record("not skipped"); return }
        #expect(try String(contentsOf: url, encoding: .utf8) == svg)
    }

    /// A thin line vanishing in a large drawing: at a small preview size it
    /// is a fraction of a pixel, so the check renders at the drawing's size.
    @Test func svgWithMissingHairlineIsRejected() async throws {
        func svg(line: Bool) -> String {
            let hairline = line ? "<path d=\"M1400 1200 L1500 1250\" stroke=\"#000\" stroke-width=\"1\"/>" : ""
            return """
            <svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1400" viewBox="0 0 1600 1400">
              <rect width="1600" height="1400" fill="#fff"/>
              <rect x="100" y="100" width="1000" height="800" fill="#468"/>
              \(hairline)
            </svg>
            """
        }
        let a = dir.appending(path: "line-a.svg"), b = dir.appending(path: "line-b.svg")
        try Data(svg(line: true).utf8).write(to: a)
        try Data(svg(line: false).utf8).write(to: b)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: a, result: b, format: .svg, pixelsMustMatch: true)
        }
    }

    /// On a square canvas a wide banner is mostly white margin, which would
    /// let a real change hide inside the allowed share of differing pixels.
    @Test func changeInWideSVGIsRejected() async throws {
        func svg(_ colour: String) -> String {
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="4000" height="100" viewBox="0 0 4000 100">
              <rect width="4000" height="100" fill="#fff"/>
              <rect x="2000" y="20" width="60" height="60" fill="\(colour)"/>
            </svg>
            """
        }
        let a = dir.appending(path: "wide-a.svg"), b = dir.appending(path: "wide-b.svg")
        try Data(svg("#135").utf8).write(to: a)
        try Data(svg("#fff").utf8).write(to: b)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: a, result: b, format: .svg, pixelsMustMatch: true)
        }
    }

    @Test func jpegWithASecondImageIsLeftAlone() async throws {
        let plain = try Data(contentsOf: write(image(), "plain.jpg", type: .jpeg,
                                               properties: [kCGImageDestinationLossyCompressionQuality: 0.95]))
        #expect(!JPEGStructure.hasSecondaryImage([UInt8](plain)))

        // A gain map, motion-photo video or trailer after the end of the image.
        let trailing = dir.appending(path: "trailing.jpg")
        try (plain + Data(repeating: 0x42, count: 3000)).write(to: trailing)
        // A multi-picture index (APP2 "MPF") right after SOI.
        let mpf = dir.appending(path: "mpf.jpg")
        let segment: [UInt8] = [0xFF, 0xE2, 0x00, 0x0A] + Array("MPF\0".utf8) + [0, 0, 0, 0]
        try (plain.prefix(2) + Data(segment) + plain.dropFirst(2)).write(to: mpf)

        for url in [trailing, mpf] {
            let before = try Data(contentsOf: url)
            guard case .skipped = try await optimize(url) else { Issue.record("\(url.lastPathComponent) not skipped"); continue }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func fileChangedDuringOptimizationIsNotOverwritten() async throws {
        let url = write(image(), "busy.png", type: .png)
        let edited = Data("someone else's edit".utf8)
        let outcome = try await FileOptimizer(settings: settings).optimize(url) { _ in
            try? edited.write(to: url)
        }
        guard case .skipped = outcome else { Issue.record("replaced a changed file: \(outcome)"); return }
        #expect(try Data(contentsOf: url) == edited)
    }

    @Test func lossyAnimatedPNGStaysAnimated() async throws {
        var settings = self.settings
        settings.lossy = true
        settings.outputLossy = .replace
        let url = dir.appending(path: "animated-lossy.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 3, nil)!
        for _ in 0..<3 {
            CGImageDestinationAddImage(dest, image(), [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.2]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
        _ = try await FileOptimizer(settings: settings).optimize(url) { _ in }
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
    }

    /// Sprites: symbols nothing in the file refers to are used by other files
    /// and pages (<use href="icons.svg#x">); they and their ids must stay.
    @Test(arguments: [false, true])
    func svgSpriteKeepsItsSymbols(lossy: Bool) async throws {
        var settings = self.settings
        settings.lossy = lossy
        settings.outputLossy = .replace
        let url = dir.appending(path: "sprite-\(lossy).svg")
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg">
              <!-- icons -->
              <symbol id="icon-first" viewBox="0 0 10 10"><path d="M0 0h10v10z"/></symbol>
              <symbol id="icon-second" viewBox="0 0 10 10"><circle cx="5" cy="5" r="3"/></symbol>
            </svg>
            """.utf8).write(to: url)
        _ = try await FileOptimizer(settings: settings).optimize(url) { _ in }
        let result = try String(contentsOf: url, encoding: .utf8)
        #expect(result.contains("id=\"icon-first\"") && result.contains("id=\"icon-second\""))
    }

    /// Ids an editor numbered itself go, even when referenced (then shortened);
    /// named ids and the role stay.
    @Test(arguments: [false, true])
    func svgLosesOnlyGeneratedIDs(lossy: Bool) async throws {
        var settings = self.settings
        settings.lossy = lossy
        settings.outputLossy = .replace
        let url = dir.appending(path: "ids-\(lossy).svg")
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100" role="img">
              <defs><linearGradient id="linearGradient4601"><stop offset="0" stop-color="#f00"/><stop offset="1" stop-color="#00f"/></linearGradient></defs>
              <g id="layer1">
                <rect id="rect1234" x="10" y="10" width="80" height="80" fill="url(#linearGradient4601)"/>
                <circle id="logo" cx="150" cy="50" r="40" fill="#0a0"/>
              </g>
            </svg>
            """.utf8).write(to: url)
        guard case .optimized = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in }) else {
            Issue.record("not optimized"); return
        }
        let result = try String(contentsOf: url, encoding: .utf8)
        #expect(result.contains("id=\"logo\""))
        #expect(!result.contains("layer1") && !result.contains("rect1234") && !result.contains("linearGradient4601"))
        #expect(result.contains("url(#"))
        #expect(result.contains("role=\"img\"")) // screen readers
    }

    /// Rounding a transform that scales a large drawing down shows; the more
    /// precise run keeps enough digits and is used instead.
    @Test func svgWhoseRoundingShowsIsOptimizedPrecisely() async throws {
        let url = dir.appending(path: "stripes.svg")
        let d = (0..<12).map { "M\(300 + $0 * 8) 20h3v400h-3z" }.joined()
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 100 100">
              <!-- stripes -->
              <path transform="matrix(0.21329178,0,0,0.21342916,-50,2)" d="\(d)" stroke="#000" stroke-width="0.5"/>
            </svg>
            """.utf8).write(to: url)
        #expect(try await isRejected(url, run: .idsKept), "the standard run must fail, or this test proves nothing")
        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
    }

    /// Runs one SVG candidate and checks its result against the original.
    private func isRejected(_ url: URL, run: Pipeline.SVGRun) async throws -> Bool {
        let output = dir.appending(path: "once-\(UUID().uuidString).svg")
        _ = try await Pipeline.oxvg(lossless: true, metadata: settings.metadata, run: run).run(url, output, dir)
        do {
            try await Verifier.verify(original: url, result: output, format: .svg, pixelsMustMatch: true)
            return false
        } catch is VerificationError {
            return true
        }
    }

    @Test func sameNamesFromDifferentFoldersGetTheirOwnResults() async throws {
        let fm = FileManager.default
        let out = dir.appending(path: "out")
        var results: [URL] = []
        for folder in ["a", "b"] {
            let sub = dir.appending(path: folder)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            let url = sub.appending(path: "IMG_1.png")
            try fm.copyItem(at: write(image(), "\(folder)-src.png", type: .png), to: url)
            guard case .optimized(_, _, _, let result, _, _) = try await FileOptimizer(settings: settings)
                .optimize(url, to: .newFile(out.appending(path: "IMG_1.png"), includeUnchanged: false), progress: { _ in })
            else { Issue.record("not optimized"); return }
            results.append(result)
        }
        #expect(Set(results.map(\.lastPathComponent)) == ["IMG_1.png", "IMG_1 2.png"])
        #expect(results.allSatisfy { fm.fileExists(atPath: $0.path) })
    }

    /// The same path in other letter case is the original itself on a
    /// case-insensitive volume: it must never go to the Trash as "an earlier result".
    @Test func outputThatIsTheOriginalIsRefused() async throws {
        let url = write(image(), "Photo.png", type: .png)
        let before = try Data(contentsOf: url)
        let sameFile = url.deletingLastPathComponent().appending(path: "photo.png")
        guard FileManager.default.fileExists(atPath: sameFile.path) else { return } // case-sensitive volume
        await #expect(throws: FileReplacer.OutputIsOriginal.self) {
            _ = try await FileOptimizer(settings: settings)
                .optimize(url, to: .newFile(sameFile, includeUnchanged: false), progress: { _ in })
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func heicRemovesPrivateDataButKeepsOrientation() async throws {
        var settings = self.settings
        settings.lossy = true
        settings.quality = 50
        settings.outputLossy = .replace
        let url = dir.appending(path: "private.heic")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        let xmp = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(xmp, nil, "xmp:CreatorTool" as CFString, "SecretApp" as CFString)
        CGImageDestinationAddImageAndMetadata(dest, image(width: 256, height: 256), xmp, [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.1, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "SN999"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        guard case .optimized = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in }) else {
            Issue.record("not optimized, nothing checked"); return
        }
        let after = props(url)
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        #expect((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifBodySerialNumber] == nil)
        #expect(!(try Data(contentsOf: url)).contains(Data("SecretApp".utf8)))
        #expect(after[kCGImagePropertyOrientation] as? Int == 6)
    }

    @Test func keptOriginalsAreNotOptimizedAgain() {
        let settings = OptimizationSettings()
        for name in ["photo (original).jpg", "photo (original 2).png", "photo (Original).jpg"] {
            #expect(OutputPlanner.isOwnOutput(dir.appending(path: name), settings: settings), "\(name)")
        }
        #expect(!OutputPlanner.isOwnOutput(dir.appending(path: "holiday (2024).jpg"), settings: settings))
    }

    @Test func svgKeepsCommentsWhenMetadataIsKept() async throws {
        var settings = self.settings
        settings.metadata = .keep
        let url = dir.appending(path: "licence.svg")
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <!-- Licence: CC BY 4.0, Jane Doe -->
              <title>Blue square</title>
              <rect x="10.000000" y="10.000000" width="80.000000" height="80.000000" fill="#0000ff"/>
            </svg>
            """.utf8).write(to: url)
        _ = try await FileOptimizer(settings: settings).optimize(url) { _ in }
        let result = try String(contentsOf: url, encoding: .utf8)
        #expect(result.contains("CC BY 4.0") && result.contains("Blue square"))
    }

    @Test func jpegCoefficientsAreCompared() async throws {
        let a = write(image(), "coef-a.jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
        let b = write(image(), "coef-b.jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.6])
        // A re-encode at another quality is a different image, whatever a viewer shows.
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: a, result: b, format: .jpeg, pixelsMustMatch: true)
        }
        // The rewritten entropy coding carries the same coefficients and earns the seal.
        guard case .optimized(_, _, let tools, _, _, let identical) = try await optimize(a) else {
            Issue.record("not optimized"); return
        }
        #expect(tools.contains("jpeg-scan"))
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

        guard case .optimized = try await optimize(url) else { Issue.record("not optimized, nothing checked"); return }
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

    @Test func lossyPNGIsQuantizedWithoutLosingItsProfile() async throws {
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
            try JPEGMetadataFilter.filter(Data([0xFF, 0xD8, 0x00, 0x01, 0x02]), level: .removePrivate, orientation: 1)
        }
        #expect(throws: JPEGMetadataFilter.Malformed.self) {
            try JPEGMetadataFilter.filter(Data("not a jpeg".utf8), level: .removePrivate, orientation: 1)
        }
    }

    @Test func pngMetadataFilterKeepsWhatChangesTheLook() throws {
        func chunk(_ type: String, _ payload: [UInt8] = []) -> Data { PNGMetadataFilter.chunk(type, payload) }
        var png = Data(PNGMetadataFilter.signature)
        for c in [chunk("IHDR", Array(repeating: 1, count: 13)), chunk("iCCP", [1, 2]), chunk("tEXt", Array("Author\0Me".utf8)),
                  chunk("eXIf", [0]), chunk("pHYs", [0]), chunk("cICP", [1, 13, 0, 1]), chunk("IDAT", [9]),
                  chunk("tIME", [0]), chunk("IEND")] { png.append(c) }
        func types(_ data: Data) -> [String] {
            var out: [String] = [], i = 8
            let b = [UInt8](data)
            while i + 12 <= b.count {
                let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
                out.append(String(decoding: b[i + 4..<i + 8], as: UTF8.self)); i += 12 + n
            }
            return out
        }
        #expect(types(try PNGMetadataFilter.filter(png, level: .removeAll, orientation: 1)) == ["IHDR", "iCCP", "cICP", "IDAT", "IEND"])
        #expect(types(try PNGMetadataFilter.filter(png, level: .removeAll, orientation: 6))
                == ["IHDR", "eXIf", "iCCP", "cICP", "IDAT", "IEND"])
        // The author stays with the rights, the physical size with the image
        // info; the time goes, and so does unreadable EXIF.
        #expect(types(try PNGMetadataFilter.filter(png, level: .removePrivate, orientation: 1))
                == ["IHDR", "iCCP", "tEXt", "pHYs", "cICP", "IDAT", "IEND"])
        #expect(types(try PNGMetadataFilter.filter(png, level: .copyrightOnly, orientation: 1))
                == ["IHDR", "iCCP", "tEXt", "cICP", "IDAT", "IEND"])
        #expect(try PNGMetadataFilter.filter(png, level: .keep, orientation: 6) == png)
        // Known CRC of an empty IEND chunk.
        #expect(chunk("IEND").suffix(4) == Data([0xAE, 0x42, 0x60, 0x82]))
        #expect(throws: PNGMetadataFilter.Malformed.self) {
            try PNGMetadataFilter.filter(Data("not a png".utf8), level: .removePrivate, orientation: 1)
        }
        #expect(throws: PNGMetadataFilter.Malformed.self) {
            try PNGMetadataFilter.filter(png.prefix(40), level: .removePrivate, orientation: 1)
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
        #expect(trashed.path.hasPrefix(Trash.testFolder!.path))
        #expect(trashed.lastPathComponent.hasPrefix("trash me ("))
        try? FileManager.default.removeItem(at: trashed.deletingLastPathComponent())
    }

    /// The backup name is longer than the original's; when it doesn't fit the
    /// volume's name limit, the original must still survive.
    @Test func originalSurvivesWhenTheBackupNameIsTooLong() throws {
        let fm = FileManager.default
        let url = dir.appending(path: String(repeating: "x", count: 245) + ".png")
        let original = Data("original".utf8), optimized = Data("optimized".utf8)
        try original.write(to: url)
        let result = dir.appending(path: "result.png")
        try optimized.write(to: result)

        let trashed = try? FileReplacer.replace(url, with: result, moveOriginalToTrash: true, keepModificationDate: false)
        let now = try Data(contentsOf: url)
        if now == optimized {
            let kept = try #require(trashed ?? nil, "the original went nowhere")
            #expect(try Data(contentsOf: kept) == original)
            try? fm.removeItem(at: kept.deletingLastPathComponent())
        } else {
            #expect(now == original)
        }
    }

    /// Files that already carry the backup name, even a dangling symlink, are
    /// never overwritten by the original.
    @Test func backupNeverOverwritesAnExistingFile() throws {
        let fm = FileManager.default
        let url = dir.appending(path: "keep.png")
        try Data("original".utf8).write(to: url)
        try Data("precious".utf8).write(to: dir.appending(path: "keep (original).png"))
        try fm.createSymbolicLink(atPath: dir.appending(path: "keep (original 2).png").path, withDestinationPath: "nowhere")
        let result = dir.appending(path: "result.png")
        try Data("optimized".utf8).write(to: result)

        let trashed = try #require(try FileReplacer.replace(url, with: result, moveOriginalToTrash: true, keepModificationDate: false))
        #expect(trashed.lastPathComponent == "keep (original 3).png")
        #expect(try Data(contentsOf: trashed) == Data("original".utf8))
        #expect(try Data(contentsOf: dir.appending(path: "keep (original).png")) == Data("precious".utf8))
        #expect(try fm.destinationOfSymbolicLink(atPath: dir.appending(path: "keep (original 2).png").path) == "nowhere")
        try? fm.removeItem(at: trashed.deletingLastPathComponent())
    }
}
