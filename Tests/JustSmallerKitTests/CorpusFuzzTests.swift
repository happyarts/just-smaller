import Foundation
import Testing
@testable import JustSmallerKit

/// Damaged versions of real files through every reader the engine has:
/// format detection, the metadata filters (and with them the EXIF, IPTC and
/// XMP readers), the multi-picture index, the quality estimate and the
/// structure check. None may stop the process, whatever the bytes.
///
/// Runs on a folder of real images, off by default. Seconds: two files per
/// format (by size, the middle one and one from the upper quarter: real
/// photos with metadata, not edge cases) and three JPEGs with Google's
/// container in their XMP, 40 rounds each. Before a release, every file with 200 rounds:
///     JUST_SMALLER_FUZZ=../Testkorpus Tools/test.sh --filter CorpusFuzz
///     JUST_SMALLER_FUZZ=../Testkorpus JUST_SMALLER_FUZZ_ALL=1 Tools/test.sh --filter CorpusFuzz
/// JUST_SMALLER_FUZZ_ROUNDS sets the rounds.
/// Before each input is tried it is saved as `fuzz-last-input` in the
/// temporary folder, so a crash can be reproduced.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["JUST_SMALLER_FUZZ"] != nil))
struct CorpusFuzzTests {
    private let environment = ProcessInfo.processInfo.environment
    private var everything: Bool { environment["JUST_SMALLER_FUZZ_ALL"] != nil }
    private var rounds: Int { Int(environment["JUST_SMALLER_FUZZ_ROUNDS"] ?? "") ?? (everything ? 200 : 40) }
    private let last = FileManager.default.temporaryDirectory.appending(path: "fuzz-last-input")

    private struct Random {
        var state: UInt64
        mutating func callAsFunction(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(n, 1)))
        }
    }

    private func files() throws -> [(URL, ImageFormat)] {
        let root = URL(fileURLWithPath: try #require(environment["JUST_SMALLER_FUZZ"]))
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let found = all.sorted { $0.path < $1.path }.compactMap { url in ImageFormat.detect(at: url).map { (url, $0) } }
        guard !everything else { return found }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        let sample = Dictionary(grouping: found, by: \.1).values.flatMap { files -> [(URL, ImageFormat)] in
            let bySize = files.sorted { size($0.0) < size($1.0) }
            return Set([bySize.count / 2, bySize.count * 3 / 4]).sorted().map { bySize[$0] }
        }
        // The container sits in the first segments: the first 64 KB tell.
        // Google's container or Dynamic Depth's (which sits in the extended XMP).
        let containers = GoogleXMP.containerNamespaces.map { Data($0.utf8) }
        let google = found.filter { url, format in
            guard format == .jpeg, let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 4 << 20)) ?? Data()
            return containers.contains { head.range(of: $0) != nil }
        }.prefix(3)
        return Array(Set((sample + google).map(\.0.path))).sorted().compactMap { path in found.first { $0.0.path == path } }
    }

    /// A few bytes changed, inserted, removed or repeated — or, for `header`,
    /// only within the first `header` bytes.
    private func mutate(_ b: [UInt8], _ random: inout Random, within header: Int? = nil) -> [UInt8] {
        var m = b
        let span = max(1, min(header ?? m.count, m.count))
        for _ in 0...random(3) {
            guard !m.isEmpty else { break }
            let at = random(min(span, m.count))
            switch random(6) {
            case 0: m[at] ^= UInt8(1 << random(8))
            case 1: m[at] = [0x00, 0xFF, 0x7F, 0x80, 0x01][random(5)]
            case 2: m.insert(contentsOf: (0..<1 + random(16)).map { _ in UInt8(random(256)) }, at: at)
            case 3: m.removeSubrange(at..<min(m.count, at + 1 + random(64)))
            case 4: // a length field: two bytes set to something large or small
                if at + 1 < m.count { m[at] = UInt8(random(256)); m[at + 1] = UInt8(random(256)) }
            default:
                if header == nil { m = Array(m.prefix(at)) }
            }
        }
        return m
    }

    /// Every reader of the engine on `m`.
    private func exercise(_ m: [UInt8], format: ImageFormat, url: URL, reference: StructureCheck.Reference) {
        let data = Data(m)
        try? data.write(to: last)
        _ = ImageFormat.detect(header: data.prefix(4096), pathExtension: url.pathExtension)
        for level in [MetadataHandling.keep, .removePrivate, .removeAll] {
            switch format {
            case .jpeg: _ = try? JPEGMetadataFilter.filter(data, level: level, orientation: 6)
            case .png: _ = try? PNGMetadataFilter.filter(data, level: level, orientation: 6)
            case .webp: _ = try? WebPMetadataFilter.filter(data, level: level)
            default: break
            }
        }
        switch format {
        case .jpeg:
            _ = MultiPictureIndex.read(ByteView(data))
            if let headers = try? JPEGMarkers.headers(ByteView(data)).segments { _ = GoogleXMP.read(headers) }
            if let layout = JPEGLayout.read(ByteView(data)) {
                for level in [MetadataHandling.keep, .removeAll] {
                    _ = try? layout.assembled(layout.images.map { data.subdata(in: $0) }, from: data, level: level)
                }
                for part in layout.keptData { _ = (try? ByteView(data).view(part.range)).flatMap(MP4Metadata.holdsMetadata) }
            }
            _ = try? JPEGMetadataFilter.filter(data, level: .removePrivate, orientation: 1, itemLengths: [1: 5, 2: Int.max])
            _ = try? JPEGLayout.imagePairs(data, data)
            _ = MetadataRegions.of(data)
            _ = JPEGQuality.estimate(data)
        case .webp:
            _ = RIFFChunks.webp(ByteView(data))
        case .svg:
            _ = SVGText.utf8(data)
        case .heic:
            _ = try? HEIFMetadataFilter.filter(data, level: .removePrivate)
            _ = try? HEIFItems.rewrite(data, adding: [HEIFItems.NewItem(type: "mime", contentType: "application/rdf+xml", data: [0x3C])])
        default: break
        }
        _ = try? StructureCheck.verify(ByteView(data), against: reference)
    }

    @Test func readersSurviveDamagedFiles() throws {
        var random = Random(state: 0xF022)
        let files = try files()
        #expect(!files.isEmpty)
        for (url, format) in files {
            let b = [UInt8](try Data(contentsOf: url))
            let reference = StructureCheck.Reference(original: url, format: format)
            for _ in 0..<rounds {
                exercise(mutate(b, &random), format: format, url: url, reference: reference)
            }
            // Damage where the metadata lives, too: the first kilobytes.
            for _ in 0..<rounds {
                exercise(mutate(b, &random, within: 4096), format: format, url: url, reference: reference)
            }
        }
    }

    /// The EXIF, IPTC and XMP blocks of the JPEGs, damaged on their own:
    /// deeper into those readers than damage to the whole file gets. XMP
    /// goes through Google's reader (with the file's other segments, so a
    /// damaged extended part is put together with the rest) and the filter.
    @Test func metadataReadersSurviveDamagedBlocks() throws {
        var random = Random(state: 0xE71F)
        for (url, format) in try files() where format == .jpeg {
            guard let headers = try? JPEGMarkers.headers(ByteView(Data(contentsOf: url))).segments else { continue }
            for h in headers {
                let payload = [UInt8](h.payload.bytes)
                let part = JPEGMarkers.part(h.marker, payload: payload)
                // The main XMP and the first extended part (with the others, so it is put together).
                if part == .xmp || part == .extendedXMP {
                    if part == .xmp || h.offset == headers.first(where: { JPEGMarkers.part($0.marker, payload: $0.payload.bytes) == .extendedXMP })?.offset {
                        xmp(h, in: headers, &random)
                    }
                    continue
                }
                guard part == .exif || part == .photoshop else { continue }
                let header = part == .exif ? JPEGMarkers.exifHeader.count : JPEGMarkers.photoshopHeader.count
                let block = Array(payload.dropFirst(header))
                for _ in 0..<rounds {
                    let m = mutate(block, &random)
                    try? Data(m).write(to: last)
                    for level in [MetadataHandling.removePrivate, .copyrightOnly, .removeAll] {
                        if part == .exif { _ = EXIFFilter.filter(m, level: level) } else { _ = IPTCFilter.filter(m, level: level) }
                    }
                    _ = try? part == .exif ? PayloadCheck.tiff(ByteView(m)) : PayloadCheck.photoshopResources(ByteView(m))
                }
            }
        }
    }

    /// The XMP segment `segment` of a file with `headers`, damaged, among
    /// the others unchanged.
    private func xmp(_ segment: JPEGMarkers.Segment, in headers: [JPEGMarkers.Segment], _ random: inout Random) {
        let payload = [UInt8](segment.payload.bytes)
        for _ in 0..<rounds {
            let m = mutate(payload, &random)
            guard m.count <= 0xFFFF - 2 else { continue }
            try? Data(m).write(to: last)
            autoreleasepool { exerciseXMP(m, segment, headers) }
        }
    }

    /// `m` in place of `segment`, through Google's reader and the XMP filter.
    private func exerciseXMP(_ m: [UInt8], _ segment: JPEGMarkers.Segment, _ headers: [JPEGMarkers.Segment]) {
        var file = Data([0xFF, 0xD8])
        for h in headers { file += h.offset == segment.offset ? JPEGMarkers.write(segment.marker, m) : h.whole.bytes }
        file += Data([0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9])
        if let damaged = try? JPEGMarkers.headers(ByteView(file)).segments { _ = GoogleXMP.read(damaged) }
        if m.starts(with: JPEGMarkers.xmpHeader) {
            _ = XMPFilter.filter(Array(m.dropFirst(JPEGMarkers.xmpHeader.count)), level: .removePrivate, itemLengths: [1: 1, 2: Int.max])
        }
    }

    /// JPEG headers the structure check accepts must be headers libjpeg reads
    /// without a warning; a difference is a rule the check is missing.
    @Test func structureCheckAgreesWithLibjpeg() async throws {
        ToolRunner.directory = toolsDirectory
        var random = Random(state: 0x11B)
        let dir = FileManager.default.temporaryDirectory.appending(path: "fuzz-libjpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var disagreements: [String] = []
        for (url, format) in try files() where format == .jpeg {
            let b = [UInt8](try Data(contentsOf: url))
            let reference = StructureCheck.Reference(original: url, format: format)
            // Only the headers: damage in the entropy-coded data is the
            // coefficient comparison's to find, not the structure check's.
            let header = (try? JPEGMarkers.headers(ByteView(b)))?.scan ?? 0
            guard header > 2 else { continue }
            for _ in 0..<rounds / 4 {
                let m = mutate(b, &random, within: header)
                guard (try? StructureCheck.verify(ByteView(m), against: reference)) != nil else { continue }
                let file = dir.appending(path: "m.jpg")
                try Data(m).write(to: file)
                do {
                    try await ToolRunner.run("jpegcmp", ["--check-headers", file.path], in: dir)
                } catch {
                    let kept = dir.deletingLastPathComponent().appending(path: "fuzz-disagreement-\(disagreements.count).jpg")
                    try? Data(m).write(to: kept)
                    disagreements.append("\(url.lastPathComponent) → \(kept.path)")
                }
            }
        }
        #expect(disagreements.isEmpty, "accepted, but libjpeg warns: \(disagreements.prefix(10))")
    }
}
