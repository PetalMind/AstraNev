import SwiftUI

/// Presentation shared by the arrival panel and saved trip history.
struct DrivingScoreSummaryCard: View {
    let trip: TripRecord
    @State private var showsReport = false

    var body: some View {
        Button {
            showsReport = true
        } label: {
            HStack(spacing: 14) {
                if let score = trip.drivingScore {
                    DrivingScoreGauge(score: score, size: 64)
                } else {
                    Image(systemName: "waveform.path")
                        .font(.title2)
                        .foregroundStyle(Color.naviTextSecondary)
                        .frame(width: 64, height: 64)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ocena prowadzenia")
                        .font(.subheadline.weight(.semibold))
                    Text(trip.drivingScore?.headline ?? "Za mało danych do oceny")
                        .font(.caption)
                        .foregroundStyle(Color.naviTextSecondary)
                    Text("Zobacz szczegóły")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.naviTextSecondary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.naviTextPrimary)
        .modifier(NavigationGlassSurface(radius: 17))
        .sheet(isPresented: $showsReport) {
            NavigationStack {
                DrivingScoreReport(trip: trip)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Gotowe") { showsReport = false }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
    }
}

struct DrivingScoreHistoryLabel: View {
    let score: DrivingScore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "steeringwheel")
            Text("Ocena \(score.score)/100")
                .monospacedDigit()
            Text(score.headline)
                .foregroundStyle(Color.naviTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(score.displayColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(score.displayColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Ocena prowadzenia: \(score.score) na 100. \(score.headline). Zobacz szczegóły")
    }
}

private struct DrivingScoreGauge: View {
    let score: DrivingScore
    var size: CGFloat = 112

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(min(100, max(0, score.score))) / 100)
                .stroke(score.displayColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score.score)")
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("/ 100")
                    .font(.system(size: size * 0.12, weight: .medium))
                    .foregroundStyle(Color.naviTextSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wynik \(score.score) na 100")
    }
}

struct DrivingScoreReport: View {
    let trip: TripRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.destination.name).font(.title3.weight(.semibold))
                    Text(TripHistoryFormat.date(trip.startedAt))
                        .font(.subheadline)
                        .foregroundStyle(Color.naviTextSecondary)
                }

                if let score = trip.drivingScore {
                    scoredContent(score)
                } else {
                    unavailableContent
                }

                methodology
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Color.naviTextPrimary)
        .environment(\.locale, TripHistoryFormat.locale)
        .navigationTitle("Ocena prowadzenia")
        .inlineDrivingScoreTitle()
    }

    private func scoredContent(_ score: DrivingScore) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 12) {
                DrivingScoreGauge(score: score)
                Text(score.headline)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Oceniono \(score.scoredCategoryCount) z 4 kategorii")
                    .font(.caption)
                    .foregroundStyle(Color.naviTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(score.displayColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))

            Label {
                Text(score.coachingTip).font(.subheadline)
            } icon: {
                Image(systemName: "lightbulb")
                    .foregroundStyle(Color.accentColor)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Text("Co składa się na wynik").font(.headline)
                category("Płynność", symbol: "waveform.path", value: score.smoothnessScore,
                         detail: "Mocne przyspieszenia: \(score.harshAccelerationCount) · hamowania: \(score.harshBrakingCount)")
                category("Prędkość", symbol: "speedometer", value: score.speedScore,
                         detail: "Wykryte przekroczenia: \(score.speedingEventCount) · czas: \(speedingTime(score.speedingDuration))",
                         partialObservation: score.speedingEventCount > 0)
                category("Zakręty", symbol: "arrow.triangle.turn.up.right.diamond", value: score.cornersScore,
                         detail: "Mocne zmiany kierunku przy wyższej prędkości: \(score.aggressiveCornerCount)")
                category("Stabilność", symbol: "arrow.left.and.right", value: score.stabilityScore,
                         detail: "Równomierność zmian tempa przy prędkości od około 29 km/h.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Dostępność danych", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Text("Limity prędkości były znane przez \(Int((min(1, max(0, score.speedLimitCoverage)) * 100).rounded()))% czasu jazdy.")
                if score.speedScore == nil {
                    Text("Prędkość nie weszła do wyniku. Potrzeba co najmniej 60 sekund pomiarów ze znanym limitem i pokrycia 40% czasu jazdy.")
                } else if score.speedLimitCoverage < 1 {
                    Text("Ocena prędkości dotyczy tylko odcinków ze znanym limitem.")
                }
                Text("Brak danych w kategorii nie oznacza 100 punktów — ta kategoria jest pomijana, a wagi pozostałych są przeliczane.")
            }
            .font(.caption)
            .foregroundStyle(Color.naviTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func category(_ title: String, symbol: String, value: Int?, detail: String,
                          partialObservation: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(value.map { "\($0)/100" } ?? "Brak danych")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(value == nil ? Color.naviTextSecondary : Color.naviTextPrimary)
            }
            if let value {
                ProgressView(value: Double(min(100, max(0, value))), total: 100)
                    .tint(Color.accentColor)
                    .accessibilityHidden(true)
            }
            Text(value != nil ? detail : (partialObservation
                ? detail + " — na odcinkach ze znanym limitem; za mało danych do oceny."
                : "Za mało wiarygodnych pomiarów do oceny tej kategorii."))
                .font(.caption)
                .foregroundStyle(Color.naviTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Za mało danych do oceny", systemImage: "waveform.path")
                .font(.headline)
            if trip.distanceMeters < 2_000 || trip.movingSeconds < 90 {
                Text("Ocena wymaga co najmniej 2 km trasy i 90 sekund jazdy. W tej podróży nie osiągnięto tych progów.")
            } else {
                Text("Nie zebrano wystarczającej liczby wiarygodnych pomiarów GPS lub danych do oceny co najmniej 3 kategorii.")
            }
            Text("Brak wyniku nie oznacza złej jazdy. Aplikacja nie zastępuje brakujących pomiarów domyślną oceną.")
                .foregroundStyle(Color.naviTextSecondary)
        }
        .font(.subheadline)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
    }

    private var methodology: some View {
        DisclosureGroup("Jak powstaje ocena?") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Wynik jest szacunkiem na podstawie GPS. Oceniane są przyspieszenia i hamowania, jazda względem znanego limitu, zmiany kierunku oraz stabilność tempa.")
                Text("Wagi: płynność 35%, prędkość 30%, zakręty 20%, stabilność 15%. Do wyniku potrzeba co najmniej 3 kategorii, 15 poprawnych próbek, 2 km i 90 sekund jazdy.")
                Text("Zdarzenia prędkości są wykrywane po przekroczeniu znanego limitu o ponad 5 km/h w kolejnych pomiarach. Ten próg filtruje pomiary i nie zmienia obowiązującego ograniczenia.")
                Text("GPS nie opisuje sytuacji na drodze ani powodu hamowania. Wynik nie jest oceną bezpieczeństwa kierowcy; warunki na drodze i jakość sygnału wpływają na pomiary.")
            }
            .font(.caption)
            .foregroundStyle(Color.naviTextSecondary)
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.medium))
    }

    private func speedingTime(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 { return "\(seconds) s" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }
}

private extension View {
    @ViewBuilder
    func inlineDrivingScoreTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

private extension DrivingScore {
    var displayColor: Color {
        switch score {
        case 80...: Color(naviHex: NaviAstraColorPalette.success)
        case 60..<80: Color(naviHex: NaviAstraColorPalette.warning)
        default: Color(naviHex: NaviAstraColorPalette.danger)
        }
    }

    var coachingTip: String {
        let losses: [(Double, String)] = [
            (smoothnessScore.map { Double(100 - $0) * 0.35 } ?? -1,
             "Najwięcej punktów ubyło za mocne przyspieszenia i hamowania. Gdy warunki pozwalają, zmieniaj tempo łagodniej i utrzymuj odstęp."),
            (speedScore.map { Double(100 - $0) * 0.30 } ?? -1,
             "Najwięcej punktów ubyło za jazdę powyżej znanego limitu. Dostosuj prędkość do znaków i warunków na drodze."),
            (cornersScore.map { Double(100 - $0) * 0.20 } ?? -1,
             "Najwięcej punktów ubyło za mocne zmiany kierunku przy wyższej prędkości. Zmniejszaj prędkość przed zakrętem, gdy pozwala na to sytuacja."),
            (stabilityScore.map { Double(100 - $0) * 0.15 } ?? -1,
             "Najwięcej punktów ubyło za zmiany tempa przy wyższej prędkości. Gdy warunki pozwalają, utrzymuj równomierne tempo.")
        ]
        guard let largest = losses.max(by: { $0.0 < $1.0 }), largest.0 > 0 else {
            return "W dostępnych pomiarach nie wykryto zdarzeń obniżających wynik."
        }
        return largest.1
    }
}
