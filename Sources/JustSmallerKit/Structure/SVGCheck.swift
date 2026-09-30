import Foundation

/// SVG: well-formed XML with the same root element as the original, in
/// UTF-8 if the original was. What it draws is the rendering comparison's job.
enum SVGCheck {
    typealias Invalid = FormatError

    /// What the original contributes: its root element (nil if it isn't
    /// well-formed XML) and whether it was UTF-8.
    struct Reference {
        let root: String?
        let isUTF8: Bool

        init(_ a: ByteView) {
            root = XML.rootElement(a.bytes)
            isUTF8 = SVGText.encoding(a.bytes) == .utf8 && String(data: a.bytes, encoding: .utf8) != nil
        }
    }

    static func check(_ b: ByteView, against reference: Reference) throws {
        guard let root = reference.root else { return }
        guard !reference.isUTF8 || String(data: b.bytes, encoding: .utf8) != nil else { throw Invalid("not UTF-8") }
        guard XML.rootElement(b.bytes) == root else { throw Invalid("not well-formed XML") }
    }
}
