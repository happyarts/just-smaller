import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes HEIC with Apple's encoder. This is always lossy, so it only runs
/// when the user chose lossy compression.
enum HEIFEncoder {
    static func recompress(_ input: URL, to output: URL, quality: Double, metadata level: MetadataHandling) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) == 1, // image sequences and bursts are left alone
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { return false }

        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if level == .keep {
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        } else {
            // The image goes in without metadata; what the level keeps of the
            // original's EXIF and XMP is put in afterwards. The orientation
            // is carried over; the colour profile is part of the image itself.
            // The tile size is carried over too, as the copy with all
            // metadata does: ImageIO shows the grid's as the TIFF tile size,
            // whatever the EXIF says, and with a size of its own choosing the
            // result would show values the original never had.
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
            let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            if let orientation = original?[kCGImagePropertyOrientation] { properties[kCGImagePropertyOrientation] = orientation }
            if let tiff = original?[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
               let width = tiff[kCGImagePropertyTIFFTileWidth] as? Int, let length = tiff[kCGImagePropertyTIFFTileLength] as? Int,
               width > 0, length > 0 {
                properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFTileWidth: width, kCGImagePropertyTIFFTileLength: length]
            }
            CGImageDestinationAddImageAndMetadata(destination, image, CGImageMetadataCreateMutable(), properties as CFDictionary)
        }
        // HDR gain maps, depth and portrait mattes: dropping them would lose
        // HDR or portrait editing.
        for (type, info) in AuxiliaryImages.infos(source) {
            CGImageDestinationAddAuxiliaryDataInfo(destination, type, info)
        }
        guard CGImageDestinationFinalize(destination) else { return false }
        // The original's EXIF and XMP as the level keeps them, byte for byte,
        // in place of whatever ImageIO wrote.
        if level != .keep {
            let result = try Data(contentsOf: output), original = try Data(contentsOf: input, options: .alwaysMapped)
            do {
                try HEIFMetadataFilter.filter(result, level: level, from: original).write(to: output)
            } catch is FormatError {
                throw VerificationError(reason: String(localized: "metadata that should have been removed is still there", bundle: .module))
            }
        }
        return true
    }
}
