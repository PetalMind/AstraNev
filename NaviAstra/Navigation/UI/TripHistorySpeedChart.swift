import SwiftUI
import Charts

/// Keeps the recorded chart independent of the frequently changing playback cursor.
struct TripHistorySpeedChart: View {
    private let tripID: UUID
    private let startedAt: Date
    private let timeline: TripPlaybackTimeline
    private let elapsed: Binding<Double>
    private let onSeek: (Double) -> Void

    init(tripID: UUID, startedAt: Date, timeline: TripPlaybackTimeline,
         elapsed: Binding<Double>, onSeek: @escaping (Double) -> Void) {
        self.tripID = tripID
        self.startedAt = startedAt
        self.timeline = timeline
        self.elapsed = elapsed
        self.onSeek = onSeek
    }

    var body: some View {
        TripHistoryStaticSpeedChart(tripID: tripID, startedAt: startedAt,
            timeline: timeline, elapsed: elapsed, onSeek: onSeek)
            .equatable()
    }
}

private struct TripHistorySpeedSample: Identifiable {
    let id: Int
    let timestamp: Date
    let speed: Double
}

private struct TripHistorySpeedSeries: Identifiable {
    let id: Int
    let samples: [TripHistorySpeedSample]
}

private struct TripHistoryStaticSpeedChart: View, Equatable {
    let tripID: UUID
    let startedAt: Date
    let timeline: TripPlaybackTimeline
    // Only the overlay reads wrappedValue, so playback does not invalidate the marks.
    let elapsed: Binding<Double>
    let onSeek: (Double) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // A detail screen owns an immutable recording snapshot for this trip.
        lhs.tripID == rhs.tripID
    }

    var body: some View {
        let series = speedSeries()
        let maximumSpeed = series.flatMap(\.samples).map(\.speed).max() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            Text("Prędkość GPS · km/h")
                .font(.caption)
                .foregroundStyle(Color.naviTextSecondary)
            Chart {
                ForEach(timeline.gaps) { gap in
                    RectangleMark(
                        xStart: .value("Początek braku GPS", startedAt.addingTimeInterval(gap.startElapsed)),
                        xEnd: .value("Koniec braku GPS", startedAt.addingTimeInterval(gap.endElapsed)))
                        .foregroundStyle(Color.secondary.opacity(0.15))
                        .accessibilityHidden(true)
                }
                ForEach(series) { segment in
                    if segment.samples.count == 1, let sample = segment.samples.first {
                        PointMark(x: .value("Godzina", sample.timestamp),
                                  y: .value("Prędkość w kilometrach na godzinę", sample.speed))
                            .foregroundStyle(Color.accentColor)
                            .symbolSize(18)
                    } else {
                        ForEach(segment.samples) { sample in
                            LineMark(x: .value("Godzina", sample.timestamp),
                                     y: .value("Prędkość w kilometrach na godzinę", sample.speed),
                                     series: .value("Odcinek pomiarów", segment.id))
                                .foregroundStyle(Color.accentColor)
                                .interpolationMethod(.linear)
                        }
                    }
                }
            }
            .chartXScale(domain: startedAt...startedAt.addingTimeInterval(max(1, timeline.duration)))
            .chartYScale(domain: 0...max(10, maximumSpeed * 1.1))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisTick()
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(date.formatted(Date.FormatStyle(date: .omitted,
                                time: timeline.duration < 3_600 ? .standard : .shortened)
                                .locale(TripHistoryFormat.locale)))
                        }
                    }
                }
            }
            .chartPlotStyle { plot in plot.clipped() }
            .chartOverlay { proxy in
                TripHistorySpeedCursor(proxy: proxy, startedAt: startedAt,
                    duration: timeline.duration, elapsed: elapsed, onSeek: onSeek)
            }
            .frame(height: 190)
            .accessibilityLabel("Wykres prędkości GPS w czasie")
            .accessibilityHint("Pozycję odtwarzania zmienisz suwakiem odtwarzania.")

            if series.isEmpty {
                Text("Brak wiarygodnych pomiarów prędkości.")
                    .font(.caption)
                    .foregroundStyle(Color.naviTextSecondary)
            }
            Text("Dotknij wykresu, aby przewinąć odtwarzanie. Zacienione pasma oznaczają brak GPS; linia urywa się także przy braku pomiaru prędkości.")
                .font(.caption)
                .foregroundStyle(Color.naviTextSecondary)
        }
        .environment(\.locale, TripHistoryFormat.locale)
    }

    private func speedSeries() -> [TripHistorySpeedSeries] {
        var result: [TripHistorySpeedSeries] = []
        var samples: [TripHistorySpeedSample] = []
        let endedAt = startedAt.addingTimeInterval(timeline.duration)
        func finishSegment() {
            guard !samples.isEmpty else { return }
            result.append(TripHistorySpeedSeries(id: result.count, samples: samples))
            samples.removeAll(keepingCapacity: true)
        }
        for (index, point) in timeline.points.enumerated() {
            if point.startsSegment { finishSegment() }
            guard let speed = point.speedKph, speed.isFinite,
                  point.timestamp >= startedAt, point.timestamp <= endedAt else {
                finishSegment()
                continue
            }
            samples.append(TripHistorySpeedSample(id: index, timestamp: point.timestamp, speed: speed))
        }
        finishSegment()
        return result
    }
}

private struct TripHistorySpeedCursor: View {
    let proxy: ChartProxy
    let startedAt: Date
    let duration: Double
    @Binding var elapsed: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            guard plot.contains(value.location),
                                  let date = proxy.value(atX: value.location.x - plot.minX, as: Date.self) else { return }
                            onSeek(clamped(date.timeIntervalSince(startedAt)))
                        })
                    if let x = proxy.position(forX: startedAt.addingTimeInterval(clamped(elapsed))) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2, height: plot.height)
                            .position(x: plot.minX + min(plot.width, max(0, x)), y: plot.midY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }

    private func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(duration, max(0, value))
    }
}
