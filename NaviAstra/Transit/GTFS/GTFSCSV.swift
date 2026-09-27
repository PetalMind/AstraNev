import Foundation

nonisolated enum GTFSCSV {
    private static let optionalFilenames: Set<String> = [
        "agency.txt", "attributions.txt", "calendar.txt", "calendar_dates.txt", "feed_info.txt", "frequencies.txt",
        "shapes.txt", "transfers.txt", "pathways.txt"
    ]

    static func rows(named filename: String, in files: [String: Data],
                     prefix: String = "", namespacedColumns: [String] = []) throws -> [[String: String]] {
        guard let data = files[filename] else {
            if optionalFilenames.contains(filename) { return [] }
            throw TransitRoutingError.invalidResponse
        }
        return try rows(named: filename, data: data, prefix: prefix,
                        namespacedColumns: namespacedColumns)
    }

    static func rows(named filename: String, in archive: GTFSZipArchive.Reader,
                     prefix: String = "", namespacedColumns: [String] = []) throws -> [[String: String]] {
        guard let data = try archive.file(named: filename) else {
            if optionalFilenames.contains(filename) { return [] }
            throw TransitRoutingError.invalidResponse
        }
        return try rows(named: filename, data: data, prefix: prefix,
                        namespacedColumns: namespacedColumns)
    }

    static func rows(named filename: String, data: Data,
                     prefix: String = "", namespacedColumns: [String] = []) throws -> [[String: String]] {
        var parsedRows: [[String: String]] = []
        try forEachRow(named: filename, data: data, prefix: prefix,
                       namespacedColumns: namespacedColumns) { parsedRows.append($0) }
        return parsedRows
    }

    static func forEachRow(named filename: String, in archive: GTFSZipArchive.Reader,
                           prefix: String = "", namespacedColumns: [String] = [],
                           body: ([String: String]) throws -> Void) throws {
        guard let data = try archive.file(named: filename) else {
            if optionalFilenames.contains(filename) { return }
            throw TransitRoutingError.invalidResponse
        }
        try forEachRow(named: filename, data: data, prefix: prefix,
                       namespacedColumns: namespacedColumns, body: body)
    }

    static func forEachRow(named filename: String, data: Data,
                           prefix: String = "", namespacedColumns: [String] = [],
                           body: ([String: String]) throws -> Void) throws {
        let namespacedColumnSet = Set(namespacedColumns)
        var header: [String]?
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var parseError: Error?
        func finishField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        func finishRow() throws {
            finishField()
            guard !row.allSatisfy(\.isEmpty) else {
                row.removeAll(keepingCapacity: true)
                return
            }
            guard let columns = header else {
                var parsedHeader = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !parsedHeader.isEmpty else {
                    row.removeAll(keepingCapacity: true)
                    return
                }
                parsedHeader[0] = parsedHeader[0].replacingOccurrences(of: "\u{feff}", with: "")
                header = parsedHeader
                row.removeAll(keepingCapacity: true)
                return
            }
            var values: [String: String] = [:]
            values.reserveCapacity(columns.count)
            for (columnIndex, column) in columns.enumerated() {
                let rawValue = row.indices.contains(columnIndex) ? row[columnIndex] : ""
                values[column] = !prefix.isEmpty && namespacedColumnSet.contains(column) && !rawValue.isEmpty
                    ? prefix + rawValue : rawValue
            }
            try body(values)
            row.removeAll(keepingCapacity: true)
        }

        data.withUnsafeBytes { bytes in
            var index = 0
            while index < bytes.count {
                if parseError != nil { break }
                let byte = bytes[index]
                if byte == 34 {
                    if quoted, index + 1 < bytes.count, bytes[index + 1] == 34 {
                        field.append(34)
                        index += 2
                        continue
                    }
                    quoted.toggle()
                } else if byte == 44, !quoted {
                    finishField()
                } else if (byte == 10 || byte == 13), !quoted {
                    if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                    do {
                        try finishRow()
                    } catch {
                        parseError = error
                    }
                } else {
                    field.append(byte)
                }
                index += 1
            }
        }
        if let parseError { throw parseError }
        if !field.isEmpty || !row.isEmpty { try finishRow() }
        guard let header, !header.isEmpty else { throw TransitRoutingError.invalidResponse }
    }

    static func serviceSeconds(_ value: String) -> Int? {
        var parts = [Int](repeating: 0, count: 3)
        var partIndex = 0
        var magnitude = 0
        var digitCount = 0
        var sign = 1
        var canReadSign = true

        for byte in value.utf8 {
            if byte == 58 {
                guard partIndex < 2, digitCount > 0 else { return nil }
                parts[partIndex] = magnitude * sign
                partIndex += 1
                magnitude = 0
                digitCount = 0
                sign = 1
                canReadSign = true
                continue
            }
            if canReadSign && (byte == 43 || byte == 45) {
                sign = byte == 45 ? -1 : 1
                canReadSign = false
                continue
            }
            guard (48...57).contains(byte) else { return nil }
            canReadSign = false
            let (scaled, multiplyOverflow) = magnitude.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = scaled.addingReportingOverflow(Int(byte - 48))
            guard !multiplyOverflow, !addOverflow else { return nil }
            magnitude = next
            digitCount += 1
        }

        guard partIndex == 2, digitCount > 0 else { return nil }
        parts[partIndex] = magnitude * sign
        let hours = parts[0]
        let minutes = parts[1]
        let seconds = parts[2]
        guard hours >= 0, (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        let (hourSeconds, hourOverflow) = hours.multipliedReportingOverflow(by: 3_600)
        let (minuteSeconds, minuteOverflow) = minutes.multipliedReportingOverflow(by: 60)
        let (withMinutes, additionOverflow) = hourSeconds.addingReportingOverflow(minuteSeconds)
        let (total, secondsOverflow) = withMinutes.addingReportingOverflow(seconds)
        guard !hourOverflow, !minuteOverflow, !additionOverflow, !secondsOverflow else { return nil }
        return total
    }

    static func serviceTimeString(_ seconds: Int) -> String {
        let total = max(0, seconds)
        return String(format: "%02d:%02d:%02d", total / 3_600,
                      (total % 3_600) / 60, total % 60)
    }
}
