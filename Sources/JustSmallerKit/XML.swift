import Foundation

/// Every XML parse in the engine goes through here. Foundation's XML classes
/// are not safe to use from several threads at once, even on separate
/// documents, so all of them — XMLDocument in XMPFilter, XMLParser for SVG,
/// Google's XMP and the structure check — share one lock. External entities
/// are never loaded.
enum XML {
    static let lock = NSLock()

    /// Runs `parser`-driven parsing of `data` under the lock; true if the
    /// document is well-formed. With `namespaces`, elements come with their
    /// namespace URI and every prefix mapping is reported (attributes keep
    /// their prefixed names).
    static func parse(_ data: Data, delegate: XMLParserDelegate, namespaces: Bool = false) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = namespaces
        parser.shouldReportNamespacePrefixes = namespaces
        return lock.withLock { parser.parse() }
    }

    /// The root element's name, nil if the document isn't well-formed.
    static func rootElement(_ data: Data) -> String? {
        let finder = RootFinder()
        return parse(data, delegate: finder) ? finder.root : nil
    }

    private final class RootFinder: NSObject, XMLParserDelegate {
        var root: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if root == nil { root = name }
        }
    }
}
