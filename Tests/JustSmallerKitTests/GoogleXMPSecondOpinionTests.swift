import Foundation
import Testing
@testable import JustSmallerKit

/// Google's XMP in real files, read by the engine (GoogleXMP) and by a
/// second, independent reader (Tests/corpus/google-xmp.py: Python, expat):
/// both must find the same directories, items and motion photo mark, and
/// the same packets unreadable. Off by default; the corpus runner runs it on
/// every tier:
///     JUST_SMALLER_SECOND_OPINION=../Testkorpus/quick Tools/test.sh --filter GoogleXMPSecondOpinion
@Suite(.enabled(if: ProcessInfo.processInfo.environment["JUST_SMALLER_SECOND_OPINION"] != nil))
struct GoogleXMPSecondOpinionTests {
    private struct Opinion: Decodable {
        let file: String, unreadable: Bool, motion: Bool, microVideoOffset: Int?
        /// Per directory, per item: semantic, mime, length, padding.
        let directories: [[[Value]]]

        enum Value: Decodable, Equatable {
            case text(String?), number(Int)
            init(from decoder: any Decoder) throws {
                let c = try decoder.singleValueContainer()
                if c.decodeNil() { self = .text(nil) } else if let n = try? c.decode(Int.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
            }
        }
    }

    @Test func pythonReadsTheSame() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["JUST_SMALLER_SECOND_OPINION"]))
        let names = [GoogleXMP.containerNamespaces, [GoogleXMP.cameraNamespace]].joined().map { Data($0.utf8) }
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { ImageFormat.detect(at: $0) == .jpeg }
            .filter { url in (try? Data(contentsOf: url, options: .alwaysMapped)).map { d in names.contains { d.range(of: $0) != nil } } ?? false }
            .sorted { $0.path < $1.path }
        // The corpus runner reads this line: no line, no comparison.
        print("second opinion: \(files.count) files")
        guard !files.isEmpty else { return }

        let python = Process(), out = Pipe()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../corpus/google-xmp.py").standardized
        python.arguments = ["python3", script.path] + files.map(\.path)
        python.standardOutput = out
        try python.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        python.waitUntilExit()
        #expect(python.terminationStatus == 0)
        let opinions = try output.split(separator: UInt8(ascii: "\n")).map { try JSONDecoder().decode(Opinion.self, from: Data($0)) }
        #expect(opinions.count == files.count)

        for opinion in opinions {
            let data = try Data(contentsOf: URL(fileURLWithPath: opinion.file), options: .alwaysMapped)
            let read = GoogleXMP.read(try JPEGMarkers.headers(ByteView(data)).segments)
            let name = URL(fileURLWithPath: opinion.file).lastPathComponent
            #expect((read == nil) == opinion.unreadable, "\(name): readable")
            guard let read else { continue }
            #expect(read.marksMotionPhoto == opinion.motion, "\(name): motion photo mark")
            #expect(read.microVideoOffset == opinion.microVideoOffset, "\(name): MicroVideoOffset")
            let ours = read.directories.map { $0.map { [Opinion.Value.text($0.semantic), .text($0.mime), .number($0.length), .number($0.padding)] } }
            #expect(ours == opinion.directories, "\(name): directories")
        }
    }
}
