import Foundation

nonisolated enum OfflineRoutingFailure: LocalizedError {
    case missingPack, unsupportedProfile, invalidArchive, incompleteCoverage(String)
    var errorDescription: String? {
        switch self {
        case .missingPack:
            return "Brak aktywnych danych drogowych offline. W Mapach offline pobierz lub zaimportuj paczkę trasowania dla tego regionu. Sama pobrana mapa nie zawiera danych do wyznaczania tras."
        case .unsupportedProfile:
            return "Aktywna paczka drogowa obsługuje tylko pojazdy silnikowe. Dla trasy pieszej lub rowerowej wybierz paczkę zawierającą te profile albo połącz się z internetem."
        case .invalidArchive:
            return "Plik nie jest kompletnym archiwum .tar z danymi drogowymi Valhalla. Kafle mapy, pliki OSM/PBF i archiwa skompresowane nie mogą służyć jako paczka trasowania."
        case .incompleteCoverage(let reason):
            return "Nie udało się wyznaczyć trasy w aktywnej paczce offline. Sprawdź, czy obejmuje całą trasę i obsługuje wybrany profil. Szczegóły: \(reason)"
        }
    }
}

nonisolated enum OfflineRoutingArchive {
    /// Validate TAR checksums and entry boundaries before passing an mmap archive to native code.
    static func validate(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length >= 1_024, length % 512 == 0 else { throw OfflineRoutingFailure.invalidArchive }
        var offset: UInt64 = 0
        var graphCount = 0
        while offset + 512 <= length {
            try Task.checkCancellation()
            try file.seek(toOffset: offset)
            let header = Array(try file.read(upToCount: 512) ?? Data())
            guard header.count == 512 else { throw OfflineRoutingFailure.invalidArchive }
            if header.allSatisfy({ $0 == 0 }) { break }
            func octal(_ range: Range<Int>) -> UInt64? {
                let value = String(bytes: header[range], encoding: .ascii)?
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                return value.flatMap { UInt64($0, radix: 8) }
            }
            guard let size = octal(124..<136), let checksum = octal(148..<156) else {
                throw OfflineRoutingFailure.invalidArchive
            }
            let actualChecksum = header.enumerated().reduce(UInt64(0)) { result, entry in
                result + ((148..<156).contains(entry.offset) ? 32 : UInt64(entry.element))
            }
            guard actualChecksum == checksum, size <= length - offset - 512 else {
                throw OfflineRoutingFailure.invalidArchive
            }
            let name = String(bytes: header[0..<100].prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            if (header[156] == 0 || header[156] == 48), name.hasSuffix(".gph"), size >= 64 {
                graphCount += 1
            }
            let padded = ((size + 511) / 512) * 512
            guard padded <= length - offset - 512 else { throw OfflineRoutingFailure.invalidArchive }
            offset += 512 + padded
        }
        guard graphCount > 0 else { throw OfflineRoutingFailure.invalidArchive }
    }
}
