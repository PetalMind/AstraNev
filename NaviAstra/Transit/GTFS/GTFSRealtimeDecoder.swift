import Foundation

nonisolated struct GTFSRealtimeSnapshot {
    let updates: [String: [String: [String: GTFSStopTimeUpdate]]]
    let canceledTrips: Set<String>
    let updatedAt: Date?
    let isAvailable: Bool
    let alertsAvailable: Bool
    let alerts: [GTFSAlert]
    let freshness: TransitRealtimeFreshness
    let sourceFreshness: [String: TransitRealtimeFreshness]
    let sourceUpdatedAt: [String: Date]

    static let empty = GTFSRealtimeSnapshot(updates: [:], canceledTrips: [], updatedAt: nil,
                                             isAvailable: false, alertsAvailable: false, alerts: [],
                                             freshness: .unavailable,
                                             sourceFreshness: ["lodz": .unavailable, "rail": .unavailable],
                                             sourceUpdatedAt: [:])

    func update(tripID: String, serviceDate: String, stopID: String,
                stopSequence: Int? = nil) -> GTFSStopTimeUpdate? {
        let datedUpdates = updates[tripID]?[serviceDate]
        if let update = datedUpdates?[stopID] { return update }
        if let stopSequence, let update = datedUpdates?["sequence:\(stopSequence)"] { return update }
        let undatedUpdates = updates[tripID]?[""]
        return undatedUpdates?[stopID]
            ?? stopSequence.flatMap { undatedUpdates?["sequence:\($0)"] }
    }

    func isCanceled(tripID: String, serviceDate: String) -> Bool {
        canceledTrips.contains("\(tripID)|\(serviceDate)") || canceledTrips.contains("\(tripID)|")
    }

    static func tripUpdates(from data: Data, prefix: String = "") throws -> GTFSRealtimeSnapshot {
        var reader = ProtoReader(data: data)
        var updates: [String: [String: [String: GTFSStopTimeUpdate]]] = [:]
        var canceled: Set<String> = []
        var timestamp: Date?
        while let field = try reader.next() {
            switch (field.number, field.bytes, field.varint) {
            case (1, let bytes?, _):
                timestamp = try parseHeader(bytes)
            case (2, let bytes?, _):
                guard let entity = try parseTripUpdateEntity(bytes) else { continue }
                let dateKey = entity.serviceDate ?? ""
                if entity.canceled {
                    canceled.insert("\(prefix)\(entity.tripID)|\(dateKey)")
                } else {
                    for (stopID, update) in entity.stopUpdates {
                        let namespacedStopID = stopID.hasPrefix("sequence:") ? stopID : prefix + stopID
                        updates[prefix + entity.tripID, default: [:]][dateKey, default: [:]][namespacedStopID] = update
                    }
                }
            default:
                continue
            }
        }
        return GTFSRealtimeSnapshot(updates: updates, canceledTrips: canceled,
                                    updatedAt: timestamp, isAvailable: true,
                                    alertsAvailable: false, alerts: [], freshness: .unavailable,
                                    sourceFreshness: [:], sourceUpdatedAt: [:])
    }

    static func alerts(from data: Data) throws -> (alerts: [GTFSAlert], updatedAt: Date?) {
        var reader = ProtoReader(data: data)
        var result: [GTFSAlert] = []
        var timestamp: Date?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                timestamp = try parseHeader(bytes)
            } else if field.number == 2, let bytes = field.bytes,
                      let alert = try parseAlertEntity(bytes), alert.isActive(at: Date()) {
                result.append(alert)
            }
        }
        return (result, timestamp)
    }

    static func vehiclePositions(from data: Data)
        throws -> (vehicles: [GTFSRealtimeVehicle], updatedAt: Date?) {
        var reader = ProtoReader(data: data)
        var vehicles: [GTFSRealtimeVehicle] = []
        var timestamp: Date?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                timestamp = try parseHeader(bytes)
            } else if field.number == 2, let bytes = field.bytes,
                      let vehicle = try parseVehicleEntity(bytes) {
                vehicles.append(vehicle)
            }
        }
        return (vehicles, timestamp)
    }

    private static func parseHeader(_ data: Data) throws -> Date? {
        var reader = ProtoReader(data: data)
        while let field = try reader.next() {
            if field.number == 3, let timestamp = field.varint {
                return Date(timeIntervalSince1970: Double(timestamp))
            }
        }
        return nil
    }

    private static func parseTripUpdateEntity(_ data: Data) throws
        -> (tripID: String, serviceDate: String?, canceled: Bool, stopUpdates: [(String, GTFSStopTimeUpdate)])? {
        var entityReader = ProtoReader(data: data)
        var tripUpdateData: Data?
        while let field = try entityReader.next() {
            if field.number == 3, let bytes = field.bytes {
                tripUpdateData = bytes
                break
            }
        }
        guard let tripUpdateData else { return nil }

        var reader = ProtoReader(data: tripUpdateData)
        var tripID: String?
        var serviceDate: String?
        var relationship: UInt64 = 0
        var stopUpdates: [(String, GTFSStopTimeUpdate)] = []
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                let descriptor = try parseTripDescriptor(bytes)
                tripID = descriptor.tripID
                serviceDate = descriptor.serviceDate
                relationship = descriptor.relationship
            } else if field.number == 2, let bytes = field.bytes,
                      let update = try parseStopTimeUpdate(bytes) {
                stopUpdates.append(update)
            }
        }
        guard let tripID, !tripID.isEmpty else { return nil }
        return (tripID, serviceDate, relationship == 3, stopUpdates)
    }

    private static func parseTripDescriptor(_ data: Data) throws
        -> (tripID: String?, serviceDate: String?, relationship: UInt64, routeID: String?) {
        var reader = ProtoReader(data: data)
        var tripID: String?
        var serviceDate: String?
        var relationship: UInt64 = 0
        var routeID: String?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes { tripID = String(data: bytes, encoding: .utf8) }
            if field.number == 3, let bytes = field.bytes { serviceDate = String(data: bytes, encoding: .utf8) }
            if field.number == 4, let value = field.varint { relationship = value }
            if field.number == 5, let bytes = field.bytes { routeID = String(data: bytes, encoding: .utf8) }
        }
        return (tripID, serviceDate, relationship, routeID)
    }

    private static func parseStopTimeUpdate(_ data: Data) throws -> (String, GTFSStopTimeUpdate)? {
        var reader = ProtoReader(data: data)
        var stopID: String?
        var stopSequence: Int?
        var arrival: GTFSStopTimeEvent?
        var departure: GTFSStopTimeEvent?
        while let field = try reader.next() {
            if field.number == 1, let value = field.varint, value <= UInt64(Int.max) {
                stopSequence = Int(value)
            }
            if field.number == 2, let bytes = field.bytes { arrival = try parseEvent(bytes) }
            if field.number == 3, let bytes = field.bytes { departure = try parseEvent(bytes) }
            if field.number == 4, let bytes = field.bytes { stopID = String(data: bytes, encoding: .utf8) }
        }
        let key = stopID.flatMap { $0.isEmpty ? nil : $0 } ?? stopSequence.map { "sequence:\($0)" }
        guard let key else { return nil }
        return (key, GTFSStopTimeUpdate(arrivalTime: arrival?.time, departureTime: departure?.time,
                                           arrivalDelay: arrival?.delay, departureDelay: departure?.delay))
    }

    private static func parseEvent(_ data: Data) throws -> GTFSStopTimeEvent {
        var reader = ProtoReader(data: data)
        var delay: Int?
        var time: Date?
        while let field = try reader.next() {
            if field.number == 1, let value = field.varint {
                delay = Int(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
            }
            if field.number == 2, let value = field.varint {
                time = Date(timeIntervalSince1970: Double(value))
            }
        }
        return GTFSStopTimeEvent(time: time, delay: delay)
    }

    private static func parseAlertEntity(_ data: Data) throws -> GTFSAlert? {
        var reader = ProtoReader(data: data)
        while let field = try reader.next() {
            guard field.number == 5, let bytes = field.bytes else { continue }
            let alert = try parseAlert(bytes)
            guard !alert.message.isEmpty else { continue }
            return GTFSAlert(message: alert.message, routeIDs: alert.routeIDs,
                             stopIDs: alert.stopIDs, activePeriods: alert.activePeriods)
        }
        return nil
    }

    private static func parseVehicleEntity(_ data: Data) throws -> GTFSRealtimeVehicle? {
        var reader = ProtoReader(data: data)
        var entityID: String?
        var vehicleData: Data?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                entityID = String(data: bytes, encoding: .utf8)
            } else if field.number == 4, let bytes = field.bytes {
                vehicleData = bytes
            }
        }
        guard let vehicleData else { return nil }
        return try parseVehiclePosition(vehicleData, entityID: entityID)
    }

    private static func parseVehiclePosition(_ data: Data, entityID: String?) throws -> GTFSRealtimeVehicle? {
        var reader = ProtoReader(data: data)
        var tripID: String?
        var routeID: String?
        var serviceDate: String?
        var currentStopID: String?
        var currentStopSequence: Int?
        var coordinate: Coordinate?
        var bearing: Double?
        var timestamp: Date?
        var vehicleID: String?
        var label: String?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                let descriptor = try parseTripDescriptor(bytes)
                tripID = descriptor.tripID
                routeID = descriptor.routeID
                serviceDate = descriptor.serviceDate
            } else if field.number == 2, let bytes = field.bytes {
                (coordinate, bearing) = try parsePosition(bytes)
            } else if field.number == 3, let value = field.varint, value <= UInt64(Int.max) {
                currentStopSequence = Int(value)
            } else if field.number == 4, let bytes = field.bytes {
                currentStopID = String(data: bytes, encoding: .utf8)
            } else if field.number == 6, let value = field.varint {
                timestamp = Date(timeIntervalSince1970: Double(value))
            } else if field.number == 8, let bytes = field.bytes {
                (vehicleID, label) = try parseVehicleDescriptor(bytes)
            }
        }
        guard let coordinate else { return nil }
        let id = vehicleID ?? entityID ?? tripID ?? routeID
        guard let id, !id.isEmpty else { return nil }
        return GTFSRealtimeVehicle(id: id, tripID: tripID, routeID: routeID,
                                   serviceDate: serviceDate, currentStopID: currentStopID,
                                   currentStopSequence: currentStopSequence,
                                   coordinate: coordinate, bearing: bearing,
                                   updatedAt: timestamp, label: label)
    }

    private static func parsePosition(_ data: Data) throws -> (Coordinate?, Double?) {
        var reader = ProtoReader(data: data)
        var latitude: Double?
        var longitude: Double?
        var bearing: Double?
        while let field = try reader.next() {
            guard let raw = field.fixed32 else { continue }
            let value = Double(Float(bitPattern: raw))
            if field.number == 1 { latitude = value }
            if field.number == 2 { longitude = value }
            if field.number == 3 { bearing = value }
        }
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            return (nil, nil)
        }
        return (Coordinate(latitude: latitude, longitude: longitude), bearing)
    }

    private static func parseVehicleDescriptor(_ data: Data) throws -> (String?, String?) {
        var reader = ProtoReader(data: data)
        var id: String?
        var label: String?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes { id = String(data: bytes, encoding: .utf8) }
            if field.number == 2, let bytes = field.bytes { label = String(data: bytes, encoding: .utf8) }
        }
        return (id, label)
    }

    private static func parseAlert(_ data: Data) throws
        -> (message: String, routeIDs: Set<String>, stopIDs: Set<String>, activePeriods: [GTFSAlertPeriod]) {
        var reader = ProtoReader(data: data)
        var header = ""
        var description = ""
        var routeIDs: Set<String> = []
        var stopIDs: Set<String> = []
        var activePeriods: [GTFSAlertPeriod] = []
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                activePeriods.append(try parseAlertPeriod(bytes))
            }
            if field.number == 10, let bytes = field.bytes { header = try parseTranslatedString(bytes) }
            if field.number == 11, let bytes = field.bytes { description = try parseTranslatedString(bytes) }
            if field.number == 5, let bytes = field.bytes {
                let selector = try parseEntitySelector(bytes)
                if let routeID = selector.routeID { routeIDs.insert(routeID) }
                if let stopID = selector.stopID { stopIDs.insert(stopID) }
            }
        }
        let message = [header, description].filter { !$0.isEmpty }.joined(separator: ": ")
        return (message, routeIDs, stopIDs, activePeriods)
    }

    private static func parseAlertPeriod(_ data: Data) throws -> GTFSAlertPeriod {
        var reader = ProtoReader(data: data)
        var start: Date?
        var end: Date?
        while let field = try reader.next() {
            if field.number == 1, let value = field.varint { start = Date(timeIntervalSince1970: Double(value)) }
            if field.number == 2, let value = field.varint { end = Date(timeIntervalSince1970: Double(value)) }
        }
        return GTFSAlertPeriod(start: start, end: end)
    }

    private static func parseEntitySelector(_ data: Data) throws -> (routeID: String?, stopID: String?) {
        var reader = ProtoReader(data: data)
        var routeID: String?
        var stopID: String?
        while let field = try reader.next() {
            if field.number == 2, let bytes = field.bytes { routeID = String(data: bytes, encoding: .utf8) }
            if field.number == 5, let bytes = field.bytes { stopID = String(data: bytes, encoding: .utf8) }
        }
        return (routeID, stopID)
    }

    private static func parseTranslatedString(_ data: Data) throws -> String {
        var reader = ProtoReader(data: data)
        var firstTranslation: String?
        var polishTranslation: String?
        while let field = try reader.next() {
            guard field.number == 1, let bytes = field.bytes else { continue }
            var translation = ProtoReader(data: bytes)
            var text: String?
            var language = ""
            while let value = try translation.next() {
                if value.number == 1, let bytes = value.bytes { text = String(data: bytes, encoding: .utf8) }
                if value.number == 2, let bytes = value.bytes { language = String(data: bytes, encoding: .utf8) ?? "" }
            }
            guard let text, !text.isEmpty else { continue }
            if firstTranslation == nil { firstTranslation = text }
            if language.lowercased().hasPrefix("pl") { polishTranslation = text }
        }
        return polishTranslation ?? firstTranslation ?? ""
    }
}

nonisolated struct GTFSRealtimeVehicle {
    let id: String
    let tripID: String?
    let routeID: String?
    let serviceDate: String?
    let currentStopID: String?
    let currentStopSequence: Int?
    let coordinate: Coordinate
    let bearing: Double?
    let updatedAt: Date?
    let label: String?
}

nonisolated struct GTFSStopTimeUpdate {
    let arrivalTime: Date?
    let departureTime: Date?
    let arrivalDelay: Int?
    let departureDelay: Int?
}

nonisolated struct GTFSStopTimeEvent {
    let time: Date?
    let delay: Int?
}

nonisolated struct GTFSAlert {
    let message: String
    let routeIDs: Set<String>
    let stopIDs: Set<String>
    let activePeriods: [GTFSAlertPeriod]

    func isActive(at date: Date) -> Bool {
        activePeriods.isEmpty || activePeriods.contains { $0.contains(date) }
    }
}

nonisolated struct GTFSAlertPeriod {
    let start: Date?
    let end: Date?

    func contains(_ date: Date) -> Bool {
        date >= (start ?? .distantPast) && date <= (end ?? .distantFuture)
    }
}

private nonisolated struct ProtoField {
    let number: Int
    let wireType: Int
    let varint: UInt64?
    let bytes: Data?
    let fixed32: UInt32?
}

private nonisolated struct ProtoReader {
    private let data: Data
    private var offset = 0

    init(data: Data) { self.data = data }

    mutating func next() throws -> ProtoField? {
        guard offset < data.count else { return nil }
        let tag = try readVarint()
        let number = Int(tag >> 3)
        let wireType = Int(tag & 7)
        guard number > 0 else { throw TransitRoutingError.invalidResponse }
        switch wireType {
        case 0:
            return ProtoField(number: number, wireType: wireType, varint: try readVarint(), bytes: nil, fixed32: nil)
        case 1:
            guard offset + 8 <= data.count else { throw TransitRoutingError.invalidResponse }
            offset += 8
        case 2:
            let rawLength = try readVarint()
            guard rawLength <= UInt64(data.count - offset) else { throw TransitRoutingError.invalidResponse }
            let length = Int(rawLength)
            let value = Data(data[offset..<(offset + length)])
            offset += length
            return ProtoField(number: number, wireType: wireType, varint: nil, bytes: value, fixed32: nil)
        case 5:
            guard offset + 4 <= data.count else { throw TransitRoutingError.invalidResponse }
            let value = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            offset += 4
            return ProtoField(number: number, wireType: wireType, varint: nil, bytes: nil, fixed32: value)
        default:
            throw TransitRoutingError.invalidResponse
        }
        return ProtoField(number: number, wireType: wireType, varint: nil, bytes: nil, fixed32: nil)
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw TransitRoutingError.invalidResponse }
            let byte = data[offset]
            offset += 1
            if shift == 63, byte > 1 { throw TransitRoutingError.invalidResponse }
            result |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        throw TransitRoutingError.invalidResponse
    }
}
