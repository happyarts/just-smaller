// imgcmp — decides whether two images look the same, using Apple's ImageIO.
//
// usage: imgcmp [--tolerance N] ORIGINAL RESULT
// exit 0: same, 1: different, 2: unreadable
//
// Every frame is decoded to 8-bit RGBA in sRGB. Fully transparent pixels count
// as equal whatever colour sits under them. Animations are compared along their
// timeline rather than frame by frame, because optimizers legitimately merge
// identical consecutive frames and add up their delays.
//
// --tolerance N allows each channel to differ by up to N, for comparing
// rasterized vector images where antialiasing may shift by a step.

import Foundation
import ImageIO
import CoreGraphics

var args = Array(CommandLine.arguments.dropFirst())
var tolerance = 0
if args.first == "--tolerance", args.count >= 2, let t = Int(args[1]) {
    tolerance = t
    args.removeFirst(2)
}
guard args.count == 2 else {
    FileHandle.standardError.write("usage: imgcmp [--tolerance N] ORIGINAL RESULT\n".data(using: .utf8)!)
    exit(2)
}

/// Decodes every frame of an image to 8-bit premultiplied-last RGBA in sRGB,
/// with fully transparent pixels zeroed so invisible colour doesn't count.
func frames(_ path: String) -> [(w: Int, h: Int, px: [UInt8], cs: Int)]? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let n = CGImageSourceGetCount(src)
    var out: [(Int, Int, [UInt8], Int)] = []
    for i in 0..<n {
        guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { return nil }
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Animation delay in centiseconds, from whichever container this is.
        var delay = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary] {
                if let d = props[key] as? [CFString: Any] {
                    let t = (d[kCGImagePropertyGIFUnclampedDelayTime] ?? d[kCGImagePropertyGIFDelayTime]
                             ?? d[kCGImagePropertyAPNGUnclampedDelayTime] ?? d[kCGImagePropertyAPNGDelayTime]
                             ?? d[kCGImagePropertyWebPUnclampedDelayTime] ?? d[kCGImagePropertyWebPDelayTime]) as? Double ?? 0
                    delay = Int((t * 100).rounded())
                }
            }
        }
        out.append((w, h, buf, delay))
    }
    return out
}

func timeline(_ f: [(w: Int, h: Int, px: [UInt8], cs: Int)]) -> [(from: Int, to: Int, idx: Int)] {
    var t = 0, out: [(Int, Int, Int)] = []
    for (i, fr) in f.enumerated() { let d = max(fr.cs, 1); out.append((t, t + d, i)); t += d }
    return out
}
func same(_ x: [UInt8], _ y: [UInt8]) -> (Int, Int) {
    var bad = 0, mx = 0
    for i in stride(from: 0, to: x.count, by: 4) {
        var d = 0
        for c in 0..<4 { d = max(d, abs(Int(x[i+c]) - Int(y[i+c]))) }
        if d > tolerance { bad += 1; mx = max(mx, d) }
    }
    return (bad, mx)
}
guard let a = frames(args[0]), let b = frames(args[1]), !a.isEmpty, !b.isEmpty else {
    print("ERROR: unreadable"); exit(2)
}
if a.first!.w != b.first!.w || a.first!.h != b.first!.h {
    print("DIFFERENT: size \(a.first!.w)x\(a.first!.h) vs \(b.first!.w)x\(b.first!.h)"); exit(1)
}
// The display orientation lives in EXIF, not in the pixels: losing it turns photos sideways.
func orientation(_ path: String) -> Int {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 1 }
    return props[kCGImagePropertyOrientation] as? Int ?? 1
}
if orientation(args[0]) != orientation(args[1]) {
    print("DIFFERENT: orientation \(orientation(args[0])) vs \(orientation(args[1]))"); exit(1)
}
// An HDR photo's gain map and other auxiliary images, and how bright it is
// shown, come from data next to the pixels: losing it changes the photo.
func hdr(_ path: String) -> String {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return "" }
    let types = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeDepth,
                 kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte]
    let aux = types.filter { CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, $0) != nil }
    let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)
    return "\(aux.count) auxiliary images, headroom \(image?.contentHeadroom ?? 0)"
}
if hdr(args[0]) != hdr(args[1]) {
    print("DIFFERENT: HDR \(hdr(args[0])) vs \(hdr(args[1]))"); exit(1)
}
let ta = timeline(a), tb = timeline(b)
let durA = ta.last!.to, durB = tb.last!.to
if a.count > 1 && durA != durB { print("DIFFERENT: duration \(durA) vs \(durB) cs"); exit(1) }
// Walk both timelines segment by segment and compare what is on screen.
var i = 0, j = 0, badSpans = 0, badPx = 0, maxDiff = 0, spans = 0
var cache: [String: (Int, Int)] = [:]
while i < ta.count && j < tb.count {
    let key = "\(ta[i].idx):\(tb[j].idx)"
    let r = cache[key] ?? same(a[ta[i].idx].px, b[tb[j].idx].px); cache[key] = r
    spans += 1
    if r.0 > 0 { badSpans += 1; badPx = max(badPx, r.0); maxDiff = max(maxDiff, r.1) }
    if ta[i].to < tb[j].to { i += 1 } else if tb[j].to < ta[i].to { j += 1 } else { i += 1; j += 1 }
}
let label = a.count == 1 ? "1 Frame" : "\(a.count)→\(b.count) Frames, \(durA) cs"
if badSpans == 0 { print("identical (\(label))"); exit(0) }
print("DIFFERENT: \(badSpans)/\(spans) time spans, up to \(badPx) pixels, max. difference \(maxDiff) (\(label))"); exit(1)
