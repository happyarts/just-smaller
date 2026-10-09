import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import JustSmallerKit

/// Animated PNGs (APNG): optimized, they stay animated with every frame,
/// its region, timing, disposal and blending, and show the same pixels at
/// every moment; the structure check holds every frame to the rules; a
/// damaged animation stays exactly as it is.
@Suite(.serialized)
final class AnimatedPNGTests {
    let dir: URL
    var settings = OptimizationSettings()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings.moveOriginalsToTrash = false
        ToolRunner.directory = toolsDirectory
        Trash.testFolder = FileManager.default.temporaryDirectory.appending(path: "JustSmallerTests-Trash")
    }
    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    /// One frame: its region of the canvas, how long it shows (numerator and
    /// denominator, in seconds), what becomes of its region afterwards
    /// (0 nothing, 1 background, 2 the previous state) and how it is drawn
    /// (0 replacing, 1 over what is there).
    struct Frame {
        var x = 0, y = 0
        var width: Int, height: Int
        var delay: (UInt16, UInt16)
        var dispose: UInt8 = 0, blend: UInt8 = 0
    }

    /// Three frames on a 64 × 48 canvas: the whole first one, then two
    /// smaller ones at an offset, one drawn over the canvas with
    /// half-transparent pixels, one replacing its region, partly with fully
    /// transparent pixels.
    static let frames = [
        Frame(width: 64, height: 48, delay: (1, 10)),
        Frame(x: 8, y: 6, width: 24, height: 16, delay: (25, 100), dispose: 2, blend: 1),
        Frame(x: 30, y: 20, width: 32, height: 24, delay: (1, 2), dispose: 1, blend: 0),
    ]

    /// Straight RGBA pixels of frame `k`, different in every frame.
    static func pixels(_ k: Int, _ f: Frame) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<f.height {
            for x in 0..<f.width {
                let alpha: UInt8 = switch k {
                case 0: 255
                case 1: (x + y) % 3 == 0 ? 128 : 255
                default: (x / 4 + y / 4) % 2 == 0 ? 0 : 255
                }
                out += [UInt8((x * 255 / f.width + 40 * k) & 255), UInt8(y * 255 / f.height), UInt8((x * y + 90 * k) & 255), alpha]
            }
        }
        return out
    }

    static func be32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).bigEndian, Array.init) }

    /// A frame's control chunk payload.
    static func fcTL(_ sequence: Int, _ f: Frame) -> [UInt8] {
        be32(sequence) + be32(f.width) + be32(f.height) + be32(f.x) + be32(f.y)
            + be32(Int(f.delay.0) << 16 | Int(f.delay.1)) + [f.dispose, f.blend]
    }

    /// The colours of a palette APNG, some half and some fully transparent.
    static let palette: [[UInt8]] = (0..<16).map { (i: Int) -> [UInt8] in
        let alpha: UInt8 = i % 5 == 0 ? 0 : i % 3 == 0 ? 128 : 255
        return [UInt8(i * 16), UInt8(255 - i * 16), UInt8(i * 53 & 255), alpha]
    }

    /// A frame's image data: each row with filter 0, deflated. RGBA, or
    /// indices into `palette`, different in every frame.
    static func imageData(_ k: Int, _ f: Frame, palette: Bool = false) -> [UInt8] {
        let values = palette ? (0..<f.width * f.height).map { UInt8(($0 % f.width / 4 + $0 / f.width / 4 + 5 * k) % 16) } : pixels(k, f)
        let row = f.width * (palette ? 1 : 4)
        let rows = (0..<f.height).flatMap { [0] + values[$0 * row..<($0 + 1) * row] }
        return [UInt8](Zlib.deflate(Data(rows))!)
    }

    /// An APNG of `frames` (RGBA, or with `palette` a palette image; 8 bits),
    /// played `plays` times (0: for ever), with `chunks` before the image
    /// data. The first frame is the image (IDAT), the others follow in fdAT
    /// chunks.
    static func apng(_ frames: [Frame] = frames, plays: Int = 0, chunks: [Data] = [], palette: Bool = false) -> Data {
        var png = Data(PNGChunks.signature)
        png += PNGChunks.write("IHDR", be32(frames[0].width) + be32(frames[0].height) + [8, palette ? 3 : 6, 0, 0, 0])
        png += PNGChunks.write("acTL", be32(frames.count) + be32(plays))
        for chunk in chunks { png += chunk }
        if palette {
            png += PNGChunks.write("PLTE", Self.palette.flatMap { $0.prefix(3) })
            png += PNGChunks.write("tRNS", Self.palette.map { $0[3] })
        }
        var sequence = 0
        for (k, f) in frames.enumerated() {
            png += PNGChunks.write("fcTL", fcTL(sequence, f))
            sequence += 1
            if k == 0 {
                png += PNGChunks.write("IDAT", imageData(k, f, palette: palette))
            } else {
                png += PNGChunks.write("fdAT", be32(sequence) + imageData(k, f, palette: palette))
                sequence += 1
            }
        }
        return png + PNGChunks.write("IEND", [])
    }

    /// The APNG of `frames` with each chunk replaced by what `change` makes
    /// of it: its type, sequence number (fcTL, fdAT) and payload in, chunks out.
    static func changed(_ change: (_ type: String, _ sequence: Int?, _ payload: [UInt8]) -> [Data]) -> Data {
        let chunks = try! PNGChunks.read(ByteView(apng()), strict: false)
        return Data(PNGChunks.signature) + chunks.flatMap { c -> [Data] in
            let sequence = ["fcTL", "fdAT"].contains(c.type) ? try? c.data.be(0, 4) : nil
            return change(c.type, sequence, [UInt8](c.data.bytes))
        }.reduce(Data(), +)
    }

    /// `payload` with `bytes` written at `offset`.
    static func patched(_ payload: [UInt8], at offset: Int, _ bytes: [UInt8]) -> [UInt8] {
        var p = payload
        p.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        return p
    }

    /// Damage to the animation that leaves the file's end and its first
    /// frame intact, so a lenient reader still shows it.
    enum Damage: String, CaseIterable, Sendable {
        case moreFramesAnnounced, fewerFramesAnnounced, frameBeyondTheCanvas, frameDataCRC, frameDataOutOfSequence,
             frameDataARowShort, frameWithoutData, frameControlOutOfSequence, secondAnimationControl,
             animationControlAfterTheImage, firstFrameSmallerThanTheCanvas, unknownDisposal

        /// The chunks that take the place of one: its type, sequence number
        /// (fcTL, fdAT) and payload.
        func change(_ t: String, _ s: Int?, _ p: [UInt8]) -> [Data] {
            let same = [PNGChunks.write(t, p)]
            switch self {
            case .moreFramesAnnounced: return t == "acTL" ? [PNGChunks.write(t, be32(4) + be32(0))] : same
            case .fewerFramesAnnounced: return t == "acTL" ? [PNGChunks.write(t, be32(2) + be32(0))] : same
            case .frameBeyondTheCanvas: return t == "fcTL" && s == 3 ? [PNGChunks.write(t, patched(p, at: 12, be32(40)))] : same
            case .frameDataCRC:
                var whole = PNGChunks.write(t, p)
                if t == "fdAT", s == 4 { whole[whole.count - 1] ^= 1 }
                return [whole]
            case .frameDataOutOfSequence: return t == "fdAT" && s == 2 ? [PNGChunks.write(t, patched(p, at: 0, be32(9)))] : same
            case .frameDataARowShort:
                guard t == "fdAT", s == 4 else { return same }
                let rows = try! Zlib.inflate([Data(p.dropFirst(4))])
                return [PNGChunks.write(t, be32(4) + [UInt8](Zlib.deflate(rows.dropLast(1 + frames[2].width * 4))!))]
            case .frameWithoutData: return t == "fdAT" && s == 2 ? [] : same
            case .frameControlOutOfSequence: return t == "fcTL" && s == 1 ? [PNGChunks.write(t, patched(p, at: 0, be32(7)))] : same
            case .secondAnimationControl: return t == "acTL" ? same + same : same
            case .animationControlAfterTheImage:
                return t == "acTL" ? [] : t == "IDAT" ? same + [PNGChunks.write("acTL", be32(3) + be32(0))] : same
            case .firstFrameSmallerThanTheCanvas: return t == "fcTL" && s == 0 ? [PNGChunks.write(t, patched(p, at: 4, be32(32)))] : same
            case .unknownDisposal: return t == "fcTL" && s == 1 ? [PNGChunks.write(t, patched(p, at: 24, [3]))] : same
            }
        }
    }

    private func saved(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func optimize(_ url: URL) async throws -> Outcome {
        try await FileOptimizer(settings: settings).optimize(url) { _ in }
    }

    /// Each frame as a viewer shows it at its moment, in sRGB with
    /// premultiplied alpha, and how long it shows.
    private func shown(_ url: URL) throws -> [(pixels: [UInt8], delay: Double)] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try (0..<CGImageSourceGetCount(source)).map { i in
            let image = try #require(CGImageSourceCreateImageAtIndex(source, i, nil))
            let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let png = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            return ([UInt8](UnsafeRawBufferPointer(start: ctx.data, count: image.width * 4 * image.height)),
                    png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double ?? -1)
        }
    }

    // MARK: - Tests

    /// Optimized at each effort, in lossy mode and as a palette image: the
    /// animation chunks keep every frame's region, timing, disposal and
    /// blending and the number of plays; every frame shows the same pixels
    /// for as long as before; the metadata filter removed what the level
    /// removes and nothing of the animation.
    @Test(arguments: [(Effort.fast, false, false), (.balanced, false, false), (.maximum, false, false), (.balanced, true, false),
                      (.balanced, false, true)])
    func staysAnimatedWithEveryFrame(effort: Effort, lossy: Bool, palette: Bool) async throws {
        settings.effort = effort
        settings.lossy = lossy
        settings.outputLossy = .replace
        settings.metadata = .removePrivate
        let original = Self.apng(plays: 3, chunks: [PNGChunks.write("tEXt", Array("Software\0SecretApp".utf8))], palette: palette)
        let url = try saved(original, "animated-\(effort)-\(lossy).png")
        let reference = try saved(original, "reference-\(effort)-\(lossy).png")

        guard case .optimized(_, _, let tools, _, _, let fidelity) = try await optimize(url) else {
            Issue.record("not optimized, nothing checked"); return
        }
        #expect(tools.contains("OxiPNG"))
        // Lossy mode has no lossy step for an animation: a palette would make it a still image.
        #expect(fidelity == .pixelIdentical)
        let result = try Data(contentsOf: url)
        func payloads(_ png: Data, _ type: String) throws -> [Data] {
            try PNGChunks.read(ByteView(png), strict: true).filter { $0.type == type }.map(\.data.bytes)
        }
        #expect(try payloads(result, "acTL") == [Data(Self.be32(3) + Self.be32(3))])
        // Each frame's region, timing, disposal and blending, after its sequence number.
        #expect(try payloads(result, "fcTL").map { $0.dropFirst(4) } == Self.frames.map { Data(Self.fcTL(0, $0).dropFirst(4)) })
        #expect(try !payloads(result, "tEXt").contains { $0.starts(with: Data("Software".utf8)) })

        let before = try shown(reference), after = try shown(url)
        #expect(after.map { Float($0.delay) } == [0.1, 0.25, 0.5])
        #expect(after.map(\.delay) == before.map(\.delay))
        #expect(after.map(\.pixels) == before.map(\.pixels))
        // Every frame shows something new.
        #expect(Set(before.map(\.pixels)).count == 3)
        try await Verifier.verify(original: reference, result: url, format: .png, pixelsMustMatch: true, exactUnderAlpha: !lossy)
    }

    /// A result that lost the animation, shows a frame for a different time
    /// or a frame with other pixels is rejected.
    @Test func lostOrChangedAnimationIsRejected() async throws {
        let original = try saved(Self.apng(), "original.png")
        // Each result with the reason it is rejected for, in English and German.
        let lost = ["animation or second image lost", "Animation oder zweites Bild verloren"]
        let timing = ["animation timing changed", "Animationszeiten verändert"]
        let pixels = ["pixels changed", "Pixel verändert"]
        let results: [(String, Data, [String])] = [
            ("still image", Self.changed { t, _, p in ["acTL", "fcTL", "fdAT"].contains(t) ? [] : [PNGChunks.write(t, p)] }, lost),
            ("frame shown longer", Self.changed { t, s, p in
                [PNGChunks.write(t, t == "fcTL" && s == 1 ? Self.patched(p, at: 20, [0, 30]) : p)]
            }, timing),
            ("delays swapped", Self.changed { t, s, p in
                let delay: [UInt8]? = t != "fcTL" ? nil : s == 1 ? [0, 50, 0, 100] : s == 3 ? [0, 25, 0, 100] : nil
                return [PNGChunks.write(t, delay.map { Self.patched(p, at: 20, $0) } ?? p)]
            }, pixels),
            ("other pixels", Self.changed { t, s, p in
                guard t == "fdAT", s == 2 else { return [PNGChunks.write(t, p)] }
                var rows = [UInt8](try! Zlib.inflate([Data(p.dropFirst(4))]))
                rows[1] ^= 0x40 // the red of the second frame's first pixel
                return [PNGChunks.write(t, Self.be32(2) + [UInt8](Zlib.deflate(Data(rows))!))]
            }, pixels),
        ]
        for (name, data, reason) in results {
            let result = try saved(data, "\(name).png")
            let error = await #expect(throws: VerificationError.self, "\(name)") {
                try await Verifier.verify(original: original, result: result, format: .png, pixelsMustMatch: true)
            }
            #expect(reason.contains(error?.reason ?? ""), "\(name): \(error?.reason ?? "")")
        }
        try await Verifier.verify(original: original, result: original, format: .png, pixelsMustMatch: true)
    }

    /// The structure check holds every frame to the rules: the APNG as
    /// written and OxiPNG's rewrite pass, each kind of damage is caught.
    @Test func structureCheckHoldsEveryFrame() async throws {
        let original = try saved(Self.apng(), "original.png")
        let reference = StructureCheck.Reference(original: original, format: .png)
        let rewritten = dir.appending(path: "rewritten.png")
        #expect(try await Pipeline.oxipng(Pipeline.oxipngOptions(.balanced), lossy: false).run(original, rewritten, dir))
        for url in [original, rewritten] {
            try StructureCheck.verify(ByteView(Data(contentsOf: url)), against: reference)
        }
        for damage in Damage.allCases {
            #expect(throws: VerificationError.self, "\(damage)") {
                try StructureCheck.verify(ByteView(Self.changed(damage.change)), against: reference)
            }
        }
    }

    /// A damaged animation whose first frame still shows stays exactly as
    /// it is: it counts as damaged from the start, the tools refuse it, or
    /// what they make of it is rejected.
    @Test(arguments: Damage.allCases)
    func damagedAnimationStaysAsItIs(damage: Damage) async throws {
        let data = Self.changed(damage.change)
        let url = try saved(data, "\(damage).png")
        if case .optimized = try? await optimize(url) { Issue.record("optimized") }
        #expect(try Data(contentsOf: url) == data)
    }
}
