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
        /// Nothing this file can get (yet): why, in words.
        case notSupported(String)
        /// It can't be converted: why, in words.
        case notConvertible(String)
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

        public var description: String {
            switch self {
            case .empty: String(localized: "Empty file", bundle: .module)
            case .notAnImage: String(localized: "Not a supported image", bundle: .module)
            case .turnedOff(let format): String(localized: "\(format.displayName) is turned off in Settings", bundle: .module)
            case .readOnly: String(localized: "The file or its destination folder is read-only", bundle: .module)
            case .damaged(nil): String(localized: "The file is damaged or incomplete", bundle: .module)
            case .damaged(let detail?): String(localized: "The file is damaged: \(detail)", bundle: .module)
            case .contentCredentials:
                String(localized: "Has Content Credentials (C2PA), which any change would invalidate", bundle: .module)
            case .appleCgBI: String(localized: "Apple’s iPhone PNG variant (CgBI), which only Apple’s tools can read", bundle: .module)
            case .motionPhotoVideo: String(localized: "Motion photo whose video can’t be located safely", bundle: .module)
            case .unreadableImages: String(localized: "Holds images that can’t be read safely", bundle: .module)
            case .uncheckable(let detail): String(localized: "\(detail) – it can’t be checked safely", bundle: .module)
            case .notSupported(let detail), .notConvertible(let detail): detail
            case .metadataNotFilterable(let detail): String(localized: "The metadata couldn’t be filtered safely: \(detail)", bundle: .module)
            case .resultRejected(let detail): String(localized: "Result rejected: \(detail)", bundle: .module)
            case .alreadyOptimal: String(localized: "Already optimal", bundle: .module)
            case .changedMeanwhile: String(localized: "The file changed in the meantime", bundle: .module)
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
