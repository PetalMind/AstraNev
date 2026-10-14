import Foundation

nonisolated enum AlternativePathKind: String, Codable, Sendable {
    case distanceShortcut, timeShortcut, comfortAlternative, unknownPreference
    var title: String {
        switch self {
        case .distanceShortcut: "Skrót dystansowy"
        case .timeShortcut: "Skrót czasowy"
        case .comfortAlternative: "Wygodniejszy wariant"
        case .unknownPreference: "Własny wariant"
        }
    }
}

nonisolated enum LearningReason: String, Codable, Sendable {
    case normalTraversal, offeredAlternatives, selectedAlternative, repeatedDeviation
    case repeatedSegmentChoice, destinationApproach, manualRouteSave, manualPreferenceRemoval
    case tripRemoved, legacyImport
    var title: String {
        switch self {
        case .normalTraversal: "Zwykły przejazd"
        case .offeredAlternatives: "Zaproponowane warianty"
        case .selectedAlternative: "Wybór alternatywy"
        case .repeatedDeviation: "Odstępstwo od propozycji"
        case .repeatedSegmentChoice: "Wybór odcinków"
        case .destinationApproach: "Dojazd do celu"
        case .manualRouteSave: "Ręczne zapisanie trasy"
        case .manualPreferenceRemoval: "Usunięcie preferencji"
        case .tripRemoved: "Usunięcie przejazdu"
        case .legacyImport: "Migracja wcześniejszej obserwacji"
        }
    }
}

nonisolated struct DrivingObservedVariant: Codable, Sendable, Identifiable {
    let id: String
    let segments: [LearnedRoadSegment]
}

nonisolated struct DrivingOfferedVariant: Codable, Sendable, Identifiable {
    let id: String
    let coordinates: [Coordinate]
}

/// Facts about one observation or user action, not synthetic opportunities.
/// A missing offer stays unknown when importing the previous profile format.
nonisolated struct PreferenceEvidence: Codable, Sendable, Identifiable {
    var id = UUID()
    let source: LearningReason
    let tripID: UUID?
    let timestamp: Date
    let context: DrivingPreferenceContext?
    let subject: String
    var offeredAlternative: [String]? = nil
    var selectedVariant: String? = nil
    var offeredSegments: [String]? = nil
    var chosenSegments: [String] = []
    var avoidedSegments: [String] = []
    var confidenceBefore: Double? = nil
    var confidenceAfter: Double? = nil
    var userConfirmed = false
    var confidenceDelta: Double? {
        guard let confidenceBefore, let confidenceAfter else { return nil }
        return confidenceAfter - confidenceBefore
    }
}

nonisolated struct PreferenceMetrics: Codable, Sendable {
    var confidence = 0.0
    var strength = 0.0
    var relevance = 1.0
    var recency = 1.0
    var userConfirmed = false
    var effective: Double { confidence * strength * relevance * recency }
}

nonisolated enum DrivingEvidenceMath {
    // Full influence for 30 days, followed by continuous decay. No old preference
    // obtains a fresh timestamp merely because a familiar road was suggested again.
    static func recency(_ timestamp: Date, at date: Date) -> Double {
        let days = max(0, date.timeIntervalSince(timestamp) / 86_400)
        guard days <= 365 else { return 0 }
        return days <= 30 ? 1 : exp(-log(2) * (days - 30) / 120)
    }

    static func metrics(trips: [LearnedDrivingTrip], at date: Date,
                        context: DrivingPreferenceContext? = nil) -> PreferenceMetrics {
        let eligible = trips.filter { $0.automaticPreferenceEligible || $0.confirmed }
        let strong = eligible.filter { $0.selectedAgainstAlternative || !$0.deviations.isEmpty }
        let statistical = DrivingLearningMath.confidence(eligible.count)
        let confirmed = eligible.contains(where: \.confirmed)
        // An explicit choice is meaningful evidence, not statistical certainty.
        let confidence = confirmed ? max(0.72, statistical) : statistical
        let choiceRatio = Double(strong.count) / Double(max(1, eligible.count))
        let strength = confirmed ? max(0.95, choiceRatio) : 0.15 + 0.85 * choiceRatio
        let weighted = eligible.map { trip -> (Double, Double) in
            let weight = trip.confirmed || trip.selectedAgainstAlternative || !trip.deviations.isEmpty ? 1.0 : 0.15
            return (recency(trip.startedAt, at: date), weight)
        }
        let totalWeight = weighted.reduce(0) { $0 + $1.1 }
        let relevance = context.map { current in eligible.map { current.affinity(to: $0.context) }.max() ?? 0 } ?? 1
        return PreferenceMetrics(confidence: confidence, strength: strength, relevance: relevance,
            recency: totalWeight > 0 ? weighted.reduce(0) { $0 + $1.0 * $1.1 } / totalWeight : 0, userConfirmed: confirmed)
    }

    static func bearingRelevance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        let angle = min(difference, 360 - difference)
        return angle >= 90 ? 0 : pow(cos(angle * .pi / 180), 2)
    }

    static func approachBearing(origin: Coordinate, destination: Coordinate) -> Double {
        DrivingLearningMath.bearing(origin, destination)
    }

    static func observations(for trip: LearnedDrivingTrip, migrated: Bool = false) -> [PreferenceEvidence] {
        let subject = "trip:\(trip.id.uuidString)"
        let selected = Set(trip.segments.map(\.id))
        let offeredRoads = Set(trip.offeredVariants.flatMap { $0.segments.map(\.id) })
            .union(trip.deviations.flatMap { $0.avoided.map(\.id) })
        let offered = offeredRoads.isEmpty ? nil : Array(offeredRoads).sorted()
        let rejectedPrimary = trip.selectedAgainstAlternative
            ? Set(trip.offeredVariants.first?.segments.map(\.id) ?? []).subtracting(selected) : []
        let bypassed = trip.automaticPreferenceEligible
            ? Set(trip.deviations.flatMap { $0.avoided.map(\.id) }).union(rejectedPrimary).subtracting(selected) : []
        let source: LearningReason = migrated ? .legacyImport : trip.selectedAgainstAlternative ? .selectedAlternative
            : trip.deviations.isEmpty ? .normalTraversal : .repeatedDeviation
        var result = [PreferenceEvidence(source: source, tripID: trip.id, timestamp: trip.startedAt,
            context: trip.context, subject: subject,
            offeredAlternative: trip.offeredVariants.isEmpty ? nil : trip.offeredVariants.map(\.id),
            selectedVariant: trip.selectedVariantID, offeredSegments: offered,
            chosenSegments: Array(selected).sorted(), avoidedSegments: Array(bypassed).sorted(), userConfirmed: trip.confirmed)]
        if !trip.offeredVariants.isEmpty {
            result.append(PreferenceEvidence(source: .offeredAlternatives, tripID: trip.id, timestamp: trip.startedAt,
                context: trip.context, subject: subject, offeredAlternative: trip.offeredVariants.map(\.id),
                selectedVariant: trip.selectedVariantID, offeredSegments: offered))
        }
        if trip.automaticPreferenceEligible {
            result.append(PreferenceEvidence(source: .destinationApproach, tripID: trip.id,
                timestamp: trip.startedAt, context: trip.context, subject: subject))
            if !trip.deviations.isEmpty || trip.selectedAgainstAlternative {
                result.append(PreferenceEvidence(source: .repeatedSegmentChoice, tripID: trip.id,
                    timestamp: trip.startedAt, context: trip.context, subject: subject,
                    chosenSegments: Array(selected).sorted(), avoidedSegments: Array(bypassed).sorted()))
            }
        }
        return result
    }
}

nonisolated struct PreferenceContribution: Codable, Sendable {
    let subject: String
    let reason: LearningReason
    let metrics: PreferenceMetrics
    var penalty = false
}

nonisolated struct DrivingRouteAssessment: Codable, Sendable {
    var score = 0.5
    var confirmed = false
    var appliedWeight = 0.0
    var contributions: [PreferenceContribution] = []
}

// Decode additions with defaults; profiles written by 1.1.76 stay readable.
extension DrivingPreferenceContext {
    nonisolated enum CodingKeys: String, CodingKey { case weekday, hourBucket, trafficLevel, bucketHours }
    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        weekday = try values.decode(Int.self, forKey: .weekday)
        bucketHours = try values.decodeIfPresent(Int.self, forKey: .bucketHours) ?? 4
        hourBucket = try values.decode(Int.self, forKey: .hourBucket)
        trafficLevel = try values.decodeIfPresent(String.self, forKey: .trafficLevel)
        guard (1...7).contains(weekday), [2, 4].contains(bucketHours), (0..<(24 / bucketHours)).contains(hourBucket) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid driving context"))
        }
    }
}

extension LearnedDrivingTrip {
    nonisolated enum CodingKeys: String, CodingKey {
        case id, destinationName, origin, destination, startedAt, duration, context, segments, deviations
        case confirmed, automaticPreferenceEligible, offeredVariants, selectedVariantID, selectedAgainstAlternative
    }
    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        destinationName = try values.decode(String.self, forKey: .destinationName)
        origin = try values.decode(Coordinate.self, forKey: .origin)
        destination = try values.decode(Coordinate.self, forKey: .destination)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        duration = try values.decode(Double.self, forKey: .duration)
        let oldContext = try values.decode(DrivingPreferenceContext.self, forKey: .context)
        context = oldContext.bucketHours == 4 ? DrivingPreferenceContext(date: startedAt, trafficLevel: oldContext.trafficLevel) : oldContext
        segments = try values.decode([LearnedRoadSegment].self, forKey: .segments)
        deviations = try values.decode([DrivingDeviation].self, forKey: .deviations)
        confirmed = try values.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        automaticPreferenceEligible = try values.decodeIfPresent(Bool.self, forKey: .automaticPreferenceEligible) ?? true
        offeredVariants = try values.decodeIfPresent([DrivingObservedVariant].self, forKey: .offeredVariants) ?? []
        selectedVariantID = try values.decodeIfPresent(String.self, forKey: .selectedVariantID)
        selectedAgainstAlternative = try values.decodeIfPresent(Bool.self, forKey: .selectedAgainstAlternative) ?? false
    }
}

extension PendingDrivingTrip {
    nonisolated enum CodingKeys: String, CodingKey {
        case id, destinationName, destination, startedAt, duration, context, trace, proposedCoordinates
        case costing, confirmed, allowAutomaticDeviations, offeredVariants, selectedVariantID, selectedAgainstAlternative
        case proposedVariantID
    }
    nonisolated init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(UUID.self, forKey: .id)
        destinationName = try v.decode(String.self, forKey: .destinationName)
        destination = try v.decode(Coordinate.self, forKey: .destination)
        startedAt = try v.decode(Date.self, forKey: .startedAt)
        duration = try v.decode(Double.self, forKey: .duration)
        let old = try v.decode(DrivingPreferenceContext.self, forKey: .context)
        context = old.bucketHours == 4 ? DrivingPreferenceContext(date: startedAt, trafficLevel: old.trafficLevel) : old
        trace = try v.decode([TripTracePoint].self, forKey: .trace)
        proposedCoordinates = try v.decode([Coordinate].self, forKey: .proposedCoordinates)
        costing = try v.decode(String.self, forKey: .costing)
        confirmed = try v.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        allowAutomaticDeviations = try v.decodeIfPresent(Bool.self, forKey: .allowAutomaticDeviations) ?? true
        offeredVariants = try v.decodeIfPresent([DrivingOfferedVariant].self, forKey: .offeredVariants) ?? []
        selectedVariantID = try v.decodeIfPresent(String.self, forKey: .selectedVariantID)
        selectedAgainstAlternative = try v.decodeIfPresent(Bool.self, forKey: .selectedAgainstAlternative) ?? false
        proposedVariantID = try v.decodeIfPresent(String.self, forKey: .proposedVariantID)
    }
}

extension DrivingDeviation {
    nonisolated enum CodingKeys: String, CodingKey { case id, entry, exit, preferred, avoided, elapsed, measuredBaselineElapsed }
    nonisolated init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        let oldID = try v.decode(String.self, forKey: .id)
        entry = try v.decode(Coordinate.self, forKey: .entry)
        exit = try v.decode(Coordinate.self, forKey: .exit)
        preferred = try v.decode([LearnedRoadSegment].self, forKey: .preferred)
        avoided = try v.decode([LearnedRoadSegment].self, forKey: .avoided)
        elapsed = try v.decodeIfPresent(Double.self, forKey: .elapsed)
        measuredBaselineElapsed = try v.decodeIfPresent(Double.self, forKey: .measuredBaselineElapsed)
        id = oldID.contains("|") ? oldID : DrivingLearningMath.alternativeID(boundary: oldID, segments: preferred)
    }
}
