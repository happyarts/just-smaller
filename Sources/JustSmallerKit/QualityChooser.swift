import Foundation

/// Chooses the quality of a lossy encoding itself, image by image, instead of
/// the fixed quality in the settings: it tries encodings and keeps one that
/// passes its own measure. Given to `FileOptimizer`, and used in lossy mode
/// only.
///
/// For the formats it handles, its encodings are the only lossy step. It gets
/// the image as the lossless steps left it, so an encoding has to beat their
/// result. Every such result has passed the chooser's `verify` as a finished
/// file against the original; when one doesn't, or the search fails, the
/// file is optimized without loss. The other formats are optimized without
/// loss too, or, if `otherFormatsLossless` is false, with the settings'
/// lossy steps.
public protocol QualityChooser: Sendable {
    /// The formats it chooses for. JPEG is the only one so far.
    var formats: Set<ImageFormat> { get }

    /// Whether the formats it doesn't handle stay without loss.
    var otherFormatsLossless: Bool { get }

    /// Writes the encoding of `image` it chooses to `output` and returns
    /// true, or returns false when none passes. `image` shows exactly what the
    /// original shows. `encode(quality, url)` writes `image` encoded at
    /// `quality` (1–100) with its metadata to `url`; an encoding that is not
    /// smaller than `image` is never used. `work` is a private folder for its
    /// own files.
    func choose(image: URL, output: URL, work: URL,
                encode: @escaping @Sendable (_ quality: Int, _ to: URL) async throws -> Void) async throws -> Bool

    /// Checks the finished file against the original, after every step:
    /// throws when it doesn't pass; the error's description says why.
    func verify(original: URL, result: URL, format: ImageFormat, work: URL) async throws
}

extension QualityChooser {
    public var otherFormatsLossless: Bool { true }
}
