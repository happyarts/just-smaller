import Foundation

/// Reads a result file the strict way before it may replace the original.
/// The pixel and coefficient comparisons prove the image is the same; this
/// proves the file around it is sound: every length, table, checksum and
/// flag as the format's specification wants it, so that no decoder — not
/// only the lenient ones used for the comparison — trips over it. Parts that
/// no step is meant to rewrite (colour profiles, unknown segments) must be
/// the original's byte for byte.
enum StructureCheck {
    struct Invalid: Error {
        let detail: String
        init(_ detail: String) { self.detail = detail }
    }

    static func verify(original: URL, result: URL, format: ImageFormat) throws {
        guard format != .gif else { return }
        do {
            let b = [UInt8](try Data(contentsOf: result, options: .alwaysMapped))
            let a = [UInt8](try Data(contentsOf: original, options: .alwaysMapped))
            switch format {
            case .jpeg: try jpeg(b, original: a)
            case .png: try png(b, original: a)
            case .webp: try webp(b, original: a)
            case .heic: try heif(b, original: a)
            case .svg: try svg(b, original: a)
            case .gif: break
            }
        } catch let error as Invalid {
            throw VerificationError(reason: String(localized: "invalid file structure (\(error.detail))", bundle: .module))
        }
    }

    // MARK: - JPEG

    /// What the strict JPEG parse found.
    struct JPEGInfo {
        var frameMarker: UInt8 = 0
        /// Every coefficient of every component is in some scan, to full precision.
        var complete = false
        /// APPn and COM segments, whole.
        var segments: [[UInt8]] = []
        /// Where the image ends (after EOI).
        var end = 0
    }

    private struct Component {
        var id: UInt8, h: Int, v: Int, table: Int
    }

    /// Parses one JPEG image from `start` to its EOI after ITU T.81: markers
    /// and lengths, tables defined before use, one frame, scans that follow
    /// the progression rules, restart markers in sequence and in the right
    /// number. Only the frame types libjpeg writes are accepted, unless the
    /// original was already of that type.
    static func parseJPEG(_ b: [UInt8], from start: Int = 0, allowing originalFrame: UInt8? = nil) throws -> JPEGInfo {
        var info = JPEGInfo()
        guard b.count >= start + 4, b[start] == 0xFF, b[start + 1] == 0xD8 else { throw Invalid("no SOI") }
        var i = start + 2
        var quant = [Bool](repeating: false, count: 4)
        var dc = [Bool](repeating: false, count: 4), ac = [Bool](repeating: false, count: 4)
        var components: [Component] = []
        var width = 0, height = 0, precision = 8
        var restartInterval = 0
        var scans = 0
        // Progressive: the last Al each coefficient was coded with, -1 before
        // its first scan. Sequential: whether the component had its scan.
        var coded: [[Int]] = []
        func u16(_ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }

        while true {
            guard i + 2 <= b.count else { throw Invalid("no EOI") }
            guard b[i] == 0xFF else { throw Invalid("data between segments") }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue } // fill byte
            if marker == 0xD9 {
                guard scans > 0 else { throw Invalid("no scan") }
                info.end = i + 2
                if info.frameMarker == 0xC2 {
                    info.complete = coded.allSatisfy { $0.allSatisfy { $0 == 0 } }
                } else {
                    info.complete = coded.allSatisfy { $0[0] == 0 }
                }
                return info
            }
            guard marker != 0x01, marker != 0xD8, !(0xD0...0xD7).contains(marker) else {
                throw Invalid(String(format: "marker %02X out of place", marker))
            }
            guard i + 4 <= b.count else { throw Invalid("truncated segment") }
            let length = u16(i + 2)
            guard length >= 2, i + 2 + length <= b.count else { throw Invalid("segment length") }
            let p = i + 4, end = i + 2 + length // payload
            switch marker {
            case 0xE0...0xEF, 0xFE:
                info.segments.append(Array(b[i..<end]))
            case 0xDB: // DQT
                var k = p
                while k < end {
                    let pq = Int(b[k] >> 4), tq = Int(b[k] & 15)
                    let size = 1 + 64 * (pq + 1)
                    guard pq <= 1, tq <= 3, k + size <= end else { throw Invalid("DQT") }
                    for n in 0..<64 {
                        let value = pq == 0 ? Int(b[k + 1 + n]) : u16(k + 1 + 2 * n)
                        guard value > 0 else { throw Invalid("DQT zero step") }
                    }
                    quant[tq] = true
                    k += size
                }
            case 0xC4: // DHT
                var k = p
                while k < end {
                    guard k + 17 <= end else { throw Invalid("DHT") }
                    let tc = Int(b[k] >> 4), th = Int(b[k] & 15)
                    guard tc <= 1, th <= 3 else { throw Invalid("DHT class") }
                    let counts = (1...16).map { Int(b[k + $0]) }
                    let total = counts.reduce(0, +)
                    guard total > 0, total <= 256, k + 17 + total <= end else { throw Invalid("DHT size") }
                    // Canonical codes must fit their lengths, and the all-ones
                    // code stays unused (libjpeg's test in jdhuff.c).
                    var code = 0
                    for (n, count) in counts.enumerated() {
                        code += count
                        guard code < 1 << (n + 1) else { throw Invalid("DHT code lengths") }
                        code <<= 1
                    }
                    if tc == 0, b[k + 17..<k + 17 + total].contains(where: { $0 > 16 }) { throw Invalid("DHT DC symbol") }
                    if tc == 0 { dc[th] = true } else { ac[th] = true }
                    k += 17 + total
                }
            case 0xDD: // DRI
                guard length == 4 else { throw Invalid("DRI") }
                restartInterval = u16(p)
            case 0xCC: // DAC, arithmetic coding only
                guard let originalFrame, Self.arithmetic.contains(originalFrame) else { throw Invalid("DAC") }
            case 0xC0...0xCF where marker != 0xC4 && marker != 0xC8 && marker != 0xCC:
                guard info.frameMarker == 0 else { throw Invalid("second frame") }
                guard [0xC0, 0xC1, 0xC2].contains(marker) || marker == originalFrame else {
                    throw Invalid(String(format: "frame type %02X", marker))
                }
                info.frameMarker = marker
                guard length >= 8 else { throw Invalid("SOF") }
                precision = Int(b[p]); height = u16(p + 1); width = u16(p + 3)
                let n = Int(b[p + 5])
                guard (1...4).contains(n), length == 8 + 3 * n, width > 0, height > 0 else { throw Invalid("SOF") }
                guard precision == 8 || (precision == 12 && marker == originalFrame) else { throw Invalid("SOF precision") }
                for c in 0..<n {
                    let q = p + 6 + 3 * c
                    let h = Int(b[q + 1] >> 4), v = Int(b[q + 1] & 15), t = Int(b[q + 2])
                    guard (1...4).contains(h), (1...4).contains(v), t <= 3, !components.contains(where: { $0.id == b[q] })
                    else { throw Invalid("SOF component") }
                    components.append(Component(id: b[q], h: h, v: v, table: t))
                }
                coded = Array(repeating: Array(repeating: -1, count: 64), count: n)
            case 0xDA: // SOS
                guard info.frameMarker != 0 else { throw Invalid("scan before frame") }
                guard length >= 3, case let ns = Int(b[p]), (1...4).contains(ns), length == 6 + 2 * ns else { throw Invalid("SOS") }
                var members: [Int] = []
                for c in 0..<ns {
                    let q = p + 1 + 2 * c
                    guard let index = components.firstIndex(where: { $0.id == b[q] }), index > (members.last ?? -1)
                    else { throw Invalid("SOS component") }
                    guard quant[components[index].table] else { throw Invalid("quantization table used before it is defined") }
                    members.append(index)
                }
                let q = p + 1 + 2 * ns
                let ss = Int(b[q]), se = Int(b[q + 1]), ah = Int(b[q + 2] >> 4), al = Int(b[q + 2] & 15)
                let huffman = [0xC0, 0xC1, 0xC2].contains(info.frameMarker)
                if info.frameMarker == 0xC2 {
                    guard ss <= se, se <= 63, (ss == 0) == (se == 0), ss == 0 || ns == 1, ah <= 13, al <= 13
                    else { throw Invalid("progression") }
                }
                for (c, index) in members.enumerated() {
                    let td = Int(b[p + 2 + 2 * c] >> 4), ta = Int(b[p + 2 + 2 * c] & 15)
                    guard td <= 3, ta <= 3, info.frameMarker != 0xC0 || (td <= 1 && ta <= 1) else { throw Invalid("SOS table") }
                    if info.frameMarker == 0xC2 {
                        if ss == 0, ah == 0, !dc[td] { throw Invalid("Huffman table used before it is defined") }
                        if ss > 0, !ac[ta] { throw Invalid("Huffman table used before it is defined") }
                        if ss > 0, coded[index][0] < 0 { throw Invalid("AC scan before DC") }
                        for k in ss...se {
                            let previous = coded[index][k]
                            guard ah == 0 ? previous < 0 : (previous == ah && al == ah - 1) else { throw Invalid("progression") }
                            coded[index][k] = al
                        }
                    } else if huffman {
                        guard ss == 0, se == 63, ah == 0, al == 0, coded[index][0] < 0 else { throw Invalid("sequential scan") }
                        guard dc[td], ac[ta] else { throw Invalid("Huffman table used before it is defined") }
                        coded[index][0] = 0
                    } else {
                        coded[index][0] = 0 // other codings: structure only
                    }
                }
                scans += 1
                // The entropy-coded data, up to the next real marker.
                var k = end, restarts = 0
                while true {
                    guard let next = nextFF(b, from: k), next + 1 < b.count else { throw Invalid("scan runs to the end of the file") }
                    let m = b[next + 1]
                    if m == 0x00 { k = next + 2; continue }
                    if m == 0xFF { k = next + 1; continue } // fill before a marker
                    if (0xD0...0xD7).contains(m) {
                        guard restartInterval > 0, Int(m) - 0xD0 == restarts % 8 else { throw Invalid("restart marker out of sequence") }
                        restarts += 1
                        k = next + 2
                        continue
                    }
                    i = next
                    break
                }
                if restartInterval > 0, !Self.lossless.contains(info.frameMarker) {
                    let hMax = components.map(\.h).max()!, vMax = components.map(\.v).max()!
                    let mcus: Int
                    if ns == 1 {
                        let c = components[members[0]]
                        mcus = divUp(divUp(width * c.h, hMax), 8) * divUp(divUp(height * c.v, vMax), 8)
                    } else {
                        mcus = divUp(width, 8 * hMax) * divUp(height, 8 * vMax)
                    }
                    guard restarts == divUp(mcus, restartInterval) - 1 else { throw Invalid("wrong number of restart markers") }
                }
                continue
            case 0xDC: throw Invalid("DNL")
            default: throw Invalid(String(format: "marker %02X", marker))
            }
            i = end
        }
    }

    private static let arithmetic: Set<UInt8> = [0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
    private static let lossless: Set<UInt8> = [0xC3, 0xC7, 0xCB, 0xCF]

    private static func nextFF(_ b: [UInt8], from k: Int) -> Int? {
        b.withUnsafeBufferPointer { p in
            guard k < p.count, let hit = memchr(p.baseAddress! + k, 0xFF, p.count - k) else { return nil }
            return p.baseAddress!.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        }
    }

    private static func divUp(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }

    private static func jpeg(_ b: [UInt8], original a: [UInt8]) throws {
        // The original's own frame type (arithmetic, 12-bit, lossless) stays allowed.
        let frame = (try? JPEGMetadataFilter.segments(Data(a)))?.headers.first { (0xC0...0xCF).contains($0.marker) && ![0xC4, 0xC8, 0xCC].contains($0.marker) }?.marker
        let before = try? parseJPEG(a, allowing: frame)
        let after = try parseJPEG(b, allowing: frame)
        if before?.complete != false, !after.complete { throw Invalid("image data incomplete") }
        try keptSegments(after.segments, original: before?.segments ?? segmentsLeniently(a))

        // After EOI: the images a multi-picture index lists, each a sound
        // JPEG, and nothing else — or exactly what the original had there.
        let trailer = b[after.end...]
        if let index = JPEGStructure.imageIndex(b), index.starts.count > 1 {
            // Each image right where the one before it ends (padding aside).
            var end = after.end
            for start in index.starts.dropFirst() {
                guard start >= end, !JPEGStructure.hasData(in: b[end..<start]) else { throw Invalid("images overlap or have data between them") }
                end = try parseJPEG(b, from: start).end
            }
            guard !JPEGStructure.hasData(after: index.end, in: b) else { throw Invalid("data after the last image") }
        } else if !trailer.isEmpty {
            let originalTrailer = before.map { a[$0.end...] } ?? []
            guard trailer.elementsEqual(originalTrailer) else { throw Invalid("data after the end of the image") }
        }
    }

    /// Metadata segments are rewritten by the metadata filter and checked by
    /// MetadataCheck; JFIF and Adobe markers are written by the encoder and
    /// checked by the coefficient comparison (colour space). Every other
    /// segment of the result — ICC profile, unknown APPn — must be the
    /// original's byte for byte.
    private static func keptSegments(_ result: [[UInt8]], original: [[UInt8]]) throws {
        typealias F = JPEGMetadataFilter
        let rewritten: [(UInt8, [UInt8])] = [(0xE0, Array("JFIF\0".utf8)), (0xE0, Array("JFXX\0".utf8)), (0xE1, F.exifHeader),
                                             (0xE1, F.xmpHeader), (0xE1, F.extendedXMPHeader), (0xE2, Array("MPF\0".utf8)),
                                             (0xED, F.photoshopHeader), (0xEE, Array("Adobe".utf8))]
        let known = Set(original)
        for s in result where !known.contains(s) {
            let isRewritten = rewritten.contains { s[1] == $0.0 && s.dropFirst(4).starts(with: $0.1) }
            guard isRewritten else { throw Invalid(s[1] == 0xFE ? "comment changed" : String(format: "APP%X segment changed", s[1] & 15)) }
        }
    }

    /// The APPn/COM segments of a file the strict parse rejected.
    private static func segmentsLeniently(_ b: [UInt8]) -> [[UInt8]] {
        guard let s = try? JPEGMetadataFilter.segments(Data(b)) else { return [] }
        return s.headers.filter { $0.marker == 0xFE || (0xE0...0xEF).contains($0.marker) }.map { [UInt8]($0.bytes) }
    }
}
