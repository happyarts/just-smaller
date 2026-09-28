import Foundation

/// Which metadata fields each level keeps. One table per kind of metadata:
/// XMP properties, EXIF tags, IPTC-IIM datasets, Photoshop resources and PNG
/// text keywords. The same field often exists in several of them (the
/// creator is EXIF Artist, IIM 2:80 and XMP dc:creator), so the tables must
/// agree; `MetadataCheck` holds every result against the XMP table.
///
/// Everything not listed goes: an unknown field could hold anything, so
/// "remove private data" keeps only what is known to be harmless.
enum MetadataPolicy {
    enum Group: Int, Comparable {
        /// Needed to show the image correctly. Kept in every level.
        case display
        /// Who made the image and the rights. Kept unless everything goes.
        case rights
        /// Descriptions, keywords, dates, camera and exposure. Kept when only
        /// private data is removed.
        case imageInfo
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    /// The widest group a level keeps; nil for `.keep`, which keeps everything.
    static func widestGroup(_ level: MetadataHandling) -> Group? {
        switch level {
        case .keep: nil
        case .removePrivate: .imageInfo
        case .copyrightOnly: .rights
        case .removeAll: .display
        }
    }

    static func keeps(_ group: Group?, at level: MetadataHandling) -> Bool {
        guard let widest = widestGroup(level) else { return true }
        guard let group else { return false }
        return group <= widest
    }

    // MARK: - XMP

    enum NS {
        static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        static let dc = "http://purl.org/dc/elements/1.1/"
        static let xmp = "http://ns.adobe.com/xap/1.0/"
        static let xmpRights = "http://ns.adobe.com/xap/1.0/rights/"
        static let xmpNote = "http://ns.adobe.com/xmp/note/"
        static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
        static let iptcCore = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
        static let iptcExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
        static let plus = "http://ns.useplus.org/ldf/xmp/1.0/"
        static let tiff = "http://ns.adobe.com/tiff/1.0/"
        static let exif = "http://ns.adobe.com/exif/1.0/"
        static let exifEX = "http://cipa.jp/exif/1.0/"
        static let aux = "http://ns.adobe.com/exif/1.0/aux/"
        static let lightroom = "http://ns.adobe.com/lightroom/1.0/"
        static let mwgKeywords = "http://www.metadataworkinggroup.com/schemas/keywords/"
    }

    /// Namespaces that describe how the image is to be shown or what else the
    /// file holds (HDR gain maps, depth, panoramas, motion photos). Readers
    /// need them to interpret the file, so they stay in every level.
    static let displayNamespaces: Set<String> = [
        "http://ns.adobe.com/hdr-gain-map/1.0/",
        "http://ns.apple.com/pixeldatainfo/1.0/",
        "http://ns.apple.com/HDRGainMap/1.0/",
        "http://ns.apple.com/depthData/1.0/",
        "http://ns.apple.com/portraitEffectsMatte/1.0/",
        "http://ns.apple.com/semanticSegmentationMatte/1.0/",
        "http://ns.google.com/photos/1.0/container/",
        "http://ns.google.com/photos/1.0/container/item/",
        "http://ns.google.com/photos/1.0/camera/",
        "http://ns.google.com/photos/1.0/panorama/",
        "http://ns.google.com/photos/1.0/depthmap/",
        "http://ns.google.com/photos/1.0/image/",
    ]

    /// The group of a top-level XMP property, or nil when it goes in every
    /// level but `.keep`.
    static func group(xmpNamespace ns: String, name: String) -> Group? {
        if displayNamespaces.contains(ns) { return .display }
        switch ns {
        case NS.tiff:
            switch name {
            // The orientation, and how the image data is laid out (HEIC
            // tiles), which encoders write themselves.
            case "Orientation", "ImageWidth", "ImageLength", "TileWidth", "TileLength", "BitsPerSample",
                 "Compression", "PhotometricInterpretation", "SamplesPerPixel", "PlanarConfiguration",
                 "YCbCrSubSampling", "YCbCrPositioning": return .display
            case "Artist", "Copyright": return .rights
            case "Software", "NativeDigest": return nil
            default: return .imageInfo
            }
        case NS.exif:
            switch name {
            case "ColorSpace", "Gamma", "ExifVersion", "PixelXDimension", "PixelYDimension": return .display
            case "UserComment", "ImageUniqueID", "MakerNote", "NativeDigest", "RelatedSoundFile": return nil
            default: return name.hasPrefix("GPS") ? nil : .imageInfo
            }
        case NS.exifEX:
            switch name {
            case "Gamma": return .display
            case "BodySerialNumber", "LensSerialNumber", "CameraOwnerName", "ImageUniqueID": return nil
            default: return .imageInfo
            }
        case NS.aux:
            switch name {
            case "SerialNumber", "LensSerialNumber", "OwnerName", "ImageNumber": return nil
            default: return .imageInfo
            }
        case NS.dc:
            switch name {
            case "creator", "rights", "copyright": return .rights // "copyright" isn't standard, but some programs write it
            case "coverage": return nil // place or period shown
            default: return .imageInfo
            }
        case NS.xmpRights, NS.plus:
            return .rights
        case NS.photoshop:
            switch name {
            case "Credit", "Source", "AuthorsPosition": return .rights
            case "LegacyIPTCDigest": return .rights // updated with the IIM block
            case "City", "State", "Country", "DocumentAncestors", "History", "TextLayers": return nil
            default: return .imageInfo
            }
        case NS.iptcCore:
            switch name {
            case "CreatorContactInfo": return .rights
            case "Location", "CountryCode": return nil
            default: return .imageInfo
            }
        case NS.iptcExt:
            switch name {
            case "DigitalSourceType", "LinkedEncRightsExpr", "EmbdEncRightsExpr": return .rights
            case "LocationCreated", "LocationShown", "PersonInImage", "PersonInImageWDetails",
                 "ImageRegion", "ModelAge": return nil
            default: return .imageInfo
            }
        case NS.xmp:
            // CreatorTool is the editing software, like EXIF's Software.
            return name == "Thumbnails" || name == "CreatorTool" ? nil : .imageInfo
        case NS.lightroom:
            return name == "hierarchicalSubject" || name == "weightedFlatSubject" ? .imageInfo : nil
        case NS.mwgKeywords:
            return .imageInfo
        default:
            // Editing history (xmpMM), develop settings (crs), face regions
            // (mwg-rs, Apple, Microsoft) and every namespace not listed.
            return nil
        }
    }

    // MARK: - EXIF

    enum IFD { case main, exif, interop }

    /// The group of an EXIF tag; nil when it goes. GPS and the thumbnail
    /// (IFD1) are not listed: they go in every level but `.keep`.
    static func group(exifTag tag: UInt16, in ifd: IFD) -> Group? {
        switch ifd {
        case .interop:
            // "R03" here is how cameras say Adobe RGB without a profile.
            return .display
        case .main:
            switch tag {
            case 0x0112: return .display // Orientation
            case 0x013B, 0x8298, 0x9C9D: return .rights // Artist, Copyright, Windows author
            case 0x010E, 0x010F, 0x0110, // ImageDescription, Make, Model
                 0x011A, 0x011B, 0x0128, // resolution
                 0x0132, 0x0213, // DateTime, YCbCrPositioning
                 0x4746, 0x4749, // Rating
                 0x9C9B, 0x9C9C, 0x9C9E, 0x9C9F: // Windows title, comment, keywords, subject
                return .imageInfo
            default: return nil
            }
        case .exif:
            switch tag {
            case 0xA001, 0xA500: return .display // ColorSpace, Gamma
            case 0x9000: return .display // ExifVersion: required in an EXIF IFD
            case 0x927C, 0x9286, 0xA004, 0xA420, 0xA430, 0xA431, 0xA435:
                // MakerNote, UserComment, RelatedSoundFile, ImageUniqueID,
                // CameraOwnerName, BodySerialNumber, LensSerialNumber
                return nil
            case 0x829A, 0x829D, 0x8822, 0x8824, 0x8827, 0x8830...0x8835,
                 0x9003, 0x9004, 0x9010...0x9012, 0x9101, 0x9102, 0x9201...0x920A, 0x9214,
                 0x9290...0x9292, 0x9400...0x9405, 0xA000, 0xA002, 0xA003,
                 0xA20B, 0xA20E...0xA210, 0xA214, 0xA215, 0xA217, 0xA300...0xA302,
                 0xA401...0xA40C, 0xA432...0xA434, 0xA460...0xA462:
                // exposure, dates and time zones, lens and camera settings
                return .imageInfo
            default: return nil
            }
        }
    }

    // MARK: - IPTC-IIM

    /// The group of an IIM dataset (record:dataset).
    static func group(iimRecord record: UInt8, dataset: UInt8) -> Group? {
        switch (record, dataset) {
        case (1, 0), (1, 90): return .rights // record version, character set
        case (2, 0): return .rights // record version
        case (2, 80), (2, 85), (2, 110), (2, 115), (2, 116), (2, 118):
            // by-line, by-line title, credit, source, copyright, contact
            return .rights
        case (2, 4), (2, 5), (2, 7), (2, 8), (2, 10), (2, 12), (2, 15), (2, 20), (2, 22), (2, 25),
             (2, 30), (2, 35), (2, 37), (2, 38), (2, 40), (2, 45), (2, 47), (2, 50),
             (2, 55), (2, 60), (2, 62), (2, 63), (2, 103), (2, 105), (2, 120), (2, 122):
            // title, status, urgency, subjects, category, keywords, dates,
            // instructions, reference, headline, caption, caption writer
            return .imageInfo
        default:
            // City, sublocation, province, country (2:90–2:101), the
            // originating program, envelope data and vendor datasets.
            return nil
        }
    }

    /// The group of a Photoshop image resource in APP13.
    static func group(photoshopResource id: UInt16) -> Group? {
        switch id {
        case 0x0404, 0x0425: return .rights // IIM and its digest (filtered, updated)
        case 0x040A, 0x040B: return .rights // copyright flag, rights URL
        case 0x07D0...0x0BB7: return .rights // clipping paths for print
        case 0x03ED: return .imageInfo // print resolution
        default: return nil // thumbnails, print settings, slices, copies of EXIF/XMP
        }
    }

    // MARK: - PNG

    /// The group of a PNG text chunk by its keyword.
    static func group(pngTextKeyword keyword: String) -> Group? {
        switch keyword {
        case "Author", "Copyright", "Disclaimer": return .rights
        case "Title", "Description", "Creation Time", "Source", "Warning": return .imageInfo
        default: return nil // Comment, Software, ImageMagick's raw profiles, …
        }
    }
}
