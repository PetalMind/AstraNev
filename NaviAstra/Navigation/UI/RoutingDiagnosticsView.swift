import SwiftUI
import UniformTypeIdentifiers

struct RoutingDiagnosticDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct RoutingDiagnosticsView: View {
    let navigation: NavigationStore
    @State private var diagnostics = RoutingDiagnostics.shared
    @State private var report: RoutingBenchmarkReport?
    @State private var busy = false
    @State private var error: String?
    @State private var document: RoutingDiagnosticDocument?
    @State private var exporting = false
    @State private var importing = false

    var body: some View {
        Form {
            Section("Lokalna diagnostyka") {
                Toggle("Zapisuj decyzje routingu", isOn: $diagnostics.recordingEnabled)
                Text("Zapis zawiera warianty i współrzędne tras. Pozostaje na urządzeniu: maksymalnie 20 zapisów i 20 MB. Nie jest wysyłany do serwera.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Usuń zapisane decyzje", role: .destructive) {
                    Task { do { try await RoutingDiagnosticsArchive.shared.clear() } catch { self.error = error.localizedDescription } }
                }
                if let archiveError = diagnostics.archiveError { Text(archiveError).foregroundStyle(.orange) }
            }
            DrivingLearningDiagnosticsView()
            if let matching = navigation.state.mapMatchingResult {
                Section("Dopasowanie pozycji") {
                    LabeledContent("Droga", value: matching.roadName ?? "Brak nazwy")
                    LabeledContent("Jakość dopasowania", value: percent(matching.match.confidence))
                    LabeledContent("Niejednoznaczność", value: matching.ambiguous ? "Tak" : "Nie")
                    LabeledContent("Stan zjazdu", value: navigation.state.deviationState.rawValue)
                }
            }
            if let reliability = navigation.state.routeReliability {
                Section("Ruch i ETA") {
                    LabeledContent("Pozostała geometria", value: meters(reliability.coverage.routeDistance))
                    LabeledContent("Monitorowany korytarz", value: meters(reliability.coverage.monitoredDistance))
                    LabeledContent("Świeże pomiary", value: meters(reliability.coverage.freshDistance))
                    LabeledContent("Pokrycie korytarza", value: percent(reliability.coverage.corridorFraction))
                    LabeledContent("Pokrycie pozostałej trasy", value: percent(reliability.coverage.routeFraction))
                    LabeledContent("Jakość danych", value: reliability.level.title)
                    LabeledContent("Budżet próbek", value: String(navigation.state.trafficSamplingBudget))
                    if let confidence = navigation.state.etaConfidence { Text(confidence.explanation) }
                    Text("Ocena jakości danych nie jest prawdopodobieństwem przyjazdu na czas. Statystyczny przedział ETA nie jest jeszcze skalibrowany.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let record = diagnostics.latest {
                Section("Ostatnia decyzja") {
                    LabeledContent("Źródło", value: record.source)
                    LabeledContent("Preferencja", value: record.preference.title)
                    if let failure = record.failure { Text(failure).foregroundStyle(.orange) }
                    if let seconds = record.calculationSeconds {
                        LabeledContent("Obliczenie planu", value: seconds.formatted(.number.precision(.fractionLength(2))) + " s")
                    }
                    ForEach(Array(record.candidates.enumerated()), id: \.element.id) { index, candidate in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Wariant \(index + 1)\(candidate.id == record.selectedRouteID ? " · aktywny" : "")")
                                .font(.headline)
                            Text("\(meters(candidate.distance)) · \(candidate.eta.map { Int(ceil($0 / 60)).description + " min" } ?? "Droga zablokowana")")
                            Text(candidate.reason).font(.caption)
                            if let personal = candidate.personalEvidence {
                                Text("Wpływ personalizacji: \(personal.appliedWeight.formatted(.percent))")
                                    .font(.caption)
                                ForEach(Array(personal.contributions.prefix(8).enumerated()), id: \.offset) { _, contribution in
                                    Text("\(contribution.reason.title): pewność \(number(contribution.metrics.confidence)), siła \(number(contribution.metrics.strength)), dopasowanie \(number(contribution.metrics.relevance)), aktualność \(number(contribution.metrics.recency))")
                                        .font(.caption)
                                }
                            }
                            Text("Czas \(number(candidate.normalized.time)) · dystans \(number(candidate.normalized.distance)) · manewry \(candidate.normalized.comfort.map(number) ?? "brak danych")")
                                .font(.caption.monospaced())
                            Text("Nawierzchnia: \(candidate.normalized.surface.map(number) ?? "brak porównywalnych danych") · ruch: \(candidate.normalized.reliability.map(number) ?? "brak porównywalnych danych")")
                                .font(.caption)
                        }
                    }
                    Text("Niższa wartość rankingu jest lepsza. Normalizacja obejmuje porównywany zestaw; brak danych nie jest zerowym kosztem.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Eksportuj decyzję JSON") { export(record) }
                }
            } else {
                Section { Text("Diagnostyka decyzji pojawi się po wyznaczeniu trasy samochodowej.") }
            }
            Section("Benchmarki krytyczne") {
                Button("Uruchom 120 scenariuszy syntetycznych") {
                    run { RoutingBenchmarkSuite.run() }
                }.disabled(busy)
                Button("Odtwórz ranking zapisanych decyzji") {
                    Task {
                        do {
                            let records = try await RoutingDiagnosticsArchive.shared.records()
                            guard !records.isEmpty else { error = "Brak zapisanych decyzji do odtworzenia."; return }
                            run { RoutingBenchmarkSuite.replay(records) }
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy)
                Button("Importuj decyzję JSON do odtworzenia") { importing = true }.disabled(busy)
                Text("Scenariusze syntetyczne sprawdzają algorytmy bez sieci. Odtworzenie zapisanych pomiarów sprawdza ranking; nie oblicza ponownie drogi w Valhalli.")
                    .font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView("Obliczanie…") }
                if let report {
                    Text(report.dataset).font(.caption)
                    LabeledContent("Scenariusze", value: String(report.cases.count))
                    LabeledContent("Różnice lub błędy", value: String(report.failures))
                    LabeledContent("Czas zestawu", value: report.elapsedSeconds.formatted(.number.precision(.fractionLength(3))) + " s")
                    ForEach(report.cases.filter { !$0.passed }, id: \.id) { item in
                        Text("\(item.id): \(item.expected) → \(item.measured)").font(.caption).foregroundStyle(.orange)
                    }
                    Button("Eksportuj raport JSON") { export(report) }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .navigationTitle("Diagnostyka routingu")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "NaviAstra-routing-diagnostics") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size <= 10_000_000 else { throw ValhallaFeatureError.message("Plik przekracza limit 10 MB.") }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                let record = try decoder.decode(RoutingDecisionRecord.self, from: Data(contentsOf: url))
                guard record.isReplayable else { throw ValhallaFeatureError.message("Nieobsługiwana wersja diagnostyki.") }
                run { RoutingBenchmarkSuite.replay([record]) }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func percent(_ value: Double) -> String { "\(Int((min(1, max(0, value)) * 100).rounded()))%" }
    private func meters(_ value: Double) -> String { (value / 1_000).formatted(.number.precision(.fractionLength(1))) + " km" }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(3))) }
    private func run(_ work: @escaping @Sendable () -> RoutingBenchmarkReport) {
        busy = true; error = nil
        Task { report = await Task.detached(priority: .utility) { work() }.value; busy = false }
    }
    private func export<T: Encodable>(_ value: T) {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            document = RoutingDiagnosticDocument(data: try encoder.encode(value)); exporting = true
        } catch { self.error = error.localizedDescription }
    }
}
