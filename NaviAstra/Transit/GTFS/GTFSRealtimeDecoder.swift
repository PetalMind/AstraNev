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
                                             sourceFreshness: ["city": .unavailable, "rail": .unavailable],
                                             sourceUpdatedAt: [:])

    func update(tripID: String, serviceDate: String, stopID: String,
                stopSequence: Int? = nil, frequencyStartSeconds: Int? = nil) -> GTFSStopTimeUpdate? {
        let datedUpdates = updates[tripID]?[serviceDate]
        let undatedUpdates = updates[tripID]?[""]
        if let frequencyStartSeconds {
            let prefix = "frequency:\(frequencyStartSeconds):"
            if let stopSequence,
               let update = datedUpdates?[prefix + "sequence:\(stopSequence)"] { return update }
            if let update = datedUpdates?[prefix + stopID] { return update }
            if let stopSequence,
               let update = undatedUpdates?[prefix + "sequence:\(stopSequence)"] { return update }
            return undatedUpdates?[prefix + stopID]
        }
        if let stopSequence, let update = datedUpdates?["sequence:\(stopSequence)"] { return update }
        if let update = datedUpdates?[stopID] { return update }
        return stopSequence.flatMap { undatedUpdates?["sequence:\($0)"] }
            ?? undatedUpdates?[stopID]
    }

    func isCanceled(tripID: String, serviceDate: String) -> Bool {
        canceledTrips.contains("\(tripID)|\(serviceDate)") || canceledTrips.contains("\(tripID)|")
    }

    func isCanceled(tripID: String, serviceDate: String, frequencyStartSeconds: Int?) -> Bool {
        if isCanceled(tripID: tripID, serviceDate: serviceDate) { return true }
        guard let frequencyStartSeconds else { return false }
        let startTime = GTFSCSV.serviceTimeString(frequencyStartSeconds)
        return canceledTrips.contains("\(tripID)|\(serviceDate)|\(startTime)")
            || canceledTrips.contains("\(tripID)||\(startTime)")
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
                    let normalizedStart = entity.startTime.flatMap(GTFSCSV.serviceSeconds)
                        .map(GTFSCSV.serviceTimeString)
                    let frequencyKey = normalizedStart.map { "|\($0)" } ?? ""
                    canceled.insert("\(prefix)\(entity.tripID)|\(dateKey)\(frequencyKey)")
                } else {
                    let frequencyPrefix: String
                    if let startTime = entity.startTime {
                        guard let startSeconds = GTFSCSV.serviceSeconds(startTime) else { continue }
                        frequencyPrefix = "frequency:\(startSeconds):"
                    } else {
                        frequencyPrefix = ""
                    }
                    for (key, update) in entity.stopUpdates {
                        let stopKey = key.hasPrefix("sequence:") ? key : prefix + key
                        let namespacedKey = frequencyPrefix + stopKey
                        updates[prefix + entity.tripID, default: [:]][dateKey, default: [:]][namespacedKey] = update
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
        -> (tripID: String, serviceDate: String?, startTime: String?, canceled: Bool,
            stopUpdates: [(String, GTFSStopTimeUpdate)])? {
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
        var startTime: String?
        var relationship: UInt64 = 0
        var stopUpdates: [(String, GTFSStopTimeUpdate)] = []
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                let descriptor = try parseTripDescriptor(bytes)
                tripID = descriptor.tripID
                serviceDate = descriptor.serviceDate
                startTime = descriptor.startTime
                relationship = descriptor.relationship
            } else if field.number == 2, let bytes = field.bytes,
                      let updates = try parseStopTimeUpdate(bytes) {
                stopUpdates.append(contentsOf: updates)
            }
        }
        guard let tripID, !tripID.isEmpty else { return nil }
        return (tripID, serviceDate, startTime, relationship == 3, stopUpdates)
    }

    private static func parseTripDescriptor(_ data: Data) throws
        -> (tripID: String?, serviceDate: String?, startTime: String?,
            relationship: UInt64, routeID: String?) {
        var reader = ProtoReader(data: data)
        var tripID: String?
        var serviceDate: String?
        var startTime: String?
        var relationship: UInt64 = 0
        var routeID: String?
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes { tripID = String(data: bytes, encoding: .utf8) }
            if field.number == 2, let bytes = field.bytes { startTime = String(data: bytes, encoding: .utf8) }
            if field.number == 3, let bytes = field.bytes { serviceDate = String(data: bytes, encoding: .utf8) }
            if field.number == 4, let value = field.varint { relationship = value }
            if field.number == 5, let bytes = field.bytes { routeID = String(data: bytes, encoding: .utf8) }
        }
        return (tripID, serviceDate, startTime, relationship, routeID)
    }

    private static func parseStopTimeUpdate(_ data: Data) throws -> [(String, GTFSStopTimeUpdate)]? {
        var reader = ProtoReader(data: data)
        var stopID: String?
        var stopSequence: Int?
        var arrival: GTFSStopTimeEvent?
        var departure: GTFSStopTimeEvent?
        var relationship = GTFSStopTimeRelationship.scheduled
        while let field = try reader.next() {
            if field.number == 1, let value = field.varint, value <= UInt64(Int.max) {
                stopSequence = Int(value)
            }
            if field.number == 2, let bytes = field.bytes { arrival = try parseEvent(bytes) }
            if field.number == 3, let bytes = field.bytes { departure = try parseEvent(bytes) }
            if field.number == 4, let bytes = field.bytes { stopID = String(data: bytes, encoding: .utf8) }
            if field.number == 5, let value = field.varint, value <= UInt64(Int.max) {
                relationship = GTFSStopTimeRelationship(rawValue: Int(value)) ?? .unknown
            }
        }
        let update = GTFSStopTimeUpdate(arrivalTime: arrival?.time, departureTime: departure?.time,
                                        arrivalDelay: arrival?.delay, departureDelay: departure?.delay,
                                        scheduleRelationship: relationship)
        var keyedUpdates: [(String, GTFSStopTimeUpdate)] = []
        if let stopSequence { keyedUpdates.append(("sequence:\(stopSequence)", update)) }
        if let stopID, !stopID.isEmpty { keyedUpdates.append((stopID, update)) }
        return keyedUpdates.isEmpty ? nil : keyedUpdates
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
            return GTFSAlert(message: alert.message, selectors: alert.selectors,
                             hasInformedEntities: alert.hasInformedEntities,
                             activePeriods: alert.activePeriods)
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
        -> (message: String, selectors: [GTFSAlertSelector], hasInformedEntities: Bool,
            activePeriods: [GTFSAlertPeriod]) {
        var reader = ProtoReader(data: data)
        var header = ""
        var description = ""
        var selectors: [GTFSAlertSelector] = []
        var hasInformedEntities = false
        var activePeriods: [GTFSAlertPeriod] = []
        while let field = try reader.next() {
            if field.number == 1, let bytes = field.bytes {
                activePeriods.append(try parseAlertPeriod(bytes))
            }
            if field.number == 10, let bytes = field.bytes { header = try parseTranslatedString(bytes) }
            if field.number == 11, let bytes = field.bytes { description = try parseTranslatedString(bytes) }
            if field.number == 5, let bytes = field.bytes {
                hasInformedEntities = true
                selectors.append(try parseEntitySelector(bytes))
            }
        }
        let message = [header, description].filter { !$0.isEmpty }.joined(separator: ": ")
        return (message, selectors, hasInformedEntities, activePeriods)
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

    private static func parseEntitySelector(_ data: Data) throws -> GTFSAlertSelector {
        var reader = ProtoReader(data: data)
        var routeID: String?
        var stopID: String?
        var tripID: String?
        var hasUnsupportedConstraint = false
        while let field = try reader.next() {
            switch (field.number, field.bytes) {
            case (2, let bytes?):
                routeID = String(data: bytes, encoding: .utf8)
            case (4, let bytes?):
                var tripReader = ProtoReader(data: bytes)
                while let tripField = try tripReader.next() {
                    if tripField.number == 1, let id = tripField.bytes {
                        tripID = String(data: id, encoding: .utf8)
                    } else if tripField.number == 5, let id = tripField.bytes {
                        routeID = String(data: id, encoding: .utf8)
                    } else {
                        hasUnsupportedConstraint = true
                    }
                }
            case (5, let bytes?):
                stopID = String(data: bytes, encoding: .utf8)
            default:
                hasUnsupportedConstraint = true
            }
        }
        return GTFSAlertSelector(routeID: routeID, stopID: stopID, tripID: tripID,
                                 hasUnsupportedConstraint: hasUnsupportedConstraint)
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
    let scheduleRelationship: GTFSStopTimeRelationship

    var isSkipped: Bool { scheduleRelationship == .skipped }
    var hasNoData: Bool { scheduleRelationship == .noData }
    var hasUsableTiming: Bool {
        scheduleRelationship == .scheduled || scheduleRelationship == .unscheduled
    }
}

nonisolated enum GTFSStopTimeRelationship: Int, Equatable, Sendable {
    case scheduled = 0
    case skipped = 1
    case noData = 2
    case unscheduled = 3
    case unknown = 255
}

nonisolated struct GTFSStopTimeEvent {
    let time: Date?
    let delay: Int?
}

nonisolated struct GTFSAlert {
    let message: String
    let selectors: [GTFSAlertSelector]
    let hasInformedEntities: Bool
    let activePeriods: [GTFSAlertPeriod]

    func applies(routeIDs: Set<String>, stopIDs: Set<String>, tripIDs: Set<String>) -> Bool {
        guard hasInformedEntities else { return true }
        return selectors.contains { selector in
            guard !selector.hasUnsupportedConstraint else { return false }
            if let routeID = selector.routeID, !routeIDs.contains(routeID) { return false }
            if let stopID = selector.stopID, !stopIDs.contains(stopID) { return false }
            if let tripID = selector.tripID, !tripIDs.contains(tripID) { return false }
            return selector.routeID != nil || selector.stopID != nil || selector.tripID != nil
        }
    }

    func isActive(at date: Date) -> Bool {
        activePeriods.isEmpty || activePeriods.contains { $0.contains(date) }
    }
}

nonisolated struct GTFSAlertSelector: Sendable {
    let routeID: String?
    let stopID: String?
    let tripID: String?
    let hasUnsupportedConstraint: Bool
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
