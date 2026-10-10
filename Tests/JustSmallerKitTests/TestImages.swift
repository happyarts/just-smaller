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
    /// headroom, a Live Photo's content identifier and another identifier)
    /// and a gain map — in a JPEG after the
    /// image, indexed by MPF; in a HEIC as an auxiliary item.
    static func gainMapPhoto(at url: URL, type: UTType = .jpeg, location: Bool = true) -> URL {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, pattern(), [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Doe", kCGImagePropertyTIFFMake: "Apple"],
            kCGImagePropertyGPSDictionary: location ? gps : [:],
            kCGImagePropertyMakerAppleDictionary: ["33": 0.5, "48": 0.001, "43": "0F1E2D3C-UUID", "17": "89175B33-LIVE"],
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

    /// A 16 × 12 lossless JPEG (SOF3), which has no quantization tables:
    /// libjpeg-turbo's cjpeg -lossless 1 on a generated gradient.
    static let losslessJPEG = Data(base64Encoded: """
        /9j/7gAOQWRvYmUAZAAAAAAA/8MAEQgADAAQA1IRAEcRAEIRAP/EABgAAQEBAQEAAAAAAAAAAAAAAAAFCAQH/9oADANSAEcAQgAB
        AADP+f8A0jvKBQKDL9AoFAoNQUCgUCgy/QKBQFV3lAoFBl+gUCgUGoKBQKBQZfoFAoCq7ygUCgy/QKBQKDUFAoFAoMv0CgUBVd5Q
        KBQZfoFAoFBqCgUCgUGX6BQKArZf7ygUCg1BQKBQKDL9AoFAoNQUCgUBVd5QKBQagoFAoFBl+gUCgUGoKBQKAqu8oFAoNQUCgUCg
        y/QKBQKDUFAoFAVXeUCgUGoKBQKBQZfoFAoFBqCgUCgK2oO8oFAoMv0CgUCg1BQKBQKDL9AoFAVXeUCgUGX6BQKBQagoFAoFBl+g
        UCgKrvKBQKDL9AoFAoNQUCgUCgy/QKBQFV3lAoFBl+gUCgUGoKBQKBQZfoFAoH//2Q==
        """, options: .ignoreUnknownCharacters)!

    /// A 32 × 24 JPEG with arithmetic coding (SOF9), quality 97: libjpeg-turbo's
    /// cjpeg, then jpegtran -arithmetic.
    static let arithmeticJPEG = Data(base64Encoded: """
        /9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQICAQEBAQMCAgICAwMEBAMDAwMEBAYFBAQFBAMDBQcFBQYG
        BgYGBAUHBwcGBwYGBgb/2wBDAQEBAQEBAQMCAgMGBAMEBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYG
        BgYGBgYGBgb/yQARCAAYACADASIAAhEBAxEB/8wACgAQEAUBEBEF/9oADAMBAAIRAxEAPwD/APcQSBU6BN0PepVzrA1xYcWttCFc
        ds+gXiCsn/Ys7QgAxAUKZl6Jh4CWNDrnbRAlS3sScmnDqez0JXaVc+299poJEEHGsH/YmygBj2HWeugzAZc995AQxHEFnPPZReFw
        1TXfgdgyeabb8TsToS43a+nq2dxA8ijl6aOgcSEcr1if4I2VVAwIhOfPy6eaqir7spi7pKTTolBWo3KwSyUpMwIPizbPRQMYbENM
        XiG5x+rvPpilbvkuuE95ygWqF8An7+3eFu54LyaTPo6l+e4dnfouGDmWAmvVg3pZXf3wAMrcAMrcwmniNzJR+UpZZt5eSEV8SBzS
        PTP8y53RsN19Au7zo7FrQD4QvHzpu76hDxcuG57x+EECUX3V+gMSNTLCeWJY3/R0/du2GAMGl/y3zpsPfxgALz1Z+bOI0aFlnRaK
        NTlfi1X7+p2wCpVvYEp6IUET1U1j9WkcjDzhCu6qA61Eu9iyhFrc3CJZfnn1ZtyLCv1o0rWSKt9tfZjwFIAQm2W+jyQyWiqkwWb2
        JbUaFdu/f6/qapLsGbRXwfjWVnQEaAWMnAatNQuHD3gNxdMwptu4bxkSDqN+uJk+6Y4+dExG/YxnUGOq1JwMV3E6GjT5LZ1HKN2+
        GV43IvcdpAB5uN+/MkK+3zW5IAzp08iTm14+OSBoXfslri+rX+9vtS+CSXMHU4CwoIx6ApMUikMB28//AGJrVIcAfcDT7Wmg4dIX
        rdIa0kLbJWjzm41hw9k63Rd5vymQ/NjNynA4AtNX7FZdtAfbk0rkXtjhoXUianzPXmHO3VB/w8KY+d+emgNnlylXpc3Q+itYUuW3
        ahx/2b7kKiAgY0qyKwDTvE44MecgP3CeG8u0LTFPeYlC2I8X/CvH7OImMeJ4QeqdPhW+0gwhP68l/wCMx8BHTL24ox5x8bP/2Q==
        """, options: .ignoreUnknownCharacters)!

    /// A flat 24 × 8 baseline JPEG, quantization all ones, whose chroma is
    /// sampled 2 × 1 against luma 3 × 1: libjpeg-turbo, cjpegli's decoder,
    /// can't upsample that ratio, but reads the coefficients. Written by
    /// hand (one MCU, one-bit Huffman codes), then rewritten by jpeg-scan.
    static let fractionalSamplingJPEG = Data(base64Encoded: """
        /9j/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAAR
        CAAIABgDATEAAiEAAyEA/8QAJgABAAAAAAAAAAAAAAAAAAAAABABAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACAAMAAD8AAAP/2Q==
        """, options: .ignoreUnknownCharacters)!

    /// The standard sRGB profile from HP and Microsoft (sRGB IEC61966-2.1,
    /// 3 144 bytes, no profile ID), as image editors embed it.
    static let standardSRGBProfile = Data(base64Encoded: """
        AAAMSExpbm8CEAAAbW50clJHQiBYWVogB84AAgAJAAYAMQAAYWNzcE1TRlQAAAAASUVDIHNSR0IAAAAAAAAAAAAAAAEAAPbWAAEA
        AAAA0y1IUCAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAARY3BydAAAAVAAAAAzZGVzYwAA
        AYQAAABsd3RwdAAAAfAAAAAUYmtwdAAAAgQAAAAUclhZWgAAAhgAAAAUZ1hZWgAAAiwAAAAUYlhZWgAAAkAAAAAUZG1uZAAAAlQA
        AABwZG1kZAAAAsQAAACIdnVlZAAAA0wAAACGdmlldwAAA9QAAAAkbHVtaQAAA/gAAAAUbWVhcwAABAwAAAAkdGVjaAAABDAAAAAM
        clRSQwAABDwAAAgMZ1RSQwAABDwAAAgMYlRSQwAABDwAAAgMdGV4dAAAAABDb3B5cmlnaHQgKGMpIDE5OTggSGV3bGV0dC1QYWNr
        YXJkIENvbXBhbnkAAGRlc2MAAAAAAAAAEnNSR0IgSUVDNjE5NjYtMi4xAAAAAAAAAAAAAAASc1JHQiBJRUM2MTk2Ni0yLjEAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFhZWiAAAAAAAADzUQABAAAAARbMWFlaIAAAAAAA
        AAAAAAAAAAAAAABYWVogAAAAAAAAb6IAADj1AAADkFhZWiAAAAAAAABimQAAt4UAABjaWFlaIAAAAAAAACSgAAAPhAAAts9kZXNj
        AAAAAAAAABZJRUMgaHR0cDovL3d3dy5pZWMuY2gAAAAAAAAAAAAAABZJRUMgaHR0cDovL3d3dy5pZWMuY2gAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZGVzYwAAAAAAAAAuSUVDIDYxOTY2LTIuMSBEZWZhdWx0IFJHQiBjb2xv
        dXIgc3BhY2UgLSBzUkdCAAAAAAAAAAAAAAAuSUVDIDYxOTY2LTIuMSBEZWZhdWx0IFJHQiBjb2xvdXIgc3BhY2UgLSBzUkdCAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAGRlc2MAAAAAAAAALFJlZmVyZW5jZSBWaWV3aW5nIENvbmRpdGlvbiBpbiBJRUM2MTk2Ni0yLjEA
        AAAAAAAAAAAAACxSZWZlcmVuY2UgVmlld2luZyBDb25kaXRpb24gaW4gSUVDNjE5NjYtMi4xAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAB2aWV3AAAAAAATpP4AFF8uABDPFAAD7cwABBMLAANcngAAAAFYWVogAAAAAABMCVYAUAAAAFcf521lYXMAAAAAAAAAAQAA
        AAAAAAAAAAAAAAAAAAAAAAKPAAAAAnNpZyAAAAAAQ1JUIGN1cnYAAAAAAAAEAAAAAAUACgAPABQAGQAeACMAKAAtADIANwA7AEAA
        RQBKAE8AVABZAF4AYwBoAG0AcgB3AHwAgQCGAIsAkACVAJoAnwCkAKkArgCyALcAvADBAMYAywDQANUA2wDgAOUA6wDwAPYA+wEB
        AQcBDQETARkBHwElASsBMgE4AT4BRQFMAVIBWQFgAWcBbgF1AXwBgwGLAZIBmgGhAakBsQG5AcEByQHRAdkB4QHpAfIB+gIDAgwC
        FAIdAiYCLwI4AkECSwJUAl0CZwJxAnoChAKOApgCogKsArYCwQLLAtUC4ALrAvUDAAMLAxYDIQMtAzgDQwNPA1oDZgNyA34DigOW
        A6IDrgO6A8cD0wPgA+wD+QQGBBMEIAQtBDsESARVBGMEcQR+BIwEmgSoBLYExATTBOEE8AT+BQ0FHAUrBToFSQVYBWcFdwWGBZYF
        pgW1BcUF1QXlBfYGBgYWBicGNwZIBlkGagZ7BowGnQavBsAG0QbjBvUHBwcZBysHPQdPB2EHdAeGB5kHrAe/B9IH5Qf4CAsIHwgy
        CEYIWghuCIIIlgiqCL4I0gjnCPsJEAklCToJTwlkCXkJjwmkCboJzwnlCfsKEQonCj0KVApqCoEKmAquCsUK3ArzCwsLIgs5C1EL
        aQuAC5gLsAvIC+EL+QwSDCoMQwxcDHUMjgynDMAM2QzzDQ0NJg1ADVoNdA2ODakNww3eDfgOEw4uDkkOZA5/DpsOtg7SDu4PCQ8l
        D0EPXg96D5YPsw/PD+wQCRAmEEMQYRB+EJsQuRDXEPURExExEU8RbRGMEaoRyRHoEgcSJhJFEmQShBKjEsMS4xMDEyMTQxNjE4MT
        pBPFE+UUBhQnFEkUahSLFK0UzhTwFRIVNBVWFXgVmxW9FeAWAxYmFkkWbBaPFrIW1hb6Fx0XQRdlF4kXrhfSF/cYGxhAGGUYihiv
        GNUY+hkgGUUZaxmRGbcZ3RoEGioaURp3Gp4axRrsGxQbOxtjG4obshvaHAIcKhxSHHscoxzMHPUdHh1HHXAdmR3DHeweFh5AHmoe
        lB6+HukfEx8+H2kflB+/H+ogFSBBIGwgmCDEIPAhHCFIIXUhoSHOIfsiJyJVIoIiryLdIwojOCNmI5QjwiPwJB8kTSR8JKsk2iUJ
        JTglaCWXJccl9yYnJlcmhya3JugnGCdJJ3onqyfcKA0oPyhxKKIo1CkGKTgpaymdKdAqAio1KmgqmyrPKwIrNitpK50r0SwFLDks
        biyiLNctDC1BLXYtqy3hLhYuTC6CLrcu7i8kL1ovkS/HL/4wNTBsMKQw2zESMUoxgjG6MfIyKjJjMpsy1DMNM0YzfzO4M/E0KzRl
        NJ402DUTNU01hzXCNf02NzZyNq426TckN2A3nDfXOBQ4UDiMOMg5BTlCOX85vDn5OjY6dDqyOu87LTtrO6o76DwnPGU8pDzjPSI9
        YT2hPeA+ID5gPqA+4D8hP2E/oj/iQCNAZECmQOdBKUFqQaxB7kIwQnJCtUL3QzpDfUPARANER0SKRM5FEkVVRZpF3kYiRmdGq0bw
        RzVHe0fASAVIS0iRSNdJHUljSalJ8Eo3Sn1KxEsMS1NLmkviTCpMcky6TQJNSk2TTdxOJU5uTrdPAE9JT5NP3VAnUHFQu1EGUVBR
        m1HmUjFSfFLHUxNTX1OqU/ZUQlSPVNtVKFV1VcJWD1ZcVqlW91dEV5JX4FgvWH1Yy1kaWWlZuFoHWlZaplr1W0VblVvlXDVchlzW
        XSddeF3JXhpebF69Xw9fYV+zYAVgV2CqYPxhT2GiYfViSWKcYvBjQ2OXY+tkQGSUZOllPWWSZedmPWaSZuhnPWeTZ+loP2iWaOxp
        Q2maafFqSGqfavdrT2una/9sV2yvbQhtYG25bhJua27Ebx5veG/RcCtwhnDgcTpxlXHwcktypnMBc11zuHQUdHB0zHUodYV14XY+
        dpt2+HdWd7N4EXhueMx5KnmJeed6RnqlewR7Y3vCfCF8gXzhfUF9oX4BfmJ+wn8jf4R/5YBHgKiBCoFrgc2CMIKSgvSDV4O6hB2E
        gITjhUeFq4YOhnKG14c7h5+IBIhpiM6JM4mZif6KZIrKizCLlov8jGOMyo0xjZiN/45mjs6PNo+ekAaQbpDWkT+RqJIRknqS45NN
        k7aUIJSKlPSVX5XJljSWn5cKl3WX4JhMmLiZJJmQmfyaaJrVm0Kbr5wcnImc951kndKeQJ6unx2fi5/6oGmg2KFHobaiJqKWowaj
        dqPmpFakx6U4pammGqaLpv2nbqfgqFKoxKk3qamqHKqPqwKrdavprFys0K1ErbiuLa6hrxavi7AAsHWw6rFgsdayS7LCszizrrQl
        tJy1E7WKtgG2ebbwt2i34LhZuNG5SrnCuju6tbsuu6e8IbybvRW9j74KvoS+/796v/XAcMDswWfB48JfwtvDWMPUxFHEzsVLxcjG
        RsbDx0HHv8g9yLzJOsm5yjjKt8s2y7bMNcy1zTXNtc42zrbPN8+40DnQutE80b7SP9LB00TTxtRJ1MvVTtXR1lXW2Ndc1+DYZNjo
        2WzZ8dp22vvbgNwF3IrdEN2W3hzeot8p36/gNuC94UThzOJT4tvjY+Pr5HPk/OWE5g3mlucf56noMui86Ubp0Opb6uXrcOv77Ibt
        Ee2c7ijutO9A78zwWPDl8XLx//KM8xnzp/Q09ML1UPXe9m32+/eK+Bn4qPk4+cf6V/rn+3f8B/yY/Sn9uv5L/tz/bf//
        """, options: .ignoreUnknownCharacters)!
}

/// Google's XMP as cameras write it, for the tests.
enum GoogleXMPSamples {
    /// An XMP packet around one rdf:Description.
    static func packet(_ description: String) -> String {
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + description + "</rdf:RDF></x:xmpmeta>"
    }

    /// An APP1 XMP segment with `description` in its packet.
    static func segment(_ description: String) -> Data {
        JPEGMarkers.write(0xE1, JPEGMarkers.xmpHeader + Array(packet(description).utf8))
    }

    /// Ultra HDR's directory (attributes): the photo, a gain map of that
    /// length (none for nil), a video of that length.
    static func directory(gainMapLength: Int?, videoLength: Int? = nil) -> String {
        func item(_ attributes: String) -> String { "<rdf:li rdf:parseType=\"Resource\"><Container:Item \(attributes)/></rdf:li>" }
        var items = item("Item:Semantic=\"Primary\" Item:Mime=\"image/jpeg\"")
        if let gainMapLength { items += item("Item:Semantic=\"GainMap\" Item:Mime=\"image/jpeg\" Item:Length=\"\(gainMapLength)\"") }
        if let videoLength { items += item("Item:Semantic=\"MotionPhoto\" Item:Mime=\"video/mp4\" Item:Length=\"\(videoLength)\"") }
        return "<rdf:Description xmlns:Container=\"\(GoogleXMP.containerNamespaces[0])\" xmlns:Item=\"\(GoogleXMP.itemNamespaces[0])\">"
            + "<Container:Directory><rdf:Seq>\(items)</rdf:Seq></Container:Directory></rdf:Description>"
    }

    /// Dynamic Depth's directory (elements in rdf:value): the photo, then
    /// `items` (MIME type and length), laid out right after the photo.
    static func depthDirectory(_ items: [(mime: String, length: Int)], paddings: [Int] = []) -> String {
        func item(_ mime: String, _ length: Int, _ padding: Int) -> String {
            "<rdf:li rdf:parseType=\"Resource\"><rdf:value rdf:parseType=\"Resource\"><Item:Mime>\(mime)</Item:Mime>"
                + "<Item:Length>\(length)</Item:Length>" + (padding > 0 ? "<Item:Padding>\(padding)</Item:Padding>" : "") + "</rdf:value></rdf:li>"
        }
        // `paddings`: the photo's, then each item's.
        func padding(_ k: Int) -> Int { paddings.indices.contains(k) ? paddings[k] : 0 }
        let entries = item("image/jpeg", 0, padding(0)) + items.enumerated().map { item($0.element.mime, $0.element.length, padding($0.offset + 1)) }.joined()
        return "<rdf:Description xmlns:Device=\"\(MetadataPolicy.NS.depthDevice)\" xmlns:Container=\"\(GoogleXMP.containerNamespaces[1])\" "
            + "xmlns:Item=\"\(GoogleXMP.itemNamespaces[1])\"><Device:Container rdf:parseType=\"Resource\"><Container:Directory><rdf:Seq>"
            + entries + "</rdf:Seq></Container:Directory></Device:Container></rdf:Description>"
    }

    /// A small MP4 as a motion photo's video: its ftyp box, and `payload`
    /// in an mdat box; with `location`, a movie whose user data holds one
    /// (as Samsung's videos do).
    static func video(_ payload: Data, location: Bool = false) -> Data {
        func box(_ type: String, _ body: Data) -> Data { Data(withUnsafeBytes(of: UInt32(8 + body.count).bigEndian, Array.init)) + Data(type.utf8) + body }
        var video = box("ftyp", Data("isom".utf8) + Data(count: 4) + Data("isommp42".utf8))
        if location { video += box("moov", box("udta", Data([0, 0, 0, 20, 0xA9, 0x78, 0x79, 0x7A]) + Data("+53.55+009.99/".utf8))) }
        return video + box("mdat", payload)
    }

    /// Google's container directory with any items: MIME type, length and
    /// padding each (attributes), after the photo with `primaryPadding`.
    static func directory(_ items: [(mime: String, length: Int, padding: Int)], primaryPadding: Int = 0) -> String {
        func item(_ mime: String, _ length: Int?, _ padding: Int) -> String {
            "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Mime=\"\(mime)\""
                + (length.map { " Item:Length=\"\($0)\"" } ?? "") + (padding > 0 ? " Item:Padding=\"\(padding)\"" : "") + "/></rdf:li>"
        }
        let entries = item("image/jpeg", nil, primaryPadding) + items.map { item($0.mime, $0.length, $0.padding) }.joined()
        return "<rdf:Description xmlns:Container=\"\(GoogleXMP.containerNamespaces[0])\" xmlns:Item=\"\(GoogleXMP.itemNamespaces[0])\">"
            + "<Container:Directory><rdf:Seq>\(entries)</rdf:Seq></Container:Directory></rdf:Description>"
    }

    /// The segments of a tiny JPEG with `main` in its XMP packet and
    /// `extended` in an extended packet, in parts as large as a segment
    /// allows (at least two).
    static func headers(_ main: String?, extended: String? = nil) throws -> [JPEGMarkers.Segment] {
        let guid = Array("0123456789ABCDEF0123456789ABCDEF".utf8)
        var file = Data([0xFF, 0xD8])
        let note = "<rdf:Description xmlns:xmpNote=\"http://ns.adobe.com/xmp/note/\" xmpNote:HasExtendedXMP=\"\(String(decoding: guid, as: UTF8.self))\"/>"
        if main != nil || extended != nil { file += segment((main ?? "") + (extended == nil ? "" : note)) }
        if let extended {
            let whole = Array(packet(extended).utf8)
            func be(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).bigEndian, Array.init) }
            let size = min(65_000, whole.count / 2 + 1)
            for offset in stride(from: 0, to: whole.count, by: size) {
                let part = whole[offset..<min(whole.count, offset + size)]
                file += JPEGMarkers.write(0xE1, JPEGMarkers.extendedXMPHeader + guid + be(whole.count) + be(offset) + Array(part))
            }
        }
        file += Data([0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9])
        return try JPEGMarkers.headers(ByteView(file)).segments
    }
}

/// A small disk image with its own file system (APFS, ExFAT, MS-DOS),
/// mounted inside `folder` and hidden from Finder, for what only other
/// volumes do. `eject` before the folder goes.
struct DiskImage {
    let mount: URL

    /// 8 MB.
    init(_ fileSystem: String, in folder: URL) throws {
        let image = folder.appending(path: "\(fileSystem).dmg")
        mount = folder.appending(path: fileSystem)
        try Self.hdiutil("create", "-size", "8m", "-fs", fileSystem, "-volname", "JSTest", image.path)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.hdiutil("attach", "-nobrowse", "-noverify", "-mountpoint", mount.path, image.path)
    }

    func eject() {
        try? Self.hdiutil("detach", "-force", mount.path)
    }

    private static func hdiutil(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.joined(separator: " ")) failed"])
        }
    }
}
