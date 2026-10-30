import SwiftUI

struct DrivingPersonalizationView: View {
    let endpoint: URL?
    private let engine = DrivingLearningEngine.shared
    @State private var confirmClear = false

    private func setting(_ key: WritableKeyPath<DrivingLearningSettings, Bool>) -> Binding<Bool> {
        Binding(get: { engine.settings[keyPath: key] }, set: { enabled in
            var settings = engine.settings
            settings[keyPath: key] = enabled
            engine.updateSettings(settings)
            if let endpoint { engine.processPending(endpoint: endpoint) }
        })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Ucz się moich tras", isOn: setting(\.enabled))
                Toggle("Zapamiętuj własne warianty", isOn: setting(\.shortcuts)).disabled(!engine.settings.enabled)
                Toggle("Ucz się preferowanych dróg", isOn: setting(\.roads)).disabled(!engine.settings.enabled)
                Toggle("Ucz się sposobu dojazdu do miejsc", isOn: setting(\.destinationApproach))
                    .disabled(!engine.settings.enabled)
            } header: {
                Text("Uczenie tras")
            } footer: {
                Text("Uczenie działa automatycznie po ukończonych przejazdach autem bez punktów pośrednich i postojów ładowania. Przerwa w GPS nie przekreśla zapisanych fragmentów drogi. Wariant powtarzany przez co najmniej trzy różne dni może wpłynąć na kolejne propozycje, także bez ręcznego potwierdzania. Pora jazdy pomaga wybrać właściwy wariant. ETA pozostaje wyliczane z trasy i ruchu.")
            }
            Section("Dopasowanie śladu i prywatność") {
                Toggle("Zezwalaj na dopasowanie na serwerze", isOn: setting(\.allowRemoteMatching))
                    .disabled(!engine.settings.enabled)
                Text("Uczenie działa lokalnie także bez pobranej paczki dróg: porównuje powtarzane ślady GPS z propozycją trasy. Paczka offline pozwala dodatkowo rozpoznać konkretne odcinki dróg. Historia i statystyki pozostają na iPhonie. Włączenie opcji powyżej pozwala wysłać ślad do skonfigurowanego serwera Valhalla. Proponowany znajomy wariant jest każdorazowo przeliczany według aktualnych ograniczeń ruchu.")
                    .font(.footnote).foregroundStyle(.secondary)
                #if os(macOS)
                Text("Na Macu dopasowanie śladów wymaga zezwolenia na użycie serwera.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
                LabeledContent("Dopasowane przejazdy", value: "\(engine.learnedTripCount)")
                LabeledContent("Oczekują na dopasowanie", value: "\(engine.pendingCount)")
                if engine.isProcessing { ProgressView("Dopasowywanie przejazdu…") }
                if let message = engine.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if engine.pendingCount > 0, let endpoint {
                    Button("Ponów dopasowanie") { engine.processPending(endpoint: endpoint) }
                        .disabled(engine.isProcessing || !engine.settings.enabled)
                }
                Text("Przechowujemy do 300 dopasowanych przejazdów z ostatniego roku. Kolejka do dopasowania mieści 10 skompresowanych śladów. Wyłączenie uczenia usuwa tę kolejkę. Preferencje możesz usunąć poniżej.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Nauczone preferencje") {
                if engine.patterns.isEmpty {
                    Label {
                        Text("Preferencje pojawią się po ukończonych przejazdach i dopasowaniu ich do dróg.")
                    } icon: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(engine.patterns) { pattern in
                    NavigationLink {
                        preferenceDetails(pattern)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Do: \(pattern.representative.destinationName)")
                            Text("\(pattern.usageCount) przejazdów · \(pattern.confirmed ? "Zapamiętana trasa" : pattern.confidence > 0 ? "Powtarzana trasa" : "Obserwacja")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            alternativeSection
            roadSection
            approachSection
            Section {
                Button("Usuń wszystkie preferencje i dane uczenia", role: .destructive) { confirmClear = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Personalizacja tras")
        .environment(\.locale, PolishRegionalFormat.locale)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { if let endpoint { engine.processPending(endpoint: endpoint) } }
        .confirmationDialog("Usunąć preferencje i dane uczenia?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Usuń dane uczenia", role: .destructive) { engine.clear() }
        }
    }

    private var alternativeSection: some View {
        Section("Własne warianty drogi") {
            if engine.shortcuts.isEmpty { Text("Brak zarejestrowanych własnych wariantów.").foregroundStyle(.secondary) }
            ForEach(engine.shortcuts) { shortcut in
                VStack(alignment: .leading, spacing: 5) {
                    Text(shortcut.deviation.preferred.flatMap(\.names).uniqued().joined(separator: ", ").nonEmpty ?? "Własny wariant drogi")
                    Text(shortcut.kind.title).font(.caption.weight(.medium))
                    Text("\(shortcut.uses) przejazdów")
                    Group {
                        if let offered = shortcut.offeredCount {
                            Text("Zaproponowano \(offered) razy · wybrano \(shortcut.chosenCount) · pominięto \(shortcut.avoidedCount)")
                        } else {
                            Text("Liczba wcześniejszych propozycji: brak danych")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text("Pewność: \(shortcut.confidence.formatted(.percent.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale)))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let duration = shortcut.averageObservedDuration {
                        Text("Średni zarejestrowany czas wariantu: " + TripHistoryFormat.duration(duration)).font(.caption)
                    }
                    Text("Oszczędność czasu: brak porównywalnego pomiaru alternatywy")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Usuń preferencję wariantu", role: .destructive) { engine.removeShortcut(shortcut.id) }
                        .font(.caption)
                }
            }
        }
    }

    private var roadSection: some View {
        Section("Preferowane i omijane drogi") {
            if engine.roads.isEmpty { Text("Brak powtarzanych wyborów konkretnych dróg.").foregroundStyle(.secondary) }
            ForEach(Array(engine.roads.prefix(100))) { road in
                VStack(alignment: .leading, spacing: 5) {
                    Text(road.names.joined(separator: ", ").nonEmpty ?? "Odcinek drogi bez nazwy")
                    Text("\(road.uses) przejazdów · \(road.selfSelected) własnych wyborów · \(road.avoided) ominięć").font(.caption).foregroundStyle(.secondary)
                    if road.offeredCountKnown {
                        Text("Zaproponowano \(road.offeredCount) razy · wybrano z propozycji \(road.chosenCount)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Dawne propozycje odcinka: brak danych").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Usuń preferencję drogi", role: .destructive) { engine.removeRoad(road.id) }
                        .font(.caption)
                }
            }
        }
    }

    private var approachSection: some View {
        Section("Preferowany dojazd do miejsc") {
            let approaches = engine.approaches.filter { $0.confidence > 0 }
            if approaches.isEmpty { Text("Brak powtarzanego sposobu dojazdu.").foregroundStyle(.secondary) }
            ForEach(approaches) { approach in
                VStack(alignment: .leading, spacing: 5) {
                    Text(approach.name)
                    Text("\(approach.trips.count) dojazdów · " + approach.segments.flatMap(\.names).uniqued().joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Usuń preferencję dojazdu", role: .destructive) { engine.removeApproach(approach.id) }
                        .font(.caption)
                }
            }
        }
    }

    private static func timeWindow(_ bucket: Int) -> String {
        guard (0..<12).contains(bucket) else { return "Nieznana pora" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = PolishRegionalFormat.locale
        guard let start = calendar.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: bucket * 2)),
              let end = calendar.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: bucket * 2 + 1, minute: 59))
        else { return "Nieznana pora" }
        return "\(PolishRegionalFormat.time(start))–\(PolishRegionalFormat.time(end))"
    }

    private func preferenceDetails(_ pattern: DrivingRoutePattern) -> some View {
        Form {
            Section("Preferowana trasa") {
                Text("Do: \(pattern.representative.destinationName)")
                LabeledContent("Liczba przejazdów", value: "\(pattern.usageCount)")
                LabeledContent("Średni zarejestrowany czas", value: TripHistoryFormat.duration(pattern.averageDuration))
                LabeledContent("Pewność dowodów", value: pattern.confidence.formatted(.percent.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale)))
                LabeledContent("Potwierdzona przez Ciebie", value: pattern.confirmed ? "Tak" : "Nie")
                LabeledContent("Siła preferencji", value: pattern.strength.formatted(.percent.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale)))
                Text("Średni czas opisuje wcześniejsze przejazdy. Nie zastępuje przewidywanego czasu nowej trasy.")
                    .font(.footnote).foregroundStyle(.secondary)
                let buckets = Set(pattern.trips.map { $0.context.hourBucket }).sorted()
                Text("Pora jazdy: " + buckets.map(Self.timeWindow).joined(separator: ", "))
                let days = Set(pattern.trips.map { $0.context.weekday }).sorted()
                Text("Dni: " + days.map(PolishRegionalFormat.weekday).joined(separator: ", "))
            }
            Section("Powtarzane odstępstwa i omijane drogi") {
                let groups = Dictionary(grouping: pattern.trips.flatMap(\.deviations), by: \.id)
                if groups.isEmpty { Text("Brak wiarygodnych odstępstw od proponowanej trasy.").foregroundStyle(.secondary) }
                ForEach(groups.keys.sorted(), id: \.self) { key in
                    if let group = groups[key], let deviation = group.first {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(deviation.preferred.flatMap(\.names).uniqued().joined(separator: ", ").nonEmpty ?? "Własny wariant drogi")
                            Text("\(group.count) użyć · \(TripHistoryFormat.distance(deviation.preferred.reduce(0) { $0 + $1.length }))")
                                .font(.caption).foregroundStyle(.secondary)
                            let avoided = deviation.avoided.flatMap(\.names).uniqued().joined(separator: ", ")
                            if !avoided.isEmpty { Text("Omijane: " + avoided).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section {
                if !pattern.confirmed, let endpoint {
                    Button("Zapamiętaj tę trasę") { engine.remember(pattern.representative.id, endpoint: endpoint) }
                }
                Button("Usuń preferencję", role: .destructive) { engine.remove(pattern) }
            }
        }
        .navigationTitle("Preferencja trasy")
        .formStyle(.grouped)
        .environment(\.locale, PolishRegionalFormat.locale)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] { Array(Set(self)).sorted() }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
