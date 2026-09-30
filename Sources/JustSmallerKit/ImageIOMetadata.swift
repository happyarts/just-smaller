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
    /// false), have the same size and — in the formats `AuxiliaryImage`
    /// reads — differ by at most 1 % of the original's range on average (a
    /// map that is another one's, or broken, differs far more); nil
    /// otherwise. Each is decoded once.
    static func sameAuxiliaryImages(_ a: CGImageSource, _ b: CGImageSource, exact: Bool = true) -> [CFString]? {
        var both: [CFString] = []
        for type in auxiliaryTypes {
            let x = CGImageSourceCopyAuxiliaryDataInfoAtIndex(a, 0, type) as? [CFString: Any]
            let y = CGImageSourceCopyAuxiliaryDataInfoAtIndex(b, 0, type) as? [CFString: Any]
            guard (x == nil) == (y == nil) else { return nil }
            guard let x, let y else { continue }
            if exact {
                guard x[kCGImageAuxiliaryDataInfoData] as? Data == y[kCGImageAuxiliaryDataInfoData] as? Data else { return nil }
            } else if let a = AuxiliaryImage(x), let b = AuxiliaryImage(y) {
                guard a.width == b.width, a.height == b.height, a.meanDifference(to: b) <= 0.01 else { return nil }
            } else {
                // Formats read here are the one-channel ones; others keep to their size.
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

/// An auxiliary image's samples, for the one-channel formats photos carry:
/// 8-bit ('L008': gain maps, mattes), 16-bit float ('hdis', 'hdep') and
/// 32-bit float ('fdis', 'fdep': disparity, depth).
private struct AuxiliaryImage {
    let width: Int, height: Int
    private let data: Data, bytesPerRow: Int, bytes: Int

    init?(_ info: [CFString: Any]) {
        guard let data = info[kCGImageAuxiliaryDataInfoData] as? Data,
              let description = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
              let width = description[kCGImagePropertyWidth] as? Int, let height = description[kCGImagePropertyHeight] as? Int,
              let bytesPerRow = description[kCGImagePropertyBytesPerRow] as? Int,
              let format = description[kCGImagePropertyPixelFormat] as? UInt32
        else { return nil }
        switch format {
        case 0x4C30_3038: bytes = 1 // 'L008'
        case 0x6864_6973, 0x6864_6570: bytes = 2 // 'hdis', 'hdep'
        case 0x6664_6973, 0x6664_6570: bytes = 4 // 'fdis', 'fdep'
        default: return nil
        }
        let (row, rowOverflow) = width.multipliedReportingOverflow(by: bytes)
        let (size, sizeOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !rowOverflow, !sizeOverflow, bytesPerRow >= row, size <= data.count else { return nil }
        (self.width, self.height, self.data, self.bytesPerRow) = (width, height, data, bytesPerRow)
    }

    private func value(_ p: UnsafeRawBufferPointer, _ x: Int, _ y: Int) -> Float {
        let at = y * bytesPerRow + x * bytes
        switch bytes {
        case 1: return Float(p[at])
        case 2: return Float(p.loadUnaligned(fromByteOffset: at, as: Float16.self))
        default: return p.loadUnaligned(fromByteOffset: at, as: Float.self)
        }
    }

    /// The mean absolute difference to `other` (same size), relative to this
    /// image's range of values (for a flat image: the format's full range).
    /// Depth and disparity mark pixels without a value as NaN: NaN in both
    /// counts as the same, NaN in one as a difference of the whole range.
    func meanDifference(to other: AuxiliaryImage) -> Float {
        data.withUnsafeBytes { a in
            other.data.withUnsafeBytes { b in
                var low = Float.infinity, high = -Float.infinity, sum: Double = 0, unmatched = 0
                for y in 0..<height {
                    for x in 0..<width {
                        let v = value(a, x, y), w = other.value(b, x, y)
                        if v.isNaN || w.isNaN {
                            if v.isNaN != w.isNaN { unmatched += 1 }
                            continue
                        }
                        low = min(low, v); high = max(high, v)
                        sum += Double(abs(v - w))
                    }
                }
                let range = high > low ? Double(high - low) : (bytes == 1 ? 255 : 1)
                let mean = (sum / range + Double(unmatched)) / Double(width * height)
                return mean.isFinite ? Float(mean) : .infinity
            }
        }
    }
}
