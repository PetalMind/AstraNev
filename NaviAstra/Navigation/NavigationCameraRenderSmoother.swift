import Foundation

/// Continuous perspective filtering after viewport fitting. Position and route
/// context always come from the supplied intent; the renderer anchors position
/// to the current puck frame. A new GPS sample changes the spring's destination,
/// without restarting its velocity or introducing an end-of-animation pause.
struct NavigationCameraRenderSmoother {
    private(set) var current: CameraIntent?
    private var lastTimestamp: TimeInterval?
    private var zoom = Spring()
    private var pitch = Spring()
    private var bearing = Spring()
    private var top = Spring()
    private var left = Spring()
    private var bottom = Spring()
    private var right = Spring()

    mutating func reset() {
        self = Self()
    }

    /// Seed from the actual rendered camera after a native transition or a
    /// gesture. Do not seed from the old policy destination after recentering.
    mutating func reset(to intent: CameraIntent, timestamp: TimeInterval) {
        current = intent
        lastTimestamp = timestamp.isFinite ? timestamp : nil
        zoom = Spring(value: intent.zoom)
        pitch = Spring(value: intent.pitch)
        bearing = Spring(value: normalized(intent.bearing))
        top = Spring(value: intent.padding.top)
        left = Spring(value: intent.padding.left)
        bottom = Spring(value: intent.padding.bottom)
        right = Spring(value: intent.padding.right)
    }

    /// Pass a monotonic display-clock timestamp, e.g. CACurrentMediaTime().
    /// Only smooth padding while UI occlusion is unchanged. A panel's new
    /// exclusion area is a hard boundary and must use the default `false`.
    mutating func step(_ desired: CameraIntent, timestamp: TimeInterval,
                       smoothPadding: Bool = false) -> CameraIntent {
        if current == nil { reset(to: desired, timestamp: timestamp) }
        let elapsed: TimeInterval
        if timestamp.isFinite {
            if let previous = lastTimestamp {
                elapsed = max(0, timestamp - previous)
                // Duplicate or out-of-order callbacks cannot advance the clock.
                lastTimestamp = max(previous, timestamp)
            } else {
                elapsed = 0
                lastTimestamp = timestamp
            }
        } else {
            elapsed = 0
        }

        if elapsed > 0.25 {
            // Returning from the background must not integrate seconds of old
            // velocity or make a large first-frame correction.
            stopVelocity()
        }
        let duration = min(elapsed, 0.05)
        let steps = max(1, Int(ceil(duration * 120)))
        let delta = duration / Double(steps)
        for _ in 0..<steps {
            zoom.advance(to: desired.zoom, delta: delta, response: 0.65,
                         maximumRate: 0.45, maximumAcceleration: 1.5)
            pitch.advance(to: desired.pitch, delta: delta, response: 0.55,
                          maximumRate: 14, maximumAcceleration: 45)
            let destination = bearing.value + shortestAngle(from: bearing.value, to: desired.bearing)
            bearing.advance(to: destination, delta: delta, response: 0.42,
                            maximumRate: 55, maximumAcceleration: 150)
            bearing.value = normalized(bearing.value)
            if smoothPadding {
                top.advance(to: desired.padding.top, delta: delta, response: 0.45,
                            maximumRate: 120, maximumAcceleration: 400)
                left.advance(to: desired.padding.left, delta: delta, response: 0.45,
                             maximumRate: 120, maximumAcceleration: 400)
                bottom.advance(to: desired.padding.bottom, delta: delta, response: 0.45,
                               maximumRate: 120, maximumAcceleration: 400)
                right.advance(to: desired.padding.right, delta: delta, response: 0.45,
                              maximumRate: 120, maximumAcceleration: 400)
            }
        }
        if !smoothPadding {
            top = Spring(value: desired.padding.top)
            left = Spring(value: desired.padding.left)
            bottom = Spring(value: desired.padding.bottom)
            right = Spring(value: desired.padding.right)
        }

        var rendered = desired
        rendered.zoom = zoom.value
        rendered.pitch = pitch.value
        rendered.bearing = bearing.value
        rendered.padding = CameraPadding(top: top.value, left: left.value,
                                         bottom: bottom.value, right: right.value)
        rendered.animationDuration = 0
        current = rendered
        return rendered
    }

    private mutating func stopVelocity() {
        zoom.velocity = 0
        pitch.velocity = 0
        bearing.velocity = 0
        top.velocity = 0
        left.velocity = 0
        bottom.velocity = 0
        right.velocity = 0
    }

    private func normalized(_ angle: Double) -> Double {
        (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    private func shortestAngle(from current: Double, to target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private struct Spring {
        var value = 0.0
        var velocity = 0.0

        mutating func advance(to target: Double, delta: TimeInterval, response: TimeInterval,
                              maximumRate: Double, maximumAcceleration: Double) {
            guard delta > 0, target.isFinite else { return }
            let omega = 2 / response
            let offset = value - target
            let decay = exp(-omega * delta)
            let component = velocity + omega * offset
            let exactValue = target + (offset + component * delta) * decay
            let exactVelocity = (velocity - omega * component * delta) * decay
            let limitedVelocity = min(maximumRate, max(-maximumRate,
                min(velocity + maximumAcceleration * delta,
                    max(velocity - maximumAcceleration * delta, exactVelocity))))
            // Use the exact critically damped solution when unconstrained.
            // Otherwise integrate the bounded velocity, limiting acceleration
            // at large target changes and at direction reversals.
            let movement = abs(limitedVelocity - exactVelocity) < 1e-10
                ? exactValue - value : (velocity + limitedVelocity) * delta / 2
            value += min(maximumRate * delta, max(-maximumRate * delta, movement))
            velocity = limitedVelocity
        }
    }
}

/// Removes only the residual position error left by a completed native camera
/// transition. New puck movement is copied immediately; the initial offset
/// disappears over half a second and ordinary following has no position lag.
struct NavigationCameraFollowHandoff {
    private struct Correction {
        let latitude: Double
        let longitude: Double
        let startedAt: TimeInterval
        var lastTimestamp: TimeInterval
    }

    private var correction: Correction?
    var isActive: Bool { correction != nil }

    mutating func cancel() {
        correction = nil
    }

    mutating func begin(from actualCenter: Coordinate, following puck: Coordinate,
                        timestamp: TimeInterval) {
        guard timestamp.isFinite, isValid(actualCenter), isValid(puck),
              actualCenter.distance(to: puck) > 0.01 else {
            cancel()
            return
        }
        correction = Correction(latitude: actualCenter.latitude - puck.latitude,
                                longitude: wrapped(actualCenter.longitude - puck.longitude),
                                startedAt: timestamp, lastTimestamp: timestamp)
    }

    mutating func coordinate(following puck: Coordinate, timestamp: TimeInterval) -> Coordinate {
        guard var correction else { return puck }
        let now = timestamp.isFinite ? max(timestamp, correction.lastTimestamp) : correction.lastTimestamp
        let progress = min(1, max(0, (now - correction.startedAt) / 0.5))
        guard progress < 1, isValid(puck) else {
            cancel()
            return puck
        }
        correction.lastTimestamp = now
        self.correction = correction
        // Quintic smoothstep has zero first and second derivatives at both ends.
        let settled = progress * progress * progress * (progress * (6 * progress - 15) + 10)
        let remainder = 1 - settled
        return Coordinate(latitude: min(90, max(-90, puck.latitude + correction.latitude * remainder)),
                          longitude: wrapped(puck.longitude + correction.longitude * remainder))
    }

    private func isValid(_ coordinate: Coordinate) -> Bool {
        coordinate.latitude.isFinite && (-90...90).contains(coordinate.latitude) &&
            coordinate.longitude.isFinite && (-180...180).contains(coordinate.longitude)
    }

    private func wrapped(_ longitude: Double) -> Double {
        ((longitude + 180).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) - 180
    }
}
