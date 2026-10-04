import SwiftUI
import QuartzCore
#if os(iOS)
import UIKit
typealias NavigationMarkerPlatformView = UIView
#else
import AppKit
import MapKit
typealias NavigationMarkerPlatformView = NSView
#endif

/// Native layers keep 60 FPS location updates outside the SwiftUI observation tree.
@MainActor
final class NavigationMarkerNativeView: NavigationMarkerPlatformView {
    private let ring = CAShapeLayer()
    private let cone = CAGradientLayer()
    private let coneMask = CAShapeLayer()
    private let body = CALayer()
    private let direction = CAShapeLayer()
    private let signal = CAShapeLayer()
    private var imageKey: String?
    private var compactDetail = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        #else
        wantsLayer = true
        #endif
        guard let root = markerLayer else { return }
        for layer in [cone, ring, body, direction, signal] { root.addSublayer(layer) }
        cone.mask = coneMask
        body.contentsGravity = .resizeAspect
        body.contentsScale = 2.5
        ring.lineWidth = 1.8
        direction.lineWidth = 1
        signal.lineWidth = 2
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    #if os(macOS)
    override var isFlipped: Bool { true }
    #endif

    private var markerLayer: CALayer? {
        #if os(iOS)
        layer
        #else
        layer
        #endif
    }

    func update(_ value: NavigationMarkerPresentation) {
        if let zoom = value.detailZoom {
            compactDetail = compactDetail ? zoom < 13.8 : zoom < 13.2
        } else {
            compactDetail = value.compact
        }
        let canvas = 64.0 * value.scale
        let size = CGSize(width: canvas, height: canvas)
        if frame.size != size { frame.size = size }
        let center = CGPoint(x: canvas / 2, y: canvas / 2)
        let weak = value.quality == .weak || value.quality == .predicted || value.quality == .noSignal
        let locationColor = color(value.night ? NaviAstraColorPalette.userLocationNight : NaviAstraColorPalette.userLocationDay)
        let statusColor = weak ? color(NaviAstraColorPalette.warning) : locationColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ringWidth = 24 * value.scale
        let ringHeight = ringWidth * (value.model == nil ? 1 : max(0.58, cos(value.pitch * .pi / 180)))
        ring.path = CGPath(ellipseIn: CGRect(x: center.x - ringWidth / 2, y: center.y - ringHeight / 2,
                                            width: ringWidth, height: ringHeight), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = statusColor.copy(alpha: weak ? 0.86 : (value.night ? 0.4 : 0.32))
        ring.lineWidth = value.increasedContrast ? 1.8 : 0.85
        ring.lineDashPattern = weak ? [3, 2] : nil
        ring.shadowColor = statusColor
        ring.shadowOpacity = value.night ? 0.1 : 0
        ring.shadowRadius = 1.5
        ring.shadowOffset = .zero
        body.shadowColor = color(value.night ? 0x91B2DB : 0x122238)
        body.shadowOpacity = value.night ? 0.16 : 0.08
        body.shadowRadius = value.night ? 1.1 : 0.6
        body.shadowOffset = .zero
        let bodySize = canvas * (compactDetail ? 0.66 : 1)
        // Ground anchor stays at the coordinate; height only changes the mesh's projection.
        body.bounds = CGRect(x: 0, y: 0, width: bodySize, height: bodySize)
        body.position = center
        body.opacity = value.quality == .noSignal ? 0.55 : 1
        body.isHidden = value.model == nil
        if let model = value.model {
            let yaw = value.bearing ?? 0
            let flat = value.pitch < 2.5
            let key = "\(model.rawValue):\(value.paint.rawValue):\(flat ? 0 : Int((yaw / 5).rounded())):\(Int((value.pitch / 5).rounded())):\(value.night)"
            if imageKey != key {
                body.contents = NavigationMarkerArtwork.image(model: model, paint: value.paint,
                    bearing: flat ? 0 : yaw, pitch: value.pitch, night: value.night)
                imageKey = key
            }
            if body.contents == nil { body.isHidden = true }
            body.setAffineTransform(flat ? CGAffineTransform(rotationAngle: yaw * .pi / 180) : .identity)
        }
        direction.path = nil
        if value.model == nil, let bearing = value.direction {
            let angle = projectedAngle(bearing, pitch: value.pitch)
            let path = CGMutablePath()
            let points = [CGPoint(x: 0, y: -14), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 5), CGPoint(x: -10, y: 10)]
            path.addLines(between: points.map {
                CGPoint(x: center.x + ($0.x * cos(angle) - $0.y * sin(angle)) * value.scale,
                        y: center.y + ($0.x * sin(angle) + $0.y * cos(angle)) * value.scale)
            })
            path.closeSubpath()
            direction.path = path
            direction.fillColor = arrowColor(value.paint, night: value.night)
            let palePaint = value.paint == .pearl || value.paint == .silver
            direction.strokeColor = color(value.night ? 0xB8D3F3 : (palePaint ? 0x35414C : 0xFFFFFF))
                .copy(alpha: value.night ? 0.5 : (palePaint ? 0.65 : 0.8))
            direction.lineWidth = value.increasedContrast ? 1.5 : 0.7
            direction.shadowColor = color(value.night ? 0x87B3E6 : 0x102039)
            direction.shadowOpacity = value.night ? 0.18 : 0.12
            direction.shadowRadius = 1.5
        } else if value.model == nil {
            // Browsing / route preview still has a precise neutral position without inventing a heading.
            direction.path = CGPath(ellipseIn: CGRect(x: center.x - 3 * value.scale, y: center.y - 3 * value.scale,
                                                     width: 6 * value.scale, height: 6 * value.scale), transform: nil)
            direction.fillColor = locationColor
            direction.strokeColor = nil
            direction.shadowOpacity = 0
        }
        coneMask.path = nil
        // Integrated direction emerges from the ground anchor, never as a floating icon.
        if value.model != nil, let heading = value.deviceHeading ?? value.direction {
            let angle = projectedAngle(heading, pitch: value.pitch)
            let radius = (compactDetail ? 23 : 30) * value.scale
            let path = CGMutablePath()
            path.move(to: center)
            path.addArc(center: center, radius: radius,
                        startAngle: angle - .pi / 2 - 0.29, endAngle: angle - .pi / 2 + 0.29, clockwise: false)
            path.closeSubpath()
            cone.frame = CGRect(origin: .zero, size: size)
            coneMask.path = path
            coneMask.fillColor = color(0xFFFFFF)
            let strength = value.increasedContrast ? 0.25 : (value.night ? 0.17 : 0.12)
            cone.colors = [locationColor.copy(alpha: strength)!, locationColor.copy(alpha: strength * 0.65)!, locationColor.copy(alpha: 0)!]
            cone.locations = [0, 0.4, 1]
            cone.startPoint = CGPoint(x: 0.5, y: 0.5)
            cone.endPoint = CGPoint(x: 0.5 + sin(angle) * radius / canvas,
                                    y: 0.5 - cos(angle) * radius / canvas)
        }
        signal.path = nil
        if weak {
            // Pattern + exclamation mark supplements color; it is not an accuracy radius.
            let p = CGPoint(x: center.x + 17 * value.scale, y: center.y + 17 * value.scale)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: p.x, y: p.y - 4))
            path.addLine(to: CGPoint(x: p.x, y: p.y + 1))
            path.move(to: CGPoint(x: p.x, y: p.y + 3))
            path.addLine(to: CGPoint(x: p.x, y: p.y + 4))
            signal.path = path
            signal.strokeColor = statusColor
            signal.lineCap = .round
        }
        CATransaction.commit()
    }

    private func projectedAngle(_ degrees: Double, pitch: Double) -> Double {
        let angle = degrees * .pi / 180
        return atan2(sin(angle), cos(angle) * cos(pitch * .pi / 180))
    }
    private func color(_ hex: UInt32) -> CGColor {
        CGColor(red: Double((hex >> 16) & 255) / 255,
                green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    }

    private func arrowColor(_ paint: NavigationMarkerPaint, night: Bool) -> CGColor {
        if paint == .blue {
            return color(night ? NaviAstraColorPalette.userLocationNight : NaviAstraColorPalette.userLocationDay)
        }
        // Keep black legible on dark maps with the same restrained cool reflection as the models.
        let reflection = night && paint == .graphite ? 0.2 : 0.0
        let highlight: UInt32 = 0x8AA5C8
        func channel(_ shift: UInt32) -> Double {
            (Double((paint.hex >> shift) & 255) * (1 - reflection)
                + Double((highlight >> shift) & 255) * reflection) / 255
        }
        return CGColor(red: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }
}

/// The settings preview uses the very same native renderer as the map.
#if os(iOS)
struct NavigationMarkerPreview: UIViewRepresentable {
    var presentation: NavigationMarkerPresentation
    func makeUIView(context: Context) -> NavigationMarkerNativeView {
        NavigationMarkerNativeView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    func updateUIView(_ view: NavigationMarkerNativeView, context: Context) { view.update(presentation) }
}
#else
@MainActor
final class NavigationMarkerMapKitView: MKAnnotationView {
    private let marker = NavigationMarkerNativeView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        addSubview(marker)
        frame.size = marker.frame.size
    }
    required init?(coder: NSCoder) { fatalError("Use init(annotation:reuseIdentifier:)") }
    func update(_ presentation: NavigationMarkerPresentation) {
        marker.update(presentation)
        if frame.size != marker.frame.size { frame.size = marker.frame.size }
        centerOffset = .zero
        setAccessibilityLabel(presentation.accessibilityLabel)
    }
}

struct NavigationMarkerPreview: NSViewRepresentable {
    var presentation: NavigationMarkerPresentation
    func makeNSView(context: Context) -> NavigationMarkerNativeView {
        NavigationMarkerNativeView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    func updateNSView(_ view: NavigationMarkerNativeView, context: Context) { view.update(presentation) }
}
#endif
