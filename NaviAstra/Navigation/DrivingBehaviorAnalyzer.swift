import Foundation

struct DrivingScore: Codable, Equatable {
    let score: Int
    let smoothnessScore: Int?
    let speedScore: Int?
    let cornersScore: Int?
    let stabilityScore: Int?
    let harshAccelerationCount: Int
    let harshBrakingCount: Int
    let aggressiveCornerCount: Int
    let speedingEventCount: Int
    let speedingDuration: TimeInterval
    let speedLimitCoverage: Double

    var scoredCategoryCount: Int {
        [smoothnessScore, speedScore, cornersScore, stabilityScore].compactMap { $0 }.count
    }

    var headline: String {
        switch score {
        case 90...: "Bardzo płynna jazda"
        case 80..<90: "Płynna jazda"
        case 70..<80: "Równa jazda z wahaniami"
        default: "Większe wahania podczas jazdy"
        }
    }
}

struct DrivingSample {
    let timestamp: Date
    let speedMetersPerSecond: Double
    let speedLimitKph: Int?
    let headingDegrees: Double?
    let horizontalAccuracy: Double
    let speedAccuracy: Double
    let courseAccuracy: Double
}

struct DrivingBehaviorAnalyzer {
    private struct AcceptedSample {
        let timestamp: Date
        let filteredSpeed: Double
        let speedLimitKph: Int?
        let headingDegrees: Double?
    }

    private struct AccelerationSample {
        let timestamp: Date
        let value: Double
    }

    private var previousSample: AcceptedSample?
    private var filteredSpeed: Double?
    private var harshAccelerationDirection: Int?
    private var harshAccelerationStreak = 0
    private var harshAccelerationActive = false
    private var lastCornerEventAt = Date.distantPast
    private var speedEventActive = false
    private var accelerationSamples: [AccelerationSample] = []
    private var stabilityDispersionTotal = 0.0
    private var stabilityDispersionCount = 0

    private(set) var validSampleCount = 0
    private(set) var validHeadingSampleCount = 0
    private(set) var accelerationSampleCount = 0
    private(set) var stabilitySampleCount = 0
    private(set) var harshAccelerationCount = 0
    private(set) var harshBrakingCount = 0
    private(set) var aggressiveCornerCount = 0
    private(set) var speedingEventCount = 0
    private(set) var speedingDuration: TimeInterval = 0
    private(set) var weightedSpeedingDuration: TimeInterval = 0
    private(set) var knownSpeedLimitDuration: TimeInterval = 0

    mutating func process(_ sample: DrivingSample) {
        guard sample.horizontalAccuracy >= 0, sample.horizontalAccuracy < 25,
              sample.speedMetersPerSecond.isFinite,
              (0...70).contains(sample.speedMetersPerSecond),
              sample.speedAccuracy < 0 || sample.speedAccuracy <= 5 else {
            resetContinuity()
            return
        }

        let heading = validHeading(sample) ? sample.headingDegrees : nil
        if heading != nil { validHeadingSampleCount += 1 }

        guard let previousSample else {
            filteredSpeed = sample.speedMetersPerSecond
            self.previousSample = AcceptedSample(timestamp: sample.timestamp,
                                                 filteredSpeed: sample.speedMetersPerSecond,
                                                 speedLimitKph: validLimit(sample.speedLimitKph),
                                                 headingDegrees: heading)
            validSampleCount += 1
            return
        }

        let interval = sample.timestamp.timeIntervalSince(previousSample.timestamp)
        guard interval >= 0.75 else { return }
        guard interval <= 3 else {
            harshAccelerationDirection = nil
            harshAccelerationStreak = 0
            harshAccelerationActive = false
            speedEventActive = false
            filteredSpeed = sample.speedMetersPerSecond
            self.previousSample = AcceptedSample(timestamp: sample.timestamp,
                                                 filteredSpeed: sample.speedMetersPerSecond,
                                                 speedLimitKph: validLimit(sample.speedLimitKph),
                                                 headingDegrees: heading)
            validSampleCount += 1
            return
        }

        let speed = 0.3 * sample.speedMetersPerSecond + 0.7 * (filteredSpeed ?? previousSample.filteredSpeed)
        filteredSpeed = speed
        let limit = validLimit(sample.speedLimitKph)
        let elapsed = min(interval, 3)
        validSampleCount += 1

        recordSpeeding(currentSpeed: speed, currentLimit: limit,
                       previous: previousSample, elapsed: elapsed)

        let acceleration = (speed - previousSample.filteredSpeed) / interval
        if acceleration.isFinite {
            accelerationSampleCount += 1
            recordHarshAcceleration(acceleration)
            recordCorner(sample: sample, heading: heading, speed: speed,
                         previous: previousSample, elapsed: interval)
            recordStability(acceleration, timestamp: sample.timestamp,
                            previousSpeed: previousSample.filteredSpeed, currentSpeed: speed)
        }

        self.previousSample = AcceptedSample(timestamp: sample.timestamp,
                                             filteredSpeed: speed,
                                             speedLimitKph: limit,
                                             headingDegrees: heading)
    }

    func score(distanceMeters: Double, movingSeconds: TimeInterval) -> DrivingScore? {
        guard distanceMeters >= 2_000, movingSeconds >= 90, validSampleCount >= 15 else { return nil }

        let smoothness = accelerationSampleCount >= 8
            ? eventScore(count: harshAccelerationCount + harshBrakingCount,
                         distanceMeters: distanceMeters)
            : nil

        let limitCoverage = min(1, max(0, knownSpeedLimitDuration / max(1, movingSeconds)))
        let speed: Int?
        if knownSpeedLimitDuration >= 60, limitCoverage >= 0.4 {
            let ratio = weightedSpeedingDuration / knownSpeedLimitDuration
            switch ratio {
            case ...0.01: speed = 100
            case ...0.03: speed = 95
            case ...0.08: speed = 85
            case ...0.15: speed = 70
            case ...0.25: speed = 55
            default: speed = 40
            }
        } else {
            speed = nil
        }

        let corners = validHeadingSampleCount >= 10
            ? eventScore(count: aggressiveCornerCount, distanceMeters: distanceMeters)
            : nil

        let stability: Int?
        if stabilitySampleCount >= 10, stabilityDispersionCount > 0 {
            let meanDispersion = stabilityDispersionTotal / Double(stabilityDispersionCount)
            switch meanDispersion {
            case ...0.65: stability = 100
            case ...0.95: stability = 92
            case ...1.3: stability = 82
            case ...1.8: stability = 70
            case ...2.5: stability = 55
            default: stability = 40
            }
        } else {
            stability = nil
        }

        let weightedCategories: [(Int?, Double)] = [
            (smoothness, 0.35), (speed, 0.30), (corners, 0.20), (stability, 0.15)
        ]
        let availableCategoryCount = weightedCategories.compactMap { $0.0 }.count
        let availableWeight = weightedCategories.reduce(0) { $0 + ($1.0 == nil ? 0 : $1.1) }
        guard availableCategoryCount >= 3, availableWeight >= 0.65 else { return nil }
        let weightedTotal = weightedCategories.reduce(0.0) { total, category in
            guard let value = category.0 else { return total }
            return total + Double(value) * category.1
        }

        return DrivingScore(
            score: Int((weightedTotal / availableWeight).rounded()),
            smoothnessScore: smoothness,
            speedScore: speed,
            cornersScore: corners,
            stabilityScore: stability,
            harshAccelerationCount: harshAccelerationCount,
            harshBrakingCount: harshBrakingCount,
            aggressiveCornerCount: aggressiveCornerCount,
            speedingEventCount: speedingEventCount,
            speedingDuration: speedingDuration,
            speedLimitCoverage: limitCoverage)
    }

    private mutating func recordSpeeding(currentSpeed: Double, currentLimit: Int?,
                                         previous: AcceptedSample, elapsed: TimeInterval) {
        guard let currentLimit, currentLimit == previous.speedLimitKph,
              let previousLimit = previous.speedLimitKph,
              previous.filteredSpeed >= 2, currentSpeed >= 2 else {
            speedEventActive = false
            return
        }
        knownSpeedLimitDuration += elapsed

        let threshold = Double(currentLimit + 5) / 3.6
        let wasOver = previous.filteredSpeed > threshold
        let isOver = currentSpeed > threshold
        guard wasOver, isOver else {
            speedEventActive = false
            return
        }

        if !speedEventActive { speedingEventCount += 1 }
        speedEventActive = true
        speedingDuration += elapsed

        let excessKph = max(0, currentSpeed * 3.6 - Double(previousLimit))
        let severity = excessKph < 10 ? 1.0 : (excessKph < 20 ? 1.5 : 2.2)
        weightedSpeedingDuration += elapsed * severity
    }

    private mutating func recordHarshAcceleration(_ acceleration: Double) {
        if abs(acceleration) < 2 {
            harshAccelerationDirection = nil
            harshAccelerationStreak = 0
            harshAccelerationActive = false
            return
        }

        let direction: Int
        if acceleration > 3.5 {
            direction = 1
        } else if acceleration < -4 {
            direction = -1
        } else {
            if !harshAccelerationActive {
                harshAccelerationDirection = nil
                harshAccelerationStreak = 0
            }
            return
        }

        if harshAccelerationDirection == direction {
            harshAccelerationStreak += 1
        } else {
            harshAccelerationDirection = direction
            harshAccelerationStreak = 1
            harshAccelerationActive = false
        }

        guard !harshAccelerationActive,
              harshAccelerationStreak >= 2 || abs(acceleration) >= 4 else { return }
        if direction > 0 {
            harshAccelerationCount += 1
        } else {
            harshBrakingCount += 1
        }
        harshAccelerationActive = true
    }

    private mutating func recordCorner(sample: DrivingSample, heading: Double?, speed: Double,
                                       previous: AcceptedSample, elapsed: TimeInterval) {
        guard let heading, let previousHeading = previous.headingDegrees,
              speed >= 13.9, previous.filteredSpeed >= 13.9,
              sample.timestamp.timeIntervalSince(lastCornerEventAt) >= 8 else { return }
        let difference = abs(shortestHeadingDifference(from: previousHeading, to: heading))
        guard difference >= 25, difference / elapsed >= 25 else { return }
        aggressiveCornerCount += 1
        lastCornerEventAt = sample.timestamp
    }

    private mutating func recordStability(_ acceleration: Double, timestamp: Date,
                                          previousSpeed: Double, currentSpeed: Double) {
        guard previousSpeed >= 8, currentSpeed >= 8, abs(acceleration) <= 3 else { return }
        stabilitySampleCount += 1
        accelerationSamples.append(AccelerationSample(timestamp: timestamp, value: acceleration))
        accelerationSamples.removeAll { timestamp.timeIntervalSince($0.timestamp) > 30 }
        guard accelerationSamples.count >= 6 else { return }

        let mean = accelerationSamples.reduce(0) { $0 + $1.value } / Double(accelerationSamples.count)
        let variance = accelerationSamples.reduce(0) { $0 + pow($1.value - mean, 2) }
            / Double(accelerationSamples.count)
        stabilityDispersionTotal += sqrt(variance)
        stabilityDispersionCount += 1
    }

    private func validHeading(_ sample: DrivingSample) -> Bool {
        guard let heading = sample.headingDegrees, heading.isFinite, (0...360).contains(heading) else {
            return false
        }
        if sample.courseAccuracy >= 0 { return sample.courseAccuracy <= 20 }
        return sample.horizontalAccuracy <= 15
    }

    private func validLimit(_ limit: Int?) -> Int? {
        guard let limit, (5...180).contains(limit) else { return nil }
        return limit
    }

    private func eventScore(count: Int, distanceMeters: Double) -> Int {
        let incidentsPerTenKilometers = Double(count) * 10_000 / max(10_000, distanceMeters)
        switch incidentsPerTenKilometers {
        case ...1: return 100
        case ...3: return 92
        case ...6: return 78
        case ...10: return 60
        default: return 45
        }
    }

    private func shortestHeadingDifference(from previous: Double, to current: Double) -> Double {
        var difference = (current - previous).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return difference
    }

    private mutating func resetContinuity() {
        previousSample = nil
        filteredSpeed = nil
        harshAccelerationDirection = nil
        harshAccelerationStreak = 0
        harshAccelerationActive = false
        speedEventActive = false
    }
}
