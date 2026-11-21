import Foundation
import ImageIO
import zlib

enum PackedSegment {
    static let referer = "https://frame.embedme.cfd/"
    private static let signature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    private static let marker = Array("TIKTIKPX".utf8)
    private static let maxPixels = 4 * 1024 * 1024
    private static let maxOutput = 32 * 1024 * 1024

    /// Some feeds wrap ordinary MPEG transport streams in PNG files.
    static func unpack(_ data: Data) -> Data {
        guard data.starts(with: signature), data.count >= 33 else { return data }
        let width = Int(int32(data, at: 16)), height = Int(int32(data, at: 20))
        guard width > 0, height > 0, width <= maxPixels / height else { return data }

        var offset = 8
        while data.count - offset >= 12 {
            let length = Int(int32(data, at: offset))
            guard length <= data.count - offset - 12 else { return data }
            let kind = int32(data, at: offset + 4)
            offset += length + 12
            if kind == 0x49454e44 { // IEND
                if isTransportStream(data, at: offset) { return data.subdata(in: offset..<data.count) }
                break
            }
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.bitsPerComponent == 8,
              image.width == width, image.height == height,
              image.bitsPerPixel == 24 || (image.bitsPerPixel == 32 && image.alphaInfo == .noneSkipLast),
              let bitmap = image.dataProvider?.data else { return data }
        let channels = image.bitsPerPixel / 8
        let rowLength = image.bytesPerRow
        guard let pixels = CFDataGetBytePtr(bitmap),
              rowLength >= width * channels, rowLength <= CFDataGetLength(bitmap) / height else { return data }
        let count = width * height * 3
        guard count >= 12 else { return data }
        func component(_ index: Int) -> UInt8 {
            let pixel = index / 3
            return pixels[(pixel / width) * rowLength + (pixel % width) * channels + index % 3]
        }
        for (index, value) in marker.enumerated() where component(index) != value { return data }
        let length = (8..<12).reduce(0) { ($0 << 8) | Int(component($1)) }
        guard length >= 2, length <= count - 12 else { return data }
        var gzip = Data(count: length)
        gzip.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let buffer = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for row in 0..<height {
                let begin = max(12, row * width * 3)
                let end = min(12 + length, (row + 1) * width * 3)
                guard begin < end else { continue }
                let line = pixels + row * rowLength
                if channels == 3 {
                    (buffer + begin - 12).update(from: line + begin - row * width * 3, count: end - begin)
                } else {
                    for index in begin..<end {
                        let x = index - row * width * 3
                        buffer[index - 12] = line[(x / 3) * channels + x % 3]
                    }
                }
            }
        }
        guard let result = gunzip(&gzip), isTransportStream(result, at: 0) else { return data }
        return result
    }

    private static func int32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func isTransportStream(_ data: Data, at offset: Int) -> Bool {
        offset + 188 < data.count && data[offset] == 0x47 && data[offset + 188] == 0x47
    }

    private static func gunzip(_ input: inout Data) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        return input.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Data? in
            stream.next_in = raw.bindMemory(to: UInt8.self).baseAddress
            stream.avail_in = UInt32(raw.count)
            var status: Int32
            repeat {
                status = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let decoded = chunkSize - Int(stream.avail_out)
                guard output.count + decoded <= maxOutput else { return nil }
                output.append(contentsOf: chunk.prefix(decoded))
            } while status == Z_OK
            return status == Z_STREAM_END ? output : nil
        }
    }
}
