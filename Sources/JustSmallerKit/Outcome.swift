import Foundation

/// What an optimized file kept of its original.
public enum Fidelity: Sendable, Equatable {
    /// Every step was proven to keep every pixel.
    case pixelIdentical
    /// No lossy step ran, but the format's check is not an exact comparison
    /// (an SVG's rendering).
    case lossless
    /// A lossy step is part of the result.
    case lossy
}

public enum Outcome: Sendable {
    /// `result` is where the optimized file is: the original's place, or a new file.
    /// `rejected`: results of single steps that failed their check on the way.
    case optimized(originalSize: Int64, newSize: Int64, tools: [String], result: URL, trashedOriginal: URL?,
                   fidelity: Fidelity, rejected: [Rejection])
    /// The file stays as it is.
    case unchanged(Unchanged)
}

/// A file that stays as it is, and why.
public struct Unchanged: Sendable, Equatable {
    public let reason: Reason
    public let size: Int64
    /// Set when an unchanged copy was written to an output folder.
    public let copy: URL?
    /// Whether the file still holds what the metadata level removes; nil
    /// when the level keeps everything or the file isn't an image.
    public let holdsPrivateData: Bool?
    /// Results that failed their check, also when another reason is the one
    /// the file stays for (a damaged original).
    public let rejected: [Rejection]

    public init(reason: Reason, size: Int64, copy: URL? = nil, holdsPrivateData: Bool? = nil, rejected: [Rejection] = []) {
        self.reason = reason
        self.size = size
        self.copy = copy
        self.holdsPrivateData = holdsPrivateData
        self.rejected = rejected
    }

    /// Why a file stays as it is. A detail is the finding in words.
    public enum Reason: Sendable, Equatable, CustomStringConvertible {
        case empty
        case notAnImage
        case turnedOff(ImageFormat)
        /// Neither the file nor its folder, or the folder a new file goes
        /// to, may be written.
        case readOnly
        /// The original isn't sound: found before (truncated, no end marker)
        /// or after a result failed (`Verifier.damage`). Nil when the file
        /// can't be read far enough to say.
        case damaged(String?)
        /// C2PA Content Credentials, which any change invalidates.
        case contentCredentials
        /// Apple's iPhone PNG variant, which only Apple's tools read.
        case appleCgBI
        /// A motion photo whose video can't be located safely.
        case motionPhotoVideo
        /// A JPEG whose further images can't be read safely.
        case unreadableImages
        /// What an SVG holds that the rendering can't check (scripts, animation).
        case uncheckable(String)
        /// Nothing this file can get (yet).
        case notSupported(Unsupported)
        /// It can't be converted.
        case notConvertible(Inconvertible)
        /// The metadata level's promise couldn't be kept: why.
        case metadataNotFilterable(String)
        /// A smaller result failed its check: why.
        case resultRejected(String)
        case alreadyOptimal
        /// The file changed while it was being worked on.
        case changedMeanwhile

        /// A recognised image that stays as it is belongs in an output
        /// folder too, so the folder is complete; what isn't an image, or
        /// changed meanwhile, doesn't.
        public var belongsInOutputFolder: Bool {
            switch self {
            case .empty, .notAnImage, .changedMeanwhile: false
            default: true
            }
        }

        /// The reason's name, the same in every language (`--json`).
        public var code: String {
            switch self {
            case .empty: "empty"
            case .notAnImage: "notAnImage"
            case .turnedOff: "turnedOff"
            case .readOnly: "readOnly"
            case .damaged: "damaged"
            case .contentCredentials: "contentCredentials"
            case .appleCgBI: "appleCgBI"
            case .motionPhotoVideo: "motionPhotoVideo"
            case .unreadableImages: "unreadableImages"
            case .uncheckable: "uncheckable"
            case .notSupported: "notSupported"
            case .notConvertible: "notConvertible"
            case .metadataNotFilterable: "metadataNotFilterable"
            case .resultRejected: "resultRejected"
            case .alreadyOptimal: "alreadyOptimal"
            case .changedMeanwhile: "changedMeanwhile"
            }
        }

        /// Which kind of a reason that has kinds (not supported, not
        /// convertible), the same in every language (`--json`).
        public var kind: String? {
            switch self {
            case .notSupported(let why): why.rawValue
            case .notConvertible(let why): why.rawValue
            default: nil
            }
        }

        public var description: String {
            switch self {
            case .empty: String(localized: "Empty file", bundle: .module)
            case .notAnImage: String(localized: "Not a supported image", bundle: .module)
            case .turnedOff(let format): String(localized: "\(format.displayName) is turned off in Settings", bundle: .module)
            case .readOnly: String(localized: "The file or its destination folder is read-only", bundle: .module)
            case .damaged(nil): String(localized: "The file is damaged or incomplete", bundle: .module)
            case .damaged(let detail?): String(localized: "The file is damaged: \(detail)", bundle: .module)
            case .contentCredentials: String(localized: "Has Content Credentials (C2PA)", bundle: .module)
            case .appleCgBI: String(localized: "Apple’s iPhone PNG variant (CgBI), which only Apple’s tools can read", bundle: .module)
            case .motionPhotoVideo: String(localized: "Motion photo whose video can’t be located safely", bundle: .module)
            case .unreadableImages: String(localized: "Holds images that can’t be read safely", bundle: .module)
            case .uncheckable(let detail): String(localized: "\(detail) – it can’t be checked safely", bundle: .module)
            case .notSupported(let why): why.description
            case .notConvertible(let why): why.description
            case .metadataNotFilterable(let detail): String(localized: "The metadata couldn’t be filtered safely: \(detail)", bundle: .module)
            case .resultRejected(let detail): String(localized: "Result rejected: \(detail)", bundle: .module)
            case .alreadyOptimal: String(localized: "Already optimal", bundle: .module)
            case .changedMeanwhile: String(localized: "The file changed in the meantime", bundle: .module)
            }
        }
    }
}

extension Unchanged {
    /// What a file can't get (yet). The raw value is the name in `--json`.
    public enum Unsupported: String, Sendable, Equatable, CustomStringConvertible {
        case animatedWebP, lossyWebP, gif
        case heicWithoutLoss, hdrHEIC
        /// A JPEG XL that wasn't made from a JPEG.
        case jxlNotFromJPEG
        /// The JPEG in a JPEG XL doesn't rebuild (damaged, or changed since).
        case jpegInJXLNotRebuildable
        /// The JPEG in a JPEG XL holds more than the photo.
        case jpegInJXLHoldsMore
        case nothingToOptimize

        public var description: String {
            switch self {
            case .animatedWebP: String(localized: "Animated WebP is not supported yet", bundle: .module)
            case .lossyWebP: String(localized: "Lossy WebP can’t be optimized without loss", bundle: .module)
            case .gif: String(localized: "GIF optimization comes in a later version", bundle: .module)
            case .heicWithoutLoss: String(localized: "HEIC can only be optimized in lossy mode", bundle: .module)
            case .hdrHEIC: String(localized: "HDR HEIC images are left untouched", bundle: .module)
            case .jxlNotFromJPEG: String(localized: "Only JPEG XL files made from a JPEG can be optimized so far", bundle: .module)
            case .jpegInJXLNotRebuildable:
                String(localized: "The JPEG in this JPEG XL can’t be rebuilt (damaged, or changed since it was made)", bundle: .module)
            case .jpegInJXLHoldsMore:
                String(localized: "The JPEG in this JPEG XL holds more than the photo (HDR gain map, depth map or video)", bundle: .module)
            case .nothingToOptimize: String(localized: "Nothing to optimize", bundle: .module)
            }
        }
    }

    /// Why a file can't be converted. The raw value is the name in `--json`.
    public enum Inconvertible: String, Sendable, Equatable, CustomStringConvertible {
        case notJPEG, notJXL
        /// Neither: a file that can't go either way.
        case notJPEGOrJXL
        /// A JPEG XL that wasn't made from a JPEG: there is none to go back to.
        case notFromJPEG
        /// A JPEG XL viewer would show only the photo, not the video.
        case motionPhoto
        /// A JPEG XL viewer would show only the photo, not the other images.
        case moreImages
        case dataAfterImage
        /// CMYK, arithmetic coding, 12 bits, or too much data after the image.
        case notLossless
        case notSmaller

        public var description: String {
            switch self {
            case .notJPEG: String(localized: "Only JPEGs can be converted to JPEG XL", bundle: .module)
            case .notJXL: String(localized: "Only JPEG XL files can be converted back to JPEG", bundle: .module)
            case .notJPEGOrJXL: String(localized: "Only JPEG and JPEG XL files can be converted", bundle: .module)
            case .notFromJPEG: String(localized: "This JPEG XL wasn’t made from a JPEG, so there is no JPEG to go back to", bundle: .module)
            case .motionPhoto: String(localized: "Motion photo – a JPEG XL viewer would show only the photo, not the video", bundle: .module)
            case .moreImages:
                String(localized: "Holds more than one image (HDR gain map, depth map or a second view) – a JPEG XL viewer would show only the photo",
                       bundle: .module)
            case .dataAfterImage: String(localized: "Holds data after the image that a JPEG XL viewer wouldn’t know", bundle: .module)
            case .notLossless:
                String(localized: "This JPEG can’t be stored as JPEG XL without loss (CMYK, arithmetic coding, 12 bits, or too much data after the image)",
                       bundle: .module)
            case .notSmaller: String(localized: "As JPEG XL it wouldn’t be smaller", bundle: .module)
            }
        }
    }
}

/// A step's result that failed its check.
public struct Rejection: Sendable, Equatable {
    /// The step, as listed among the tools.
    public let step: String
    /// What the check found.
    public let reason: String
    /// The check compared the image data (pixels, DCT coefficients) and
    /// found it changed: the tool broke the image.
    public let pixelsChanged: Bool
}

extension Unchanged {
    /// Whether `file` still holds what `level` removes, said of every image
    /// that stays as it is unless the level keeps everything.
    static func holdsPrivateData(_ file: URL, reason: Reason, level: MetadataHandling) -> Bool? {
        level == .keep || !reason.belongsInOutputFolder ? nil : MetadataCheck.hasFieldsToRemove(file, level: level)
    }
}

extension Rejection {
    init(_ error: VerificationError, step: String) {
        self.init(step: step, reason: error.reason, pixelsChanged: error.pixelsChanged)
    }
}
