import Foundation
import UniformTypeIdentifiers

/// The image formats Just Smaller optimizes. Detection looks at the file's
/// contents, so a PNG named `.jpg` is still treated as a PNG.
public enum ImageFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case png, jpeg, gif, webp, svg, heic

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .gif: "GIF"
        case .webp: "WebP"
        case .svg: "SVG"
        case .heic: "HEIC"
        }
    }

    public var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .gif: .gif
        case .webp: .webP
        case .svg: .svg
        case .heic: .heic
        }
    }

    /// Reads the first bytes of the file. Returns nil for anything that is
    /// not one of the supported formats, including unreadable files.
    public static func detect(at url: URL) -> ImageFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 12 else { return nil }
        return detect(header: head, pathExtension: url.pathExtension)
    }

    public static func detect(header: Data, pathExtension: String) -> ImageFormat? {
        let b = ByteView(header)
        if b.has(PNGChunks.signature) { return .png }
        if b.has([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if b.has("GIF87a") || b.has("GIF89a") { return .gif }
        if b.has("RIFF") && b.has("WEBP", at: 8) { return .webp }
        if b.has("ftyp", at: 4), isHEIF(b) { return .heic }
        if pathExtension.lowercased() == "svg", looksLikeSVG(header) { return .svg }
        return nil
    }

    /// HEIF files share their container with AVIF, so check the brands:
    /// the major brand, then the compatible ones, inside the ftyp box.
    private static func isHEIF(_ b: ByteView) -> Bool {
        guard let ftyp = try? BMFFBoxes.box(at: 0, in: b, topLevel: true).payload else { return false }
        let heicBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx"]
        let brands = stride(from: 0, to: ftyp.count - 3, by: 4).filter { $0 != 4 } // minor version at 4
            .compactMap { (try? ftyp.view($0, 4)).map { String(decoding: $0.bytes, as: UTF8.self) } }
        return !brands.contains("avif") && brands.contains(where: heicBrands.contains)
    }

    private static func looksLikeSVG(_ data: Data) -> Bool {
        var text: String?
        if case let .utf16(bigEndian, _) = SVGText.encoding(data) {
            text = String(data: data.prefix(data.count & ~1), encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian)
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        guard let text else { return false }
        return text.range(of: "<svg", options: .caseInsensitive) != nil
    }
}
