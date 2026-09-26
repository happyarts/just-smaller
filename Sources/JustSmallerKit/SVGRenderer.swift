import AppKit
import WebKit

/// Renders an SVG the way a web browser shows it: through WebKit, embedded as
/// an `<img>`, which is how most pages use SVGs (no scripts, no external
/// resources). Apple's other SVG renderer, CoreSVG (used by Quick Look
/// thumbnails), is more forgiving: it drew a font-family list that oxvg had
/// broken with the intended font, while browsers fell back to a serif font.
@MainActor
enum SVGRenderer {
    static let size = 512

    static func render(_ svg: URL) async throws -> CGImage {
        let folder = svg.deletingLastPathComponent()
        let page = folder.appending(path: "render-\(UUID().uuidString).html")
        let name = svg.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? svg.lastPathComponent
        let html = """
            <!doctype html><html><body style="margin:0;background:#fff">
            <img src="\(name)" style="display:block;width:\(size)px;height:\(size)px;object-fit:contain">
            </body></html>
            """
        try Data(html.utf8).write(to: page)
        defer { try? FileManager.default.removeItem(at: page) }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: size, height: size), configuration: configuration)
        let loader = Loader()
        view.navigationDelegate = loader
        try await loader.load(page, readAccess: folder, in: view)

        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = CGRect(x: 0, y: 0, width: size, height: size)
        snapshot.snapshotWidth = NSNumber(value: size)
        let image = try await view.takeSnapshot(configuration: snapshot)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw VerificationError(reason: String(localized: "unreadable", bundle: .module))
        }
        return cgImage
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, any Error>?

        func load(_ page: URL, readAccess: URL, in view: WKWebView) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                view.loadFileURL(page, allowingReadAccessTo: readAccess)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume(); continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            continuation?.resume(throwing: error); continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            continuation?.resume(throwing: error); continuation = nil
        }
    }
}
