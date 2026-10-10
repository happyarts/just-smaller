import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

/// JPEGs with restart markers (an interval in DRI, RST0–RST7 in the scans):
/// optimized without loss, their coefficients proven the same; the metadata
/// filter leaves interval and markers as they are; the structure check
/// counts them in every scan, by the scan's own blocks, and in a gain map
/// too.
@Suite(.serialized)
final class RestartMarkerTests {
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

    /// A 40 × 24 progressive JPEG, 4:2:0, with a restart after every MCU
    /// (DRI 1): the scans of one component restart after each of their own
    /// blocks, 15 for luma, 6 for each chroma component. libjpeg-turbo's
    /// cjpeg -quality 90 -sample 2x2,1x1,1x1 on a generated gradient, then
    /// jpegtran -progressive -restart 1B.
    static let progressiveJPEG = Data(base64Encoded: """
        /9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMU
        FRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU
        FBQUFBQUFBT/wgARCAAYACgDASIAAhEBAxEB/8QAFwABAQEBAAAAAAAAAAAAAAAAAAUGB//EABcBAQEBAQAAAAAAAAAAAAAAAAYF
        BwL/3QAEAAH/2gAMAwEAAhADEAAAAeG1ddUUxP/Q5tU11Wkp/9HPuhOdj//Sp1SRin//095UCJj/1OygdR//xAAXEAADAQAAAAAA
        AAAAAAAAAAAAAwQU/9oACAEBAAEFAlw6T//QXDpP/9FcOk//0lw6T//TXDpP/9RcOk//1Vw6T//WXDpP/9dcOk//0Fw6T//RXDpP
        /9JcOk//01w6T//UXDpP/9VcOk//xAAeEQAABQUBAAAAAAAAAAAAAAAAAQIDBAUREjFB4f/aAAgBAwEBPwGDVLd8H//Qg1S3fB//
        0Warii2Vh//ShSHE6PQ//9OFIcTo9D//1G5TqCxSY//EACgRAAADBQcFAQAAAAAAAAAAABESEwABAgMEBRQhMUFhgjJjcaKzQv/a
        AAgBAgEBPwGbaC/cU4rF+afs3//Qm2gv3FOKxfmn7N//0Yp18evd1x/ZiDx0DLcBb//Slzo6y7r4rmPuTp8BsA6t/9OXOjrLuviu
        Y+5OnwGwDq3/1KGmk2pTw1lZCaZEIvxdk8NAdk5v/8QAFxAAAwEAAAAAAAAAAAAAAAAAABESMf/aAAgBAQAGPwLJR//QyUf/0clH
        /9LJR//TyUf/1MlH/9XJR//WyUf/18lH/9DJR//RyUf/0slH/9PJR//UyUf/1clH/8QAFhABAQEAAAAAAAAAAAAAAAAAAPER/9oA
        CAEBAAE/IaDr/9Cg6//RpOv/0qS//9Og6//UoO6//9Wg6//WoO6//9ekv//QoO6//9Gkv//StOv/06Dr/9Sk6//VpL//2gAMAwEA
        AgADAAAAEJP/0OP/0T//0o//0/8A/9QL/8QAHREAAQQCAwAAAAAAAAAAAAAAEQAhMYEBUWGhsf/aAAgBAwEBPxBvAW709L//0G8B
        bvT0v//RGUgRa//SIaA4Mr//0yGgODK//9RnjGF//8QAHxEAAAYCAwEAAAAAAAAAAAAAAAERITFBUYFhofDR/9oACAECAQE/EMj2
        MQcNtR//0Mj2MQcNtR//0fiH7XKCuwP/0ny189UgLuB//9N8tfPVIC7gf//UtcAKKEYxCEExFCm4/8QAGxAAAQUBAQAAAAAAAAAA
        AAAAIQARMZGhUcH/2gAIAQEAAT8QHxyVxf/QHxyVxf/RGxzU0L//0hsZvTQv/9MfHJXF/9QfH4OL/9UfHJXF/9YfH5OL/9cbGb00
        L//QHx+Di//RGxm9NC//0gsclcX/0x8c1cX/1BsU1NC//9UbGb00L//Z
        """, options: .ignoreUnknownCharacters)!

    enum Fixture: String, CaseIterable, Sendable {
        /// ImageIO's baseline JPEG, 4:2:0: a restart after every MCU row.
        case baseline
        case progressive
    }

    /// The fixture as a file; the baseline JPEG with a location, so the
    /// metadata filter has something to remove.
    private func file(_ fixture: Fixture, _ name: String) throws -> URL {
        let url = dir.appending(path: name)
        switch fixture {
        case .baseline:
            // 7 × 10 MCUs: restarts numbered past RST7.
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, TestImages.pattern(width: 100, height: 150),
                                       [kCGImagePropertyGPSDictionary: TestImages.gps] as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
        case .progressive:
            try Self.progressiveJPEG.write(to: url)
        }
        return url
    }

    /// Whether the structure check rejects `bytes` as the result of optimizing `original`.
    private func rejects(_ bytes: Data, original: URL) throws -> Bool {
        do {
            try StructureCheck.verify(ByteView(bytes), against: StructureCheck.Reference(original: original, format: .jpeg))
            return false
        } catch is VerificationError {
            return true
        }
    }

    private func optimize(_ url: URL) async throws -> Outcome {
        try await FileOptimizer(settings: settings).optimize(url) { _ in }
    }

    // MARK: - Tests

    /// Both fixtures restart as described, with the markers numbered 0–7 in
    /// turn and past RST7; optimized, they keep every DCT coefficient.
    @Test(arguments: Fixture.allCases)
    func optimizedWithTheSameCoefficients(fixture: Fixture) async throws {
        let url = try file(fixture, "\(fixture).jpg")
        let original = try Data(contentsOf: url)
        let r = TestImages.restarts(original)
        switch fixture {
        case .baseline:
            #expect(r.interval > 0 && r.scans.count == 1 && r.scans[0].markers.count > 8)
        case .progressive:
            #expect(r.interval == 1 && r.scans.count == 10)
            // Scans of all three components count MCUs (6), of luma its 15 blocks, of chroma its 6.
            #expect(Set(r.scans.map { [$0.components, $0.markers.count] }) == [[3, 5], [1, 14], [1, 5]])
        }
        for scan in r.scans { #expect(scan.markers.map { Int(original[$0 + 1]) - 0xD0 } == scan.markers.indices.map { $0 % 8 }) }
        let reference = dir.appending(path: "reference-\(fixture).jpg")
        try original.write(to: reference)

        guard case .optimized(_, _, let tools, _, _, let fidelity, _) = try await optimize(url) else {
            Issue.record("not optimized, nothing checked"); return
        }
        #expect(tools.contains("jpeg-scan") && fidelity == .pixelIdentical)
        try await Verifier.verify(original: reference, result: url, format: .jpeg, pixelsMustMatch: true)
    }

    /// The metadata filter rewrites only the segments before the first scan
    /// and keeps the restart interval: the scans stay byte for byte.
    @Test(arguments: Fixture.allCases)
    func metadataFilterKeepsIntervalAndMarkers(fixture: Fixture) throws {
        let url = try file(fixture, "metadata-\(fixture).jpg")
        let original = try Data(contentsOf: url)
        let filtered = try JPEGMetadataFilter.filter(original, level: .removePrivate, orientation: 1)
        if fixture == .baseline { #expect(filtered != original) }
        let before = TestImages.restarts(original), after = TestImages.restarts(filtered)
        #expect(after.interval == before.interval)
        func scans(_ d: Data) throws -> Data { d.suffix(from: d.startIndex + (try JPEGMarkers.headers(ByteView(d)).scan)) }
        #expect(try scans(filtered) == scans(original))
        let result = dir.appending(path: "filtered-\(fixture).jpg")
        try filtered.write(to: result)
        try MetadataCheck.verify(original: url, result: result, level: .removePrivate)
        #expect(try !rejects(filtered, original: url))
    }

    /// Sound files pass — the fixtures and jpeg-scan's rewrite of them —
    /// and every kind of wrong restart is caught: a marker out of turn, one
    /// missing or one too many (in a scan of one subsampled component, too,
    /// which counts that component's blocks), no interval for the markers,
    /// or another interval.
    @Test(arguments: Fixture.allCases)
    func structureCheckCountsRestartMarkers(fixture: Fixture) async throws {
        let url = try file(fixture, "check-\(fixture).jpg")
        let b = try Data(contentsOf: url)
        #expect(try !rejects(b, original: url))
        let rewritten = dir.appending(path: "rewritten-\(fixture).jpg")
        try await ToolRunner.run("jpeg-scan", [url.path, rewritten.path], in: dir)
        #expect(try !rejects(try Data(contentsOf: rewritten), original: url))

        let r = TestImages.restarts(b)
        let dri = try #require(r.dri)
        // The scan whose markers are damaged: for the progressive JPEG one of a chroma component.
        let scan = try #require(fixture == .baseline ? r.scans.first : r.scans.first { $0.components == 1 && $0.markers.count == 5 })
        let last = try #require(scan.markers.last)
        var outOfTurn = b
        outOfTurn[scan.markers[1] + 1] = 0xD7
        #expect(try rejects(outOfTurn, original: url), "marker out of turn")
        // The last one missing: the others still in turn, one too few.
        #expect(try rejects(b[..<last] + b[(last + 2)...], original: url), "marker missing")
        // One more right after the last, numbered in turn.
        let next = UInt8(0xD0 + scan.markers.count % 8)
        #expect(try rejects(b[..<last] + Data([0xFF, b[last + 1], 0xFF, next]) + b[(last + 2)...], original: url), "marker too many")
        #expect(try rejects(b[..<dri] + b[(dri + 6)...], original: url), "no interval")
        // Twice the interval: fewer restarts than there are markers.
        let doubled = UInt16(r.interval * 2)
        #expect(try rejects(b[..<(dri + 4)] + Data([UInt8(doubled >> 8), UInt8(doubled & 0xFF)]) + b[(dri + 6)...], original: url),
                "other interval")
    }

    /// In a JPEG with a gain map (ImageIO restarts its one component too),
    /// the structure check counts the gain map's restart markers as well.
    @Test func gainMapRestartsAreCounted() throws {
        let url = TestImages.gainMapPhoto(at: dir.appending(path: "gain-map.jpg"))
        let b = try Data(contentsOf: url)
        let gainMap = try #require(JPEGLayout.read(ByteView(b))?.images.dropFirst().first)
        let r = TestImages.restarts(b, from: gainMap.lowerBound)
        #expect(r.scans.count == 1 && r.scans[0].components == 1 && r.scans[0].markers.count > 1)
        #expect(try !rejects(b, original: url))
        var outOfTurn = b
        outOfTurn[r.scans[0].markers[1] + 1] = 0xD7
        #expect(try rejects(outOfTurn, original: url), "marker out of turn")
        let dri = try #require(r.dri)
        #expect(try rejects(b[..<dri] + b[(dri + 6)...], original: url), "no interval")
    }
}
