#if os(iOS)
import SwiftUI

/// Geometria prezentacji panelu na zegarze renderera, bez aktualizacji stanu SwiftUI co klatkę.
struct NavigationCameraViewportTransition {
    private(set) var current: CameraPadding?
    private(set) var isAnimating = false
    private var target: CameraPadding?
    private var velocity = CameraPadding(top: 0, left: 0, bottom: 0, right: 0)
    private var lastTimestamp: TimeInterval?
    // Te same parametry co NavigationBottomSheet i przycisk podsumowania podróży.
    private let spring = Spring(response: 0.38, dampingRatio: 0.86)

    mutating func reset() { self = Self() }

    mutating func reset(to padding: CameraPadding, timestamp: TimeInterval) {
        current = padding
        target = padding
        velocity = CameraPadding(top: 0, left: 0, bottom: 0, right: 0)
        lastTimestamp = timestamp
        isAnimating = false
    }

    mutating func step(_ padding: CameraPadding, timestamp: TimeInterval,
                       isTrackingFinger: Bool, reduceMotion: Bool) -> CameraPadding {
        guard var value = current, let previousTarget = target, let lastTimestamp,
              !isTrackingFinger, !reduceMotion else {
            reset(to: padding, timestamp: timestamp)
            return padding
        }
        // Najpierw kończymy odcinek poprzedniego celu. Nowa próbka GPS nie
        // restartuje animacji, a zmiana detentu zachowuje pozycję i prędkość.
        let delta = max(0, timestamp - lastTimestamp)
        if delta > 0 {
            spring.update(value: &value.top, velocity: &velocity.top,
                          target: previousTarget.top, deltaTime: delta)
            spring.update(value: &value.left, velocity: &velocity.left,
                          target: previousTarget.left, deltaTime: delta)
            spring.update(value: &value.bottom, velocity: &velocity.bottom,
                          target: previousTarget.bottom, deltaTime: delta)
            spring.update(value: &value.right, velocity: &velocity.right,
                          target: previousTarget.right, deltaTime: delta)
            self.lastTimestamp = timestamp
        }
        target = padding
        isAnimating = zip([value.top, value.left, value.bottom, value.right],
                          [padding.top, padding.left, padding.bottom, padding.right])
            .contains { pair in abs(pair.0 - pair.1) > 0.01 }
            || [velocity.top, velocity.left, velocity.bottom, velocity.right]
                .contains { abs($0) > 0.1 }
        if !isAnimating {
            reset(to: padding, timestamp: timestamp)
            return padding
        }
        current = value
        return value
    }
}
#endif
