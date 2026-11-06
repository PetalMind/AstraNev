#if os(iOS)
import MapLibre
import UIKit

@MainActor
final class ParkedCarAnnotationView: MLNAnnotationView {
    private let surface = CAShapeLayer()
    private let icon = UIImageView()
    private let title = UILabel()
    private let timestamp = UILabel()

    func configure(timestamp text: String, parkedAt: Date, dark: Bool) {
        if surface.superlayer == nil {
            backgroundColor = .clear
            scalesWithViewingDistance = false
            layer.insertSublayer(surface, at: 0)
            surface.lineWidth = 1
            surface.shadowColor = UIColor.black.cgColor
            surface.shadowOpacity = 0.20
            surface.shadowRadius = 3
            surface.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(icon)
            addSubview(title)
            addSubview(timestamp)
            title.text = "Moje auto"
            icon.contentMode = .center
            icon.image = UIImage(systemName: "car.side.fill", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
            isAccessibilityElement = true
            accessibilityTraits = .button
            accessibilityLabel = "Zaparkowany samochód"
            accessibilityHint = "Otwiera kartę samochodu z opcją dojścia pieszo"
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ParkedCarAnnotationView, _) in
                view.layoutBadge()
            }
        }
        timestamp.text = text
        accessibilityValue = PolishRegionalFormat.dateTime(parkedAt)
        applyMapAppearance(dark: dark)
        layoutBadge()
    }

    func applyMapAppearance(dark: Bool) {
        surface.fillColor = UIColor(naviHex: PlacePOIMapPalette.backgroundHex(dark: dark)).cgColor
        let rim = dark ? UIColor.white : UIColor(naviHex: NaviAstraColorPalette.textPrimaryDay)
        surface.strokeColor = rim.withAlphaComponent(dark ? 0.32 : 0.20).cgColor
        icon.backgroundColor = UIColor(naviHex: PlacePOIMapMarkerKind.parking.colorHex(dark: dark))
        icon.tintColor = dark ? UIColor(naviHex: NaviAstraColorPalette.navigationSurface) : .white
        title.textColor = UIColor(naviHex: dark ? NaviAstraColorPalette.textSecondaryNight : NaviAstraColorPalette.textSecondaryDay)
        timestamp.textColor = UIColor(naviHex: dark ? NaviAstraColorPalette.textPrimaryNight : NaviAstraColorPalette.textPrimaryDay)
    }

    private func layoutBadge() {
        title.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 11, weight: .medium), compatibleWith: traitCollection)
        timestamp.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold), compatibleWith: traitCollection)
        title.sizeToFit()
        timestamp.sizeToFit()
        let textHeight = title.bounds.height + 1 + timestamp.bounds.height
        let bodyHeight = max(42, textHeight + 10)
        let textX: CGFloat = 45
        let width = ceil(textX + max(title.bounds.width, timestamp.bounds.width) + 10)
        let height = bodyHeight + 6
        bounds.size = CGSize(width: width, height: height)
        centerOffset = CGVector(dx: 0, dy: -(height / 2) + 0.5)
        icon.frame = CGRect(x: 6, y: (bodyHeight - 32) / 2, width: 32, height: 32)
        icon.layer.cornerRadius = 16
        title.frame.origin = CGPoint(x: textX, y: (bodyHeight - textHeight) / 2)
        timestamp.frame.origin = CGPoint(x: textX, y: title.frame.maxY + 1)

        // The tip and the label share a single outline, with the tip on the map coordinate.
        let left: CGFloat = 0.5, top: CGFloat = 0.5, right = width - 0.5, bottom = bodyHeight - 0.5
        let middle = width / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: middle + 5, y: bottom))
        path.addLine(to: CGPoint(x: middle, y: height - 0.5))
        path.addLine(to: CGPoint(x: middle - 5, y: bottom))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: top), radius: 15)
        path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: right, y: top), radius: 15)
        path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: bottom), radius: 15)
        path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: left, y: bottom), radius: 15)
        path.closeSubpath()
        surface.path = path
        surface.shadowPath = path
    }
}
#endif
