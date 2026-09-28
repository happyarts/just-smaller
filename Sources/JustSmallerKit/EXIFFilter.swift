import Foundation

/// Rewrites an EXIF block (a TIFF structure) with only the tags a level
/// keeps. Values are copied byte for byte in the file's own byte order; only
/// the layout is new. GPS, MakerNotes and the thumbnail (IFD1) never survive
/// filtering.
enum EXIFFilter {
    private struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var value: [UInt8] // raw bytes in the block's byte order
    }

    private static let sizes: [UInt16: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
    private static let exifPointer: UInt16 = 0x8769
    private static let interopPointer: UInt16 = 0xA005

    /// The filtered TIFF block, or nil when nothing worth keeping is left.
    /// Unreadable EXIF is dropped as a whole: better no data than stray data.
    static func filter(_ tiff: [UInt8], level: MetadataHandling) -> [UInt8]? {
        guard let reader = Reader(tiff) else { return nil }
        guard let main = reader.entries(at: reader.firstIFD) else { return nil }
        var exif: [Entry] = [], interop: [Entry] = []
        if let offset = main.first(where: { $0.tag == exifPointer }).flatMap(reader.offset),
           let entries = reader.entries(at: offset) {
            exif = entries
            if let offset = entries.first(where: { $0.tag == interopPointer }).flatMap(reader.offset) {
                interop = reader.entries(at: offset) ?? []
            }
        }
        func kept(_ entries: [Entry], _ ifd: MetadataPolicy.IFD) -> [Entry] {
            entries.filter { MetadataPolicy.keeps(MetadataPolicy.group(exifTag: $0.tag, in: ifd), at: level) }
        }
        let keptMain = kept(main, .main)
        let keptInterop = kept(interop, .interop)
        var keptExif = kept(exif, .exif)
        // ExifVersion alone says nothing; neither does sRGB, the default.
        let meaningful = keptExif.contains { !($0.tag == 0x9000 || $0.tag == 0xA001 && reader.short($0) == 1) }
        if !meaningful && keptInterop.isEmpty { keptExif = [] }
        if keptMain.isEmpty && keptExif.isEmpty { return nil }
        if keptMain.count == 1, keptMain[0].tag == 0x0112, reader.short(keptMain[0]) == 1, keptExif.isEmpty { return nil }
        var writer = Writer(bigEndian: reader.bigEndian)
        return writer.write(main: keptMain, exif: keptExif, interop: keptInterop)
    }

    /// Reads IFDs defensively: every offset and count is checked against the
    /// block, and a loop of IFDs can't run forever (only fixed IFDs are read).
    private struct Reader {
        let b: [UInt8]
        let bigEndian: Bool
        private(set) var firstIFD: Int

        init?(_ b: [UInt8]) {
            guard b.count >= 8 else { return nil }
            switch (b[0], b[1]) {
            case (0x4D, 0x4D): bigEndian = true
            case (0x49, 0x49): bigEndian = false
            default: return nil
            }
            self.b = b
            firstIFD = 0
            guard u16(2) == 42 else { return nil }
            firstIFD = Int(u32(4))
        }

        func u16(_ i: Int) -> UInt16 {
            bigEndian ? UInt16(b[i]) << 8 | UInt16(b[i + 1]) : UInt16(b[i + 1]) << 8 | UInt16(b[i])
        }

        func u32(_ i: Int) -> UInt32 {
            let v = [b[i], b[i + 1], b[i + 2], b[i + 3]].map(UInt32.init)
            return bigEndian ? v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3] : v[3] << 24 | v[2] << 16 | v[1] << 8 | v[0]
        }

        func entries(at offset: Int) -> [Entry]? {
            guard offset >= 8, offset + 2 <= b.count else { return nil }
            let n = Int(u16(offset))
            guard offset + 2 + n * 12 <= b.count else { return nil }
            var out: [Entry] = []
            for k in 0..<n {
                let e = offset + 2 + k * 12
                let tag = u16(e), type = u16(e + 2), count = u32(e + 4)
                guard let size = sizes[type], count <= UInt32(b.count) else { continue } // unknown type: dropped
                let length = size * Int(count)
                var start = e + 8
                if length > 4 { start = Int(u32(e + 8)) }
                guard start + length <= b.count else { continue }
                out.append(Entry(tag: tag, type: type, count: count, value: Array(b[start..<start + length])))
            }
            return out
        }

        /// The IFD a pointer entry points to.
        func offset(_ entry: Entry) -> Int? {
            guard entry.type == 4 || entry.type == 13, entry.count == 1 else { return nil }
            let v = entry.value.map(UInt32.init)
            return Int(bigEndian ? v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3] : v[3] << 24 | v[2] << 16 | v[1] << 8 | v[0])
        }

        func short(_ entry: Entry) -> UInt16? {
            guard entry.type == 3, entry.count == 1 else { return nil }
            return bigEndian ? UInt16(entry.value[0]) << 8 | UInt16(entry.value[1]) : UInt16(entry.value[1]) << 8 | UInt16(entry.value[0])
        }
    }

    /// Lays out IFD0, the EXIF IFD and the Interop IFD one after another,
    /// each followed by its out-of-line values, all at even offsets.
    private struct Writer {
        let bigEndian: Bool
        var out: [UInt8] = []

        init(bigEndian: Bool) { self.bigEndian = bigEndian }

        func u16(_ v: UInt16) -> [UInt8] { bigEndian ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) -> [UInt8] {
            let be = [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
            return bigEndian ? be : be.reversed()
        }

        mutating func write(main: [Entry], exif: [Entry], interop: [Entry]) -> [UInt8] {
            out = (bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]) + u16(42) + u32(8)
            var main = main.filter { $0.tag != EXIFFilter.exifPointer }
            var exif = exif.filter { $0.tag != EXIFFilter.interopPointer }
            if !exif.isEmpty { main.append(Entry(tag: EXIFFilter.exifPointer, type: 4, count: 1, value: [0, 0, 0, 0])) }
            if !interop.isEmpty { exif.append(Entry(tag: EXIFFilter.interopPointer, type: 4, count: 1, value: [0, 0, 0, 0])) }
            let mainPointer = writeIFD(main)
            if let slot = mainPointer[EXIFFilter.exifPointer] {
                patch(slot, UInt32(out.count))
                let exifPointer = writeIFD(exif)
                if let slot = exifPointer[EXIFFilter.interopPointer] {
                    patch(slot, UInt32(out.count))
                    _ = writeIFD(interop)
                }
            }
            return out
        }

        /// Writes one IFD and returns where each entry's value field is, so
        /// pointers can be filled in once their target's offset is known.
        private mutating func writeIFD(_ entries: [Entry]) -> [UInt16: Int] {
            let sorted = entries.sorted { $0.tag < $1.tag }
            let start = out.count
            var dataOffset = start + 2 + sorted.count * 12 + 4
            var slots: [UInt16: Int] = [:]
            var data: [UInt8] = []
            out += u16(UInt16(sorted.count))
            for e in sorted {
                out += u16(e.tag) + u16(e.type) + u32(e.count)
                slots[e.tag] = out.count
                if e.value.count <= 4 {
                    out += e.value + [UInt8](repeating: 0, count: 4 - e.value.count)
                } else {
                    out += u32(UInt32(dataOffset))
                    data += e.value
                    if data.count % 2 == 1 { data.append(0) }
                    dataOffset = start + 2 + sorted.count * 12 + 4 + data.count
                }
            }
            out += u32(0) // no next IFD: the thumbnail's IFD1 is gone
            out += data
            return slots
        }

        private mutating func patch(_ at: Int, _ value: UInt32) {
            out.replaceSubrange(at..<at + 4, with: u32(value))
        }
    }
}
