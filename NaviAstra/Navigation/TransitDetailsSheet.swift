import SwiftUI

enum TransitSheetSelection: Identifiable {
    case stop(TransitStop)
    case vehicle(TransitVehicle)
    case departure(TransitDeparture)
    case line(TransitLineDetails)

    var id: String {
        switch self {
        case .stop(let stop): "stop-\(stop.id)"
        case .vehicle(let vehicle): "vehicle-\(vehicle.id)"
        case .departure(let departure): "trip-\(departure.id)"
        case .line(let line): "line-\(line.id)"
        }
    }
}

struct TransitDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: TransitSheetSelection
    let onSelectDeparture: (TransitDeparture) -> Void

    @State private var departures: [TransitDeparture] = []
    @State private var alerts: [String] = []
    @State private var tripDetails: TransitTripDetails?
    @State private var railwayAttribution: String?
    @State private var isLoading = true

    private let provider = LodzTransitRouteProvider()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: contentSpacing) {
                    selectionContents
                    if let railwayAttribution {
                        Text(railwayAttribution)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle(title)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zamknij") { dismiss() }
                }
            }
            .task(id: selection.id) {
                await loadDetails()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { break }
                    await refreshDetails()
                }
            }
        }
    }

    private var contentSpacing: CGFloat {
        if case .line = selection { return 14 }
        return 18
    }

    @ViewBuilder
    private var selectionContents: some View {
        switch selection {
        case .stop(let stop):
            stopContents(stop)
        case .vehicle(let vehicle):
            tripContents(vehicle: vehicle)
        case .departure:
            tripContents(vehicle: nil)
        case .line(let line):
            HStack(spacing: 12) {
                TransitLineBadge(title: line.name, color: line.colorHex)
                VStack(alignment: .leading, spacing: 3) {
                    Text(modeLabel(line.mode))
                        .font(.headline)
                    if !line.directions.isEmpty {
                        Text(line.directions).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Przystanki na trasie").font(.headline)
            ForEach(line.stops.indices, id: \.self) { index in
                let stop = line.stops[index]
                HStack(spacing: 12) {
                    Text("\(index + 1)").font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary).frame(width: 24)
                    Text(stop.name).font(.subheadline)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var title: String {
        switch selection {
        case .stop(let stop): stop.name
        case .vehicle(let vehicle): "\(modeLabel(vehicle.mode)) \(vehicle.line)"
        case .departure(let departure): "\(departure.line) → \(departure.destination)"
        case .line(let line): "\(line.mode == "RAIL" ? "Pociąg" : "Linia") \(line.name)"
        }
    }

    private func modeLabel(_ mode: String) -> String {
        switch mode {
        case "RAIL": "Pociąg"
        case "TRAM": "Tramwaj"
        default: "Autobus"
        }
    }

    private var currentStopStatus: String {
        guard case .departure(let departure) = selection else { return "teraz" }
        return eta(at: departure.estimatedDeparture, now: Date())
    }

    private var selectedIsRail: Bool {
        switch selection {
        case .stop(let stop): stop.mapModes.contains(.rail)
        case .vehicle(let vehicle): vehicle.mode == "RAIL"
        case .departure(let departure): departure.mode == "RAIL"
        case .line(let line): line.mode == "RAIL"
        }
    }

    @ViewBuilder
    private func stopContents(_ stop: TransitStop) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stop.name).font(.title2.weight(.bold))
            if let address = stop.address, !address.isEmpty {
                Text(address).font(.subheadline).foregroundStyle(.secondary)
            }
            if stop.mapModes.count > 1 {
                HStack(spacing: 10) {
                    ForEach(stop.mapModes, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbolName)
                            .font(.caption.weight(.medium))
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Odjazdy").font(.headline)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }
            if departures.isEmpty, !isLoading {
                Text("Brak kolejnych odjazdów w opublikowanym rozkładzie.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(departures) { departure in
                Button { onSelectDeparture(departure) } label: {
                    TransitDepartureRow(departure: departure)
                }
                .buttonStyle(.plain)
            }
        }
        if !alerts.isEmpty {
            ForEach(Array(alerts.enumerated()), id: \.offset) { _, detail in alertCard(detail) }
        } else if !isLoading {
            Label(departures.contains(where: \.hasRealtime)
                  ? "Czasy z aktualizacji na żywo"
                  : "Brak danych live · pokazano rozkład",
                  systemImage: departures.contains(where: \.hasRealtime) ? "dot.radiowaves.left.and.right" : "clock")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tripContents(vehicle: TransitVehicle?) -> some View {
        if let tripDetails {
            HStack(spacing: 12) {
                TransitLineBadge(title: tripDetails.line, color: tripDetails.colorHex)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tripDetails.destination.isEmpty ? "Kierunek nieznany" : tripDetails.destination)
                        .font(.title3.weight(.semibold))
                    Text(modeLabel(tripDetails.mode))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let actualVehicle = tripDetails.vehicle ?? vehicle {
                Label("Pozycja z pojazdu · \(actualVehicle.updatedAt.formatted(date: .omitted, time: .shortened))",
                      systemImage: "location.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("Dane z rozkładu", systemImage: "clock")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if vehicle != nil {
                ForEach(tripDetails.pastStops) { stop in
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                        Text(stop.name).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text(stop.arrival.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
            if let currentStopName = tripDetails.currentStopName {
                HStack(spacing: 9) {
                    Circle().fill(Color.accentColor).frame(width: 9, height: 9)
                    Text(currentStopName).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(currentStopStatus).font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            VStack(spacing: 0) {
                ForEach(Array(tripDetails.nextStops.enumerated()), id: \.element.id) { index, stop in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().strokeBorder(index == 0 ? Color.accentColor : .secondary.opacity(0.55), lineWidth: 2)
                                .frame(width: 10, height: 10)
                            Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2, height: 30)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(stop.name).font(.subheadline.weight(.medium))
                            Text(stop.arrival.formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let delay = stop.delaySeconds, abs(delay) >= 30 {
                            Text(delayLabel(delay)).font(.caption.weight(.semibold))
                                .foregroundStyle(delayColor(delay))
                        } else if stop.hasRealtime {
                            Text("live").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let alert = tripDetails.activeAlert { alertCard(alert) }
            if isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
        } else if isLoading {
            ProgressView("Pobieram przebieg kursu…").frame(maxWidth: .infinity).padding(.top, 30)
        } else {
            ContentUnavailableView("Brak szczegółów kursu", systemImage: "train.side.front.car", description: Text("Nie udało się pobrać kolejnych przystanków."))
        }
    }

    private func alertCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadDetails() async {
        isLoading = true
        railwayAttribution = selectedIsRail ? await provider.railwayScheduleAttribution() : nil
        await refreshDetails()
        isLoading = false
    }

    private func refreshDetails() async {
        switch selection {
        case .stop(let stop):
            async let board = provider.departures(at: stop.detailStopIDs)
            async let activeAlerts = provider.alerts(for: stop.detailStopIDs)
            let (loadedDepartures, loadedAlerts) = await (board, activeAlerts)
            departures = loadedDepartures
            alerts = loadedAlerts
            tripDetails = nil
        case .vehicle(let vehicle):
            tripDetails = await provider.vehicleDetails(id: vehicle.id)
            departures = []
            alerts = []
        case .departure(let departure):
            tripDetails = await provider.tripDetails(for: departure)
            departures = []
            alerts = []
        case .line:
            departures = []
            tripDetails = nil
            alerts = []
        }
    }
}

private struct TransitDepartureRow: View {
    let departure: TransitDeparture

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            HStack(spacing: 11) {
                TransitLineBadge(title: departure.line, color: departure.colorHex)
                VStack(alignment: .leading, spacing: 3) {
                    Text(departure.destination).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 5) {
                        Text("rozkład \(departure.scheduledDeparture.formatted(date: .omitted, time: .shortened))")
                        if departure.hasRealtime { Text("·"); Label("live", systemImage: "dot.radiowaves.left.and.right") }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(eta(at: departure.estimatedDeparture, now: context.date))
                        .font(.headline.monospacedDigit()).foregroundStyle(.primary)
                    if let delay = departure.delaySeconds, abs(delay) >= 30 {
                        Text(delayLabel(delay)).font(.caption2.weight(.semibold)).foregroundStyle(delayColor(delay))
                    } else {
                        Text(departure.estimatedDeparture.formatted(date: .omitted, time: .shortened))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
    }
}

private struct TransitLineBadge: View {
    let title: String
    let color: UInt32

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 38, minHeight: 32)
            .padding(.horizontal, 5)
            .background(transitColor(color), in: RoundedRectangle(cornerRadius: 9))
    }
}

private func eta(at departure: Date, now: Date) -> String {
    let minutes = Int(ceil(departure.timeIntervalSince(now) / 60))
    if minutes <= 0 { return "teraz" }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    guard hours > 0 else { return "\(minutes) min" }
    guard remainingMinutes > 0 else { return "\(hours) godz." }
    return "\(hours) godz. \(remainingMinutes) min"
}

private func delayLabel(_ seconds: Int) -> String {
    let minutes = max(1, Int((Double(abs(seconds)) / 60).rounded()))
    return seconds > 0 ? "+\(minutes) min" : "−\(minutes) min"
}

private func delayColor(_ seconds: Int) -> Color {
    guard seconds > 0 else { return .secondary }
    let minutes = abs(seconds) / 60
    if minutes > 5 { return .red }
    if minutes >= 3 { return .orange }
    return .secondary
}

private func transitColor(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xff) / 255,
          green: Double((hex >> 8) & 0xff) / 255,
          blue: Double(hex & 0xff) / 255)
}
