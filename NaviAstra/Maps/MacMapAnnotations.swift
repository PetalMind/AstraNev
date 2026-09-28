#if os(macOS)
import AppKit
import MapKit
import QuartzCore
import SwiftUI

final class TransitStopMapAnnotationView: MKAnnotationView {
    private var shownPresentation: TransitStopMapPresentation?

    func render(_ presentation: TransitStopMapPresentation) {
        guard shownPresentation != presentation else { return }
        shownPresentation = presentation
        subviews.forEach { $0.removeFromSuperview() }
        let iconWidth = presentation.modes.count > 1
            ? CGFloat(presentation.modes.count) * 15 + 12 : CGFloat(presentation.markerSize)
        let iconHeight = CGFloat(presentation.markerSize)
        let titleHeight: CGFloat = presentation.name == nil ? 0 : 16
        let badgeHeight: CGFloat = presentation.showsAlightingBadge ? 17 : 0
        let titleWidth = presentation.name.map { CGFloat(min(170, max(60, $0.count * 7))) } ?? 0
        let contentWidth = max(iconWidth, titleWidth)
        frame = NSRect(x: 0, y: 0, width: contentWidth,
                       height: iconHeight + titleHeight + badgeHeight
                         + (titleHeight > 0 || badgeHeight > 0 ? 3 : 0))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 2
        if presentation.isActive && !presentation.isAlighting {
            let pulse = CABasicAnimation(keyPath: "shadowRadius")
            pulse.fromValue = 1.5
            pulse.toValue = 4
            pulse.duration = 1.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            layer?.add(pulse, forKey: "transit-active-stop-pulse")
        }

        let capsule = NSView(frame: NSRect(x: (contentWidth - iconWidth) / 2,
                                           y: frame.height - iconHeight,
                                           width: iconWidth, height: iconHeight))
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        capsule.layer?.cornerRadius = presentation.isMultimodal || presentation.modes.contains(.rail)
            ? iconHeight / 2 : 8
        capsule.layer?.borderWidth = presentation.isActive || presentation.isAlighting ? 3
            : presentation.isSelected || presentation.isOnRoute ? 2.5 : 1.5
        let accent: NSColor = presentation.isAlighting ? .systemPurple
            : presentation.isActive ? .systemOrange
            : presentation.isSelected ? .systemBlue
            : presentation.isOnRoute ? .systemTeal
            : transitMarkerColor(for: presentation.modes.first)
        capsule.layer?.borderColor = accent.cgColor
        addSubview(capsule)
        alphaValue = CGFloat(presentation.opacity)

        let imageSize: CGFloat = presentation.modes.count > 1 ? 13 : min(19, iconHeight * 0.58)
        let spacing: CGFloat = 1
        let symbolsWidth = CGFloat(presentation.modes.count) * imageSize
            + CGFloat(max(0, presentation.modes.count - 1)) * spacing
        var x = (iconWidth - symbolsWidth) / 2
        for mode in presentation.modes {
            let image = NSImageView(frame: NSRect(x: x, y: (iconHeight - imageSize) / 2,
                                                  width: imageSize, height: imageSize))
            image.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: imageSize, weight: .semibold))
            image.contentTintColor = transitMarkerColor(for: mode)
            image.imageScaling = .scaleProportionallyUpOrDown
            capsule.addSubview(image)
            x += imageSize + spacing
        }

        if presentation.showsAlightingBadge {
            let badge = NSTextField(labelWithString: "WYSIĄDŹ")
            badge.frame = NSRect(x: (contentWidth - 64) / 2, y: titleHeight + 1, width: 64, height: 14)
            badge.alignment = .center
            badge.font = .systemFont(ofSize: 8, weight: .bold)
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.systemPurple.cgColor
            badge.layer?.cornerRadius = 6
            addSubview(badge)
        }
        if let name = presentation.name {
            let label = NSTextField(labelWithString: name)
            label.frame = NSRect(x: 0, y: 0, width: contentWidth, height: titleHeight)
            label.alignment = .center
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
            label.layer?.cornerRadius = 5
            addSubview(label)
        }
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityRole(.button)
    }

    private func transitMarkerColor(for mode: TransitStopMode?) -> NSColor {
        guard let mode else { return .systemBlue }
        return NSColor(calibratedRed: CGFloat((mode.accentHex >> 16) & 0xff) / 255,
                       green: CGFloat((mode.accentHex >> 8) & 0xff) / 255,
                       blue: CGFloat(mode.accentHex & 0xff) / 255, alpha: 1)
    }
}

final class TrafficMapAnnotationView: MKAnnotationView {
    private var shownPresentation: TrafficMapPresentation?
    private var shownClusterCount: Int?
    private var shownNavigating = false
    private var selectedRoadSign = false

    var isShowingRoadSign: Bool { shownPresentation?.roadSign != nil }

    func render(presentation: TrafficMapPresentation, clusterCount: Int? = nil,
                isNavigating: Bool = false, isSelected: Bool = false) {
        shownPresentation = presentation
        shownClusterCount = clusterCount
        shownNavigating = isNavigating
        selectedRoadSign = isSelected
        subviews.forEach { $0.removeFromSuperview() }
        let roadSignSize = presentation.roadSign?.displaySize(isNavigating: isNavigating)
        let size = CGFloat(clusterCount == nil
            ? (roadSignSize.map { Double($0 + 8) } ?? presentation.markerSize)
            : 38)
        frame = NSRect(x: 0, y: 0, width: size, height: size)
        wantsLayer = true

        if let roadSign = presentation.roadSign, let roadSignSize {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.cornerRadius = 0
            layer?.borderWidth = 0
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.12
            layer?.shadowRadius = 2
            let artworkFrame = NSRect(x: (size - roadSignSize - 8) / 2,
                                      y: (size - roadSignSize - 8) / 2,
                                      width: roadSignSize + 8, height: roadSignSize + 8)
            let host = NSHostingView(rootView: RoadSignView(symbol: roadSign,
                                                            size: roadSignSize,
                                                            isSelected: isSelected))
            host.frame = artworkFrame
            host.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            host.alphaValue = presentation.isDirectionUncertain ? 0.66 : 1
            addSubview(host)

            if let clusterCount, clusterCount > 1 {
                let badge = NSTextField(labelWithString: "+\(clusterCount - 1)")
                badge.frame = NSRect(x: size - 20, y: size - 13, width: 20, height: 13)
                badge.alignment = .center
                badge.font = .boldSystemFont(ofSize: 8)
                badge.textColor = .white
                badge.wantsLayer = true
                badge.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor
                badge.layer?.cornerRadius = 6.5
                addSubview(badge)
            }
            canShowCallout = true
            clusteringIdentifier = clusterCount == nil ? "traffic-events" : nil
            displayPriority = .defaultHigh
            setAccessibilityLabel(annotation?.title ?? "Znak drogowy")
            setAccessibilityRole(.button)
            return
        }

        let color = NSColor(calibratedRed: CGFloat((presentation.colorHex >> 16) & 0xff) / 255,
                            green: CGFloat((presentation.colorHex >> 8) & 0xff) / 255,
                            blue: CGFloat(presentation.colorHex & 0xff) / 255, alpha: 1)
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = size / 2
        layer?.borderWidth = presentation.isCritical ? 2.5 : 1.5
        layer?.borderColor = (presentation.isCritical ? NSColor.systemRed : NSColor.white).cgColor
        layer?.shadowColor = (presentation.isCritical ? NSColor.systemRed : color).cgColor
        layer?.shadowOpacity = presentation.isCritical ? 0.48 : 0.24
        layer?.shadowRadius = presentation.isCritical ? 5 : 3

        if let clusterCount {
            let label = NSTextField(labelWithString: String(clusterCount))
            label.frame = NSRect(x: 0, y: 0, width: size, height: size)
            label.alignment = .center
            label.font = .boldSystemFont(ofSize: 15)
            label.textColor = .white
            addSubview(label)
            setAccessibilityLabel("\(clusterCount) zdarzeń drogowych")
        } else if let text = presentation.markerText {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 0, y: 0, width: size, height: size)
            label.alignment = .center
            label.font = .systemFont(ofSize: text.count > 2 ? 10 : 13, weight: .bold)
            label.textColor = .white
            addSubview(label)
        } else {
            let glyphSize = size * 0.54
            let image = NSImageView(frame: NSRect(x: (size - glyphSize) / 2,
                                                  y: (size - glyphSize) / 2,
                                                  width: glyphSize, height: glyphSize))
            image.image = NSImage(systemSymbolName: presentation.symbolName,
                                  accessibilityDescription: "Zdarzenie drogowe")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: glyphSize * 0.78,
                                                                     weight: .semibold))
            image.contentTintColor = .white
            image.imageScaling = .scaleProportionallyUpOrDown
            addSubview(image)
        }
        canShowCallout = true
        clusteringIdentifier = clusterCount == nil ? "traffic-events" : nil
        displayPriority = .defaultHigh
        setAccessibilityRole(.button)
    }

    func setRoadSignSelected(_ selected: Bool) {
        guard isShowingRoadSign, selectedRoadSign != selected,
              let shownPresentation else { return }
        render(presentation: shownPresentation, clusterCount: shownClusterCount,
               isNavigating: shownNavigating, isSelected: selected)
    }
}
#endif
