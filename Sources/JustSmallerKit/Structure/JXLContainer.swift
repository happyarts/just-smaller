import Compression
import Foundation

/// JPEG XL files (ISO/IEC 18181-2): a bare codestream, or a container of
/// boxes — the codestream in one `jxlc` box or split over `jxlp` boxes,
/// metadata in `Exif`, `xml ` and `jumb` boxes, any of them Brotli-compressed
/// inside a `brob` box, and the data to rebuild a JPEG it was made from in a
/// `jbrd` box. Reads through `BMFFBoxes`, strictly: a container that breaks
/// the specification's rules is rejected.
enum JXLContainer {
    /// The signature box every container starts with.
    static let signature: [UInt8] = [0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
    /// A bare codestream starts with this.
    static let codestreamSignature: [UInt8] = [0xFF, 0x0A]

    static func isJXL(_ b: ByteView) -> Bool { b.has(signature) || b.has(codestreamSignature) }

    struct File {
        /// The top-level boxes; empty for a bare codestream.
        let boxes: [BMFFBoxes.Box]
        /// The data to rebuild the JPEG the file was made from.
        let hasReconstructionData: Bool
        /// EXIF (the TIFF structure, without the box's offset field) and XMP,
        /// unpacked from `brob` where they were compressed.
        let exif: [Data]
        let xmp: [Data]
        /// JUMBF boxes, unpacked; C2PA manifests live in one labelled "c2pa".
        let jumbf: [Data]
    }

    /// Unpacked metadata is never larger than this.
    static let metadataLimit = 64 << 20

    static func read(_ b: ByteView) throws -> File {
        if b.has(codestreamSignature) {
            return File(boxes: [], hasReconstructionData: false, exif: [], xmp: [], jumbf: [])
        }
        guard b.has(signature) else { throw FormatError("JPEG XL signature") }
        let boxes = try BMFFBoxes.boxes(b, topLevel: true)
        guard boxes.count >= 3, boxes[1].type == "ftyp" else { throw FormatError("JPEG XL ftyp") }
        let ftyp = boxes[1].payload
        guard ftyp.count >= 8, ftyp.count % 4 == 0, ftyp.has("jxl ") else { throw FormatError("JPEG XL brand") }
        // A size of 0 ("to the end of the file") only for the last box.
        guard boxes.dropLast().allSatisfy({ $0.size > 0 }) else { throw FormatError("box size") }

        var exif: [Data] = [], xmp: [Data] = [], jumbf: [Data] = []
        var partial: [Int] = [], whole = 0, reconstruction = 0, level = 0, codestreamSeen = false
        for box in boxes.dropFirst(2) {
            var type = box.type, payload = box.payload.bytes
            if type == "brob" {
                guard box.payload.count >= 4 else { throw FormatError("brob box") }
                type = String(decoding: try box.payload.view(0, 4).bytes, as: UTF8.self)
                // Codestream, reconstruction data and nested brob boxes are never compressed.
                guard !type.hasPrefix("jxl"), type != "jbrd", type != "brob" else { throw FormatError("\(type) in brob") }
                payload = try brotli(box.payload.view(from: 4).bytes)
            }
            switch type {
            case "JXL ", "ftyp": throw FormatError("second \(type) box")
            case "jxll":
                // The level comes before the codestream, once.
                level += 1
                guard level == 1, !codestreamSeen, payload.count == 1 else { throw FormatError("jxll box") }
            case "jxlc":
                whole += 1
                codestreamSeen = true
            case "jxlp":
                // Numbered from 0; the last one has the top bit set.
                guard payload.count >= 4 else { throw FormatError("jxlp box") }
                partial.append(try ByteView(payload).be(0, 4))
                codestreamSeen = true
            case "jbrd":
                reconstruction += 1
            case "Exif":
                guard payload.count >= 4 else { throw FormatError("Exif box") }
                let offset = try ByteView(payload).be(0, 4)
                guard offset <= payload.count - 4 else { throw FormatError("Exif offset") }
                exif.append(payload.dropFirst(4 + offset))
            case "xml ": xmp.append(payload)
            case "jumb": jumbf.append(payload)
            default: break // other boxes are ignored, as the specification says
            }
        }
        guard reconstruction <= 1 else { throw FormatError("second jbrd box") }
        if whole > 0 {
            guard whole == 1, partial.isEmpty else { throw FormatError("codestream boxes") }
        } else {
            let numbers = partial.map { $0 & 0x7FFF_FFFF }
            guard !partial.isEmpty, numbers == Array(numbers.indices),
                  partial.dropLast().allSatisfy({ $0 & 0x8000_0000 == 0 }), partial.last! & 0x8000_0000 != 0
            else { throw FormatError("codestream boxes") }
        }
        return File(boxes: boxes, hasReconstructionData: reconstruction == 1, exif: exif, xmp: xmp, jumbf: jumbf)
    }

    /// A complete Brotli stream, unpacked; at most `metadataLimit` bytes.
    static func brotli(_ data: Data) throws -> Data {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI) == COMPRESSION_STATUS_OK else {
            throw FormatError("Brotli")
        }
        defer { compression_stream_destroy(&stream) }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        let status = data.withUnsafeBytes { input -> compression_status in
            stream.src_ptr = input.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(bitPattern: 1)!
            stream.src_size = input.count
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { output -> compression_status in
                    stream.dst_ptr = output.baseAddress!
                    stream.dst_size = output.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                out.append(contentsOf: buffer[0..<(buffer.count - stream.dst_size)])
                if status != COMPRESSION_STATUS_OK || out.count > metadataLimit { return status }
                // OK with no progress: the stream is cut short.
                if stream.dst_size == buffer.count, stream.src_size == 0 { return COMPRESSION_STATUS_ERROR }
            }
        }
        guard status == COMPRESSION_STATUS_END, out.count <= metadataLimit, stream.src_size == 0 else { throw FormatError("Brotli") }
        return out
    }
}
