import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import zlib
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

        guard case .optimized(let before, let after, let tools, _, _, let fidelity, _) = try await optimize(url) else {
            Issue.record("not optimized"); return
        }
        #expect(after < before)
        #expect(tools.contains("OxiPNG"))
        #expect(fidelity == .pixelIdentical)
        try await Verifier.verify(original: copy, result: url, format: .png, pixelsMustMatch: true)
    }

    /// OxiPNG's filters chosen section by section (our patch, from Balanced
    /// on) and its Zopfli run at Maximum: an image of several sections with
    /// different content and transparent areas keeps every pixel, also where
    /// invisible colours may change, in 16 bits and from an interlaced file.
    @Test(arguments: [(false, false, false), (true, false, false), (false, true, false), (false, false, true)])
    func sectionFiltersAndZopfliKeepEveryPixel(lossy: Bool, sixteenBits: Bool, interlaced: Bool) async throws {
        let width = 300, height = 600, bytes = sixteenBits ? 2 : 1
        var pixels = [UInt8](repeating: 0, count: width * height * 4 * bytes)
        for y in 0..<height {
            for x in 0..<width {
                let transparent = y >= 400 && (x / 16 + y / 16) % 3 == 0
                let value: (Int, Int, Int) = y < 200 ? (x * 255 / width, y, 128)
                    : y < 400 ? ((x / 8 + y / 8) % 2 == 0 ? (240, 240, 240) : (20, 30, 40))
                    : ((x * 7919 ^ y * 104_729) & 255, (x * y) & 255, (x + 3 * y) & 255)
                if transparent { continue }
                for (c, v) in [value.0, value.1, value.2, 255].enumerated() {
                    let i = ((y * width + x) * 4 + c) * bytes
                    pixels[i] = UInt8(v)
                    // Big-endian 16 bits; the low byte varies too, so it isn't 8 bits in disguise.
                    if sixteenBits { pixels[i + 1] = c == 3 ? 255 : UInt8((x + y + c) & 255) }
                }
            }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | (sixteenBits ? CGBitmapInfo.byteOrder16Big.rawValue : 0))
        let image = CGImage(width: width, height: height, bitsPerComponent: 8 * bytes, bitsPerPixel: 32 * bytes, bytesPerRow: width * 4 * bytes,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let name = "sections-\(lossy)-\(sixteenBits)-\(interlaced)"
        let url = write(image, "\(name).png", type: .png,
                        properties: interlaced ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 1]] : [:])
        for (i, options) in [Pipeline.oxipngOptions(.balanced), Pipeline.oxipngZopfliOptions].enumerated() {
            let result = dir.appending(path: "\(name)-result\(i).png")
            #expect(try await Pipeline.oxipng(options, lossy: lossy).run(url, result, dir))
            try await Verifier.verify(original: url, result: result, format: .png, pixelsMustMatch: true, exactUnderAlpha: !lossy)
        }
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

    /// Checked by its rendering, an SVG is never proven pixel identical; in
    /// lossy mode its optimizer may approximate.
    @Test(arguments: [false, true])
    func svgGetsSmallerAndLooksTheSame(lossy: Bool) async throws {
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
        var settings = self.settings
        settings.lossy = lossy
        guard case .optimized(let before, let after, _, _, _, let fidelity, _) =
            try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        else { Issue.record("not optimized"); return }
        #expect(after < before / 2)
        #expect(fidelity == (lossy ? .lossy : .lossless))
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
            let outcome = try await optimize(url)
            #expect(TestImages.reason(outcome) == .readOnly, "\(url.lastPathComponent): \(outcome)")
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

        guard case .optimized(_, let after, _, let result, nil, _, _) = try await FileOptimizer(settings: settings)
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
        guard case .uncheckable = TestImages.reason(try await optimize(url)) else { Issue.record("not left alone"); return }
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

    /// Content Credentials in a JPEG live in APP11 (JUMBF): those files stay
    /// as they are. The same two words elsewhere — a comment, Base64 depth
    /// data in a Pixel portrait — are chance, not a manifest.
    @Test func contentCredentialsAreFoundInAPP11Only() throws {
        let plain = try Data(contentsOf: write(image(), "c2pa.jpg", type: .jpeg))
        func file(_ marker: UInt8, _ name: String) throws -> URL {
            let segment = JPEGMarkers.write(marker, Array("JP".utf8) + [0, 1, 0, 0, 0, 1] + Array("jumbc2pa".utf8))
            let url = dir.appending(path: name)
            try (plain.prefix(2) + segment + plain.dropFirst(2)).write(to: url)
            return url
        }
        #expect(FileOptimizer.hasContentCredentials(try file(0xEB, "app11.jpg"), format: .jpeg))
        #expect(!FileOptimizer.hasContentCredentials(try file(0xFE, "comment.jpg"), format: .jpeg))

        // The other containers: in their manifest chunk or box, not in image data.
        let words = Array("JP".utf8) + [0, 1] + Array("jumbc2pa".utf8)
        func saved(_ data: Data, _ name: String) throws -> URL { let url = dir.appending(path: name); try data.write(to: url); return url }
        func png(_ type: String) -> Data {
            Data(PNGChunks.signature) + PNGChunks.write("IHDR", [UInt8](repeating: 1, count: 13)) + PNGChunks.write(type, words) + PNGChunks.write("IEND", [])
        }
        #expect(FileOptimizer.hasContentCredentials(try saved(png("caBX"), "c.png"), format: .png))
        #expect(!FileOptimizer.hasContentCredentials(try saved(png("IDAT"), "i.png"), format: .png))
        func webp(_ type: String) -> Data { RIFFChunks.write(form: "WEBP", [("VP8X", Data(count: 10)), (type, Data(words))]) }
        #expect(FileOptimizer.hasContentCredentials(try saved(webp("C2PA"), "c.webp"), format: .webp))
        #expect(!FileOptimizer.hasContentCredentials(try saved(webp("VP8L"), "i.webp"), format: .webp))
        func heif(_ type: String) -> Data {
            func box(_ type: String, _ payload: [UInt8]) -> Data {
                Data(withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian, Array.init) + Array(type.utf8) + payload)
            }
            return box("ftyp", Array("heic".utf8) + [0, 0, 0, 0]) + box(type, words)
        }
        #expect(FileOptimizer.hasContentCredentials(try saved(heif("jumb"), "c.heic"), format: .heic))
        #expect(!FileOptimizer.hasContentCredentials(try saved(heif("mdat"), "i.heic"), format: .heic))
    }

    /// The metadata check accepts a value as the original's only where the
    /// original keeps metadata: text in image data is chance.
    @Test func metadataRegionsLeaveImageDataOut() throws {
        let jpeg = Data([0xFF, 0xD8]) + JPEGMarkers.write(0xFE, Array("in a comment".utf8))
            + Data([0xFF, 0xDA, 0x00, 0x02]) + Data("in the image".utf8) + Data([0xFF, 0xD9])
        let png = Data(PNGChunks.signature) + PNGChunks.write("IHDR", [UInt8](repeating: 1, count: 13))
            + PNGChunks.write("tEXt", Array("in a comment".utf8)) + PNGChunks.write("IDAT", Array("in the image".utf8)) + PNGChunks.write("IEND", [])
        // An APNG's later frames are image data too.
        let apng = png.dropLast(12) + PNGChunks.write("fdAT", [0, 0, 0, 1] + Array("in a frame".utf8)) + PNGChunks.write("IEND", [])
        for data in [jpeg, png, apng] {
            let regions = MetadataRegions.of(data)
            #expect(regions.contains { $0.range(of: Data("in a comment".utf8)) != nil })
            #expect(!regions.contains { $0.range(of: Data("in the image".utf8)) != nil })
            #expect(!regions.contains { $0.range(of: Data("in a frame".utf8)) != nil })
        }
        // HEIC keeps EXIF as an item in mdat, next to the image data: the item counts, the image doesn't.
        let heic = try Data(contentsOf: TestImages.gainMapPhoto(at: dir.appending(path: "regions.heic"), type: .heic))
        let regions = MetadataRegions.of(heic)
        #expect(regions.contains { $0.range(of: Data("Jane Doe".utf8)) != nil })
        #expect(regions.reduce(0) { $0 + $1.count } < heic.count / 2)
    }

    /// Bytes after the image (cameras leave buffer leftovers there) stay
    /// where they were when everything is kept, and go otherwise — like
    /// unknown metadata. A multi-picture index that lists nothing leaves the
    /// file as it is: the images it should list can't be found.
    @Test(arguments: [MetadataHandling.keep, .removePrivate])
    func jpegWithDataAfterTheImage(level: MetadataHandling) async throws {
        let plain = try Data(contentsOf: write(image(), "plain-\(level.rawValue).jpg", type: .jpeg,
                                               properties: [kCGImageDestinationLossyCompressionQuality: 0.95]))
        #expect(JPEGLayout.read(ByteView(plain))?.isPlain == true)
        settings.metadata = level

        let trailing = dir.appending(path: "trailing-\(level.rawValue).jpg")
        let leftover = Data(repeating: 0x42, count: 3000)
        try (plain + leftover).write(to: trailing)
        guard case .optimized = try await optimize(trailing) else { Issue.record("not optimized"); return }
        let data = try Data(contentsOf: trailing)
        #expect(data.suffix(leftover.count) == leftover || level != .keep)
        #expect(!data.contains(leftover) || level == .keep)

        let mpf = dir.appending(path: "mpf-\(level.rawValue).jpg")
        let segment: [UInt8] = [0xFF, 0xE2, 0x00, 0x0A] + Array("MPF\0".utf8) + [0, 0, 0, 0]
        try (plain.prefix(2) + Data(segment) + plain.dropFirst(2)).write(to: mpf)
        let before = try Data(contentsOf: mpf)
        #expect(TestImages.reason(try await optimize(mpf)) == .unreadableImages)
        #expect(try Data(contentsOf: mpf) == before)
    }

    @Test func fileChangedDuringOptimizationIsNotOverwritten() async throws {
        let url = write(image(), "busy.png", type: .png)
        let edited = Data("someone else's edit".utf8)
        let outcome = try await FileOptimizer(settings: settings).optimize(url) { _ in
            try? edited.write(to: url)
        }
        guard TestImages.reason(outcome) == .changedMeanwhile else { Issue.record("replaced a changed file: \(outcome)"); return }
        #expect(try Data(contentsOf: url) == edited)
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

    /// A document's size in mm stays in mm: print, plotter and cutter software
    /// may read px at another resolution than 96 dpi.
    @Test(arguments: [false, true])
    func svgKeepsAbsoluteUnits(lossy: Bool) async throws {
        var settings = self.settings
        settings.lossy = lossy
        settings.outputLossy = .replace
        let url = dir.appending(path: "a4-\(lossy).svg")
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" width="210mm" height="297mm" viewBox="0 0 210 297">
              <rect x="10" y="10" width="50" height="30" fill="none" stroke="#000" stroke-width="0.5mm"/>
              <circle cx="105" cy="150" r="40" fill="#09c" stroke="#000" style="stroke-width:0.3mm"/>
            </svg>
            """.utf8).write(to: url)
        guard case .optimized = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in }) else {
            Issue.record("not optimized"); return
        }
        let result = try String(contentsOf: url, encoding: .utf8)
        #expect(result.contains("width=\"210mm\"") && result.contains("height=\"297mm\""))
        #expect(result.contains("stroke-width=\".5mm\"") && result.contains("stroke-width:.3mm"))
    }

    /// A uniform scale may move into a stroked path and its stroke width; a
    /// non-uniform one would distort the stroke, so it stays a transform.
    @Test func svgStrokedPathsTakeOnlyUniformScales() async throws {
        let url = dir.appending(path: "stroked.svg")
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 200 200">
              <g transform="scale(2)"><path d="M10 10h40v40H10z" fill="none" stroke="#000" stroke-width="1"/></g>
              <g transform="scale(2 1)"><path d="M10 100h40v40H10z" fill="none" stroke="#000" stroke-width="1"/></g>
            </svg>
            """.utf8).write(to: url)
        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
        let result = try String(contentsOf: url, encoding: .utf8)
        #expect(result.contains("stroke-width=\"2\""))
        #expect(result.contains("scale(2 1)"))
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

    /// Rounding a transform that scales a large drawing down would show; the
    /// lossless configuration keeps enough digits for it.
    @Test func svgWithScaledDownDrawingKeepsItsTransformDigits() async throws {
        let url = dir.appending(path: "stripes.svg")
        let d = (0..<12).map { "M\(300 + $0 * 8) 20h3v400h-3z" }.joined()
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 100 100">
              <!-- stripes -->
              <path transform="matrix(0.21329178,0,0,0.21342916,-50,2)" d="\(d)" stroke="#000" stroke-width="0.5"/>
            </svg>
            """.utf8).write(to: url)
        #expect(try await !isRejected(url, run: .idsKept))
        guard case .optimized = try await optimize(url) else { Issue.record("not optimized"); return }
    }

    /// oxvg 0.0.9 dropped a translation by (1, 1) and closed an open subpath
    /// that the next one continued from.
    @Test func svgKeepsUnitTranslationsAndOpenSubpaths() async throws {
        let url = dir.appending(path: "unit-translate.svg")
        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 20 20">
              <g transform="matrix(1 0 0 1 1 1)"><circle cx="10" cy="10" r="2"/></g>
              <path fill="none" stroke="#000" d="M2 2l4 4M6 6L10 2"/>
            </svg>
            """.utf8).write(to: url)
        #expect(try await !isRejected(url, run: .idsKept))
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
            guard case .optimized(_, _, _, let result, _, _, _) = try await FileOptimizer(settings: settings)
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
        guard case .optimized(_, _, let tools, _, _, let fidelity, _) = try await optimize(a) else {
            Issue.record("not optimized"); return
        }
        #expect(tools.contains("jpeg-scan"))
        #expect(fidelity == .pixelIdentical)
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
        guard case .optimized(let before, let after, let tools, _, _, let fidelity, _) =
            try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        else { Issue.record("not optimized"); return }
        #expect(tools.contains("jpegli"))
        #expect(after < before)
        #expect(fidelity == .lossy)
        #expect(props(url)[kCGImagePropertyOrientation] as? Int == 6)
        #expect(iccName(url) == CGColorSpace.displayP3 as String)
    }

    /// cjpegli can't read arithmetic coding, 12 bits or CMYK. The lossy step
    /// is left out for such a JPEG, decided by its frame header: the file is
    /// optimized without loss or stays as it is, never an error.
    @Test func lossyJPEGLeavesOutJpegliWhereItCantRead() async throws {
        let url = dir.appending(path: "arithmetic.jpg")
        try TestImages.arithmeticJPEG.write(to: url)
        let layout = try #require(JPEGLayout.read(ByteView(TestImages.arithmeticJPEG)))
        #expect(layout.isPlain && !layout.mayChangeWithLoss)
        var settings = self.settings
        settings.lossy = true
        settings.quality = 70
        settings.outputLossy = .replace
        let facts = FileFacts(byteSize: 1, jpegQuality: 97, jpegLayout: layout)
        let lossy = Pipeline.stages(for: .jpeg, facts: facts, settings: settings).joined().filter(\.isLossy)
        #expect(lossy.isEmpty)
        try await expectOptimizedWithoutLossOrUnchanged(url, original: TestImages.arithmeticJPEG, settings: settings)
    }

    /// A JPEG whose frame header the lossy encoder reads, but whose data its
    /// decoder rejects: jpegli leaves the image as it is, and the file is
    /// optimized without loss or stays as it is, never an error.
    @Test func lossyJPEGStaysWhenJpegliCantDecode() async throws {
        let original = TestImages.fractionalSamplingJPEG
        let url = dir.appending(path: "fractional.jpg")
        try original.write(to: url)
        let layout = try #require(JPEGLayout.read(ByteView(original)))
        #expect(layout.isPlain && layout.mayChangeWithLoss)
        let changed = try await Pipeline.jpegli(quality: 70, layout: layout).run(url, dir.appending(path: "out.jpg"), dir)
        #expect(!changed)

        var settings = self.settings
        settings.lossy = true
        settings.quality = 70
        settings.metadata = .keep
        var facts = FileOptimizer.facts(about: url, format: .jpeg, size: Int64(original.count))
        facts.jpegLayout = layout
        let lossy = Pipeline.stages(for: .jpeg, facts: facts, settings: settings).joined().filter(\.isLossy)
        #expect(lossy.map(\.name) == ["jpegli"])
        try await expectOptimizedWithoutLossOrUnchanged(url, original: original, settings: settings)
    }

    /// Lossy settings, but `url` is optimized without loss or stays as it
    /// is, never an error.
    private func expectOptimizedWithoutLossOrUnchanged(_ url: URL, original: Data, settings: OptimizationSettings) async throws {
        switch try await FileOptimizer(settings: settings).optimize(url, progress: { _ in }) {
        case .optimized(_, _, let tools, _, _, let fidelity, _): #expect(fidelity == .pixelIdentical && !tools.contains("jpegli"))
        case .unchanged: #expect(try Data(contentsOf: url) == original)
        }
    }

    /// Which frames the lossy encoder reads: Huffman-coded 8-bit images in
    /// grey or colour, lossless ones too.
    @Test func framesTheLossyEncoderReads() {
        func reads(_ marker: UInt8, _ precision: Int = 8, _ components: Int = 3) -> Bool {
            JPEGLayout.readsForEncoding(JPEGMarkers.Frame(marker: marker, precision: precision, components: components))
        }
        #expect(reads(0xC0) && reads(0xC1) && reads(0xC2) && reads(0xC3) && reads(0xC0, 8, 1))
        #expect(!reads(0xC9) && !reads(0xCA) && !reads(0xCB) && !reads(0xC5) && !reads(0xCD))
        #expect(!reads(0xC1, 12) && !reads(0xC0, 8, 4) && !reads(0xC0, 8, 2))
        #expect(!JPEGLayout.readsForEncoding(nil) && !JPEGLayout.readsForEncoding(JPEGMarkers.Frame(marker: 0xC0, precision: nil, components: nil)))
    }

    /// Photo-like: gradients with grain, which a palette stores in a third of the bytes.
    private func grainyImage() -> CGImage {
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
        return ctx.makeImage()!
    }

    @Test func lossyPNGIsQuantizedWithoutLosingItsProfile() async throws {
        settings.lossy = true
        let url = write(grainyImage(), "quantize.png", type: .png)
        let before = try Data(contentsOf: url).count
        let outcome = try await optimize(url)
        guard case .optimized(_, _, let tools, _, _, _, _) = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(tools.contains("quantizr"), "\(tools)")
        #expect(try Data(contentsOf: url).count < before)
        #expect(iccName(url) == CGColorSpace.displayP3 as String)
    }

    /// A palette image counts only when it saves enough over the file
    /// compressed without loss — not over the original. A smooth gradient of
    /// 512 colours, stored uncompressed, is far smaller as a palette than as
    /// it is, but without loss its identical rows shrink to almost nothing.
    @Test func lossyPNGStaysLosslessWhenAPaletteSavesTooLittle() async throws {
        settings.lossy = true
        let url = dir.appending(path: "gradient-rows.png")
        try uncompressedPNG(width: 512, height: 256) { x, _ in [UInt8(x / 2), UInt8(255 - x / 2), UInt8(x % 2 * 255)] }.write(to: url)
        let original = dir.appending(path: "gradient-rows-original.png")
        try FileManager.default.copyItem(at: url, to: original)

        let outcome = try await optimize(url)
        guard case .optimized(_, _, let tools, _, _, let fidelity, _) = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(!tools.contains("quantizr") && fidelity == .pixelIdentical, "\(tools)")
        try await Verifier.verify(original: original, result: url, format: .png, pixelsMustMatch: true)
    }

    /// Half red, half fully transparent, with or without colour under the
    /// transparent half.
    private func halfTransparentPNG(_ name: String, hiddenColour: Bool) throws -> URL {
        let url = dir.appending(path: name)
        try uncompressedPNG(width: 256, height: 64, alpha: true) { x, y in
            x < 128 ? [200, 40, 40, 255] : hiddenColour ? [UInt8(x), UInt8(y * 4), UInt8(x * y & 255), 0] : [0, 0, 0, 0]
        }.write(to: url)
        return url
    }

    /// Where the colour under fully transparent pixels may change, the check
    /// says whether it did; where it may not, a change fails it.
    @Test func colourUnderTransparencyIsReported() async throws {
        let a = try halfTransparentPNG("hidden-a.png", hiddenColour: true)
        let b = try halfTransparentPNG("hidden-b.png", hiddenColour: false)
        await #expect(throws: VerificationError.self) {
            try await Verifier.verify(original: a, result: b, format: .png, pixelsMustMatch: true)
        }
        #expect(try await Verifier.verify(original: a, result: b, format: .png, pixelsMustMatch: true, exactUnderAlpha: false) == false)
        #expect(try await Verifier.verify(original: b, result: b, format: .png, pixelsMustMatch: true, exactUnderAlpha: false))
    }

    /// In lossy mode OxiPNG may clear the colour under fully transparent
    /// pixels: then the visible pixels are proven identical, not the file.
    /// Without such colour the file stays pixel identical.
    @Test(arguments: [false, true])
    func lossyPNGThatClearsHiddenColourIsVisiblyIdentical(hiddenColour: Bool) async throws {
        settings.lossy = true
        let url = try halfTransparentPNG("half-\(hiddenColour).png", hiddenColour: hiddenColour)
        guard case .optimized(_, _, let tools, _, _, let fidelity, _) = try await optimize(url) else { Issue.record("not optimized"); return }
        #expect(!tools.contains("quantizr"), "\(tools)")
        #expect(fidelity == (hiddenColour ? .visiblyIdentical : .pixelIdentical))
    }

    /// The palette image says how its colours are meant exactly as the
    /// original does: an sRGB chunk alone gets no gamma or chromaticities
    /// added (the structure check would reject the palette).
    @Test func lossyPNGWithAnSRGBChunkIsQuantized() async throws {
        settings.lossy = true
        let url = dir.appending(path: "srgb-grain.png")
        try uncompressedPNG(width: 256, height: 256, colour: [PNGChunks.write("sRGB", [0])]) { x, y in
            let grain = (x * 7919 ^ y * 104_729) % 13
            return [UInt8(x / 2 + grain), UInt8(100 + grain), UInt8(y / 2 + grain)]
        }.write(to: url)

        let outcome = try await optimize(url)
        guard case .optimized(_, _, let tools, _, _, _, _) = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(tools.contains("quantizr"), "\(tools)")
        let chunks = try PNGChunks.read(ByteView(Data(contentsOf: url)), strict: true)
        #expect(chunks.map(\.type) == ["IHDR", "sRGB", "PLTE", "IDAT", "IEND"])
        #expect(chunks.first { $0.type == "sRGB" }?.data.bytes == Data([0]))
    }

    /// 8-bit RGB, the rows as they are, packed without compression; `colour`
    /// chunks right after IHDR.
    private func uncompressedPNG(width: Int, height: Int, alpha: Bool = false, colour: [Data] = [],
                                 pixel: (_ x: Int, _ y: Int) -> [UInt8]) -> Data {
        var rows: [UInt8] = []
        for y in 0..<height {
            rows.append(0)
            for x in 0..<width { rows += pixel(x, y) }
        }
        var size = uLongf(compressBound(uLong(rows.count)))
        var packed = [UInt8](repeating: 0, count: Int(size))
        precondition(compress2(&packed, &size, rows, uLong(rows.count), 0) == Z_OK)
        let bigEndian = { (n: Int) in (0..<4).map { UInt8(n >> (24 - 8 * $0) & 0xFF) } }
        return Data(PNGChunks.signature) + PNGChunks.write("IHDR", bigEndian(width) + bigEndian(height) + [8, alpha ? 6 : 2, 0, 0, 0])
            + colour.reduce(Data(), +) + PNGChunks.write("IDAT", Array(packed.prefix(Int(size)))) + PNGChunks.write("IEND", [])
    }

    /// The palette image keeps the metadata: EXIF, XMP and text on their side
    /// of the image data, and the time. What describes the old pixels goes
    /// (background colour, significant bits, unsafe-to-copy chunks of other
    /// programs). At "keep everything" nothing may be missing.
    @Test(arguments: [MetadataHandling.keep, .removePrivate])
    func lossyPNGKeepsItsMetadata(level: MetadataHandling) async throws {
        settings.lossy = true
        settings.metadata = level
        let written = write(grainyImage(), "quantize-metadata.png", type: .png, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Doe", kCGImagePropertyTIFFCopyright: "Public domain"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Diary"],
        ])
        var png = Data(PNGChunks.signature), inFront = true
        for chunk in try PNGChunks.read(ByteView(Data(contentsOf: written)), strict: true) {
            if chunk.type == "IDAT", inFront {
                inFront = false
                png.append(PNGChunks.write("bKGD", [0, 255, 0, 255, 0, 255]))
                png.append(PNGChunks.write("sBIT", [8, 8, 8]))
                png.append(PNGChunks.write("prVT", [1, 2, 3]))
            }
            if chunk.type == "IEND" {
                png.append(PNGChunks.write("tEXt", Array("Disclaimer\0After the image data".utf8)))
                png.append(PNGChunks.write("tIME", [0x07, 0x6A, 1, 2, 3, 4, 5]))
            }
            png.append(chunk.whole.bytes)
        }
        let url = dir.appending(path: "quantize-metadata-\(level).png")
        try png.write(to: url)
        let original = dir.appending(path: "quantize-metadata-\(level)-original.png")
        try png.write(to: original)
        func types(_ url: URL) throws -> [String] { try PNGChunks.read(ByteView(Data(contentsOf: url)), strict: true).map(\.type) }
        let before = try types(url)
        #expect(before.contains("eXIf") && before.contains("iTXt"), "ImageIO wrote no EXIF or XMP: \(before)")

        let outcome = try await optimize(url)
        guard case .optimized(_, _, let tools, _, _, _, _) = outcome else { Issue.record("not optimized: \(outcome)"); return }
        #expect(tools.contains("quantizr"), "\(tools)")
        try MetadataCheck.verify(original: original, result: url, level: level)
        let after = try types(url), image = try #require(after.firstIndex(of: "IDAT"))
        #expect(!after.contains("bKGD") && !after.contains("sBIT") && !after.contains("prVT"), "\(after)")
        #expect(after.firstIndex(of: "eXIf").map { $0 < image } == true, "\(after)")
        #expect(after.firstIndex(of: "tEXt").map { $0 > image } == true, "\(after)")
        if level == .keep {
            #expect(MetadataCheck.fields(try Data(contentsOf: url)) == MetadataCheck.fields(png))
            #expect(after.contains("tIME") && after.contains("iTXt"), "\(after)")
        }
        let fields = MetadataCheck.fields(try Data(contentsOf: url))
        #expect(fields.values.contains { $0.text.contains("Jane Doe") }, "\(fields)")
        #expect(fields.values.contains { $0.text.contains("Public domain") }, "\(fields)")
    }

    @Test func lowQualityJPEGIsNotReencoded() async throws {
        var settings = self.settings
        settings.lossy = true
        settings.quality = 90
        let url = write(image(width: 400, height: 300), "already-small.jpg", type: .jpeg,
                        properties: [kCGImageDestinationLossyCompressionQuality: 0.4])
        #expect((JPEGQuality.estimate(try Data(contentsOf: url)) ?? 100) < 90)
        guard case .optimized(_, _, let tools, _, _, let fidelity, _) =
            try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
        else { Issue.record("not optimized"); return }
        #expect(!tools.contains("jpegli"))
        #expect(fidelity == .pixelIdentical)
    }

    @Test func jpegQualityEstimateRisesWithQuality() throws {
        let estimates = try [0.3, 0.6, 0.9].map { q in
            let url = write(image(), "q\(q).jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: q])
            return try #require(JPEGQuality.estimate(try Data(contentsOf: url)))
        }
        #expect(estimates[0] < estimates[1] && estimates[1] < estimates[2])
    }

    /// `jpeg` with a minimal APP11 segment that holds a JUMBF superbox labelled "c2pa".
    private static func withContentCredentials(_ jpeg: Data) -> Data {
        let payload: [UInt8] = Array("JP".utf8) + [0, 1, 0, 0, 0, 1] + [0, 0, 0, 24] + Array("jumb".utf8)
            + [0, 0, 0, 16] + Array("jumd".utf8) + Array("c2pa".utf8) + [0, 0, 0, 0]
        return jpeg.prefix(2) + JPEGMarkers.write(0xEB, payload) + jpeg.dropFirst(2)
    }

    @Test func contentCredentialsAreLeftIntact() async throws {
        let plain = write(image(), "c2pa-source.jpg", type: .jpeg,
                          properties: [kCGImageDestinationLossyCompressionQuality: 0.95])
        let bytes = Self.withContentCredentials(try Data(contentsOf: plain))
        let url = dir.appending(path: "c2pa.jpg")
        try bytes.write(to: url)

        #expect(TestImages.reason(try await optimize(url)) == .contentCredentials)
        #expect(try Data(contentsOf: url) == bytes)
    }

    /// What stays as it is still goes into an output folder, so that the
    /// folder is complete: an image as it was (Content Credentials, a
    /// truncated PNG), what isn't an image not at all. An image says whether
    /// it still holds what the metadata level removes, unless the level
    /// keeps everything.
    @Test func whatStaysGoesIntoTheOutputFolder() async throws {
        let located = write(image(), "located.jpg", type: .jpeg,
                            properties: [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.1, kCGImagePropertyGPSLatitudeRef: "N"],
                                         kCGImageDestinationLossyCompressionQuality: 0.95])
        let c2pa = dir.appending(path: "c2pa.jpg")
        try Self.withContentCredentials(try Data(contentsOf: located)).write(to: c2pa)
        let png = try Data(contentsOf: write(image(), "whole.png", type: .png))
        let truncated = dir.appending(path: "truncated.png")
        try png.prefix(png.count / 2).write(to: truncated)
        let text = dir.appending(path: "text.gif")
        try Data("not a gif at all".utf8).write(to: text)

        func kept(_ url: URL, _ level: MetadataHandling) async throws -> Unchanged? {
            var settings = self.settings
            (settings.metadata, settings.moveOriginalsToTrash) = (level, false)
            let target = dir.appending(path: "output-\(level.rawValue)").appending(path: url.lastPathComponent)
            guard case .unchanged(let kept) = try await FileOptimizer(settings: settings)
                .optimize(url, to: .newFile(target, includeUnchanged: true), progress: { _ in }) else { return nil }
            #expect((kept.copy == nil) == !FileManager.default.fileExists(atPath: target.path))
            if let copy = kept.copy { #expect(try Data(contentsOf: copy) == Data(contentsOf: url)) }
            return kept
        }
        let credentials = try #require(try await kept(c2pa, .removePrivate))
        #expect(credentials.reason == .contentCredentials && credentials.copy != nil && credentials.holdsPrivateData == true)
        let damaged = try #require(try await kept(truncated, .removePrivate))
        guard case .damaged(_?) = damaged.reason else { Issue.record("\(damaged)"); return }
        #expect(damaged.copy != nil && damaged.holdsPrivateData == false)
        let notAnImage = try #require(try await kept(text, .removePrivate))
        #expect(notAnImage.reason == .notAnImage && notAnImage.copy == nil && notAnImage.holdsPrivateData == nil)
        let everything = try #require(try await kept(c2pa, .keep))
        #expect(everything.copy != nil && everything.holdsPrivateData == nil)
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
        func chunk(_ type: String, _ payload: [UInt8] = []) -> Data { PNGChunks.write(type, payload) }
        var png = Data(PNGChunks.signature)
        for c in [chunk("IHDR", Array(repeating: 1, count: 13)), chunk("iCCP", [1, 2]), chunk("tEXt", Array("Author\0Me".utf8)),
                  chunk("eXIf", [0]), chunk("pHYs", [0]), chunk("cICP", [1, 13, 0, 1]), chunk("IDAT", [9]),
                  chunk("tIME", [0]), chunk("IEND")] { png.append(c) }
        // Read strictly: the filter's CRCs must be right too.
        func types(_ data: Data) throws -> [String] { try PNGChunks.read(ByteView(data), strict: true).map(\.type) }
        #expect(try types(PNGMetadataFilter.filter(png, level: .removeAll, orientation: 1)) == ["IHDR", "iCCP", "pHYs", "cICP", "IDAT", "IEND"])
        #expect(try types(PNGMetadataFilter.filter(png, level: .removeAll, orientation: 6))
                == ["IHDR", "eXIf", "iCCP", "pHYs", "cICP", "IDAT", "IEND"])
        // The author stays with the rights, the physical size at every level;
        // the time goes, and so does unreadable EXIF.
        #expect(try types(PNGMetadataFilter.filter(png, level: .removePrivate, orientation: 1))
                == ["IHDR", "iCCP", "tEXt", "pHYs", "cICP", "IDAT", "IEND"])
        #expect(try types(PNGMetadataFilter.filter(png, level: .copyrightOnly, orientation: 1))
                == ["IHDR", "iCCP", "tEXt", "pHYs", "cICP", "IDAT", "IEND"])
        #expect(try PNGMetadataFilter.filter(png, level: .keep, orientation: 6) == png)
        // Readable EXIF stays where it stands, once.
        var rotated = Data(PNGChunks.signature)
        for c in [chunk("IHDR", Array(repeating: 1, count: 13)), chunk("iCCP", [1, 2]),
                  chunk("eXIf", JPEGMetadataFilter.minimalTIFF(orientation: 6)), chunk("IDAT", [9]), chunk("IEND")] { rotated.append(c) }
        #expect(try types(PNGMetadataFilter.filter(rotated, level: .removeAll, orientation: 6)) == ["IHDR", "iCCP", "eXIf", "IDAT", "IEND"])
        // Known CRC of an empty IEND chunk.
        #expect(chunk("IEND").suffix(4) == Data([0xAE, 0x42, 0x60, 0x82]))
        #expect(throws: PNGMetadataFilter.Malformed.self) {
            try PNGMetadataFilter.filter(Data("not a png".utf8), level: .removePrivate, orientation: 1)
        }
        #expect(throws: PNGMetadataFilter.Malformed.self) {
            try PNGMetadataFilter.filter(png.prefix(40), level: .removePrivate, orientation: 1)
        }
    }

    /// An iCCP chunk holding `profile`: name, NUL, method 0, zlib data.
    private func iccpChunk(_ profile: Data, level: Int32 = 9) -> Data {
        var size = uLongf(compressBound(uLong(profile.count)))
        var packed = [UInt8](repeating: 0, count: Int(size))
        let status = profile.withUnsafeBytes { compress2(&packed, &size, $0.bindMemory(to: UInt8.self).baseAddress, uLong(profile.count), level) }
        precondition(status == Z_OK)
        return PNGChunks.write("iCCP", Array("ICC profile".utf8) + [0, 0] + packed.prefix(Int(size)))
    }

    /// A profile whose header carries the ID of a standard sRGB profile, but
    /// whose data doesn't match it.
    private var forgedSRGBProfile: Data {
        var p = [UInt8](repeating: 0, count: 200)
        p[67] = 1
        p.replaceSubrange(84..<100, with: [0x29, 0xf8, 0x3d, 0xde, 0xaf, 0xf2, 0x55, 0xae, 0x78, 0x42, 0xfa, 0xe4, 0xca, 0x83, 0x39, 0x0d])
        return Data(p)
    }

    /// A standard sRGB profile says nothing the sRGB chunk doesn't: it becomes
    /// one, at every level. Any other profile stays as it is.
    @Test func pngStandardSRGBProfileBecomesTheSRGBChunk() throws {
        func png(_ colour: [Data]) -> Data {
            Data(PNGChunks.signature) + PNGChunks.write("IHDR", Array(repeating: 1, count: 13)) + colour.reduce(Data(), +)
                + PNGChunks.write("IDAT", [9]) + PNGChunks.write("IEND", [])
        }
        func chunks(_ data: Data) throws -> [(String, Data)] {
            try PNGChunks.read(ByteView(data), strict: true).map { ($0.type, $0.data.bytes) }
        }
        let standard = png([iccpChunk(TestImages.standardSRGBProfile)])
        for level in MetadataHandling.allCases {
            let result = try chunks(PNGMetadataFilter.filter(standard, level: level, orientation: 1))
            #expect(result.map(\.0) == ["IHDR", "sRGB", "IDAT", "IEND"], "\(level)")
            #expect(result.first { $0.0 == "sRGB" }?.1 == Data([1]), "\(level)")
        }
        // An sRGB chunk is there already: the profile just goes.
        let both = png([PNGChunks.write("sRGB", [0]), iccpChunk(TestImages.standardSRGBProfile)])
        #expect(try chunks(PNGMetadataFilter.filter(both, level: .keep, orientation: 1)).map(\.0) == ["IHDR", "sRGB", "IDAT", "IEND"])
        // An ID that doesn't belong to the data isn't trusted.
        let forged = png([iccpChunk(forgedSRGBProfile)])
        #expect(try chunks(PNGMetadataFilter.filter(forged, level: .removeAll, orientation: 1)).map(\.0) == ["IHDR", "iCCP", "IDAT", "IEND"])
        // Display P3 stays byte for byte.
        let p3Profile = CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData()! as Data
        let p3 = png([iccpChunk(p3Profile)])
        #expect(try PNGMetadataFilter.filter(p3, level: .keep, orientation: 1) == p3)
        #expect(try chunks(PNGMetadataFilter.filter(p3, level: .removeAll, orientation: 1)).map(\.0) == ["IHDR", "iCCP", "IDAT", "IEND"])
        // Packed loosely, it is recompressed: smaller, the same profile.
        let loose = png([iccpChunk(p3Profile, level: 0)])
        let repacked = try PNGMetadataFilter.filter(loose, level: .keep, orientation: 1)
        #expect(repacked.count < loose.count)
        let profile = try PNGChunks.read(ByteView(repacked), strict: true).first { $0.type == "iCCP" }.map { try PNGChunks.text($0) }
        #expect(profile?.content == p3Profile && profile?.keyword == "ICC profile")
    }

    /// End to end, with every check: a PNG with the standard sRGB profile comes
    /// out with the sRGB chunk instead, its pixels identical.
    @Test func pngWithStandardSRGBProfileIsOptimizedWithTheSRGBChunk() async throws {
        let written = try Data(contentsOf: write(image(), "profile-source.png", type: .png))
        let all = try PNGChunks.read(ByteView(written), strict: true)
        var png = Data(PNGChunks.signature) + all[0].whole.bytes + iccpChunk(TestImages.standardSRGBProfile)
        for c in all.dropFirst() where PNGChunks.isCritical(c) { png += c.whole.bytes }
        let url = dir.appending(path: "hp-srgb.png")
        try png.write(to: url)
        guard case .optimized(_, _, _, _, _, let fidelity, _) = try await optimize(url) else {
            Issue.record("not optimized"); return
        }
        #expect(fidelity == .pixelIdentical)
        let types = try PNGChunks.read(ByteView(Data(contentsOf: url)), strict: true).map(\.type)
        #expect(types.contains("sRGB") && !types.contains("iCCP"))
    }

    /// The structure check lets an sRGB chunk replace only a standard sRGB
    /// profile, with the same rendering intent.
    @Test func structureCheckAllowsSRGBOnlyForAStandardProfile() throws {
        let image = try Data(contentsOf: write(image(), "colour.png", type: .png))
        let all = try PNGChunks.read(ByteView(image), strict: true)
        func png(_ colour: Data) -> Data {
            var out = Data(PNGChunks.signature) + all[0].whole.bytes + colour
            for c in all.dropFirst() where PNGChunks.isCritical(c) { out += c.whole.bytes }
            return out
        }
        func passes(_ original: Data, _ result: Data) -> Bool {
            (try? PNGCheck.check(ByteView(result), against: PNGCheck.Reference(ByteView(original)))) != nil
        }
        let standard = png(iccpChunk(TestImages.standardSRGBProfile))
        #expect(passes(standard, png(PNGChunks.write("sRGB", [1]))))
        #expect(!passes(standard, png(PNGChunks.write("sRGB", [0]))))
        let p3 = png(iccpChunk(CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData()! as Data))
        #expect(passes(p3, p3))
        #expect(!passes(p3, png(PNGChunks.write("sRGB", [0]))))
        #expect(!passes(png(iccpChunk(forgedSRGBProfile)), png(PNGChunks.write("sRGB", [1]))))
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
        let outcome = try await optimize(truncated)
        guard case .damaged(let detail?) = TestImages.reason(outcome), detail.contains("end marker") || detail.contains("Ende") else {
            Issue.record("a truncated PNG must be left alone, not attempted: \(outcome)"); return
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(leftovers == ["source.png", "text.gif", "truncated.png"])
    }

    /// A file whose end and first image are whole but that is damaged
    /// elsewhere gets past the first check. When nothing comes of it, the
    /// damage is the reason given (not a tool's message, nor the metadata
    /// step's), and the file stays as it is: a PNG with a second colour
    /// profile whose checksum is wrong, at every level; a JPEG with a
    /// restart marker out of turn, whose location must go.
    @Test func damageIsTheReasonAFileStays() async throws {
        @discardableResult
        func staysDamaged(_ url: URL, _ level: MetadataHandling) async throws -> Outcome {
            var settings = self.settings
            settings.metadata = level
            let before = try Data(contentsOf: url)
            let outcome = try await FileOptimizer(settings: settings).optimize(url) { _ in }
            #expect(TestImages.isDamaged(outcome), "\(url.lastPathComponent), \(level): \(outcome)")
            #expect(try Data(contentsOf: url) == before)
            return outcome
        }
        let png = try Data(contentsOf: write(image(space: CGColorSpace.displayP3), "profiles.png", type: .png,
                                              properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGSoftware: "SecretApp"]]))
        let profile = try #require(try PNGChunks.read(ByteView(png), strict: true).first { $0.type == "iCCP" }).whole.bytes
        let at = try #require(png.range(of: profile)).lowerBound
        var broken = Data(profile)
        broken[broken.count - 1] ^= 1
        let profiles = dir.appending(path: "two-profiles.png")
        for level in MetadataHandling.allCases {
            try (png[..<at] + broken + png[at...]).write(to: profiles)
            try await staysDamaged(profiles, level)
        }

        let jpeg = write(image(), "restart.jpg", type: .jpeg, properties: [kCGImagePropertyGPSDictionary: TestImages.gps])
        var b = try Data(contentsOf: jpeg)
        let marker = try #require(TestImages.restarts(b).scans.first?.markers.dropFirst().first)
        b[marker + 1] = 0xD7
        try b.write(to: jpeg)
        try await staysDamaged(jpeg, .removePrivate)

        // A sound structure whose image data the decoder finds damaged (bytes
        // near the end of the last scan zeroed), in the photo and in a gain
        // map, at every level. The photo as written at "keep" already, so
        // that there only jpeg-scan reads its image data.
        var keep = settings
        keep.metadata = .keep
        let sound = TestImages.gainMapPhoto(at: dir.appending(path: "gain-map.jpg"))
        guard case .optimized = try await FileOptimizer(settings: keep).optimize(sound, progress: { _ in }) else {
            Issue.record("the sound photo wasn't optimized"); return
        }
        let photo = try Data(contentsOf: sound)
        for (n, image) in try #require(JPEGLayout.read(ByteView(photo))?.images).enumerated() {
            var damaged = photo
            damaged.resetBytes(in: image.upperBound - 48..<image.upperBound - 16)
            let url = dir.appending(path: "damaged-data-\(n).jpg")
            try damaged.write(to: url)
            #expect(StructureCheck.damage(of: url, format: .jpeg) == nil, "image \(n + 1)")
            // The damage is the reason; what the checks said of the results
            // is still listed, and none of them changed pixels.
            var rejected: [Rejection] = []
            for level in MetadataHandling.allCases {
                if case .unchanged(let kept) = try await staysDamaged(url, level) { rejected += kept.rejected }
            }
            #expect(!rejected.isEmpty && rejected.allSatisfy { !$0.pixelsChanged }, "image \(n + 1): \(rejected)")
        }
    }

    /// A check that compares the image data says so when it differs; other
    /// findings don't.
    @Test func changedPixelsAreNamedAsSuch() async throws {
        let a = write(image(), "a.png", type: .png)
        let ctx = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image(), in: CGRect(x: 0, y: 0, width: 96, height: 64))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 10, y: 10, width: 1, height: 1))
        let b = write(ctx.makeImage()!, "b.png", type: .png)
        let c = write(image(width: 95), "c.png", type: .png)
        func finding(_ result: URL) async -> VerificationError? {
            do { try await Verifier.verify(original: a, result: result, format: .png, pixelsMustMatch: true) } catch { return error as? VerificationError }
            return nil
        }
        #expect(await finding(b)?.pixelsChanged == true)
        #expect(await finding(c).map { !$0.pixelsChanged } == true)
    }

    @Test func originalGoesToTrashAndCanBeFound() async throws {
        var settings = self.settings
        settings.moveOriginalsToTrash = true
        let url = write(image(), "trash me.png", type: .png)
        guard case .optimized(_, _, _, _, let trashed?, _, _) = try await FileOptimizer(settings: settings).optimize(url, progress: { _ in })
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
