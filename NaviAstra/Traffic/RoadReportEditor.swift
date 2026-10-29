#if os(iOS)
import SwiftUI

struct RoadReportEditor: View {
    let coordinate: Coordinate?
    let locationTimestamp: Date?
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var store = LocalRoadReportStore.shared
    @State private var kind: RoadReportKind = .hazard
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var savedReport: LocalRoadReport?

    var body: some View {
        NavigationStack {
            Form {
                Section("Nowe zgłoszenie") {
                    Picker("Rodzaj", selection: $kind) {
                        ForEach(RoadReportKind.allCases) { kind in Label(kind.title, systemImage: kind.symbol).tag(kind) }
                    }
                    Text("Punkt zgłoszenia to Twoja bieżąca pozycja GPS. Zgłoszenie jest niepotwierdzone i wygaśnie po 30 minutach.")
                    if coordinate == nil {
                        Label("Czekam na świeżą, dokładną pozycję GPS.", systemImage: "location.slash")
                    }
                    Button("Zapisz tylko na tym urządzeniu") { save(shared: false) }
                        .disabled(coordinate == nil || saving)
                    if SharedRoadReportsClient.endpoint != nil {
                        Button("Udostępnij zgłoszenie innym") { save(shared: true) }
                            .disabled(coordinate == nil || saving)
                        Text("Udostępnisz rodzaj zdarzenia, przybliżony punkt (około 100 m) i czas. Nie wysyłamy historii trasy, danych konta ani identyfikatora urządzenia.")
                            .font(.caption)
                    } else {
                        Text("Wspólne zgłoszenia nie są skonfigurowane. Lokalny zapis jest widoczny wyłącznie na tym urządzeniu.")
                            .font(.caption)
                    }
                    Text("Usunięcie lokalnego zapisu nie usuwa udostępnionego wpisu. Wspólny wpis wygaśnie po 30 minutach.")
                        .font(.caption)
                    Text("Zgłoszenie korka jest obserwacją użytkownika, a nie pomiarem prędkości. Nie zmienia czasu przejazdu ani automatycznie trasy.")
                        .font(.caption)
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
                Section("Moje zgłoszenia lokalne") {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let reports = store.reports.filter { $0.expiresAt > context.date }
                        if reports.isEmpty { Text("Brak aktywnych zgłoszeń") }
                        ForEach(reports) { report in
                            HStack {
                                VStack(alignment: .leading) {
                                    Label(report.kind.title, systemImage: report.kind.symbol)
                                    Text("Wygasa o " + report.expiresAt.formatted(.dateTime.locale(Locale(identifier: "pl_PL")).hour().minute()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Usuń lokalnie", role: .destructive) {
                                    do { try store.remove(report.id); onChange() }
                                    catch { self.errorMessage = RoadReportError.storage.errorDescription }
                                }
                            }
                        }
                    }
                }
            }
            .environment(\.locale, Locale(identifier: "pl_PL"))
            .navigationTitle("Zgłoś zdarzenie")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Zamknij") { dismiss() } } }
        }
    }

    private func save(shared: Bool) {
        guard let coordinate, let locationTimestamp, (-5...60).contains(Date().timeIntervalSince(locationTimestamp)) else { errorMessage = RoadReportError.invalidLocation.errorDescription; return }
        saving = true; errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                let report: LocalRoadReport
                if let savedReport, savedReport.kind == kind, LocalRoadReportStore.valid(savedReport, at: Date()) {
                    report = savedReport
                } else {
                    report = try store.add(kind: kind, coordinate: coordinate)
                    savedReport = report
                    onChange()
                }
                if shared { try await SharedRoadReportsClient.publish(report) }
                dismiss()
            } catch let failure as RoadReportError { errorMessage = failure.errorDescription }
            catch { errorMessage = RoadReportError.server.errorDescription }
        }
    }
}
#endif
