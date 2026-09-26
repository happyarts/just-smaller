import Foundation

/// How long the optimizers search for the smallest encoding. Effort never
/// changes how an image looks — in lossy mode that is the quality's job —
/// only how much time is spent for the last few percent. It matters most for
/// PNG; the JPEG, SVG and HEIC tools are fast at their best setting anyway.
public enum Effort: String, CaseIterable, Codable, Sendable, Identifiable {
    case fast, balanced, thorough, maximum
    public var id: Self { self }
}

public enum MetadataHandling: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Keep everything.
    case keep
    /// Remove camera data, location, comments and editing history. The colour
    /// profile and the orientation are always kept: removing them changes how
    /// the image looks.
    case strip
    public var id: Self { self }
}

/// Where an optimized file goes.
public enum OutputMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// In place of the original, which goes to the Trash (if enabled).
    case replace
    /// Next to the original, with a suffix: photo-optimized.jpg.
    case suffix
    /// Into a chosen folder, mirroring the subfolders of a dropped folder.
    case folder
    public var id: Self { self }
}

/// Everything that decides how a file is optimized. A snapshot is taken when a
/// file starts, so changing a setting never affects a file half-way through.
public struct OptimizationSettings: Hashable, Codable, Sendable {
    public var lossy = false
    /// Lossy mode only: 1–100, translated into each format's own scale.
    public var quality = 85
    public var metadata = MetadataHandling.strip
    public var effort = Effort.balanced
    public var disabledFormats: Set<ImageFormat> = []
    /// Replaced originals go to the Trash. The app always does this; the
    /// command line tool can turn it off for scripts.
    public var moveOriginalsToTrash = true
    public var keepModificationDate = false
    /// Lossless results replace the original by default: nothing about the
    /// image changes. Lossy results are written next to it, so the original
    /// stays until the user decides otherwise.
    public var outputLossless = OutputMode.replace
    public var outputLossy = OutputMode.suffix
    public var suffix = OptimizationSettings.defaultSuffix
    /// Required for `.folder` output.
    public var outputFolder = ""

    /// The mode for the current compression setting.
    public var output: OutputMode { lossy ? outputLossy : outputLossless }

    public static var defaultSuffix: String { String(localized: "-optimized", bundle: .module, comment: "Default file name suffix, as in photo-optimized.jpg") }

    public init() {}

    public func isEnabled(_ format: ImageFormat) -> Bool { !disabledFormats.contains(format) }

    /// JPEG and HEIC use the quality as it is.
    public var jpegQuality: Int { quality }
    public var gifQuality: Int { quality }
}
