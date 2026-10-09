import Foundation

/// Reads a result file the strict way before it may replace the original.
/// The pixel and coefficient comparisons prove the image is the same; this
/// proves the file around it is sound: every length, table, checksum and
/// flag as the format's specification wants it, so that no decoder — not
/// only the lenient ones used for the comparison — trips over it.
///
/// One check per format (JPEGCheck, PNGCheck, WebPCheck, HEIFCheck,
/// SVGCheck), all reading through `ByteView`. Parts no step is meant to
/// rewrite (colour profiles, unknown segments) must be the original's byte
/// for byte; metadata a step did rewrite is checked by `PayloadCheck`, the
/// same way in every container. The original is summarized once per step,
/// read leniently: it only says what may stay as it was.
enum StructureCheck {
    typealias Invalid = FormatError

    /// What the checks need to know about the original.
    struct Reference {
        fileprivate enum Summary {
            case jpeg(JPEGCheck.Reference), png(PNGCheck.Reference), webp(WebPCheck.Reference)
            case heif(HEIFCheck.Reference), svg(SVGCheck.Reference), none
        }
        fileprivate let summary: Summary
        /// A JPEG original's reference.
        var jpeg: JPEGCheck.Reference? {
            if case .jpeg(let r) = summary { return r }
            return nil
        }

        /// `level`: the metadata level the result was made for (what may go).
        init(original: URL, format: ImageFormat, level: MetadataHandling = .keep) {
            guard let data = try? Data(contentsOf: original, options: .alwaysMapped) else {
                summary = .none
                return
            }
            let a = ByteView(data)
            switch format {
            case .jpeg: summary = .jpeg(JPEGCheck.Reference(a, level: level))
            case .png: summary = .png(PNGCheck.Reference(a))
            case .webp: summary = .webp(WebPCheck.Reference(a))
            case .heic: summary = .heif(HEIFCheck.Reference(a))
            case .svg: summary = .svg(SVGCheck.Reference(a))
            case .gif: summary = .none // no step writes GIF yet
            case .jxl: summary = .none // read strictly by Verifier.verifyConversion
            }
        }
    }

    static func verify(result: URL, against reference: Reference) throws {
        if case .none = reference.summary { return }
        try verify(ByteView(try Data(contentsOf: result, options: .alwaysMapped)), against: reference)
    }

    static func verify(_ b: ByteView, against reference: Reference) throws {
        try reporting {
            switch reference.summary {
            case .jpeg(let r): try JPEGCheck.check(b, against: r)
            case .png(let r): try PNGCheck.check(b, against: r)
            case .webp(let r): try WebPCheck.check(b, against: r)
            case .heif(let r): try HEIFCheck.check(b, against: r)
            case .svg(let r): try SVGCheck.check(b, against: r)
            case .none: break
            }
        }
    }

    /// The original by the same rules, on its own: whether it is sound in
    /// itself, to say why a file stays as it is. A JPEG's images each on
    /// their own; the rules around them hold a result to its original.
    static func verifyOriginal(_ url: URL, format: ImageFormat) throws {
        guard format == .jpeg else { return try verify(result: url, against: Reference(original: url, format: format)) }
        let b = ByteView(try Data(contentsOf: url, options: .alwaysMapped))
        try reporting { try JPEGCheck.checkImages(b) }
    }

    /// A check's finding as the reason a file is rejected.
    private static func reporting(_ check: () throws -> Void) throws {
        do {
            try check()
        } catch let error as Invalid {
            throw VerificationError(reason: String(localized: "invalid file structure (\(error.detail))", bundle: .module))
        }
    }
}
