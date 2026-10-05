import SwiftUI

enum ARLaunchReadiness: Equatable {
    case checking
    case ready
    case unavailable(String)

    var color: Color {
        switch self {
        case .checking: Color(naviHex: NaviAstraColorPalette.warning)
        case .ready: Color(naviHex: NaviAstraColorPalette.success)
        case .unavailable: Color.naviTextInactive
        }
    }

    var explanation: String {
        switch self {
        case .checking: "Sprawdzam dostępność AR"
        case .ready: "AR jest dostępne. Dokładność zostanie oceniona po uruchomieniu kamery."
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

private enum ARGuidanceMode: Equatable {
    case local, geographic
    var title: String { self == .geographic ? "AR geograficzne" : "AR · GPS i kompas" }
}

struct ARNavigationView: View {
    let route: NavigationRoute
    let progress: RouteProgress?
    let location: NavigationLocation?
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraGranted = false
    @State private var cameraChecked = false
    @State private var mode: ARGuidanceMode = .local
    @State private var trackingMessage: String? = "Skieruj telefon na otoczenie."
    @State private var geoMessage: String?
    @State private var sessionFailed = false
    @State private var geometry: RouteProgressGeometry?

    private var currentProgress: RouteProgress? {
        progress?.geometryRouteID == route.id ? progress : nil
    }

    private var availabilityKey: String {
        guard cameraGranted, scenePhase == .active, let location,
              ARRouteGuidance.hasUsableLocation(location) else { return "waiting" }
        // Recheck regional coverage after about a kilometre, not every GPS fix.
        return "\(Int(location.coordinate.latitude * 100)):\(Int(location.coordinate.longitude * 100))"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cameraGranted, ARWorldTrackingConfiguration.isSupported {
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    let points = geometry.flatMap { geometry -> [ARArrowPoint]? in
                        guard geometry.routeID == route.id else { return nil }
                        return ARRouteGuidance.points(geometry: geometry, progress: currentProgress,
                                               location: location, at: clock.date)
                    } ?? []
                    ZStack {
                        if scenePhase == .active, !sessionFailed {
                            ARGuidanceScene(mode: mode, points: points, location: location,
                                            trackingMessage: $trackingMessage,
                                            failure: handleSessionFailure)
                                .ignoresSafeArea()
                        }
                        LinearGradient(colors: [.black.opacity(0.6), .clear, .black.opacity(0.65)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea().allowsHitTesting(false)
                        cameraOverlay(points: points, at: clock.date)
                    }
                }
            } else {
                unavailableView
            }
        }
        .preferredColorScheme(.dark)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await prepareCamera()
        }
        .task(id: route.id) {
            let routeSnapshot = route
            let prepared = await Task.detached(priority: .userInitiated) {
                RouteProgressGeometry(routeSnapshot)
            }.value
            guard !Task.isCancelled else { return }
            geometry = prepared
        }
        .task(id: availabilityKey) {
            guard availabilityKey != "waiting", let location else { return }
            await selectGeographicMode(at: location.coordinate)
        }
    }

    private func cameraOverlay(points: [ARArrowPoint], at now: Date) -> some View {
        VStack(spacing: 14) {
            HStack {
                Button(action: onClose) {
                    Label("Mapa", systemImage: "map.fill")
                        .font(.headline)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .modifier(NavigationStableSurface(radius: 24))
                }
                .accessibilityLabel("Wróć do mapy")
                Spacer()
                Label(mode.title, systemImage: mode == .geographic ? "viewfinder" : "location.north.circle")
                    .font(.caption.weight(.semibold))
                    .padding(12)
                    .modifier(NavigationStableSurface(radius: 24))
            }
            if let status = statusMessage(points: points, at: now) {
                messageCard(status, symbol: "location.magnifyingglass")
            }
            Spacer(minLength: 0)
            if mode == .local {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wskazówki orientacyjne").font(.subheadline.weight(.semibold))
                    Text("\(gpsAccuracyText) · Strzałki nie wyznaczają dokładnej pozycji chodnika.")
                        .font(.caption)
                    if let geoMessage { Text(geoMessage).font(.caption) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(NavigationStableSurface(radius: 18))
            }
            maneuverCard
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
        .foregroundStyle(Color.naviTextPrimary)
    }

    private var gpsAccuracyText: String {
        guard let location, location.accuracy.isFinite, (0...25).contains(location.accuracy) else {
            return "Dokładność GPS niedostępna"
        }
        return "GPS ±\(Int(location.accuracy.rounded())) m"
    }

    private func statusMessage(points: [ARArrowPoint], at now: Date) -> String? {
        if sessionFailed { return "Śledzenie AR zostało przerwane. Wróć do mapy lub spróbuj ponownie." }
        guard ARRouteGuidance.hasUsableLocation(location, at: now) else {
            return "Oczekiwanie na świeży GPS o dokładności do 25 m. Strzałki są ukryte."
        }
        if points.isEmpty { return "Brak pewnego odcinka trasy przed Tobą. Kontynuuj według mapy i instrukcji." }
        return trackingMessage
    }

    private func messageCard(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3)
                .foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
            Text(text).font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NavigationStableSurface(radius: 20))
    }

    private var maneuverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ManeuverIcon(type: currentProgress?.nextManeuver?.type,
                             fallbackSymbol: currentProgress?.nextManeuver?.iconName ?? "figure.walk", size: 34, roundabout: currentProgress?.nextManeuver?.roundabout)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    if let distance = currentProgress.map({ $0.nextManeuver == nil ? $0.remainingDistance : $0.distanceToNextManeuver }) {
                        Text(distanceText(distance)).font(.title2.bold().monospacedDigit())
                    }
                    Text(currentProgress?.nextManeuver?.displayInstruction ?? "Idź wyznaczoną trasą")
                        .font(.headline).fixedSize(horizontal: false, vertical: true)
                }
            }
            if sessionFailed {
                Button("Spróbuj ponownie") {
                    trackingMessage = "Ponowne uruchamianie śledzenia…"
                    sessionFailed = false
                }.buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NavigationStableSurface(radius: 24))
    }

    private var unavailableView: some View {
        VStack(spacing: 20) {
            Image(systemName: "viewfinder").font(.system(size: 44))
            if !cameraChecked {
                ProgressView("Przygotowywanie kamery…")
            } else {
                Text(cameraGranted ? "To urządzenie nie obsługuje śledzenia AR."
                     : "Zezwól aplikacji na dostęp do kamery w Ustawieniach.")
                    .multilineTextAlignment(.center)
                if !cameraGranted {
                    Button("Otwórz Ustawienia") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }.buttonStyle(.bordered)
                }
            }
            Button("Wróć do mapy", action: onClose).buttonStyle(.borderedProminent)
        }
        .padding(28).foregroundStyle(.white)
    }

    @MainActor private func prepareCamera() async {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let granted = authorization == .notDetermined
            ? await AVCaptureDevice.requestAccess(for: .video)
            : authorization == .authorized
        guard !Task.isCancelled else { return }
        cameraGranted = granted
        cameraChecked = true
    }

    @MainActor private func selectGeographicMode(at coordinate: Coordinate) async {
        guard ARGeoTrackingConfiguration.isSupported else {
            geoMessage = "Tryb GPS działa bez Apple Geo Tracking."
            return
        }
        let available = await ARGeoAvailabilityProbe().check(at: coordinate)
        guard !Task.isCancelled else { return }
        if available {
            mode = .geographic
            trackingMessage = "Ustalanie położenia AR. Stań i skieruj telefon na otoczenie."
            geoMessage = nil
        } else {
            mode = .local
            geoMessage = "Brak dostępnego pozycjonowania Apple w tej okolicy."
        }
    }

    private func handleSessionFailure(_ reason: String) {
        if mode == .geographic {
            mode = .local
            geoMessage = reason
            trackingMessage = "Ustalanie kierunku z GPS i kompasu…"
        } else {
            trackingMessage = reason
            sessionFailed = true
        }
    }

    private func distanceText(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "Dystans niedostępny" }
        if meters >= 1000 { return String(format: "Za %.1f km", meters / 1000) }
        return "Za \(Int(meters.rounded())) m"
    }
}

/// Bounds Apple's callback API so a missing network response cannot block AR.
@MainActor private final class ARGeoAvailabilityProbe {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?

    func check(at coordinate: Coordinate) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [self] in
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                self.finish(false)
            }
            ARGeoTrackingConfiguration.checkAvailability(at: coordinate.cl) { [weak self] available, error in
                let result = available && error == nil
                Task { @MainActor in self?.finish(result) }
            }
        }
    }

    private func finish(_ result: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: result)
    }
}

/// ARKit session commands can block while camera and tracking resources start.
/// This queue owns run/pause ordering, including a dismissal during startup.
nonisolated private final class ARSessionCommands: @unchecked Sendable {
    private struct RunRequest: @unchecked Sendable {
        let configuration: ARConfiguration
        let options: ARSession.RunOptions
    }

    private let session: ARSession
    private let queue = DispatchQueue(label: "NaviAstra.AR.session", qos: .userInitiated)

    init(session: ARSession) { self.session = session }

    func run(_ configuration: ARConfiguration, options: ARSession.RunOptions = []) {
        let request = RunRequest(configuration: configuration, options: options)
        queue.async { [self, request] in
            session.run(request.configuration, options: request.options)
        }
    }

    func pause() {
        queue.async { [self] in session.pause() }
    }
}

private struct ARGuidanceScene: UIViewRepresentable {
    let mode: ARGuidanceMode
    let points: [ARArrowPoint]
    let location: NavigationLocation?
    @Binding var trackingMessage: String?
    let failure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, trackingMessage: $trackingMessage, failure: failure)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        context.coordinator.view = view
        view.session.delegateQueue = .main
        view.session.delegate = context.coordinator
        context.coordinator.startSession()
        context.coordinator.update(mode: mode, points: points, location: location)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.trackingMessage = $trackingMessage
        context.coordinator.update(mode: mode, points: points, location: location)
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.stop()
        view.session.delegate = nil
        view.scene.anchors.removeAll()
    }

    final class Coordinator: NSObject, ARSessionDelegate, CLLocationManagerDelegate {
        weak var view: ARView?
        var trackingMessage: Binding<String?>
        private var mode: ARGuidanceMode
        private let failure: (String) -> Void
        private let headingManager = CLLocationManager()
        private var heading: CLHeading?
        private var points: [ARArrowPoint] = []
        private var location: NavigationLocation?
        private var displayedPoints: [ARArrowPoint] = []
        private var geoAnchors: [ARGeoAnchor] = []
        private var roots: [AnchorEntity] = []
        private var origin: NavigationLocation?
        private var originPosition: SIMD3<Float> = .zero
        private var groundHeight: Float?
        private var groundPlaneID: UUID?
        private var normalTracking = false
        private var geoLocalized = false
        private var active = true
        private var interrupted = false
        private var hasFailed = false
        private var lastFrameUpdate: TimeInterval = 0
        private var geoStartedAt = Date()
        private var sessionCommands: ARSessionCommands?

        init(mode: ARGuidanceMode, trackingMessage: Binding<String?>, failure: @escaping (String) -> Void) {
            self.mode = mode
            self.trackingMessage = trackingMessage
            self.failure = failure
        }

        func startSession(resetTracking: Bool = false) {
            guard active, let view else { return }
            if sessionCommands == nil { sessionCommands = ARSessionCommands(session: view.session) }
            let configuration: ARConfiguration
            if mode == .geographic {
                let geographic = ARGeoTrackingConfiguration()
                geographic.planeDetection = [.horizontal]
                configuration = geographic
                geoStartedAt = Date()
            } else {
                let local = ARWorldTrackingConfiguration()
                local.worldAlignment = .gravityAndHeading
                local.planeDetection = [.horizontal]
                configuration = local
                startHeading()
            }
            sessionCommands?.run(configuration, options: resetTracking ? [.resetTracking, .removeExistingAnchors] : [])
        }

        func startHeading() {
            headingManager.delegate = self
            headingManager.headingFilter = 3
            headingManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            headingManager.distanceFilter = 100
            // True north requires location updates. App navigation remains the GPS source.
            headingManager.startUpdatingLocation()
            headingManager.startUpdatingHeading()
        }

        func stop() {
            active = false
            sessionCommands?.pause()
            headingManager.stopUpdatingHeading()
            headingManager.stopUpdatingLocation()
            headingManager.delegate = nil
        }

        func update(mode requestedMode: ARGuidanceMode, points: [ARArrowPoint], location: NavigationLocation?) {
            if mode != requestedMode {
                headingManager.stopUpdatingHeading()
                headingManager.stopUpdatingLocation()
                clearAnchors()
                mode = requestedMode
                normalTracking = false
                geoLocalized = false
                hasFailed = false
                interrupted = false
                heading = nil
                lastFrameUpdate = 0
                groundHeight = nil
                groundPlaneID = nil
                startSession(resetTracking: true)
            }
            self.points = points
            self.location = location
            refresh()
        }

        private func refresh() {
            guard active, let view else { return }
            let now = Date()
            let usableGPS = ARRouteGuidance.hasUsableLocation(location, at: now)
            let usableHeading = heading.map {
                $0.trueHeading >= 0 && $0.headingAccuracy >= 0 && $0.headingAccuracy <= 20
                    && (0...10).contains(now.timeIntervalSince($0.timestamp))
            } ?? false
            updateGroundLevel(from: view.session.currentFrame)
            let visible = groundHeight != nil && !hasFailed && !interrupted && normalTracking && usableGPS && !points.isEmpty
                && (mode == .geographic ? geoLocalized : usableHeading)
            roots.forEach { $0.isEnabled = visible }
            let status: String?
            if interrupted {
                status = "Kamera jest chwilowo niedostępna. Strzałki są ukryte."
            } else if !normalTracking {
                status = "Skieruj telefon na dobrze oświetlone otoczenie i poruszaj nim powoli."
            } else if mode == .local && !usableHeading {
                status = "Oczekiwanie na dokładny kompas. Odsuń telefon od metalowych przedmiotów."
            } else if mode == .geographic && !geoLocalized {
                status = "Ustalanie położenia AR. Stań i skieruj telefon na budynki wokół."
            } else if groundHeight == nil {
                status = "Skieruj kamerę na ziemię i poruszaj telefonem powoli, aby ułożyć strzałki na podłożu."
            } else {
                status = nil
            }
            publish(status)
            if mode == .geographic, !geoLocalized, now.timeIntervalSince(geoStartedAt) > 20 {
                fail("Pozycjonowanie Apple trwa zbyt długo. Włączono GPS i kompas.")
                return
            }
            guard visible else {
                // Remove old guidance on GPS loss, route end or rerouting.
                if !usableGPS || points.isEmpty { clearAnchors() }
                return
            }
            if mode == .local, let location, let frame = view.session.currentFrame {
                let shouldRebase = origin.map {
                    location.timestamp.timeIntervalSince($0.timestamp) >= 20
                        || $0.coordinate.distance(to: location.coordinate) >= max(8, location.accuracy)
                } ?? true
                if shouldRebase {
                    origin = location
                    originPosition = SIMD3(frame.camera.transform.columns.3.x,
                                           groundHeight ?? frame.camera.transform.columns.3.y,
                                           frame.camera.transform.columns.3.z)
                    displayedPoints = []
                }
            }
            alignMarkersToGround()
            guard points != displayedPoints else { return }
            clearAnchors(resetOrigin: false)
            displayedPoints = points
            for (index, point) in points.enumerated() {
                let root: AnchorEntity
                if mode == .geographic {
                    let anchor = ARGeoAnchor(coordinate: point.coordinate.cl)
                    root = AnchorEntity(anchor: anchor)
                    view.session.add(anchor: anchor)
                    geoAnchors.append(anchor)
                } else if let origin {
                    let position = originPosition + ARRouteGuidance.offset(from: origin.coordinate, to: point.coordinate)
                    root = AnchorEntity(world: position)
                } else { continue }
                let arrow = Self.arrowEntity(first: index == 0)
                arrow.orientation = simd_quatf(angle: ARRouteGuidance.yaw(for: point.bearing), axis: [0, 1, 0])
                root.addChild(arrow)
                root.isEnabled = visible
                view.scene.addAnchor(root)
                roots.append(root)
            }
            alignMarkersToGround()
        }

        private func updateGroundLevel(from frame: ARFrame?) {
            guard let frame else {
                groundHeight = nil
                groundPlaneID = nil
                return
            }
            let camera = frame.camera.transform.columns.3
            let candidates = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { plane in
                guard plane.alignment == .horizontal else { return false }
                switch plane.classification {
                case .floor, .none: break
                default: return false
                }
                let center = plane.transform * SIMD4<Float>(plane.center, 1)
                let belowCamera = camera.y - center.y
                let distance = hypot(camera.x - center.x, camera.z - center.z)
                // Ignore elevated surfaces and distant patches unrelated to the user's ground.
                return (0.6...2.5).contains(belowCamera) && distance < 8
                    && plane.planeExtent.width * plane.planeExtent.height >= 0.5
            }
            let selected = candidates.first { $0.identifier == groundPlaneID } ?? candidates.min { lhs, rhs in
                if (lhs.classification == .floor) != (rhs.classification == .floor) {
                    return lhs.classification == .floor
                }
                let left = lhs.transform * SIMD4<Float>(lhs.center, 1)
                let right = rhs.transform * SIMD4<Float>(rhs.center, 1)
                return hypot(camera.x - left.x, camera.z - left.z)
                    < hypot(camera.x - right.x, camera.z - right.z)
            }
            groundPlaneID = selected?.identifier
            groundHeight = selected.map { ($0.transform * SIMD4<Float>($0.center, 1)).y }
        }

        private func alignMarkersToGround() {
            guard let groundHeight else { return }
            for root in roots {
                // Geographic anchors acquire their world transform asynchronously.
                let anchorHeight = root.position(relativeTo: nil).y
                for marker in root.children {
                    marker.position.y = groundHeight - anchorHeight + 0.015
                }
            }
        }

        private func clearAnchors(resetOrigin: Bool = true) {
            guard let view else { return }
            geoAnchors.forEach { view.session.remove(anchor: $0) }
            geoAnchors.removeAll()
            roots.forEach { view.scene.removeAnchor($0) }
            roots.removeAll()
            displayedPoints = []
            if resetOrigin { origin = nil }
        }

        private func publish(_ message: String?) {
            // Never mutate SwiftUI bindings during updateUIView.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.trackingMessage.wrappedValue != message else { return }
                self.trackingMessage.wrappedValue = message
            }
        }

        private func fail(_ message: String) {
            guard !hasFailed else { return }
            hasFailed = true
            roots.forEach { $0.isEnabled = false }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.failure(message)
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard active, frame.timestamp - lastFrameUpdate >= 0.25 else { return }
            lastFrameUpdate = frame.timestamp
            normalTracking = frame.camera.trackingState == .normal
            refresh()
        }

        func session(_ session: ARSession, didChange geoTrackingStatus: ARGeoTrackingStatus) {
            guard active, mode == .geographic else { return }
            geoLocalized = geoTrackingStatus.state == .localized
                && (geoTrackingStatus.accuracy == .medium || geoTrackingStatus.accuracy == .high)
            if geoLocalized { geoStartedAt = Date() }
            if geoTrackingStatus.state == .notAvailable {
                fail("Pozycjonowanie Apple jest niedostępne. Włączono GPS i kompas.")
            } else { refresh() }
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            guard active else { return }
            fail("Sesja AR została przerwana. Sprawdź dostęp do kamery i spróbuj ponownie.")
        }

        func sessionWasInterrupted(_ session: ARSession) {
            guard active else { return }
            interrupted = true
            normalTracking = false
            refresh()
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            guard active else { return }
            interrupted = false
            normalTracking = false
            geoLocalized = false
            geoStartedAt = Date()
            clearAnchors()
            groundHeight = nil
            groundPlaneID = nil
            if let configuration = session.configuration {
                sessionCommands?.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
            guard active, mode == .local else { return }
            heading = newHeading
            refresh()
        }

        // Reuse one solid silhouette for every layer and route anchor.
        private static let guidanceArrowMesh: MeshResource? = {
            let outline: [SIMD2<Float>] = [
                [0, -0.95], [0.85, 0.25], [0.72, 0.45],
                [0, -0.05], [-0.72, 0.45], [-0.85, 0.25]
            ]
            let height: Float = 0.008
            var positions = outline.map { SIMD3<Float>($0.x, height, $0.y) }
            positions += outline.map { SIMD3<Float>($0.x, 0, $0.y) }
            // Top faces point upward; the underside uses the opposite winding.
            let top: [UInt32] = [0, 2, 1, 0, 3, 2, 0, 4, 3, 0, 5, 4]
            var triangles = top
            for index in stride(from: 0, to: top.count, by: 3) {
                triangles += [top[index] + 6, top[index + 2] + 6, top[index + 1] + 6]
            }
            for index in outline.indices {
                let current = UInt32(index)
                let next = UInt32((index + 1) % outline.count)
                triangles += [current, next, current + 6, next, next + 6, current + 6]
            }
            var descriptor = MeshDescriptor(name: "AR guidance arrow")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.primitives = .triangles(triangles)
            return try? MeshResource.generate(from: [descriptor])
        }()

        private static func arrowEntity(first: Bool) -> Entity {
            let color = UIColor.white
            let arrow = Entity()
            guard let mesh = guidanceArrowMesh else {
                // Keep a directional marker if custom mesh creation is unavailable.
                let material = UnlitMaterial(color: color)
                let shaft = ModelEntity(mesh: .generateBox(size: [0.4, 0.008, 1.25]), materials: [material])
                shaft.position = [0, 0.005, 0.2]
                arrow.addChild(shaft)
                for side in [Float(-1), Float(1)] {
                    let arm = ModelEntity(mesh: .generateBox(size: [0.32, 0.008, 0.85]), materials: [material])
                    arm.position = [side * 0.25, 0.005, -0.62]
                    arm.orientation = simd_quatf(angle: side * .pi / 4, axis: [0, 1, 0])
                    arrow.addChild(arm)
                }
                arrow.scale = SIMD3<Float>(repeating: first ? 1.18 : 1)
                return arrow
            }

            // Opaque, unlit layers stay legible over both bright and dark camera imagery.
            // Each layer follows the arrow silhouette instead of covering the road with a plate.
            let contour = ModelEntity(mesh: mesh, materials: [UnlitMaterial(
                color: UIColor(red: 0.025, green: 0.055, blue: 0.11, alpha: 1)
            )])
            contour.scale = [1.16, 1, 1.12]
            contour.position.y = 0
            arrow.addChild(contour)

            let border = ModelEntity(mesh: mesh, materials: [UnlitMaterial(
                color: UIColor(naviHex: first ? NaviAstraColorPalette.navigationActiveNight
                                   : NaviAstraColorPalette.navigationActiveDay)
            )])
            border.scale = [1.06, 0.6, 1.04]
            border.position.y = 0.009
            arrow.addChild(border)

            let face = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
            face.scale = [0.9, 0.6, 0.94]
            face.position.y = 0.015
            arrow.addChild(face)

            // Emphasize the next marker without moving its route anchor.
            arrow.scale = SIMD3<Float>(repeating: first ? 1.18 : 1)
            return arrow
        }
    }
}

enum ARLaunchReadinessChecker {
    static func check(location: NavigationLocation?, route: NavigationRoute?, progress: RouteProgress?) async -> ARLaunchReadiness {
        guard ARWorldTrackingConfiguration.isSupported else {
            return .unavailable("To urządzenie nie obsługuje śledzenia AR")
        }
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard cameraStatus != .denied, cameraStatus != .restricted else {
            return .unavailable("Brak dostępu do kamery")
        }
        guard ARRouteGuidance.hasUsableLocation(location) else {
            return .unavailable("Wymagany jest świeży GPS o dokładności do 25 m")
        }
        guard let route else {
            return .unavailable("Brak pewnego odcinka trasy przed bieżącą pozycją")
        }
        let geometry = await Task.detached(priority: .userInitiated) {
            RouteProgressGeometry(route)
        }.value
        guard !Task.isCancelled,
              !ARRouteGuidance.points(geometry: geometry, progress: progress, location: location).isEmpty else {
            return .unavailable("Brak pewnego odcinka trasy przed bieżącą pozycją")
        }
        // Apple geographic coverage is an optional improvement, not a launch gate.
        return .ready
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
