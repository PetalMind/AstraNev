#if os(iOS)
import MapLibre
import SwiftUI
import UIKit

struct OfflineAreaCameraRequest: Equatable {
    var id = UUID()
    let bounds: OfflineMapBounds
}

private final class OfflineAreaNativeMap: MLNMapView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// A north-up map ensures the highlighted screen rectangle matches the downloaded bounds.
struct OfflineAreaMap: UIViewRepresentable {
    let cameraRequest: OfflineAreaCameraRequest
    let route: [Coordinate]
    let onSelection: (OfflineMapBounds?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = OfflineAreaNativeMap(frame: .zero, styleURL: MapResourceConfiguration.url)
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.automaticallyAdjustsContentInset = false
        map.preferredFramesPerSecond = MLNMapViewPreferredFramesPerSecond(rawValue: 30)
        map.onLayout = { [weak map, weak coordinator = context.coordinator] in
            guard let map, let coordinator else { return }
            coordinator.applyCamera(on: map)
            coordinator.publishSelection(on: map)
        }
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.dropPin(_:)))
        map.addGestureRecognizer(press)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyCamera(on: map)
    }

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        map.delegate = nil
        (map as? OfflineAreaNativeMap)?.onLayout = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: OfflineAreaMap
        weak var map: MLNMapView?
        private var appliedRequest: UUID?
        private var lastSelection: OfflineMapBounds?
        private var selectionGeneration = 0
        private var pin: MLNPointAnnotation?

        init(_ parent: OfflineAreaMap) { self.parent = parent }

        func applyCamera(on map: MLNMapView) {
            guard map.bounds.width > 80, map.bounds.height > 100,
                  appliedRequest != parent.cameraRequest.id, parent.cameraRequest.bounds.isValid else { return }
            appliedRequest = parent.cameraRequest.id
            lastSelection = nil
            map.setVisibleCoordinateBounds(parent.cameraRequest.bounds.mapLibreBounds,
                edgePadding: UIEdgeInsets(top: 52, left: 40, bottom: 52, right: 40), animated: false,
                completionHandler: nil)
            publishSelection(on: map)
        }

        func publishSelection(on map: MLNMapView) {
            guard appliedRequest != nil, map.bounds.width > 80, map.bounds.height > 100 else { return }
            let rect = map.bounds.insetBy(dx: 28, dy: 40)
            let sw = map.convert(CGPoint(x: rect.minX, y: rect.maxY), toCoordinateFrom: map)
            let ne = map.convert(CGPoint(x: rect.maxX, y: rect.minY), toCoordinateFrom: map)
            let bounds = OfflineMapBounds(south: sw.latitude, west: sw.longitude, north: ne.latitude, east: ne.longitude)
            let selection = bounds.isValid ? bounds : nil
            guard selection != lastSelection else { return }
            lastSelection = selection
            selectionGeneration &+= 1
            let generation = selectionGeneration
            // Map callbacks also occur during SwiftUI layout; publish after that update finishes.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionGeneration == generation else { return }
                self.parent.onSelection(selection)
            }
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) { publishSelection(on: mapView) }
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { publishSelection(on: mapView) }
        func mapViewDidBecomeIdle(_ mapView: MLNMapView) { publishSelection(on: mapView) }

        @objc func dropPin(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            if let pin { map.removeAnnotation(pin) }
            let marker = MLNPointAnnotation()
            marker.coordinate = coordinate
            marker.title = "Wybrane miejsce"
            pin = marker
            map.addAnnotation(marker)
            map.setCenter(coordinate, animated: true)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            guard parent.route.count > 1 else { return }
            var points = parent.route.map(\.cl)
            let feature = MLNPolylineFeature(coordinates: &points, count: UInt(points.count))
            let source = MLNShapeSource(identifier: "offline-area-route-source", shape: feature, options: nil)
            style.addSource(source)
            let layer = MLNLineStyleLayer(identifier: "offline-area-route", source: source)
            layer.lineColor = NSExpression(forConstantValue: UIColor(naviHex: NaviAstraColorPalette.navigationActiveDay))
            layer.lineWidth = NSExpression(forConstantValue: 4)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(layer)
        }
    }
}

struct OfflineAreaSelectionMask: View {
    var body: some View {
        GeometryReader { geometry in
            let rectangle = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 28, dy: 40)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: geometry.size))
                path.addRect(rectangle)
            }
            .fill(.black.opacity(0.38), style: FillStyle(eoFill: true))
            Rectangle().stroke(.white, lineWidth: 3).padding(.horizontal, 28).padding(.vertical, 40)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
