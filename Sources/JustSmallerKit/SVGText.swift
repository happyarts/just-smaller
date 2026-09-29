import Foundation

/// SVG files in UTF-16. The optimizer and the renderer read UTF-8 only, and
/// UTF-8 is half the size for the ASCII that makes up almost all of an SVG:
/// the same text, re-encoded, is the first step for such a file.
enum SVGText {
    enum Encoding: Equatable {
        case utf8, utf16(bigEndian: Bool, bom: Bool)
    }

    /// How the file's text is encoded: a byte order mark, or without one an
    /// XML declaration `<?xml` in UTF-16 (XML's own detection, Appendix F).
    /// UTF-16 without either is no XML document browsers show.
    static func encoding(_ b: some Collection<UInt8>) -> Encoding {
        let head = Array(b.prefix(10))
        if head.starts(with: [0xFF, 0xFE]) { return .utf16(bigEndian: false, bom: true) }
        if head.starts(with: [0xFE, 0xFF]) { return .utf16(bigEndian: true, bom: true) }
        let declaration = Array("<?xml".utf8)
        if head == declaration.flatMap({ [$0, 0] }) { return .utf16(bigEndian: false, bom: false) }
        if head == declaration.flatMap({ [0, $0] }) { return .utf16(bigEndian: true, bom: false) }
        return .utf8
    }

    /// The text of a UTF-16 file, nil unless decoding it loses nothing: it
    /// must encode back to exactly the same bytes.
    static func utf16Text(_ data: Data) -> String? {
        guard case let .utf16(bigEndian, bom) = encoding(data), data.count % 2 == 0 else { return nil }
        let body = bom ? data.dropFirst(2) : data[...]
        let unicode: String.Encoding = bigEndian ? .utf16BigEndian : .utf16LittleEndian
        guard let text = String(data: body, encoding: unicode), text.data(using: unicode) == body else { return nil }
        return text
    }

    /// The same text in UTF-8, with the XML declaration saying so.
    static func utf8(_ data: Data) -> Data? {
        utf16Text(data).map { Data(declaringUTF8($0).utf8) }
    }

    /// Replaces the encoding named in the XML declaration, if there is one.
    static func declaringUTF8(_ text: String) -> String {
        guard text.hasPrefix("<?xml"), let end = text.range(of: "?>") else { return text }
        let declaration = text[..<end.lowerBound]
        guard let name = declaration.range(of: #"encoding\s*=\s*["'][^"']*["']"#, options: .regularExpression) else { return text }
        return text.replacingCharacters(in: name, with: #"encoding="UTF-8""#)
    }

    /// Proves `result` holds exactly the text of the UTF-16 `original`.
    static func isSameText(original: Data, result: Data) -> Bool {
        // Bytes, not Strings: Swift compares strings by canonical equivalence.
        guard let text = utf16Text(original) else { return false }
        return Data(declaringUTF8(text).utf8) == result
    }
}
