import Foundation

/// Finds what makes an SVG impossible to check: the result is compared by
/// rendering it with resvg, which draws static SVG only. Scripts, animation,
/// embedded HTML and some CSS would look the same in both renderings even if
/// the optimizer broke them, so such files are left alone.
enum SVGContent {
    private static let elements: Set<String> = ["script", "foreignObject", "animate", "animateMotion",
                                                "animateTransform", "animateColor", "set"]
    /// CSS that resvg doesn't apply.
    private static let css = ["@font-face", "@import", "@media", "@supports", "@keyframes", "var(--"]

    /// Why the file can't be checked, or nil.
    static func uncheckableReason(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let scanner = Scanner()
        let parser = XMLParser(data: data)
        parser.delegate = scanner
        parser.shouldResolveExternalEntities = false
        // What the parser can't read, it can't vouch for either.
        guard parser.parse() else { return String(localized: "Couldn’t be read completely", bundle: .module) }
        if scanner.hasScript { return String(localized: "Contains scripts", bundle: .module) }
        if scanner.hasAnimation { return String(localized: "Contains animation", bundle: .module) }
        if scanner.hasHTML { return String(localized: "Contains embedded HTML", bundle: .module) }
        if css.contains(where: { scanner.styleText.contains($0) }) {
            return String(localized: "Contains CSS that can’t be checked", bundle: .module)
        }
        return nil
    }

    private final class Scanner: NSObject, XMLParserDelegate {
        var hasScript = false, hasAnimation = false, hasHTML = false
        var styleText = ""
        private var inStyle = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            switch local {
            case "script": hasScript = true
            case "foreignObject": hasHTML = true
            case _ where elements.contains(local): hasAnimation = true
            case "style": inStyle = true
            default: break
            }
            // Event handlers (onload, onclick, …) are scripts too.
            if attributes.keys.contains(where: { $0.lowercased().hasPrefix("on") }) { hasScript = true }
            if let style = attributes["style"] { styleText += style }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name.hasSuffix("style") { inStyle = false }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inStyle { styleText += string }
        }

        /// <?xml-stylesheet href="…"?>: CSS from another file.
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            if target == "xml-stylesheet" { styleText += "@import" }
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            if inStyle { styleText += String(decoding: block, as: UTF8.self) }
        }
    }
}
