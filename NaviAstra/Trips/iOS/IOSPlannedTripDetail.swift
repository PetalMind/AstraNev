#if os(iOS)
import SwiftUI

struct IOSPlannedTripDetail: View {
    let trip: PlannedTrip
    let navigationIsActive: Bool
    let refreshing: Bool
    let onEdit: (PlannedTrip) -> Void
    let onStart: (PlannedTrip) -> Void
    let onRefresh: () -> Void
    let onSkip: () -> Void
    let onDelete: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(occurrence: trip.occurrences(after: context.date).first)
        }
    }

    private func content(occurrence: Date?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(trip.displayTitle).font(.title2.weight(.bold))
                    if let occurrence {
                        Text(trip.timing.title).font(.subheadline).foregroundStyle(.secondary)
                        Text(PolishRegionalFormat.dateTime(occurrence, dateStyle: .complete, timeZone: trip.calendar.timeZone)).font(.headline)
                        if let departure = trip.departure(for: occurrence) {
                            Text("Wyjazd około \(PolishRegionalFormat.time(departure, timeZone: trip.calendar.timeZone))").font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor)
                        }
                    } else { Text("Termin minął lub został wykorzystany. Możesz zaplanować tę trasę ponownie.").font(.subheadline).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Label(trip.origin.name, systemImage: "a.circle.fill")
                    ForEach(Array(trip.waypoints.enumerated()), id: \.element.id) { index, stop in Label(stop.name, systemImage: "\(index + 1).circle") }
                    Label(trip.destination.name, systemImage: "flag.fill")
                    Button("Podgląd i edycja na mapie", systemImage: "map") { onEdit(trip) }.frame(minHeight: 44)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).iosCardSurface(radius: 20)
                if let estimate = trip.estimate {
                    VStack(alignment: .leading, spacing: 8) {
                        IOSSectionHeading(title: "Ostatnie przeliczenie", symbol: "clock.arrow.circlepath")
                        Text("\(TravelDurationFormatter.string(minutes: Int(ceil(estimate.travelSeconds / 60)))) · \(String(format: "%.1f km", locale: PolishRegionalFormat.locale, estimate.distanceMeters / 1_000))")
                        Text("Przyjazd około \(PolishRegionalFormat.dateTime(estimate.arrival, timeZone: trip.calendar.timeZone))")
                        Text("Obliczono \(PolishRegionalFormat.dateTime(estimate.updatedAt, timeZone: trip.calendar.timeZone))").font(.footnote).foregroundStyle(.secondary)
                        if !estimate.preferredRouteMatched { Text("Poprzedni wariant jest niedostępny. Użyto aktualnej rekomendacji.").font(.footnote).foregroundStyle(.orange) }
                    }
                }
                if trip.refreshError != nil { Label("Nie udało się odświeżyć trasy. Zapisany plan pozostaje dostępny.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary) }
                Button("Odśwież czas przejazdu", systemImage: "arrow.clockwise") { onRefresh() }
                    .disabled(refreshing || occurrence == nil)
                DisclosureGroup("Przypomnienia i ustawienia planu") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Transport", value: trip.transportMode.title)
                        LabeledContent("Powtarzanie", value: IOSPlannedTripLibrarySnapshot.scheduleTitle(trip))
                        LabeledContent("Bufor", value: "\(trip.bufferMinutes) min")
                        if !trip.waypoints.isEmpty { LabeledContent("Czas postojów", value: "\(trip.stopMinutes) min") }
                        Text(trip.reminderMinutes.isEmpty ? "Przypomnienia wyłączone" : "Przypomnienia: " + trip.reminderMinutes.sorted(by: >).map { $0 == 0 ? "w chwili wyjazdu" : $0 == 1_440 ? "dzień wcześniej" : "\($0) min wcześniej" }.joined(separator: ", "))
                        if trip.timeZoneIdentifier != TimeZone.current.identifier { LabeledContent("Strefa czasowa", value: trip.calendar.timeZone.localizedName(for: .generic, locale: PolishRegionalFormat.locale) ?? trip.timeZoneIdentifier) }
                    }.font(.subheadline).padding(.top, 10)
                }
                if occurrence != nil { Button("Pomiń najbliższy termin", systemImage: "calendar.badge.minus") { onSkip() } }
                Button("Usuń plan", systemImage: "trash", role: .destructive) { onDelete() }
                if navigationIsActive { Text("Zakończ bieżącą nawigację, aby rozpocząć następną podróż.").font(.footnote).foregroundStyle(.secondary) }
            }.padding(16).frame(maxWidth: IOSLayout.readableWidth).frame(maxWidth: .infinity)
        }.background(Color(.systemGroupedBackground)).navigationTitle("Zaplanowana podróż").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button { onStart(trip) } label: { Label("Rozpocznij z bieżącego miejsca", systemImage: "location.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 46) }
                    .buttonStyle(.borderedProminent).disabled(navigationIsActive)
                    .padding(16).frame(maxWidth: IOSLayout.readableWidth).frame(maxWidth: .infinity).background(.regularMaterial)
            }
    }
}
#endif
