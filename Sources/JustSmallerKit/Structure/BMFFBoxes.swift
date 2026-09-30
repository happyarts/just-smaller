import Foundation

/// The one way the engine reads ISO base media file boxes (HEIF): format
/// detection and the structure check.
enum BMFFBoxes {
    struct Box {
        let type: String
        let payload: ByteView
        /// Where the payload starts in the view the box was read from.
        let offset: Int
        /// The whole box, header included.
        let size: Int
    }

    /// The box at `i`: 32-bit size (1: a 64-bit size follows; 0: to the end,
    /// top level only), type, and 16 more bytes of type for "uuid".
    static func box(at i: Int, in b: ByteView, topLevel: Bool = false) throws -> Box {
        var size = try b.be(i, 4), header = 8
        let type = String(decoding: try b.view(i + 4, 4).bytes, as: UTF8.self)
        if size == 1 {
            size = try b.be(i + 8, 8); header = 16
        } else if size == 0 {
            guard topLevel else { throw FormatError("\(type) size") }
            size = b.count - i
        }
        if type == "uuid" { header += 16 }
        guard size >= header, size <= b.count - i else { throw FormatError("\(type) size") }
        return Box(type: type, payload: try b.view(i + header, size - header), offset: i + header, size: size)
    }

    /// The boxes in `b`, which they must fill exactly.
    static func boxes(_ b: ByteView, topLevel: Bool = false) throws -> [Box] {
        var out: [Box] = [], i = 0
        while i < b.count {
            let box = try box(at: i, in: b, topLevel: topLevel)
            out.append(box)
            i += box.size
        }
        return out
    }
}
