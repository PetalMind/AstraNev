import SwiftUI
import MapKit

/// Owns the playback clock so map updates do not rebuild the trip's statistics.
struct TripHistoryPlaybackView: View {
    let trip: TripRecord
    private let timeline: TripPlaybackTimeline
    private let overview: MKCoordinateRegion
    private let hasSpeedData: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var elapsed = 0.0
    @State private var playing = false
    @State private var rate = 5.0
    @State private var seekGeneration = 0
    @State private var scrubbing = false
    @State private var resumeAfterScrubbing = false
    @State private var followsPosition = false
    @State private var cameraDistance = 1_200.0
    @State private var lastCameraUpdate = -Double.infinity
    @State private var mapPosition: MapCameraPosition

    init(trip: TripRecord) {
        self.trip = trip
        let timeline = TripPlaybackTimeline(trip: trip)
        self.timeline = timeline
        let overview = Self.overviewRegion(for: timeline.points)
        self.overview = overview
        hasSpeedData = timeline.points.contains { $0.speedKph != nil }
        _mapPosition = State(initialValue: .region(overview))
    }

    var body: some View {
        let position = timeline.position(at: elapsed)
        VStack(alignment: .leading, spacing: 24) {
            HistoryDetailSection(title: "Przebieg trasy", symbol: "map") {
                if let position {
                    traceMap(position: position)
                    mapActions(position: position)
                    playbackControls(position: position)
                    traceAnalysisLink
                } else {
                    ContentUnavailableView("Brak śladu GPS", systemImage: "map",
                        description: Text(trip.traceAvailabilityDescription))
                }
            }
            if hasSpeedData {
                HistoryDetailSection(title: "Prędkość w czasie", symbol: "waveform.path") {
                    TripHistorySpeedChart(tripID: trip.id, startedAt: trip.startedAt,
                        timeline: timeline, elapsed: $elapsed, onSeek: { seek(to: $0, resume: false) })
                }
            }
        }
        .environment(\.locale, TripHistoryFormat.locale)
        .task(id: PlaybackRun(playing: playing, rate: rate, generation: seekGeneration)) {
            guard playing, timeline.duration > 0 else { return }
            let base = elapsed
            let started = ProcessInfo.processInfo.systemUptime
            let activeRate = rate
            let activeGeneration = seekGeneration
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                // A cancelled sleep/task must never overwrite a seek or a pause.
                guard !Task.isCancelled, playing, !scrubbing, scenePhase == .active,
                      seekGeneration == activeGeneration, rate == activeRate else { return }
                elapsed = timeline.clampedElapsed(base +
                    (ProcessInfo.processInfo.systemUptime - started) * activeRate)
                updateFollowingCamera()
                if elapsed >= timeline.duration {
                    playing = false
                    return
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { pause() }
        }
        .onDisappear { pause() }
    }

    private func traceMap(position: TripPlaybackPosition) -> some View {
        Map(position: $mapPosition, interactionModes: [.pan, .zoom, .rotate]) {
            ForEach(timeline.segments) { segment in
                if segment.coordinates.count > 1 {
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(Color.accentColor.opacity(0.75), lineWidth: 4)
                }
            }
            if let first = timeline.points.first {
                Marker("Pierwszy pomiar GPS", systemImage: "flag", coordinate: first.coordinate.cl)
                    .tint(.green)
            }
            if timeline.points.count > 1, let last = timeline.points.last {
                Marker("Ostatni pomiar GPS", systemImage: "flag.checkered", coordinate: last.coordinate.cl)
                    .tint(.orange)
            }
            Annotation("Pozycja odtwarzania", coordinate: position.coordinate.cl, anchor: .center) {
                ZStack {
                    Circle().fill(positionColor(position.kind).opacity(0.2)).frame(width: 38, height: 38)
                    Circle().fill(positionColor(position.kind)).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.background, lineWidth: 3))
                    if position.kind == .gap || position.kind == .afterLastFix {
                        Image(systemName: "clock").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 3)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(positionTitle(position.kind))
                .accessibilityValue(positionDetail(position))
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .onMapCameraChange(frequency: .continuous) { context in
            // Direct map interaction takes precedence over automatic following.
            if mapPosition.positionedByUser {
                followsPosition = false
                cameraDistance = context.camera.distance
            }
        }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func mapActions(position: TripPlaybackPosition) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { overviewButton; followButton }
            VStack(alignment: .leading, spacing: 8) { overviewButton; followButton }
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
    }

    private var overviewButton: some View {
        Button {
            followsPosition = false
            mapPosition = .region(overview)
        } label: {
            Label("Cała trasa", systemImage: "arrow.up.left.and.arrow.down.right")
                .frame(minHeight: 32)
        }
        .accessibilityHint("Dopasowuje mapę do całego zapisanego przebiegu.")
    }

    private var followButton: some View {
        Button {
            followsPosition.toggle()
            if followsPosition {
                cameraDistance = min(3_000, max(300, cameraDistance))
                updateFollowingCamera(force: true)
            }
        } label: {
            Label(followsPosition ? "Śledzenie włączone" : "Śledź znacznik",
                  systemImage: followsPosition ? "location.fill" : "location")
                .frame(minHeight: 32)
        }
        .accessibilityValue(followsPosition ? "Włączone" : "Wyłączone")
        .accessibilityHint("Ręczne przesunięcie mapy wyłącza podążanie za znacznikiem.")
    }

    private func playbackControls(position: TripPlaybackPosition) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { backwardButton; playButton; forwardButton }
                VStack(spacing: 8) {
                    playButton
                    HStack { backwardButton; Spacer(); forwardButton }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { restartButton; Spacer(minLength: 0); ratePicker }
                VStack(alignment: .leading, spacing: 8) { restartButton; ratePicker }
            }
            if timeline.duration > 0 {
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { elapsed }, set: { value in
                        // VoiceOver adjustments also use this setter; they do not
                        // necessarily deliver the touch editing callbacks.
                        if !scrubbing { pause() }
                        elapsed = timeline.clampedElapsed(value)
                        seekGeneration &+= 1
                        updateFollowingCamera(force: true)
                    }), in: 0...timeline.duration, onEditingChanged: handleScrubbing)
                    .accessibilityLabel("Pozycja na osi czasu podróży")
                    .accessibilityValue("\(TripHistoryFormat.duration(elapsed)) z \(TripHistoryFormat.duration(timeline.duration))")
                    .accessibilityHint("Zmienia odtwarzany moment podróży.")
                    PlaybackGapTrack(gaps: timeline.gaps, duration: timeline.duration)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(TripHistoryFormat.duration(elapsed))
                Spacer(minLength: 8)
                Text(TripHistoryFormat.duration(timeline.duration))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(Color.naviTextSecondary)
            Text(playbackDate(position.timelineDate))
                .font(.subheadline.monospacedDigit())
            VStack(alignment: .leading, spacing: 6) {
                Label(positionTitle(position.kind), systemImage: positionSymbol(position.kind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(positionColor(position.kind))
                Text(positionDetail(position))
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(position.speedKph.map {
                    $0.formatted(.number.precision(.fractionLength(0)).locale(TripHistoryFormat.locale)) + " km/h"
                } ?? "Prędkość w tym momencie niedostępna")
                    .font(.subheadline.monospacedDigit())
            }
            if position.kind == .gap || position.kind == .beforeFirstFix,
               let next = position.nextMeasurementElapsed {
                Button {
                    seek(to: next, resume: playing)
                } label: {
                    Label("Do następnego pomiaru", systemImage: "forward.end")
                        .frame(minHeight: 32)
                }
                .buttonStyle(.bordered)
            } else if position.kind == .afterLastFix, elapsed < timeline.duration {
                Button("Przejdź do końca zapisu", systemImage: "forward.end") {
                    seek(to: timeline.duration, resume: false)
                }
                .frame(minHeight: 44)
            }
            if elapsed >= timeline.duration, timeline.duration > 0 {
                Text("Odtwarzanie zakończone")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.naviTextSecondary)
            }
            if !timeline.gaps.isEmpty {
                Text("Pomarańczowe odcinki osi czasu oznaczają brak ciągłego zapisu GPS. Znacznik pozostaje na ostatniej znanej pozycji; nie oznacza to postoju.")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
            }
        }
    }

    private var playButton: some View {
        Button {
            if playing { pause() }
            else {
                if elapsed >= timeline.duration { elapsed = 0 }
                seekGeneration &+= 1
                playing = true
                updateFollowingCamera(force: true)
            }
        } label: {
            Label(playing ? "Pauza" : (elapsed >= timeline.duration ? "Odtwórz ponownie" : "Odtwórz"),
                  systemImage: playing ? "pause.fill" : "play.fill")
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .disabled(timeline.duration == 0)
    }

    private var backwardButton: some View {
        Button { seek(to: elapsed - 15, resume: playing) } label: {
            Image(systemName: "gobackward.15").font(.title3).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Cofnij o 15 sekund")
        .disabled(elapsed <= 0)
    }

    private var forwardButton: some View {
        Button { seek(to: elapsed + 15, resume: playing) } label: {
            Image(systemName: "goforward.15").font(.title3).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Przewiń o 15 sekund")
        .disabled(elapsed >= timeline.duration)
    }

    private var restartButton: some View {
        Button("Od początku", systemImage: "backward.end") { seek(to: 0, resume: false) }
            .frame(minHeight: 44)
            .disabled(elapsed == 0 && !playing)
    }

    private var ratePicker: some View {
        Picker("Tempo odtwarzania", selection: $rate) {
            ForEach([1.0, 5.0, 20.0, 100.0], id: \.self) { value in
                Text("\(Int(value))×").tag(value)
                    .accessibilityLabel("\(Int(value)) razy")
            }
        }
        .pickerStyle(.menu)
        .frame(minHeight: 44)
        .accessibilityValue("\(Int(rate)) razy")
    }

    @ViewBuilder private var traceAnalysisLink: some View {
        if let mode = trip.transportMode, mode != .transit {
            NavigationLink("Analizuj ślad i dopasuj do dróg") {
                ValhallaTraceView(endpoint: URL(string: UserDefaults.standard.string(forKey: "routingServer")
                    ?? "https://valhalla1.openstreetmap.de") ?? URL(string: "https://valhalla1.openstreetmap.de")!,
                    preferences: (UserDefaults.standard.data(forKey: "routingPreferences")
                        .flatMap { try? JSONDecoder().decode(RoutingPreferences.self, from: $0) }) ?? RoutingPreferences(),
                    initialTrace: trip.valhallaTraceSegments, initialMode: mode)
            }
        }
    }

    private func handleScrubbing(_ editing: Bool) {
        if editing {
            resumeAfterScrubbing = playing
            scrubbing = true
            playing = false
            seekGeneration &+= 1
        } else {
            scrubbing = false
            playing = resumeAfterScrubbing && scenePhase == .active && elapsed < timeline.duration
            resumeAfterScrubbing = false
            seekGeneration &+= 1
            updateFollowingCamera(force: true)
        }
    }

    private func pause() {
        playing = false
        scrubbing = false
        resumeAfterScrubbing = false
        seekGeneration &+= 1
    }

    private func seek(to value: Double, resume: Bool) {
        elapsed = timeline.clampedElapsed(value)
        resumeAfterScrubbing = false
        seekGeneration &+= 1
        playing = resume && scenePhase == .active && elapsed < timeline.duration
        updateFollowingCamera(force: true)
    }

    private func updateFollowingCamera(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard followsPosition, force || now - lastCameraUpdate >= 0.2,
              let point = timeline.position(at: elapsed) else { return }
        lastCameraUpdate = now
        // No implicit camera/marker animation: seeks and gaps must not invent
        // movement through places for which the recording contains no fixes.
        mapPosition = .camera(MapCamera(centerCoordinate: point.coordinate.cl, distance: cameraDistance))
    }

    private func playbackDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: Calendar.current.isDate(date, inSameDayAs: trip.startedAt)
            ? .omitted : .abbreviated, time: .standard).locale(TripHistoryFormat.locale))
    }

    private func positionTitle(_ kind: TripPlaybackKind) -> String {
        switch kind {
        case .recorded: "Zapisana pozycja GPS"
        case .interpolated: "Pozycja między pomiarami"
        case .gap, .afterLastFix: "Ostatnia znana pozycja"
        case .beforeFirstFix: "Przed pierwszym pomiarem GPS"
        }
    }

    private func positionSymbol(_ kind: TripPlaybackKind) -> String {
        switch kind {
        case .recorded, .interpolated: "location.fill"
        case .gap, .afterLastFix: "antenna.radiowaves.left.and.right.slash"
        case .beforeFirstFix: "clock"
        }
    }

    private func positionColor(_ kind: TripPlaybackKind) -> Color {
        switch kind {
        case .recorded, .interpolated: .accentColor
        case .gap, .afterLastFix: .orange
        case .beforeFirstFix: .secondary
        }
    }

    private func positionDetail(_ position: TripPlaybackPosition) -> String {
        switch position.kind {
        case .recorded:
            "Zapis GPS: \(playbackDate(position.measurementDate))."
        case .interpolated:
            "Pozycja i dostępna prędkość są przybliżone na podstawie sąsiednich pomiarów GPS."
        case .gap, .afterLastFix:
            "Brak pomiaru od \(TripHistoryFormat.duration(position.missingDuration)). Ostatni zapis: \(playbackDate(position.measurementDate))."
        case .beforeFirstFix:
            "Znacznik pokazuje pierwszy zapisany punkt, dostępny za \(TripHistoryFormat.duration(position.missingDuration)). To nie jest pozycja z wybranego momentu."
        }
    }

    private static func overviewRegion(for points: [TripTracePoint]) -> MKCoordinateRegion {
        guard !points.isEmpty else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 52, longitude: 19),
                span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 10))
        }
        let latitudes = points.map { min(85, max(-85, $0.coordinate.latitude)) }
        let longitudes = points.map { ($0.coordinate.longitude + 360).truncatingRemainder(dividingBy: 360) }.sorted()
        var largestGap = -1.0
        var arcStart = longitudes[0]
        for index in longitudes.indices {
            let next = index + 1 < longitudes.count ? longitudes[index + 1] : longitudes[0] + 360
            if next - longitudes[index] > largestGap {
                largestGap = next - longitudes[index]
                arcStart = next.truncatingRemainder(dividingBy: 360)
            }
        }
        let longitudeSpan = max(0, 360 - largestGap)
        let centerLongitude = (arcStart + longitudeSpan / 2 + 540).truncatingRemainder(dividingBy: 360) - 180
        let minLatitude = latitudes.min() ?? 0
        let maxLatitude = latitudes.max() ?? 0
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2,
                longitude: centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: min(170, max(0.005, (maxLatitude - minLatitude) * 1.3)),
                longitudeDelta: min(360, max(0.005, longitudeSpan * 1.3))))
    }
}

private struct PlaybackRun: Equatable {
    let playing: Bool
    let rate: Double
    let generation: Int
}

private struct PlaybackGapTrack: View {
    let gaps: [TripPlaybackGap]
    let duration: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.accentColor.opacity(0.2))
                ForEach(gaps) { gap in
                    Rectangle().fill(.orange.opacity(0.7))
                        .frame(width: max(1, geometry.size.width * gap.duration / duration))
                        .offset(x: geometry.size.width * gap.startElapsed / duration)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
