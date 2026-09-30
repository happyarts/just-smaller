// gain-map — writes a photo with an HDR gain map again with Core Image,
// which stores an ISO 21496-1 gain map: a JPEG that holds two images.
//
// usage: gain-map INPUT OUTPUT.jpg

import CoreImage
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: gain-map INPUT OUTPUT.jpg\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
guard let sdr = CIImage(contentsOf: input), let hdr = CIImage(contentsOf: input, options: [.expandToHDR: true]) else { exit(1) }
do {
    try CIContext().writeJPEGRepresentation(of: sdr, to: URL(fileURLWithPath: args[2]),
                                            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                            options: [CIImageRepresentationOption.hdrImage: hdr])
} catch {
    print(error)
    exit(1)
}
