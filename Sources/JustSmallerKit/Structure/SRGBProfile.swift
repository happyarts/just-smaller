import CryptoKit
import Foundation

/// Standard sRGB ICC profiles, which say nothing the PNG `sRGB` chunk doesn't:
/// the image is sRGB, displayed with the profile's rendering intent. The
/// known profiles are libpng's (`png_sRGB_checks`): identified by the MD5 in
/// the profile header, which must be the MD5 of the profile itself, or,
/// where that is empty, by CRC-32 and length.
enum SRGBProfile {
    private static let ids: Set<[UInt8]> = [
        [0x29, 0xf8, 0x3d, 0xde, 0xaf, 0xf2, 0x55, 0xae, 0x78, 0x42, 0xfa, 0xe4, 0xca, 0x83, 0x39, 0x0d],
        [0xc9, 0x5b, 0xd6, 0x37, 0xe9, 0x5d, 0x8a, 0x3b, 0x0d, 0xf3, 0x8f, 0x99, 0xc1, 0x32, 0x03, 0x89],
        [0xfc, 0x66, 0x33, 0x78, 0x37, 0xe2, 0x88, 0x6b, 0xfd, 0x72, 0xe9, 0x83, 0x82, 0x28, 0xf1, 0xb8],
        [0x34, 0x56, 0x2a, 0xbf, 0x99, 0x4c, 0xcd, 0x06, 0x6d, 0x2c, 0x57, 0x21, 0xd0, 0xd6, 0x8c, 0x5d],
    ]
    /// Profiles without an ID: (CRC-32, length).
    private static let withoutID: Set<[UInt32]> = [[0x5d51_29ce, 3024], [0x182e_a552, 3144], [0xf29e_526d, 3144]]

    /// The rendering intent (0–3) if `profile` is a standard sRGB profile.
    static func renderingIntent(_ profile: Data) -> UInt8? {
        let p = [UInt8](profile)
        guard p.count >= 128, p[64...66].allSatisfy({ $0 == 0 }), p[67] <= 3 else { return nil }
        let id = Array(p[84..<100])
        if ids.contains(id) { return Array(md5(p)) == id ? p[67] : nil }
        guard id.allSatisfy({ $0 == 0 }), let length = UInt32(exactly: p.count) else { return nil }
        return withoutID.contains([PNGChunks.crc32(profile), length]) ? p[67] : nil
    }

    /// The profile ID after ICC.1: the MD5 of the profile with the flags,
    /// the rendering intent and the ID itself set to zero.
    private static func md5(_ profile: [UInt8]) -> Insecure.MD5Digest {
        var p = profile
        for range in [44..<48, 64..<68, 84..<100] { p.replaceSubrange(range, with: repeatElement(0, count: range.count)) }
        return Insecure.MD5.hash(data: p)
    }
}
