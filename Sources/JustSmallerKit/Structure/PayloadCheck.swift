import Foundation

/// The metadata inside a container, checked the same way wherever it lives:
/// EXIF (a TIFF structure), XMP (XML), IPTC (Photoshop resources holding
/// IIM datasets), JFIF and the Adobe marker. The containers decide what a
/// step wrote and call these; each names the part a failure is in with
/// `Invalid.within`.
enum PayloadCheck {
    typealias Invalid = FormatError

    /// A TIFF structure (EXIF): every IFD and entry inside the block, values
    /// where their offsets say, the Exif, GPS and interoperability IFDs
    /// followed, no IFD twice.
    static func tiff(_ t: ByteView) throws {
        let reader = try TIFFReader(t)
        var pending = [try reader.firstIFD], seen: Set<Int> = []
        while let offset = pending.popLast() {
            guard seen.insert(offset).inserted else { throw Invalid("IFD offset") }
            let ifd = try reader.ifd(at: offset)
            for entry in ifd.entries {
                guard entry.value != nil else { throw Invalid(TIFFReader.sizes[entry.type] == nil ? "value type" : "value outside the block") }
                if TIFFReader.ifdPointers.contains(entry.tag) {
                    guard let pointer = reader.pointer(entry) else { throw Invalid("IFD pointer") }
                    pending.append(pointer)
                }
            }
            guard let next = ifd.next else { throw Invalid("truncated data") }
            if next != 0 { pending.append(next) }
        }
    }

    /// Well-formed XML. A closing zero byte (ImageIO writes one after XMP)
    /// isn't part of the document. Stricter than the readers
    /// (`XML.document(ofPacket:)`): junk after the trailer is what others
    /// leave, never what a step may write.
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

    /// Photoshop image resources with the IPTC-IIM datasets of resource
    /// 0x0404, read strictly.
    static func photoshopResources(_ r: ByteView) throws {
        for resource in try IPTCRecords.resources(r, strict: true) where resource.id == 0x0404 {
            _ = try IPTCRecords.datasets(resource.data, strict: true)
        }
    }

    /// JFIF: version 1.x (2.x read too), units, density, and a thumbnail of
    /// exactly its size.
    static func jfif(_ p: ByteView) throws {
        guard p.count >= 14, try [1, 2].contains(p.u8(5)), try p.u8(7) <= 2, try p.be(8, 2) > 0, try p.be(10, 2) > 0,
              try p.count == 14 + 3 * p.u8(12) * p.u8(13)
        else { throw Invalid("layout") }
    }

    /// Adobe: version, two flag words, the colour transform (0–2).
    static func adobe(_ p: ByteView) throws {
        guard p.count == 12, try p.u8(11) <= 2 else { throw Invalid("layout") }
    }
}
