import Foundation

/// The metadata inside a container, checked the same way wherever it lives:
/// EXIF (a TIFF structure), XMP (XML), IPTC (Photoshop resources holding
/// IIM datasets), JFIF and the Adobe marker. The containers decide what a
/// step wrote and call these; each names the part a failure is in with
/// `Invalid.within`.
enum PayloadCheck {
    typealias Invalid = StructureCheck.Invalid

    /// A TIFF structure (EXIF): every IFD and entry inside the block, values
    /// where their offsets say, the Exif, GPS and interoperability IFDs
    /// followed, no IFD twice.
    static func tiff(_ t: ByteView) throws {
        let reader = try TIFFReader(t)
        var pending = [try reader.firstIFD], seen: Set<Int> = []
        while let ifd = pending.popLast() {
            guard ifd >= 8, seen.insert(ifd).inserted else { throw Invalid("IFD offset") }
            let entries = try reader.read(ifd, 2)
            for e in 0..<entries {
                let at = ifd + 2 + 12 * e
                let tag = try reader.read(at, 2), type = try reader.read(at + 2, 2), count = try reader.read(at + 4, 4)
                guard let size = EXIFFilter.sizes[UInt16(type)] else { throw Invalid("value type") }
                if size * count > 4 { _ = try t.view(reader.read(at + 8, 4), size * count) }
                if EXIFFilter.ifdPointers.contains(UInt16(tag)) {
                    guard [4, 13].contains(type), count == 1 else { throw Invalid("IFD pointer") }
                    pending.append(try reader.read(at + 8, 4))
                }
            }
            let next = try reader.read(ifd + 2 + 12 * entries, 4)
            if next != 0 { pending.append(next) }
        }
    }

    /// Well-formed XML. A closing zero byte (ImageIO writes one after XMP)
    /// isn't part of the document.
    static func xml(_ x: ByteView) throws {
        var text = x.bytes
        while text.last == 0 { text.removeLast() }
        guard XML.rootElement(text) != nil else { throw Invalid("not well-formed XML") }
    }

    /// JPEG's extended XMP: GUID, full length, offset, then its part.
    static func extendedXMP(_ p: ByteView) throws {
        guard p.count > 40, try p.view(0, 32).bytes.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) }),
              try p.be(36, 4) + (p.count - 40) <= p.be(32, 4)
        else { throw Invalid("layout") }
    }

    /// Photoshop image resources ("8BIM", id, padded name, size, padded
    /// data), with the IPTC-IIM datasets of resource 0x0404.
    static func photoshopResources(_ r: ByteView) throws {
        var k = 0
        while k < r.count, !(try r.view(from: k).isPadding) {
            guard r.has("8BIM", at: k) else { throw Invalid("resource") }
            let id = try r.be(k + 4, 2), nameLength = try r.u8(k + 6)
            let sizeAt = k + 6 + ((1 + nameLength + 1) & ~1)
            let size = try r.be(sizeAt, 4)
            let data = try r.view(sizeAt + 4, size)
            if id == 0x0404 { try iim(data) }
            k = sizeAt + 4 + size + (size & 1)
        }
    }

    /// IPTC-IIM: tag 0x1C, record, dataset, length (extended when the top
    /// bit is set), data; nothing else.
    private static func iim(_ d: ByteView) throws {
        var k = 0
        while k < d.count, !(try d.view(from: k).isPadding) {
            guard try d.u8(k) == 0x1C else { throw Invalid("dataset") }
            var length = try d.be(k + 3, 2), header = 5
            if length & 0x8000 != 0 {
                let bytes = length & 0x7FFF
                guard (1...4).contains(bytes) else { throw Invalid("dataset length") }
                length = try d.be(k + 5, bytes)
                header += bytes
            }
            _ = try d.view(k + header, length)
            k += header + length
        }
    }

    /// JFIF: version, units, density, and a thumbnail of exactly its size.
    static func jfif(_ p: ByteView) throws {
        guard p.count >= 14, try p.u8(7) <= 2, try p.be(8, 2) > 0, try p.be(10, 2) > 0,
              try p.count == 14 + 3 * p.u8(12) * p.u8(13)
        else { throw Invalid("layout") }
    }

    /// Adobe: version, two flag words, the colour transform (0–2).
    static func adobe(_ p: ByteView) throws {
        guard p.count == 12, try p.u8(11) <= 2 else { throw Invalid("layout") }
    }
}
