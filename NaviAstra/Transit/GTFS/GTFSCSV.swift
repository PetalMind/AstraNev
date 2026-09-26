import Foundation

nonisolated enum GTFSCSV {
    static func rows(named filename: String, in files: [String: Data]) throws -> [[String: String]] {
        guard let data = files[filename] else {
            if ["agency.txt", "attributions.txt", "calendar.txt", "calendar_dates.txt", "feed_info.txt",
                "shapes.txt", "transfers.txt", "pathways.txt"].contains(filename) { return [] }
            throw TransitRoutingError.invalidResponse
        }
        var rawRows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var index = 0
        while index < data.count {
            let byte = data[index]
            if byte == 34 {
                if quoted, index + 1 < data.count, data[index + 1] == 34 {
                    field.append(34)
                    index += 2
                    continue
                }
                quoted.toggle()
            } else if byte == 44, !quoted {
                row.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
            } else if (byte == 10 || byte == 13), !quoted {
                if byte == 13, index + 1 < data.count, data[index + 1] == 10 { index += 1 }
                row.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
                if !row.allSatisfy(\.isEmpty) { rawRows.append(row) }
                row.removeAll(keepingCapacity: true)
            } else {
                field.append(byte)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(String(decoding: field, as: UTF8.self))
            if !row.allSatisfy(\.isEmpty) { rawRows.append(row) }
        }
        guard var header = rawRows.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              !header.isEmpty else { throw TransitRoutingError.invalidResponse }
        header[0] = header[0].replacingOccurrences(of: "\u{feff}", with: "")
        return rawRows.dropFirst().map { values in
            Dictionary(uniqueKeysWithValues: header.enumerated().map { index, key in
                (key, values.indices.contains(index) ? values[index] : "")
            })
        }
    }

    static func serviceSeconds(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 3, let hours = Int(parts[0]),
              let minutes = Int(parts[1]), let seconds = Int(parts[2]),
              hours >= 0, (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }
}
