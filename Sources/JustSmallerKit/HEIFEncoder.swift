import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes HEIC with Apple's encoder. This is always lossy, so it only runs
/// when the user chose lossy compression.
enum HEIFEncoder {
    /// Auxiliary images that belong to the photo: HDR gain maps, depth and
    /// portrait mattes. Dropping them would lose HDR or portrait editing.
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

    static func recompress(_ input: URL, to output: URL, quality: Double, stripPrivateData: Bool) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) == 1, // image sequences and bursts are left alone
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { return false }

        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if stripPrivateData {
            // kCFNull removes the dictionary; orientation and profile stay.
            properties[kCGImagePropertyGPSDictionary] = kCFNull
            properties[kCGImagePropertyMakerAppleDictionary] = kCFNull
            properties[kCGImagePropertyIPTCDictionary] = kCFNull
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        for type in auxiliaryTypes {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) {
                CGImageDestinationAddAuxiliaryDataInfo(destination, type, info)
            }
        }
        return CGImageDestinationFinalize(destination)
    }
}
