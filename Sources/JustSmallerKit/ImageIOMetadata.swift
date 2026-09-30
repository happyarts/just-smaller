import Foundation
import ImageIO

/// Filters metadata through ImageIO, for files our own filters can't rewrite
/// safely: HEIC. ImageIO copies the image data unchanged and writes new
/// metadata around it; the auxiliary images (HDR gain map, portrait depth
/// and mattes) are rebuilt, and are checked to be all there.
enum ImageIOMetadata {
    private static var auxiliaryTypes: [CFString] { [
        kCGImageAuxiliaryDataTypeHDRGainMap,
        kCGImageAuxiliaryDataTypeISOGainMap,
        kCGImageAuxiliaryDataTypeDepth,
        kCGImageAuxiliaryDataTypeDisparity,
        kCGImageAuxiliaryDataTypePortraitEffectsMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
    ] }

    /// Auxiliary images that belong to the photo; they must all survive.
    static func auxiliaryImages(_ source: CGImageSource) -> [CFString] {
        auxiliaryTypes.filter { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }
    }

    /// The auxiliary images both hold, when they hold the same ones and they
    /// decode to the same data; nil otherwise. Each is decoded once.
    static func sameAuxiliaryImages(_ a: CGImageSource, _ b: CGImageSource) -> [CFString]? {
        var both: [CFString] = []
        for type in auxiliaryTypes {
            let x = CGImageSourceCopyAuxiliaryDataInfoAtIndex(a, 0, type) as? [CFString: Any]
            let y = CGImageSourceCopyAuxiliaryDataInfoAtIndex(b, 0, type) as? [CFString: Any]
            guard (x == nil) == (y == nil), x?[kCGImageAuxiliaryDataInfoData] as? Data == y?[kCGImageAuxiliaryDataInfoData] as? Data
            else { return nil }
            if x != nil { both.append(type) }
        }
        return both
    }

    /// Writes `input` with only the metadata the level keeps. False when the
    /// file holds several images ImageIO would not all copy (bursts, sequences).
    static func copy(_ input: URL, to output: URL, level: MetadataHandling) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil)
        else { return false }
        // HEIC keeps XMP that only exists there (e.g. xmp:CreatorTool) even
        // so; the check afterwards catches that, and lossy mode's re-encode
        // then takes over.
        let options: [CFString: Any] = [kCGImageDestinationMetadata: filtered(CGImageSourceCopyMetadataAtIndex(source, 0, nil), level),
                                        kCGImageDestinationMergeMetadata: false]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else { return false }

        // Every auxiliary image must still be there, decoding to the same data:
        // ImageIO copies them, and must never re-encode them.
        guard let result = CGImageSourceCreateWithURL(output as CFURL, nil), sameAuxiliaryImages(source, result) != nil else {
            throw VerificationError(reason: String(localized: "animation or second image lost", bundle: .module))
        }
        return true
    }

    /// A copy of the metadata with only the properties the level keeps.
    static func filtered(_ metadata: CGImageMetadata?, _ level: MetadataHandling) -> CGImageMetadata {
        let out = CGImageMetadataCreateMutable()
        guard let metadata else { return out }
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            guard let ns = CGImageMetadataTagCopyNamespace(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String?,
                  MetadataPolicy.keeps(MetadataPolicy.group(xmpNamespace: ns, name: name), at: level)
            else { return true }
            if let prefix = CGImageMetadataTagCopyPrefix(tag) {
                CGImageMetadataRegisterNamespaceForPrefix(out, ns as CFString, prefix, nil)
            }
            CGImageMetadataSetTagWithPath(out, nil, path, tag)
            return true
        }
        return out
    }
}
