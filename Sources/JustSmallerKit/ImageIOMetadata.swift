import Foundation
import ImageIO

/// What HEIC's lossy re-encode needs from ImageIO: the auxiliary images
/// (HDR gain map, portrait depth and mattes) that must all come along, and
/// the metadata to start from.
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
    /// decode to the same data — or, after a lossy re-encode (`exact`
    /// false), have the same size; nil otherwise. Each is decoded once.
    static func sameAuxiliaryImages(_ a: CGImageSource, _ b: CGImageSource, exact: Bool = true) -> [CFString]? {
        var both: [CFString] = []
        for type in auxiliaryTypes {
            let x = CGImageSourceCopyAuxiliaryDataInfoAtIndex(a, 0, type) as? [CFString: Any]
            let y = CGImageSourceCopyAuxiliaryDataInfoAtIndex(b, 0, type) as? [CFString: Any]
            guard (x == nil) == (y == nil) else { return nil }
            guard let x, let y else { continue }
            if exact {
                guard x[kCGImageAuxiliaryDataInfoData] as? Data == y[kCGImageAuxiliaryDataInfoData] as? Data else { return nil }
            } else {
                let size = { (info: [CFString: Any]) -> [Int?] in
                    let description = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any]
                    return [description?[kCGImagePropertyWidth] as? Int, description?[kCGImagePropertyHeight] as? Int]
                }
                guard size(x) == size(y) else { return nil }
            }
            both.append(type)
        }
        return both
    }

    /// The metadata as a copy of the original's, with every property removed
    /// the level doesn't keep. ImageIO's own bookkeeping stays: without it,
    /// ImageIO brings back fields that were removed. The copy also carries
    /// what ImageIO doesn't show (maker notes), so ImageIO writes items large
    /// enough for everything; `HEIFMetadataFilter` then puts in what stays.
    static func filtered(_ metadata: CGImageMetadata?, _ level: MetadataHandling) -> CGImageMetadata {
        guard let metadata, let out = CGImageMetadataCreateMutableCopy(metadata) else { return CGImageMetadataCreateMutable() }
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            guard let ns = CGImageMetadataTagCopyNamespace(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String?,
                  ns != MetadataCheck.imageIONamespace, !MetadataPolicy.keeps(MetadataPolicy.group(xmpNamespace: ns, name: name), at: level)
            else { return true }
            CGImageMetadataRemoveTagWithPath(out, nil, path)
            return true
        }
        return out
    }
}
