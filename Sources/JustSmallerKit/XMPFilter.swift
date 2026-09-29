import Foundation

/// Filters an XMP packet by `MetadataPolicy` and writes it compactly: no
/// padding, no indentation, no unused namespace declarations. Properties are
/// judged by namespace URI, never by prefix (older files write "xap:" for
/// "xmp:").
enum XMPFilter {
    static let packetHeader = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
    static let packetTrailer = "<?xpacket end=\"w\"?>"

    /// Only the padding: the whitespace an editor leaves before the packet's
    /// end so it can grow in place. The rest stays byte for byte.
    static func withoutPadding(_ packet: [UInt8]) -> [UInt8] {
        guard let end = packet.lastRange(of: Array("<?xpacket end=".utf8)) else { return packet }
        var start = end.lowerBound
        while start > 0, [0x20, 0x0A, 0x0D, 0x09].contains(packet[start - 1]) { start -= 1 }
        // One line break stays, as most writers put it.
        guard end.lowerBound - start > 1 else { return packet }
        return Array(packet[..<start]) + [0x0A] + Array(packet[end.lowerBound...])
    }

    /// The filtered packet, or nil when nothing is left. `extended` is the
    /// reassembled extended XMP of a JPEG, merged in before filtering. `digest` replaces
    /// photoshop:LegacyIPTCDigest when the IIM block it describes changed.
    /// Unparseable XMP is dropped: better no data than stray data.
    static func filter(_ packet: [UInt8], level: MetadataHandling, merging extended: [UInt8]? = nil,
                       digest: (old: String, new: String)? = nil) -> [UInt8]? {
        // Under the engine's XML lock (see XML). Removed nodes still point
        // into their document, so the documents must outlive them: they are
        // released only after the autorelease pool that holds the nodes.
        XML.lock.withLock {
            var documents: [XMLDocument] = []
            let result = autoreleasepool { filterLocked(packet, level: level, merging: extended, digest: digest, documents: &documents) }
            withExtendedLifetime(documents) {}
            return result
        }
    }

    private static func filterLocked(_ packet: [UInt8], level: MetadataHandling, merging extended: [UInt8]?,
                                     digest: (old: String, new: String)?, documents: inout [XMLDocument]) -> [UInt8]? {
        guard let document = parse(packet), let rdf = findRDF(document.rootElement()) else { return nil }
        documents.append(document)
        if let extended, let extra = parse(extended), let extraRDF = findRDF(extra.rootElement()) {
            documents.append(extra)
            // Namespaces declared further up in the extension go along.
            var inherited: [XMLNode] = []
            var ancestor: XMLNode? = extraRDF
            while let element = ancestor as? XMLElement {
                inherited += element.namespaces ?? []
                ancestor = element.parent
            }
            for description in (extraRDF.children ?? []).compactMap({ $0 as? XMLElement }) {
                description.detach()
                for ns in inherited where ns.name.map({ description.namespace(forPrefix: $0) == nil }) ?? false {
                    description.addNamespace(ns.copy() as! XMLNode)
                }
                rdf.addChild(description)
            }
        }
        for description in (rdf.children ?? []).compactMap({ $0 as? XMLElement }) {
            filterDescription(description, level: level, digest: digest)
            if (description.attributes ?? []).allSatisfy({ isRDF($0, in: description) }),
               !(description.children ?? []).contains(where: { $0.kind == .element }) {
                description.detach()
            }
        }
        guard (rdf.children ?? []).contains(where: { $0.kind == .element }), let root = document.rootElement() else { return nil }
        // The toolkit's name and version: which software wrote the packet.
        root.removeAttribute(forName: "x:xmptk")
        compact(root)
        pruneNamespaces(root)
        let body = root.xmlString(options: [.nodeCompactEmptyElement])
        return Array((packetHeader + body + packetTrailer).utf8)
    }

    private static func parse(_ packet: [UInt8]) -> XMLDocument? {
        // The packet may carry trailing NULs or junk after the trailer.
        var bytes = packet
        if let end = bytes.lastRange(of: Array("?>".utf8)) { bytes = Array(bytes[..<end.upperBound]) }
        return try? XMLDocument(data: Data(bytes), options: [.nodePreserveCDATA, .nodeLoadExternalEntitiesNever])
    }

    private static func findRDF(_ element: XMLElement?) -> XMLElement? {
        guard let element else { return nil }
        if element.localName == "RDF", element.uri == MetadataPolicy.NS.rdf { return element }
        for child in element.children ?? [] {
            if let found = findRDF(child as? XMLElement) { return found }
        }
        return nil
    }

    private static func namespace(of node: XMLNode, in element: XMLElement) -> String? {
        if let uri = node.uri { return uri }
        guard let name = node.name, let prefix = XMLNode.prefix(forName: name), !prefix.isEmpty else { return nil }
        return element.resolveNamespace(forName: name)?.stringValue
    }

    private static func isRDF(_ attribute: XMLNode, in element: XMLElement) -> Bool {
        let ns = namespace(of: attribute, in: element)
        return ns == MetadataPolicy.NS.rdf || ns == nil || attribute.name?.hasPrefix("xml:") == true
    }

    private static func keeps(_ node: XMLNode, in description: XMLElement, level: MetadataHandling) -> Bool {
        guard let ns = namespace(of: node, in: description), let name = node.localName else { return false }
        if ns == MetadataPolicy.NS.xmpNote { return false } // HasExtendedXMP: merged into this packet
        if MetadataPolicy.isDerivable(xmpNamespace: ns, name: name) { return false }
        return MetadataPolicy.keeps(MetadataPolicy.group(xmpNamespace: ns, name: name), at: level)
    }

    private static func filterDescription(_ description: XMLElement, level: MetadataHandling,
                                          digest: (old: String, new: String)?) {
        for attribute in description.attributes ?? [] where !isRDF(attribute, in: description) {
            if !keeps(attribute, in: description, level: level), let name = attribute.name {
                description.removeAttribute(forName: name)
            } else if let digest, isDigest(attribute, in: description), attribute.stringValue == digest.old {
                attribute.stringValue = digest.new
            }
        }
        for child in description.children ?? [] {
            guard let property = child as? XMLElement else { continue }
            if !keeps(property, in: description, level: level) {
                property.detach()
            } else if let digest, isDigest(property, in: description), property.stringValue == digest.old {
                property.stringValue = digest.new
            }
        }
    }

    private static func isDigest(_ node: XMLNode, in element: XMLElement) -> Bool {
        node.localName == "LegacyIPTCDigest" && namespace(of: node, in: element) == MetadataPolicy.NS.photoshop
    }

    /// Removes whitespace between elements. Text inside a property that has
    /// no child elements is its value and stays exactly as it is.
    private static func compact(_ element: XMLElement) {
        let children = element.children ?? []
        let hasElements = children.contains { $0.kind == .element }
        for child in children {
            if let child = child as? XMLElement {
                compact(child)
            } else if hasElements, child.kind == .text,
                      child.stringValue?.allSatisfy({ $0.isWhitespace }) ?? true {
                child.detach()
            } else if child.kind == .comment {
                child.detach()
            }
        }
    }

    /// Drops namespace declarations nothing in the element's subtree uses.
    private static func pruneNamespaces(_ root: XMLElement) {
        var used = Set<String>()
        func collect(_ element: XMLElement) {
            if let name = element.name { used.insert(XMLNode.prefix(forName: name) ?? "") }
            for attribute in element.attributes ?? [] {
                if let name = attribute.name { used.insert(XMLNode.prefix(forName: name) ?? "") }
            }
            for child in element.children ?? [] { if let child = child as? XMLElement { collect(child) } }
        }
        collect(root)
        func prune(_ element: XMLElement) {
            for ns in element.namespaces ?? [] {
                if let prefix = ns.name, !used.contains(prefix) { element.removeNamespace(forPrefix: prefix) }
            }
            for child in element.children ?? [] { if let child = child as? XMLElement { prune(child) } }
        }
        prune(root)
    }
}

extension Array where Element == UInt8 {
    func lastRange(of needle: [UInt8]) -> Range<Int>? {
        guard needle.count <= count else { return nil }
        var i = count - needle.count
        while i >= 0 {
            if self[i..<i + needle.count].elementsEqual(needle) { return i..<i + needle.count }
            i -= 1
        }
        return nil
    }

    func firstRange(of needle: [UInt8], from start: Int = 0) -> Range<Int>? {
        guard needle.count <= count, start <= count - needle.count else { return nil }
        for i in start...(count - needle.count) where self[i..<i + needle.count].elementsEqual(needle) {
            return i..<i + needle.count
        }
        return nil
    }
}
