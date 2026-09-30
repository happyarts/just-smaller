import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import JustSmallerKit

/// Images the multi-image JPEG and HEIC tests share.
enum TestImages {
    /// A pattern of coloured squares.
    static func pattern(width: Int = 160, height: Int = 120) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                ctx.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                                 blue: (x / 8 + y / 8) % 2 == 0 ? 0.9 : 0.1, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return ctx.makeImage()!
    }

    static var gps: [CFString: Any] { [kCGImagePropertyGPSLatitude: 48.1, kCGImagePropertyGPSLatitudeRef: "N"] }

    /// A photo with an Apple HDR gain map as ImageIO writes it: the main
    /// image with EXIF (creator, location, Apple's maker note with the HDR
    /// headroom and an identifier) and a gain map — in a JPEG after the
    /// image, indexed by MPF; in a HEIC as an auxiliary item.
    static func gainMapPhoto(at url: URL, type: UTType = .jpeg, location: Bool = true) -> URL {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, pattern(), [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Doe", kCGImagePropertyTIFFMake: "Apple"],
            kCGImagePropertyGPSDictionary: location ? gps : [:],
            kCGImagePropertyMakerAppleDictionary: ["33": 0.5, "48": 0.001, "43": "0F1E2D3C-UUID"],
        ] as CFDictionary)
        let gainMap = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(gainMap, "http://ns.apple.com/HDRGainMap/1.0/" as CFString, "HDRGainMap" as CFString, nil)
        CGImageMetadataSetValueWithPath(gainMap, nil, "HDRGainMap:HDRGainMapVersion" as CFString, 65536 as CFNumber)
        CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeHDRGainMap, [
            kCGImageAuxiliaryDataInfoData: Data((0..<80 * 60).map { UInt8($0 % 251) }) as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: [kCGImagePropertyWidth: 80, kCGImagePropertyHeight: 60,
                                                       kCGImagePropertyBytesPerRow: 80,
                                                       kCGImagePropertyPixelFormat: 0x4C30_3038], // 'L008'
            kCGImageAuxiliaryDataInfoMetadata: gainMap,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any] ?? [:]
    }

    /// How far above white the image may be shown.
    static func headroom(_ url: URL) -> Float? {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)?.contentHeadroom
    }
}
