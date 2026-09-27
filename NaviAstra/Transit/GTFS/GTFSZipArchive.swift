import Foundation
import zlib

nonisolated enum GTFSZipArchive {
    nonisolated struct Entry: Sendable {
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    nonisolated struct Reader: Sendable {
        let archive: Data
        let entries: [String: Entry]

        func file(named name: String) throws -> Data? {
            guard let entry = entries[name] else { return nil }
            let localOffset = entry.localOffset
            guard archive.count >= 30, localOffset >= 0, localOffset <= archive.count - 30,
                  GTFSZipArchive.littleUInt32(archive, localOffset) == 0x04034b50 else {
                throw TransitRoutingError.invalidResponse
            }
            let dataStart = localOffset + 30
                + Int(GTFSZipArchive.littleUInt16(archive, localOffset + 26))
                + Int(GTFSZipArchive.littleUInt16(archive, localOffset + 28))
            guard dataStart >= 0, dataStart <= archive.count,
                  entry.compressedSize <= archive.count - dataStart else {
                throw TransitRoutingError.invalidResponse
            }
            let compressed = archive[dataStart..<(dataStart + entry.compressedSize)]
            switch entry.method {
            case 0:
                return compressed
            case 8:
                return try GTFSZipArchive.inflateRaw(compressed, expectedSize: entry.uncompressedSize)
            default:
                return nil
            }
        }
    }

    static func open(_ archive: Data) throws -> Reader {
        guard archive.count >= 22 else { throw TransitRoutingError.invalidResponse }
        let searchStart = max(0, archive.count - 65_557)
        var endRecord: Int?
        for offset in stride(from: archive.count - 22, through: searchStart, by: -1) {
            if littleUInt32(archive, offset) == 0x06054b50 {
                endRecord = offset
                break
            }
        }
        guard let endRecord else { throw TransitRoutingError.invalidResponse }
        let entryCount = Int(littleUInt16(archive, endRecord + 10))
        var cursor = Int(littleUInt32(archive, endRecord + 16))
        guard cursor >= 0, cursor < archive.count else { throw TransitRoutingError.invalidResponse }
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard archive.count >= 46, cursor >= 0, cursor <= archive.count - 46,
                  littleUInt32(archive, cursor) == 0x02014b50 else {
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
            let nextEntry = nameEnd + extraLength + commentLength
            guard nameEnd <= archive.count, nextEntry >= nameEnd, nextEntry <= archive.count else {
                throw TransitRoutingError.invalidResponse
            }
            let name = String(decoding: archive[nameStart..<nameEnd], as: UTF8.self)
            if !name.hasSuffix("/") {
                entries[name] = Entry(method: method, compressedSize: compressedSize,
                                      uncompressedSize: uncompressedSize, localOffset: localOffset)
            }
            cursor = nextEntry
        }
        return Reader(archive: archive, entries: entries)
    }

    static func extract(_ archive: Data) throws -> [String: Data] {
        let reader = try open(archive)
        var files: [String: Data] = [:]
        files.reserveCapacity(reader.entries.count)
        for name in reader.entries.keys {
            if let file = try reader.file(named: name) { files[name] = file }
        }
        return files
    }

    private static func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0, expectedSize <= 150_000_000 else {
            throw TransitRoutingError.invalidResponse
        }
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
        return expectedSize == 0 ? Data() : output
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
