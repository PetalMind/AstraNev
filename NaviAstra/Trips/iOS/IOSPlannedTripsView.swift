#if os(iOS)
import SwiftUI

struct IOSPlannedTripsView: View {
    @Bindable var service: TripPlanningService
    let focusTripID: UUID?
    let navigationIsActive: Bool
    let onCreate: () -> Void
    let onEdit: (PlannedTrip) -> Void
    let onStart: (PlannedTrip) -> Void
    let onHistory: () -> Void
    let onClose: () -> Void
    private enum Tab: Hashable { case upcoming, regular }
    @State private var tab: Tab = .upcoming
    @State private var path: [UUID] = []
    @State private var removing: PlannedTrip?
    @State private var skipping: PlannedTrip?
    var body: some View {
        NavigationStack(path: $path) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                library(IOSPlannedTripLibrarySnapshot(trips: service.trips, now: context.date))
            }
            .navigationTitle("Podróże").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zamknij", action: onClose) }
                ToolbarItem(placement: .primaryAction) { Button("Zaplanuj", systemImage: "plus", action: onCreate) }
            }
            .navigationDestination(for: UUID.self) { detail($0) }
            .refreshable { await service.refreshUpcoming(force: true) }
            .task {
                if let id = service.requestedTripID ?? focusTripID { open(id); service.requestedTripID = nil }
                await service.refreshUpcoming()
            }
            .onChange(of: service.requestedTripID) { _, id in if let id { open(id); service.requestedTripID = nil } }
            .confirmationDialog("Usunąć plan i jego przypomnienia?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Usuń plan", role: .destructive) { if let removing { service.delete(removing.id) }; removing = nil; path = [] }
            }
            .confirmationDialog("Pominąć najbliższy termin tej podróży?", isPresented: Binding(get: { skipping != nil }, set: { if !$0 { skipping = nil } })) {
                Button("Pomiń termin") {
                    if let skipping, let occurrence = skipping.occurrences(after: Date()).first { service.complete(skipping.id, occurrence: occurrence) }
                    skipping = nil
                }
            }
        }.environment(\.locale, PolishRegionalFormat.locale)
    }

    private func library(_ snapshot: IOSPlannedTripLibrarySnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Picker("Podróże", selection: $tab) { Text("Zaplanowane").tag(Tab.upcoming); Text("Regularne").tag(Tab.regular) }.pickerStyle(.segmented)
                if service.errorMessage != nil { notice("Nie udało się odczytać lub zapisać planów na urządzeniu. Zachowaliśmy dotychczasowe dane.", symbol: "exclamationmark.triangle") }
                if let message = service.reminderMessage { notice(IOSTripUserMessage.reminders(message), symbol: "bell.badge") }
                if tab == .upcoming {
                    ForEach(snapshot.sections) { group in
                        IOSSectionHeading(title: group.title)
                        ForEach(group.entries) { entry in tripCard(entry, regular: false) }
                    }
                    if snapshot.sections.isEmpty { emptyState }
                    if !snapshot.past.isEmpty {
                        DisclosureGroup("Poprzednie plany") {
                            VStack(spacing: 10) { ForEach(snapshot.past) { entry in tripCard(entry, regular: false) } }.padding(.top, 10)
                        }.font(.subheadline.weight(.semibold))
                    }
                } else {
                    ForEach(snapshot.regular) { entry in tripCard(entry, regular: true) }
                    if snapshot.regular.isEmpty { emptyState }
                }
                Button("Ostatnie podróże", systemImage: "clock.arrow.circlepath", action: onHistory)
                    .frame(minHeight: 44).font(.subheadline.weight(.semibold))
                Text("Plany pozostają na tym urządzeniu. Przypomnienia korzystają z ostatnio obliczonej trasy.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: IOSLayout.readableWidth).frame(maxWidth: .infinity)
        }.background(Color(.systemGroupedBackground))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(tab == .upcoming ? "Zaplanuj następną podróż" : "Brak regularnych podróży", systemImage: "calendar.badge.plus")
        } description: {
            Text("Wybierz miejsca na mapie lub wpisz adres, sprawdź trasę i ustaw termin.")
        } actions: {
            Button("Zaplanuj podróż", action: onCreate).buttonStyle(.borderedProminent)
        }
        .iosCardSurface(radius: 22)
    }

    private func tripCard(_ entry: IOSPlannedTripLibrarySnapshot.Entry, regular: Bool) -> some View {
        NavigationLink(value: entry.id) {
            IOSPlannedTripCard(entry: entry, regular: regular, refreshing: service.refreshingIDs.contains(entry.id))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edytuj na mapie", systemImage: "map") { onEdit(entry.trip) }
            Button("Usuń plan", systemImage: "trash", role: .destructive) { removing = entry.trip }
        }
    }

    @ViewBuilder private func detail(_ id: UUID) -> some View {
        if let trip = service.trips.first(where: { $0.id == id }) {
            IOSPlannedTripDetail(trip: trip, navigationIsActive: navigationIsActive,
                refreshing: service.refreshingIDs.contains(trip.id), onEdit: onEdit, onStart: onStart,
                onRefresh: { Task { await service.refresh(trip.id) } },
                onSkip: { skipping = trip }, onDelete: { removing = trip })
        } else { ContentUnavailableView("Plan nie jest dostępny", systemImage: "calendar") }
    }
    private func notice(_ text: String, symbol: String) -> some View { Label(text, systemImage: symbol).font(.footnote).foregroundStyle(.secondary) }
    private func open(_ id: UUID) { if service.trips.contains(where: { $0.id == id }) { path = [id] } }

}

enum IOSTripUserMessage {
    static func reminders(_ message: String) -> String {
        if message.hasPrefix("Powiadomienia są wyłączone") || message.hasPrefix("Ustawiono najbliższe przypomnienia") { return message }
        return "Nie udało się ustawić części przypomnień. Plan jest zapisany; sprawdź powiadomienia w ustawieniach systemu."
    }
}
#endif
