import Foundation

/// JPEG after ITU T.81: markers and lengths, tables defined before use, one
/// frame, scans that follow the progression rules, restart markers in
/// sequence and in the right number — and every image a multi-picture index
/// lists, sound in the same way. Around the images, the rules of
/// `JPEGLayout`: as many images as before, only those that may change
/// changed, the index exact, the bytes between and after them as they were
/// or gone.
enum JPEGCheck {
    typealias Invalid = FormatError

    /// What the original contributes.
    struct Reference {
        /// Its frame type, which stays allowed (arithmetic, 12-bit, lossless).
        let frame: UInt8?
        /// Whether all its coefficients are coded; nil if it isn't strictly valid.
        let complete: Bool?
        /// The APPn and COM segments of all its images, whole.
        let segments: Set<Data>
        /// The original as it is, its layout, and the metadata level the
        /// rules for the bytes around its images follow.
        let original: ByteView
        let layout: JPEGLayout?
        let level: MetadataHandling

        init(_ a: ByteView, level: MetadataHandling = .keep) {
            let lenient = (try? JPEGMarkers.headers(a))?.segments ?? []
            let frame = JPEGMarkers.frame(lenient)?.marker
            self.frame = frame
            let strict = try? JPEGCheck.parse(a, allowing: frame)
            complete = strict?.complete
            var segments = Set(strict?.segments ?? lenient.filter { JPEGCheck.isMetadata($0.marker) }.map(\.whole.bytes))
            let layout = JPEGLayout.read(a, firstEnd: strict?.end)
            // Those of the images after the first, too.
            for image in layout?.images.dropFirst() ?? [] {
                if let s = try? JPEGMarkers.headers(a.view(image)).segments {
                    segments.formUnion(s.filter { JPEGCheck.isMetadata($0.marker) }.map(\.whole.bytes))
                }
            }
            self.segments = segments
            self.layout = layout
            original = a
            self.level = level
        }
    }

    /// What the strict parse of one image found.
    struct Image {
        var frame: UInt8 = 0
        /// Every coefficient of every component is in some scan, to full precision.
        var complete = false
        /// APPn and COM segments, whole.
        var segments: [Data] = []
        /// Where the image ends (after EOI).
        var end = 0
    }

    private struct Component {
        var id: Int, h: Int, v: Int, table: Int
    }

    /// APPn and COM: metadata, not image data.
    static func isMetadata(_ marker: UInt8) -> Bool { (0xE0...0xEF).contains(marker) || marker == 0xFE }

    static func check(_ b: ByteView, against reference: Reference) throws {
        let image = try parse(b, allowing: reference.frame)
        if reference.complete != false, !image.complete { throw Invalid("image data incomplete") }
        try metadata(image.segments, original: reference.segments)

        try layout(b, firstEnd: image.end, against: reference)
    }

    /// An original on its own: each of its images strict, with its own frame
    /// type allowed, and every coefficient coded — not the rules around the
    /// images, which hold a result to its original.
    static func checkImages(_ b: ByteView) throws {
        /// Where the image from `start` ends.
        func image(from start: Int) throws -> Int {
            let frame = JPEGMarkers.frame(try JPEGMarkers.headers(b.view(from: start)).segments)?.marker
            let image = try parse(b, from: start, allowing: frame)
            guard image.complete else { throw Invalid("image data incomplete") }
            return image.end
        }
        let firstEnd = try image(from: 0)
        for (n, range) in (JPEGLayout.read(b, firstEnd: firstEnd)?.images ?? []).enumerated().dropFirst() {
            try Invalid.within("image \(n + 1)") { _ = try image(from: range.lowerBound) }
        }
    }

    /// Around the images, the rules of the original's `JPEGLayout`; each
    /// image after the first a sound JPEG with only metadata changed that
    /// may change. An original whose layout can't be read gives one image,
    /// and nothing but padding after it.
    private static func layout(_ b: ByteView, firstEnd: Int, against reference: Reference) throws {
        guard let after = JPEGLayout.read(b, firstEnd: firstEnd) else { throw Invalid("unreadable") }
        if let layout = reference.layout {
            try layout.check(after, in: b, original: reference.original, level: reference.level)
        } else {
            guard after.isPlain else { throw Invalid("data after the end of the image") }
        }
        for (n, range) in after.images.enumerated().dropFirst() {
            try Invalid.within("image \(n + 1)") {
                let image = try parse(b, from: range.lowerBound)
                guard image.end == range.upperBound else { throw Invalid("end of image") }
                try metadata(image.segments, original: reference.segments)
            }
        }
    }

    /// Parses one image from `start` to its EOI. Only the frame types libjpeg
    /// writes are accepted, and the original's own.
    static func parse(_ b: ByteView, from start: Int = 0, allowing originalFrame: UInt8? = nil) throws -> Image {
        var image = Image()
        guard try b.be(start, 2) == 0xFFD8 else { throw Invalid("no SOI") }
        var i = start + 2
        var quant = [Bool](repeating: false, count: 4)
        var dc = [Bool](repeating: false, count: 4), ac = [Bool](repeating: false, count: 4)
        var components: [Component] = []
        var width = 0, height = 0, restartInterval = 0, scans = 0
        // Progressive: the last Al each coefficient was coded with, -1 before
        // its first scan. Other frames: [0] says whether the component had its scan.
        var coded: [[Int]] = []

        while true {
            let segment = try JPEGMarkers.segment(at: i, in: b)
            let marker = segment.marker, s = segment.payload, end = segment.end
            if marker == 0xD9 {
                guard scans > 0 else { throw Invalid("no scan") }
                image.end = end
                image.complete = image.frame == 0xC2
                    ? coded.allSatisfy { $0.allSatisfy { $0 == 0 } }
                    : coded.allSatisfy { $0[0] == 0 }
                return image
            }
            guard JPEGMarkers.hasLength(marker) else { throw Invalid(String(format: "marker %02X out of place", marker)) }
            switch marker {
            case _ where isMetadata(marker):
                image.segments.append(segment.whole.bytes)
            case 0xDB: // DQT
                for table in try JPEGMarkers.quantTables(s) {
                    guard table.precision <= 1, table.id <= 3 else { throw Invalid("DQT") }
                    guard !table.steps.contains(0) else { throw Invalid("DQT zero step") }
                    quant[table.id] = true
                }
            case 0xC4: // DHT
                var k = 0
                while k < s.count {
                    let tc = try s.u8(k) >> 4, th = try s.u8(k) & 15
                    guard tc <= 1, th <= 3 else { throw Invalid("DHT class") }
                    let counts = try (1...16).map { try s.u8(k + $0) }
                    let total = counts.reduce(0, +)
                    guard total > 0, total <= 256 else { throw Invalid("DHT size") }
                    // Canonical codes must fit their lengths, and the all-ones
                    // code stays unused (libjpeg's test in jdhuff.c).
                    var code = 0
                    for (n, count) in counts.enumerated() {
                        code += count
                        guard code < 1 << (n + 1) else { throw Invalid("DHT code lengths") }
                        code <<= 1
                    }
                    // DC symbols count bits: up to 16 (lossless 16-bit).
                    if tc == 0, try s.view(k + 17, total).bytes.contains(where: { $0 > 16 }) { throw Invalid("DHT DC symbol") }
                    if tc == 0 { dc[th] = true } else { ac[th] = true }
                    k += 17 + total
                }
                guard k == s.count else { throw Invalid("DHT size") }
            case 0xDD: // DRI
                guard s.count == 2 else { throw Invalid("DRI") }
                restartInterval = try s.be(0, 2)
            case 0xCC: // DAC, arithmetic coding only: class/table, then DC bounds L ≤ U or AC Kx 1–63
                guard let originalFrame, JPEGMarkers.arithmetic.contains(originalFrame), s.count % 2 == 0 else { throw Invalid("DAC") }
                for k in stride(from: 0, to: s.count, by: 2) {
                    let tc = try s.u8(k) >> 4, tb = try s.u8(k) & 15, value = try s.u8(k + 1)
                    guard tc <= 1, tb <= 3, tc == 0 ? value & 15 <= value >> 4 : (1...63).contains(value) else { throw Invalid("DAC") }
                }
            case _ where JPEGMarkers.isFrame(marker):
                guard image.frame == 0 else { throw Invalid("second frame") }
                guard [0xC0, 0xC1, 0xC2].contains(marker) || marker == originalFrame else {
                    throw Invalid(String(format: "frame type %02X", marker))
                }
                image.frame = marker
                let precision = try s.u8(0)
                height = try s.be(1, 2); width = try s.be(3, 2)
                let n = try s.u8(5)
                guard (1...4).contains(n), s.count == 6 + 3 * n, width > 0, height > 0 else { throw Invalid("SOF") }
                // 8 or 12 bits for DCT, 2–16 lossless; anything but 8 only where the original had it.
                let precisions = JPEGMarkers.lossless.contains(marker) ? 2...16 : 8...12
                guard precisions.contains(precision), JPEGMarkers.lossless.contains(marker) || precision % 4 == 0,
                      precision == 8 || marker == originalFrame
                else { throw Invalid("SOF precision") }
                for c in 0..<n {
                    let id = try s.u8(6 + 3 * c), hv = try s.u8(7 + 3 * c), t = try s.u8(8 + 3 * c)
                    let h = hv >> 4, v = hv & 15
                    guard (1...4).contains(h), (1...4).contains(v), t <= 3, !components.contains(where: { $0.id == id })
                    else { throw Invalid("SOF component") }
                    components.append(Component(id: id, h: h, v: v, table: t))
                }
                coded = Array(repeating: Array(repeating: -1, count: 64), count: n)
            case 0xDA: // SOS
                guard image.frame != 0 else { throw Invalid("scan before frame") }
                let ns = try s.u8(0)
                guard (1...4).contains(ns), s.count == 4 + 2 * ns else { throw Invalid("SOS") }
                var members: [Int] = []
                for c in 0..<ns {
                    let id = try s.u8(1 + 2 * c)
                    guard let index = components.firstIndex(where: { $0.id == id }), index > (members.last ?? -1)
                    else { throw Invalid("SOS component") }
                    // Lossless frames are not quantized: they have no tables.
                    guard quant[components[index].table] || JPEGMarkers.lossless.contains(image.frame)
                    else { throw Invalid("quantization table used before it is defined") }
                    members.append(index)
                }
                let ss = try s.u8(1 + 2 * ns), se = try s.u8(2 + 2 * ns)
                let ah = try s.u8(3 + 2 * ns) >> 4, al = try s.u8(3 + 2 * ns) & 15
                try checkScan(frame: image.frame, members: members, tables: s, ss: ss, se: se, ah: ah, al: al,
                              dc: dc, ac: ac, coded: &coded)
                scans += 1
                // The entropy-coded data, up to the next real marker.
                let data = JPEGMarkers.entropyData(from: end, in: b)
                guard data.end < b.count else { throw Invalid("scan runs to the end of the file") }
                guard data.restarts == 0 || restartInterval > 0, data.inSequence else { throw Invalid("restart marker out of sequence") }
                let restarts = data.restarts
                i = data.end
                if restartInterval > 0, !JPEGMarkers.lossless.contains(image.frame) {
                    let hMax = components.map(\.h).max() ?? 1, vMax = components.map(\.v).max() ?? 1
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

    /// APPn and COM segments: those the metadata filter writes are checked,
    /// every other one must be the original's.
    private static func metadata(_ segments: [Data], original: Set<Data>) throws {
        var photoshop = Data(), photoshopChanged = false
        for s in segments {
            let v = ByteView(s), marker = s[s.startIndex + 1], payload = try v.view(from: 4)
            let part = JPEGMarkers.part(marker, payload: payload.bytes)
            let changed = !original.contains(s)
            if part == .photoshop {
                // Resources may continue from one APP13 to the next.
                photoshop += payload.bytes.dropFirst(JPEGMarkers.photoshopHeader.count)
                photoshopChanged = photoshopChanged || changed
                continue
            }
            guard changed else { continue }
            switch part {
            case .jfif: try Invalid.within("JFIF") { try PayloadCheck.jfif(payload) }
            case .jfifExtension, .multiPicture: break // a JFIF thumbnail; the index is checked image by image
            case .exif: try Invalid.within("EXIF") { try PayloadCheck.tiff(payload.view(from: JPEGMarkers.exifHeader.count)) }
            case .xmp: try Invalid.within("XMP") { try PayloadCheck.xml(payload.view(from: JPEGMarkers.xmpHeader.count)) }
            case .extendedXMP:
                try Invalid.within("extended XMP") { try PayloadCheck.extendedXMP(payload.view(from: JPEGMarkers.extendedXMPHeader.count)) }
            case .adobe: try Invalid.within("Adobe marker") { try PayloadCheck.adobe(payload) }
            case .comment: throw Invalid("comment changed")
            case .iccProfile: throw Invalid("colour profile changed")
            case .photoshop, .isoGainMap, .other: throw Invalid(String(format: "APP%X segment changed", marker & 15))
            }
        }
        if photoshopChanged { try Invalid.within("IPTC") { try PayloadCheck.photoshopResources(ByteView(photoshop)) } }
    }

    /// One scan's parameters against T.81 G.1.1.1 (progression) or the
    /// sequential rules, and the tables it needs.
    private static func checkScan(frame: UInt8, members: [Int], tables s: ByteView, ss: Int, se: Int, ah: Int, al: Int,
                                  dc: [Bool], ac: [Bool], coded: inout [[Int]]) throws {
        if frame == 0xC2 {
            guard ss <= se, se <= 63, (ss == 0) == (se == 0), ss == 0 || members.count == 1, ah <= 13, al <= 13
            else { throw Invalid("progression") }
        }
        for (c, index) in members.enumerated() {
            let td = try s.u8(2 + 2 * c) >> 4, ta = try s.u8(2 + 2 * c) & 15
            guard td <= 3, ta <= 3, frame != 0xC0 || (td <= 1 && ta <= 1) else { throw Invalid("SOS table") }
            switch frame {
            case 0xC2:
                if ss == 0, ah == 0, !dc[td] { throw Invalid("Huffman table used before it is defined") }
                if ss > 0, !ac[ta] { throw Invalid("Huffman table used before it is defined") }
                if ss > 0, coded[index][0] < 0 { throw Invalid("AC scan before DC") }
                for k in ss...se {
                    let previous = coded[index][k]
                    guard ah == 0 ? previous < 0 : (previous == ah && al == ah - 1) else { throw Invalid("progression") }
                    coded[index][k] = al
                }
            case 0xC0, 0xC1:
                guard ss == 0, se == 63, ah == 0, al == 0, coded[index][0] < 0 else { throw Invalid("sequential scan") }
                guard dc[td], ac[ta] else { throw Invalid("Huffman table used before it is defined") }
                coded[index][0] = 0
            default:
                coded[index][0] = 0 // the original's own coding: structure only
            }
        }
    }

    private static func divUp(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }
}
