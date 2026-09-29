import Foundation

/// Which ids of an SVG must stay as they are. Other files and pages can
/// point at an id (<use href="icons.svg#home">, sprite sheets, views), and
/// no rendering of the file itself shows that. Ids that editors number on
/// their own (Inkscape's path1234, Illustrator's SVGID_1_, …) are not names
/// anyone refers to from outside, so they may be shortened or removed.
enum SVGIDs {
    /// The ids to keep, or nil when every id stays: none is generated,
    /// sprites (symbols) and views exist to be used from outside, a file that
    /// refers to ids through a file name (`other.svg#x`, also its own) may be
    /// pointed at the same way, and a file the parser can't read completely
    /// can't be vouched for.
    static func toPreserve(in url: URL) -> [String]? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        let scanner = Scanner()
        parser.delegate = scanner
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !scanner.isShared else { return nil }
        let named = scanner.ids.filter { !isGenerated($0) }
        return named.count < scanner.ids.count ? named.sorted() : nil
    }

    /// Element names followed by a number (Inkscape `path1234`, `g12-3`,
    /// Sketch `path-1`), Illustrator's `SVGID_1_`, `XMLID_2_` and `Layer_1`,
    /// Affinity's `_Radial1`, Figma's `clip0_12_34` and `paint0_linear_1_2`,
    /// SVG-edit's `svg_1`.
    static func isGenerated(_ id: String) -> Bool {
        (try? generated.wholeMatch(in: id)) != nil
    }

    private static let elements = [
        "svg", "g", "defs", "symbol", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "textPath", "image", "linearGradient", "radialGradient", "stop", "clipPath", "mask",
        "pattern", "filter", "fe[A-Z][A-Za-z]*", "marker", "switch", "style", "title", "desc", "metadata",
        "layer", "namedview", "guide", "grid", "swatch", "path-effect", "perspective",
        "flowRoot", "flowRegion", "flowPara", "flowSpan",
    ].joined(separator: "|")

    nonisolated(unsafe) private static let generated = try! Regex(
        "(?:\(elements))-?[0-9]+(?:-[0-9]+)*"
            + "|SVGID_[0-9]+_(?:[0-9]+_)?|XMLID_[0-9]+_|Layer_[0-9]+"
            + "|_(?:Radial|Linear|Image|clip|Effect)[0-9]+"
            + "|(?:clip|paint|filter|mask|pattern|image)[0-9]+(?:_[a-z]+)*(?:_[0-9]+)+"
            + "|svg_[0-9]+")

    /// `url(file.svg#x)`: a fragment in another (or this) file.
    nonisolated(unsafe) private static let fileReference = try! Regex(#"url\(\s*['"]?[^#'"\s)]+#"#)

    private final class Scanner: NSObject, XMLParserDelegate {
        var ids: Set<String> = []
        var isShared = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if local == "symbol" || local == "view" { isShared = true }
            if let id = attributes["id"] { ids.insert(id) }
            for (attribute, value) in attributes where value.contains("#") {
                let isLink = attribute == "href" || attribute.hasSuffix(":href")
                if isLink && !value.hasPrefix("#") || (try? fileReference.firstMatch(in: value)) != nil { isShared = true }
            }
        }
    }
}
