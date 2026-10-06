#if os(iOS)
import MapLibre
import Observation
import SwiftUI
import UIKit

@MainActor @Observable
private final class TripMapThumbnailModel: NSObject, MLNMapSnapshotterDelegate {
    var image: UIImage?
    var failed = false
    @ObservationIgnored private var snapshotter: MLNMapSnapshotter?
    @ObservationIgnored private var generation = 0
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    func load(trip: TripRecord) {
        cancel()
        image = nil
        failed = false
        let segments = trip.traceSegments.filter { $0.coordinates.count > 1 }
        let coordinates = segments.flatMap(\.coordinates).filter {
            $0.latitude.isFinite && $0.longitude.isFinite
                && (-85...85).contains($0.latitude) && (-180...180).contains($0.longitude)
        }
        guard coordinates.count > 1 else { failed = true; return }
        var hasher = Hasher()
        hasher.combine(trip.id)
        for segment in segments {
            hasher.combine(segment.id)
            for point in segment.coordinates {
                hasher.combine(point.latitude)
                hasher.combine(point.longitude)
            }
        }
        let cacheKey = String(hasher.finalize())
        if let cached = Self.cache.object(forKey: cacheKey as NSString) { image = cached; return }
        let latitudes = coordinates.map(\.latitude), longitudes = coordinates.map(\.longitude)
        let south = latitudes.min()!, north = latitudes.max()!
        let west = longitudes.min()!, east = longitudes.max()!
        let latitudePadding = max(0.002, (north - south) * 0.15)
        let longitudePadding = max(0.002, (east - west) * 0.15)
        let camera = MLNMapCamera(lookingAtCenter: CLLocationCoordinate2D(
            latitude: (south + north) / 2, longitude: (west + east) / 2), altitude: 10_000, pitch: 0, heading: 0)
        let options = MLNMapSnapshotOptions(styleURL: MapResourceConfiguration.url, camera: camera,
                                            size: CGSize(width: 160, height: 100))
        options.coordinateBounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: max(-85, south - latitudePadding),
                                        longitude: max(-180, west - longitudePadding)),
            ne: CLLocationCoordinate2D(latitude: min(85, north + latitudePadding),
                                        longitude: min(180, east + longitudePadding)))
        let renderer = MLNMapSnapshotter(options: options)
        renderer.delegate = self
        // Segment boundaries preserve GPS gaps instead of drawing invented connections.
        renderer.add(segments.map { segment in
            var points = segment.coordinates
            return MLNPolyline(coordinates: &points, count: UInt(points.count))
        })
        snapshotter = renderer
        let requestGeneration = generation
        renderer.start { [weak self] snapshot, error in
            MainActor.assumeIsolated {
                guard let self, self.generation == requestGeneration else { return }
                self.snapshotter = nil
                if let snapshot, error == nil {
                    self.image = snapshot.image
                    Self.cache.setObject(snapshot.image, forKey: cacheKey as NSString,
                        cost: Int(snapshot.image.size.width * snapshot.image.size.height
                                  * snapshot.image.scale * snapshot.image.scale * 4))
                } else { self.failed = true }
            }
        }
    }

    func cancel() {
        generation &+= 1
        snapshotter?.cancel()
        snapshotter = nil
    }

    func mapSnapshotter(_ snapshotter: MLNMapSnapshotter,
                       strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
        UIColor(naviHex: NaviAstraColorPalette.navigationActiveDay)
    }

    func mapSnapshotter(_ snapshotter: MLNMapSnapshotter,
                       lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat { 4 }
}

struct TripMapThumbnail: View {
    let trip: TripRecord
    @State private var model = TripMapThumbnailModel()

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.1)
            if let image = model.image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if model.failed {
                Image(systemName: "map").foregroundStyle(.secondary)
            } else { ProgressView() }
        }
        .frame(width: 96, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
        .onAppear { model.load(trip: trip) }
        .onDisappear { model.cancel() }
    }
}
#endif
