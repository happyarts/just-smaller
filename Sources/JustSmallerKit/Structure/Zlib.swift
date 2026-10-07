import Foundation
import zlib

/// The one way the engine inflates zlib data (PNG image data, text and
/// profiles): the stream checked by zlib (header, Adler-32), and never more
/// output than asked for. Deflating is for the small chunks the metadata
/// filter writes again.
enum Zlib {
    /// `data` as one zlib stream at the highest level.
    static func deflate(_ data: Data) -> Data? {
        var size = uLongf(compressBound(uLong(data.count)))
        var out = [UInt8](repeating: 0, count: Int(size))
        let status = data.withUnsafeBytes {
            compress2(&out, &size, $0.bindMemory(to: UInt8.self).baseAddress, uLong(data.count), Z_BEST_COMPRESSION)
        }
        return status == Z_OK ? Data(out.prefix(Int(size))) : nil
    }

    /// One complete stream over `pieces`, inflated; at most `limit` bytes.
    static func inflate(_ pieces: [Data], limit: Int = 64 << 20) throws -> Data {
        var out = Data()
        guard stream(pieces, sink: { piece in
            out.append(contentsOf: piece)
            return out.count <= limit
        }) else { throw FormatError("compressed data") }
        return out
    }

    /// Runs zlib over the pieces in turn, handing each inflated piece to
    /// `sink` (which may stop it). True if the stream ended exactly at the
    /// end of the last piece.
    static func stream(_ pieces: [Data], sink: (ArraySlice<UInt8>) -> Bool) -> Bool {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return false }
        defer { inflateEnd(&stream) }
        var buffer = [UInt8](repeating: 0, count: 256 << 10)
        var ended = false
        /// One inflate call; false on an error or when the sink stops.
        func step() -> Bool {
            let status = buffer.withUnsafeMutableBufferPointer { out in
                stream.next_out = out.baseAddress
                stream.avail_out = uInt(out.count)
                return zlib.inflate(&stream, Z_NO_FLUSH)
            }
            let produced = buffer.count - Int(stream.avail_out)
            guard sink(buffer[0..<produced]) else { return false }
            if status == Z_STREAM_END { ended = true; return true }
            return status == Z_OK && (produced > 0 || stream.avail_in > 0)
        }
        for piece in pieces where !piece.isEmpty {
            guard !ended else { return false } // data after the end of the stream
            let ok = piece.withUnsafeBytes { input -> Bool in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                while stream.avail_in > 0, !ended {
                    guard step() else { return false }
                }
                return stream.avail_in == 0
            }
            guard ok else { return false }
        }
        // Output still inside zlib once all input is in.
        while !ended {
            guard step() else { return false }
        }
        return true
    }
}
