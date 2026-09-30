// multi-image — writes JPEGs that hold several images, the way Apple's
// frameworks write them.
//
// usage: multi-image iso INPUT OUTPUT.jpg
//          a photo with an HDR gain map, written again by Core Image with
//          an ISO 21496-1 gain map
//        multi-image portrait INPUT OUTPUT.jpg
//          INPUT as a portrait photo: disparity (depth), a portrait effects
//          matte and skin and hair mattes, as ImageIO writes them

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4, ["iso", "portrait"].contains(args[1]) else {
    FileHandle.standardError.write("usage: multi-image iso|portrait INPUT OUTPUT.jpg\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])

if args[1] == "iso" {
    guard let sdr = CIImage(contentsOf: input), let hdr = CIImage(contentsOf: input, options: [.expandToHDR: true]) else { exit(1) }
    do {
        try CIContext().writeJPEGRepresentation(of: sdr, to: output, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                options: [CIImageRepresentationOption.hdrImage: hdr])
    } catch {
        print(error)
        exit(1)
    }
    exit(0)
}

// Portrait: the auxiliary images are made from the photo's own brightness,
// at a quarter (disparity) and half (mattes) of its size.
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let photo = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
else { exit(1) }

func gray(_ width: Int, _ height: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * height)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.draw(photo, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixels
}

func add(_ type: CFString, _ data: Data, width: Int, height: Int, bytesPerRow: Int, format: UInt32, metadata: CGImageMetadata? = nil) {
    var info: [CFString: Any] = [
        kCGImageAuxiliaryDataInfoData: data as CFData,
        kCGImageAuxiliaryDataInfoDataDescription: [kCGImagePropertyWidth: width, kCGImagePropertyHeight: height,
                                                   kCGImagePropertyBytesPerRow: bytesPerRow, kCGImagePropertyPixelFormat: format],
    ]
    if let metadata { info[kCGImageAuxiliaryDataInfoMetadata] = metadata }
    CGImageDestinationAddAuxiliaryDataInfo(destination, type, info as CFDictionary)
}

CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
let w = photo.width / 4, h = photo.height / 4
// Disparity as 16-bit floats ('hdis'), from 0.2 to 1.2.
let disparity = gray(w, h).map { Float16(0.2 + Float($0) / 255) }
add(kCGImageAuxiliaryDataTypeDisparity, disparity.withUnsafeBytes { Data($0) }, width: w, height: h, bytesPerRow: w * 2,
    format: 0x6864_6973)
let mw = photo.width / 2, mh = photo.height / 2, matte = gray(mw, mh)
for type in [kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
             kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte] {
    // One-component 8-bit ('L008'); each matte a different threshold.
    let cut = UInt8(type == kCGImageAuxiliaryDataTypePortraitEffectsMatte ? 96 : type == kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte ? 128 : 160)
    add(type, Data(matte.map { $0 > cut ? 255 : 0 }), width: mw, height: mh, bytesPerRow: mw, format: 0x4C30_3038)
}
guard CGImageDestinationFinalize(destination) else { exit(1) }
