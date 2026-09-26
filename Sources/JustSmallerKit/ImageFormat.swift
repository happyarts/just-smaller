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
        let b = [UInt8](header)
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes
        }
        func ascii(_ s: String, at offset: Int = 0) -> Bool { starts(Array(s.utf8), at: offset) }

        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if ascii("GIF87a") || ascii("GIF89a") { return .gif }
        if ascii("RIFF") && ascii("WEBP", at: 8) { return .webp }
        if ascii("ftyp", at: 4), isHEIF(b) { return .heic }
        if pathExtension.lowercased() == "svg", looksLikeSVG(header) { return .svg }
        return nil
    }

    /// HEIF files share their container with AVIF, so check the brands.
    private static func isHEIF(_ b: [UInt8]) -> Bool {
        let boxSize = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        let end = min(boxSize, b.count)
        guard end >= 16 else { return false }
        let heicBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx"]
        var brands = [String(decoding: b[8..<12], as: UTF8.self)]
        var offset = 16 // major brand, minor version, then the compatible brands
        while offset + 4 <= end {
            brands.append(String(decoding: b[offset..<offset + 4], as: UTF8.self))
            offset += 4
        }
        return !brands.contains("avif") && brands.contains(where: heicBrands.contains)
    }

    private static func looksLikeSVG(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return false }
        return text.range(of: "<svg", options: .caseInsensitive) != nil
    }
}
