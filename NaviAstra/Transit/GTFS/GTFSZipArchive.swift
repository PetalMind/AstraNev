import Foundation
import zlib

nonisolated enum GTFSZipArchive {
    static func extract(_ archive: Data) throws -> [String: Data] {
        guard archive.count >= 22 else { throw TransitRoutingError.invalidResponse }
        let searchStart = max(0, archive.count - 65_557)
        var endRecord: Int?
        if archive.count >= 22 {
            for offset in stride(from: archive.count - 22, through: searchStart, by: -1) {
                if littleUInt32(archive, offset) == 0x06054b50 {
                    endRecord = offset
                    break
                }
            }
        }
        guard let endRecord else { throw TransitRoutingError.invalidResponse }
        let entryCount = Int(littleUInt16(archive, endRecord + 10))
        var cursor = Int(littleUInt32(archive, endRecord + 16))
        guard cursor >= 0, cursor < archive.count else { throw TransitRoutingError.invalidResponse }
        var files: [String: Data] = [:]
        for _ in 0..<entryCount {
            guard cursor + 46 <= archive.count, littleUInt32(archive, cursor) == 0x02014b50 else {
                throw TransitRoutingError.invalidResponse
            }
            let method = littleUInt16(archive, cursor + 10)
            let compressedSize = Int(littleUInt32(archive, cursor + 20))
            let uncompressedSize = Int(littleUInt32(archive, cursor + 24))
            let nameLength = Int(littleUInt16(archive, cursor + 28))
            let extraLength = Int(littleUInt16(archive, cursor + 30))
            let commentLength = Int(littleUInt16(archive, cursor + 32))
            let localOffset = Int(littleUInt32(archive, cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= archive.count, localOffset + 30 <= archive.count,
                  littleUInt32(archive, localOffset) == 0x04034b50 else {
                throw TransitRoutingError.invalidResponse
            }
            let name = String(decoding: archive[nameStart..<nameEnd], as: UTF8.self)
            let dataStart = localOffset + 30
                + Int(littleUInt16(archive, localOffset + 26))
                + Int(littleUInt16(archive, localOffset + 28))
            let dataEnd = dataStart + compressedSize
            guard dataStart >= 0, dataEnd <= archive.count else { throw TransitRoutingError.invalidResponse }
            if !name.hasSuffix("/") {
                let compressed = Data(archive[dataStart..<dataEnd])
                let payload: Data
                switch method {
                case 0:
                    payload = compressed
                case 8:
                    payload = try inflateRaw(compressed, expectedSize: uncompressedSize)
                default:
                    cursor = nameEnd + extraLength + commentLength
                    continue
                }
                files[name] = payload
            }
            cursor = nameEnd + extraLength + commentLength
        }
        return files
    }

    private static func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0, expectedSize <= 150_000_000 else { throw TransitRoutingError.invalidResponse }
        var output = Data(count: max(1, expectedSize))
        let outputCapacity = output.count
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw TransitRoutingError.invalidResponse }
        defer { inflateEnd(&stream) }

        let status = compressed.withUnsafeBytes { sourceBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                stream.next_in = UnsafeMutablePointer(mutating: sourceBuffer.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCapacity)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize else {
            throw TransitRoutingError.invalidResponse
        }
        return Data(output.prefix(expectedSize))
    }

    private static func littleUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
