import SwiftUI

enum ARLaunchReadiness: Equatable {
    case checking
    case ready
    case unavailable(String)

    var color: Color {
        switch self {
        case .checking: .orange
        case .ready: .green
        case .unavailable: .gray
        }
    }

    var explanation: String {
        switch self {
        case .checking: "Sprawdzam dostępność AR"
        case .ready: "Nawigacja AR jest gotowa do uruchomienia"
        case let .unavailable(reason): reason
        }
    }
}

#if os(iOS)
import ARKit
import CoreLocation
import RealityKit
import AVFoundation
import UIKit
import simd

struct ARNavigationView: View {
    let route: NavigationRoute
    let progress: RouteProgress?
    let location: NavigationLocation?
    let onClose: () -> Void

    @State private var cameraGranted = false
    @State private var geoAvailable = false
    @State private var geoLocalized = false
    @State private var message: String?

    private var arrowCoordinates: [ARArrowPoint] {
        guard !route.coordinates.isEmpty else { return [] }
        let fraction = progress?.geometryRouteID == route.id ? progress?.geometryProgress ?? 0 : 0
        let startIndex = min(route.coordinates.count - 1,
                             max(0, Int(Double(route.coordinates.count - 1) * fraction)))
        let candidates = Array(route.coordinates.dropFirst(startIndex))
        guard let current = location?.coordinate else { return [] }
        let nearby = candidates.filter { current.distance(to: $0) >= 10 && current.distance(to: $0) <= 250 }
        return nearby.enumerated().compactMap { index, coordinate -> ARArrowPoint? in
            guard index.isMultiple(of: 3), nearby.indices.contains(index + 1) else { return nil }
            return ARArrowPoint(coordinate: coordinate,
                                bearing: Self.bearing(from: coordinate, to: nearby[index + 1]))
        }.prefix(8).map { $0 }
    }

    private static func bearing(from start: Coordinate, to end: Coordinate) -> Double {
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2) - sin(latitude1) * cos(latitude2) * cos(longitudeDelta)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cameraGranted && geoAvailable, let location {
                ARGeoScene(coordinates: arrowCoordinates,
                           localized: $geoLocalized,
                           failure: {
                    message = $0
                    geoAvailable = false
                })
                    .ignoresSafeArea()
                if !geoLocalized {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Ustalanie położenia AR…")
                            .font(.headline)
                        Text("Stań w miejscu i skieruj telefon na otoczenie.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
                }
                VStack {
                    HStack {
                        Button(action: onClose) {
                            Label("Mapa", systemImage: "map.fill")
                                .font(.headline)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer()
                    }
                    Spacer()
                    maneuverCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            } else {
                unavailableView
            }
        }
        .preferredColorScheme(.dark)
        .task { await prepareAR() }
    }

    private var maneuverCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: progress?.nextManeuver?.iconName ?? "arrow.up")
                    .font(.system(size: 28, weight: .bold))
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress?.nextManeuver?.displayInstruction ?? "Idź wyznaczoną trasą")
                        .font(.headline)
                    Text(distanceText(progress?.nextManeuver == nil
                                      ? progress?.remainingDistance ?? 0
                                      : progress?.distanceToNextManeuver ?? 0))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.primary)
    }

    private var unavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder").font(.system(size: 42)).foregroundStyle(.orange)
            Text(message ?? "Nawigacja AR jest niedostępna")
                .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("Możesz kontynuować prowadzenie na mapie.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Wróć do mapy", action: onClose)
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .foregroundStyle(.white)
    }

    @MainActor
    private func prepareAR() async {
        guard ARGeoTrackingConfiguration.isSupported else {
            message = "To urządzenie nie obsługuje pozycjonowania AR."
            return
        }
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let granted: Bool
        if authorization == .authorized {
            granted = true
        } else if authorization == .notDetermined {
            granted = await AVCaptureDevice.requestAccess(for: .video)
        } else {
            granted = false
        }
        guard granted else {
            message = "Zezwól aplikacji na dostęp do kamery w Ustawieniach."
            return
        }
        guard let location else {
            message = "Oczekiwanie na dokładną pozycję GPS."
            return
        }
        guard location.accuracy >= 0, location.accuracy <= 25,
              Date().timeIntervalSince(location.timestamp) <= 15 else {
            message = "Pozycja GPS jest zbyt niedokładna dla strzałek AR. Wróć do mapy i spróbuj ponownie."
            return
        }
        guard arrowCoordinates.count >= 1 else {
            message = "Nie ma pewnego odcinka trasy przed Tobą, który można oznaczyć w AR."
            return
        }
        cameraGranted = true
        let available = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ARGeoTrackingConfiguration.checkAvailability(at: location.coordinate.cl) { available, error in
                continuation.resume(returning: available && error == nil)
            }
        }
        guard !Task.isCancelled else { return }
        geoAvailable = available
        if !available {
            cameraGranted = false
            message = "Pozycjonowanie AR nie jest dostępne w tej okolicy."
        }
    }

    private func distanceText(_ meters: Double) -> String {
        if meters >= 1000 { return String(format: "Za %.1f km", meters / 1000) }
        return "Za \(Int(meters.rounded())) m"
    }
}

private struct ARGeoScene: UIViewRepresentable {
    let coordinates: [ARArrowPoint]
    @Binding var localized: Bool
    let failure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(localized: $localized, failure: failure) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.session.delegate = context.coordinator
        let configuration = ARGeoTrackingConfiguration()
        view.session.run(configuration)
        context.coordinator.updateAnchors(in: view, coordinates: coordinates)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.localized = $localized
        context.coordinator.updateAnchors(in: view, coordinates: coordinates)
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        view.session.pause()
        view.scene.anchors.removeAll()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        var localized: Binding<Bool>
        let failure: (String) -> Void
        private var coordinateSignature = ""
        private var geoAnchors: [ARGeoAnchor] = []

        init(localized: Binding<Bool>, failure: @escaping (String) -> Void) {
            self.localized = localized
            self.failure = failure
        }

        func updateAnchors(in view: ARView, coordinates: [ARArrowPoint]) {
            let signature = coordinates.map { "\($0.coordinate.latitude),\($0.coordinate.longitude),\($0.bearing)" }.joined(separator: "|")
            guard signature != coordinateSignature else { return }
            coordinateSignature = signature
            geoAnchors.forEach { view.session.remove(anchor: $0) }
            geoAnchors.removeAll()
            view.scene.anchors.removeAll()
            for (index, point) in coordinates.enumerated() {
                let anchor = ARGeoAnchor(coordinate: point.coordinate.cl)
                let root = AnchorEntity(anchor: anchor)
                let arrow = Self.arrowEntity(color: index == 0 ? .systemBlue : .white)
                arrow.orientation = simd_quatf(angle: Float(point.bearing * .pi / 180), axis: [0, 1, 0])
                root.addChild(arrow)
                view.scene.addAnchor(root)
                view.session.add(anchor: anchor)
                geoAnchors.append(anchor)
            }
        }

        func session(_ session: ARSession, didChange geoTrackingStatus: ARGeoTrackingStatus) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.localized.wrappedValue = geoTrackingStatus.state == .localized
                if geoTrackingStatus.state == .notAvailable {
                    self.failure("Nie udało się ustalić położenia strzałek. Wróć do mapy i spróbuj ponownie na otwartej przestrzeni.")
                }
            }
        }

        private static func arrowEntity(color: UIColor) -> ModelEntity {
            let material = SimpleMaterial(color: color, roughness: 0.35, isMetallic: false)
            let shaft = ModelEntity(mesh: .generateBox(size: [0.45, 0.08, 1.4]), materials: [material])
            shaft.position.y = 0.12
            let tip = ModelEntity(mesh: .generateCone(height: 0.8, radius: 0.45), materials: [material])
            tip.position = [0, 0.12, -0.95]
            tip.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            let arrow = ModelEntity()
            arrow.addChild(shaft)
            arrow.addChild(tip)
            return arrow
        }
    }
}

private struct ARArrowPoint {
    let coordinate: Coordinate
    let bearing: Double
}

enum ARLaunchReadinessChecker {
    static func check(location: NavigationLocation?, route: NavigationRoute?, progress: RouteProgress?) async -> ARLaunchReadiness {
        guard ARGeoTrackingConfiguration.isSupported else {
            return .unavailable("To urządzenie nie obsługuje AR Geo Tracking")
        }
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard cameraStatus != .denied, cameraStatus != .restricted else {
            return .unavailable("Brak dostępu do kamery")
        }
        guard let location,
              location.accuracy >= 0, location.accuracy <= 25,
              Date().timeIntervalSince(location.timestamp) <= 15 else {
            return .unavailable("Wymagany jest świeży GPS o dokładności do 25 m")
        }
        guard let route, route.coordinates.count > 1 else {
            return .unavailable("Brak geometrii trasy do wyświetlenia")
        }
        let fraction = progress?.geometryRouteID == route.id ? progress?.geometryProgress ?? 0 : 0
        let index = min(route.coordinates.count - 1,
                        max(0, Int(Double(route.coordinates.count - 1) * fraction)))
        let nextPoints = route.coordinates.dropFirst(index).filter {
            let distance = location.coordinate.distance(to: $0)
            return distance >= 10 && distance <= 250
        }
        guard nextPoints.count >= 2 else {
            return .unavailable("Brak dokładnego odcinka trasy przed bieżącą pozycją")
        }
        let available = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ARGeoTrackingConfiguration.checkAvailability(at: location.coordinate.cl) { available, error in
                continuation.resume(returning: available && error == nil)
            }
        }
        return available
            ? .ready
            : .unavailable("AR Geo Tracking nie jest dostępny w tej okolicy lub brak połączenia")
    }
}
#else
struct ARNavigationView: View {
    let route: NavigationRoute
    let progress: RouteProgress?
    let location: NavigationLocation?
    let onClose: () -> Void

    var body: some View { EmptyView() }
}
#endif
