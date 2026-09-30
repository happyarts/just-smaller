import Foundation

/// Rewrites an EXIF block (a TIFF structure) with only the tags a level
/// keeps. Values are copied byte for byte in the file's own byte order; only
/// the layout is new. GPS, MakerNotes and the thumbnail (IFD1) never survive
/// filtering.
enum EXIFFilter {
    /// An entry as the writer lays it out.
    private struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var value: [UInt8] // raw bytes in the block's byte order

        init(tag: UInt16, type: UInt16, count: UInt32, value: [UInt8]) {
            self.tag = tag; self.type = type; self.count = count; self.value = value
        }

        init(_ read: TIFFReader.Entry) {
            self.init(tag: UInt16(read.tag), type: UInt16(read.type), count: UInt32(read.count), value: [UInt8](read.value?.bytes ?? Data()))
        }
    }

    private static let exifPointer = UInt16(TIFFReader.exifPointer), interopPointer = UInt16(TIFFReader.interopPointer)

    /// The filtered TIFF block, or nil when nothing worth keeping is left.
    /// Unreadable EXIF is dropped as a whole: better no data than stray data.
    static func filter(_ tiff: [UInt8], level: MetadataHandling) -> [UInt8]? {
        guard let reader = try? TIFFReader(ByteView(tiff)), let first = try? reader.firstIFD,
              let main = entries(reader, at: first) else { return nil }
        var exif: [TIFFReader.Entry] = [], interop: [TIFFReader.Entry] = []
        if let offset = main.first(where: { $0.tag == TIFFReader.exifPointer }).flatMap(reader.pointer),
           let entries = entries(reader, at: offset) {
            exif = entries
            if let offset = entries.first(where: { $0.tag == TIFFReader.interopPointer }).flatMap(reader.pointer) {
                interop = self.entries(reader, at: offset) ?? []
            }
        }
        func kept(_ entries: [TIFFReader.Entry], _ ifd: MetadataPolicy.IFD) -> [TIFFReader.Entry] {
            entries.filter { MetadataPolicy.keeps(MetadataPolicy.group(exifTag: UInt16($0.tag), in: ifd), at: level) }
        }
        let keptMain = kept(main, .main)
        let keptInterop = kept(interop, .interop)
        var keptExif = kept(exif, .exif)
        // ExifVersion alone says nothing; neither does sRGB, the default.
        let meaningful = keptExif.contains { !($0.tag == 0x9000 || $0.tag == 0xA001 && reader.number($0) == 1) }
        if !meaningful && keptInterop.isEmpty { keptExif = [] }
        if keptMain.isEmpty && keptExif.isEmpty { return nil }
        if keptMain.count == 1, keptMain[0].tag == 0x0112, reader.number(keptMain[0]) == 1, keptExif.isEmpty { return nil }
        var writer = Writer(bigEndian: reader.bigEndian)
        return writer.write(main: keptMain.map(Entry.init), exif: keptExif.map(Entry.init), interop: keptInterop.map(Entry.init))
    }

    /// An IFD's entries with a readable value: those of unknown types or
    /// with values outside the block are dropped. Only the fixed IFDs are
    /// read, so a loop of IFDs can't run forever.
    private static func entries(_ reader: TIFFReader, at offset: Int) -> [TIFFReader.Entry]? {
        (try? reader.ifd(at: offset))?.entries.filter { $0.value != nil }
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
