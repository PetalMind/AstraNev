import SwiftUI

struct DrivingLearningDiagnosticsView: View {
    @State private var engine = DrivingLearningEngine.shared

    var body: some View {
        Section("Pamięć personalizacji") {
            LabeledContent("Baza SQLite", value: engine.databaseBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "Pomiar niedostępny")
            LabeledContent("Dopasowane przejazdy", value: "\(engine.learnedTripCount)")
            LabeledContent("Oczekujące ślady", value: "\(engine.pendingCount)")
            LabeledContent("Odcinki w przejazdach", value: "\(engine.segmentCount)")
            LabeledContent("Dopasowane propozycje tras", value: "\(engine.offeredVariantCount)")
            LabeledContent("Wzorce tras", value: "\(engine.patterns.count)")
            LabeledContent("Własne warianty", value: "\(engine.shortcuts.count)")
            LabeledContent("Dojazdy", value: "\(engine.approaches.count)")
            LabeledContent("Dowody i działania", value: "\(engine.evidence.count)")
            Text("Liczby wynikają z lokalnej bazy. Brak informacji o dawnych propozycjach nie jest traktowany jako zero szans wyboru.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Ostatnie powody uczenia") {
            if engine.evidence.isEmpty { Text("Brak dowodów uczenia.").foregroundStyle(.secondary) }
            ForEach(Array(engine.evidence.prefix(30))) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.source.title).font(.subheadline.weight(.medium))
                    Text(TripHistoryFormat.date(item.timestamp)).font(.caption).foregroundStyle(.secondary)
                    Text(item.subject).font(.caption.monospaced()).textSelection(.enabled)
                    if let tripID = item.tripID { Text("Przejazd: \(tripID.uuidString)").font(.caption.monospaced()) }
                    if let before = item.confidenceBefore, let after = item.confidenceAfter {
                        Text("Pewność: \(before.formatted(.number.precision(.fractionLength(2)))) → \(after.formatted(.number.precision(.fractionLength(2))))")
                            .font(.caption)
                    }
                    if let offered = item.offeredAlternative {
                        Text("Zaproponowano \(offered.count) wariantów").font(.caption)
                    } else if item.source == .legacyImport {
                        Text("Dawne propozycje wariantów: brak danych").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
