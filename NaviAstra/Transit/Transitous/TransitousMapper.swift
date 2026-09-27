import Foundation

enum TransitousMapper {
    static func journeys(from response: TransitousPlanResponseDTO) throws -> [TransitJourney] {
        try (response.itineraries + (response.direct ?? [])).compactMap { itinerary in
            guard !itinerary.legs.contains(where: { $0.cancelled == true }) else { return nil }
            return try journey(from: itinerary)
        }
    }

    private static func journey(from dto: TransitousItineraryDTO) throws -> TransitJourney {
        guard let departure = TransitousDateParser.date(dto.startTime),
              let arrival = TransitousDateParser.date(dto.endTime),
              arrival >= departure, !dto.legs.isEmpty else {
            throw TransitRouteError.decoding
        }
        let legs = try dto.legs.enumerated().map { index, leg in
            try map(leg, itineraryID: dto.id, legIndex: index)
        }
        let walkingLegs = legs.filter { $0.mode == .walk }
        let legDuration = legs.reduce(0.0) { $0 + $1.duration }
        let alerts = Array(Set(legs.flatMap(\.alerts))).sorted()
        return TransitJourney(
            id: dto.id,
            departure: departure,
            arrival: arrival,
            duration: max(TimeInterval(dto.duration), arrival.timeIntervalSince(departure)),
            transfers: max(0, dto.transfers),
            walkingDuration: walkingLegs.reduce(0) { $0 + $1.duration },
            walkingDistance: walkingLegs.reduce(0) { $0 + $1.distance },
            waitingDuration: max(0, arrival.timeIntervalSince(departure) - legDuration),
            legs: legs,
            realtimeAvailable: legs.contains { $0.isTransit && $0.realtimeAvailable },
            alerts: alerts)
    }

    private static func map(_ dto: TransitousLegDTO, itineraryID: String,
                            legIndex: Int) throws -> TransitLeg {
        guard let departure = TransitousDateParser.date(dto.startTime),
              let arrival = TransitousDateParser.date(dto.endTime),
              let scheduledDeparture = TransitousDateParser.date(dto.scheduledStartTime),
              let scheduledArrival = TransitousDateParser.date(dto.scheduledEndTime),
              arrival >= departure else {
            throw TransitRouteError.decoding
        }
        let from = coordinate(for: dto.from)
        let to = coordinate(for: dto.to)
        var geometry = TransitousPolylineDecoder.decode(dto.legGeometry.points,
                                                        precision: dto.legGeometry.precision)
        if geometry.isEmpty { geometry = [from, to] }
        let mode = mapMode(dto.mode)
        let stops = mode.isTransit
            ? mapStops([dto.from] + (dto.intermediateStops ?? []) + [dto.to],
                       leg: dto, departure: departure, arrival: arrival,
                       itineraryID: itineraryID, legIndex: legIndex)
            : []
        let delay = dto.realTime
            ? max(Int(departure.timeIntervalSince(scheduledDeparture).rounded()),
                 Int(arrival.timeIntervalSince(scheduledArrival).rounded()))
            : nil
        let line = dto.displayName?.nilIfBlank
            ?? dto.routeShortName?.nilIfBlank
            ?? dto.tripShortName?.nilIfBlank
            ?? dto.routeLongName?.nilIfBlank
        let alerts = dto.alerts?.map(\.headerText).filter { !$0.isEmpty } ?? []
        return TransitLeg(
            id: "\(itineraryID)-\(legIndex)",
            mode: mode,
            sourceMode: dto.mode,
            line: line,
            direction: dto.headsign?.nilIfBlank ?? dto.tripTo?.name.nilIfBlank,
            operatorName: dto.agencyName?.nilIfBlank,
            fromStop: dto.from.name,
            toStop: dto.to.name,
            fromCoordinate: from,
            toCoordinate: to,
            scheduledDeparture: scheduledDeparture,
            estimatedDeparture: departure,
            scheduledArrival: scheduledArrival,
            estimatedArrival: arrival,
            delaySeconds: delay,
            intermediateStops: stops,
            geometry: geometry,
            distance: max(0, dto.distance ?? Self.distance(of: geometry)),
            realtimeAvailable: dto.realTime && mode.isTransit,
            routeID: dto.routeId,
            tripID: dto.tripId,
            lineColorHex: Self.colorValue(dto.routeColor),
            alerts: alerts,
            isInterlined: dto.interlineWithPreviousLeg == true)
    }

    private static func mapStops(_ places: [TransitousPlaceDTO], leg: TransitousLegDTO,
                                 departure: Date, arrival: Date,
                                 itineraryID: String, legIndex: Int) -> [TransitJourneyStop] {
        var seen = Set<String>()
        return places.enumerated().compactMap { index, place in
            let stopID = place.stopId ?? "\(itineraryID)-\(legIndex)-\(index)"
            guard seen.insert(stopID).inserted else { return nil }
            let scheduledArrival = TransitousDateParser.date(place.scheduledArrival)
            let scheduledDeparture = TransitousDateParser.date(place.scheduledDeparture)
            let actualArrival = TransitousDateParser.date(place.arrival) ?? scheduledArrival
                ?? (index == 0 ? departure : arrival)
            let actualDeparture = TransitousDateParser.date(place.departure) ?? scheduledDeparture
                ?? actualArrival
            let delay = [
                scheduledArrival.map { Int((actualArrival.timeIntervalSince($0)).rounded()) },
                scheduledDeparture.map { Int((actualDeparture.timeIntervalSince($0)).rounded()) }
            ].compactMap { $0 }.max()
            return TransitJourneyStop(
                id: "\(itineraryID)-\(legIndex)-\(index)",
                stopID: stopID,
                name: place.name,
                coordinate: coordinate(for: place),
                arrival: actualArrival,
                departure: actualDeparture,
                delaySeconds: delay,
                hasRealtime: leg.realTime && (place.arrival != nil || place.departure != nil),
                sequence: index,
                scheduledArrival: scheduledArrival,
                scheduledDeparture: scheduledDeparture)
        }
    }

    private static func coordinate(for place: TransitousPlaceDTO) -> Coordinate {
        Coordinate(latitude: place.lat, longitude: place.lon)
    }

    private static func mapMode(_ rawValue: String) -> TransitLegMode {
        switch rawValue.uppercased() {
        case "WALK": .walk
        case "BUS", "COACH": .bus
        case "TRAM": .tram
        case "RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "HIGHSPEED_RAIL": .train
        case "SUBURBAN": .suburbanRail
        case "SUBWAY", "METRO": .metro
        case "FERRY": .ferry
        case "BIKE": .bicycle
        case "CAR": .car
        default: .unknown
        }
    }

    private static func colorValue(_ color: String?) -> UInt32? {
        guard var value = color?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 8 { value = String(value.suffix(6)) }
        return UInt32(value, radix: 16)
    }

    private static func distance(of coordinates: [Coordinate]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }
}

private enum TransitousDateParser {
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private enum TransitousPolylineDecoder {
    static func decode(_ encoded: String, precision: Int) -> [Coordinate] {
        guard !encoded.isEmpty, (0...7).contains(precision) else { return [] }
        let bytes = Array(encoded.utf8)
        var index = 0
        var latitude: Int64 = 0
        var longitude: Int64 = 0
        let scale = pow(10.0, Double(precision))
        var coordinates: [Coordinate] = []

        func nextValue() -> Int64? {
            var result: Int64 = 0
            var shift: UInt32 = 0
            while index < bytes.count {
                let byte = Int64(bytes[index]) - 63
                index += 1
                guard (0...63).contains(byte), shift < 60 else { return nil }
                result |= (byte & 0x1f) << shift
                if byte < 0x20 {
                    let delta = (result & 1) == 1 ? ~(result >> 1) : result >> 1
                    return delta
                }
                shift += 5
            }
            return nil
        }

        while index < bytes.count {
            guard let latitudeDelta = nextValue(), let longitudeDelta = nextValue() else { return [] }
            latitude += latitudeDelta
            longitude += longitudeDelta
            coordinates.append(Coordinate(latitude: Double(latitude) / scale,
                                           longitude: Double(longitude) / scale))
        }
        return coordinates
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
