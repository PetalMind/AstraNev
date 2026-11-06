import SwiftUI
import Charts
import OSLog

struct RouteInformationView: View {
    private static let logger = Logger(subsystem: "NaviAstra", category: "RouteInformation")
    let route: NavigationRoute
    @State private var expanded = false
    @State private var details: DetailedRouteInformation?
    @State private var loading = false
    @State private var failure: String?
    @State private var retry = 0
    @State private var loadID = UUID()

    var body: some View {
        if let information = route.information {
            DisclosureGroup(information.scopeDescription ?? "Szczegóły trasy", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    summary(information)
                    if expanded {
                        detailedContent
                            .task(id: retry) { await load(information.source) }
                    }
                    Text("Ograniczenia mogą być niepełne. Kwoty opłat nie są uwzględnione.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private func summary(_ information: RouteInformation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Odcinki płatne", flag(information.toll))
            row("Autostrady", flag(information.highway))
            row("Promy", flag(information.ferry))
            row("Ograniczenia zależne od czasu", flag(information.timeRestrictions))
            if !information.countries.isEmpty { row("Kraje", information.countries.joined(separator: " · ")) }
            if let side = information.destinationSide, side == "left" || side == "right" {
                row("Cel po stronie", side == "left" ? "Lewej" : "Prawej")
            }
            let notices = Array(Set(route.maneuvers.flatMap { $0.information?.notices ?? [] })).sorted()
            ForEach(notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder private var detailedContent: some View {
        if loading { ProgressView("Pobieranie szczegółów odcinków…").font(.caption) }
        if let failure {
            Text(failure).font(.caption).foregroundStyle(.secondary)
            if route.information?.source != nil {
                Button("Spróbuj ponownie") { retry += 1 }.font(.caption)
            }
        }
        if let details {
            if details.completedLegs < details.totalLegs {
                Text("Nie udało się pobrać wszystkich szczegółów trasy.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Ponów pobieranie") { retry += 1 }.font(.caption)
            }
            if !details.countries.isEmpty { row("Kraje odcinków", details.countries.joined(separator: " · ")) }
            if !details.regions.isEmpty { row("Regiony", details.regions.joined(separator: " · ")) }
            if !details.sections.isEmpty {
                DisclosureGroup("Nawierzchnia, rodzaje dróg i limity") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(["Nawierzchnia", "Klasa drogi", "Rodzaj odcinka", "Limit prędkości", "Liczba pasów", "Chodnik", "Pas rowerowy", "Trudność szlaku"], id: \.self) { title in
                            distribution(title, sections: details.sections)
                        }
                        ForEach(["Tunel", "Most", "Opłaty", "Nawierzchnia nieutwardzona lub nierówna"], id: \.self) { title in
                            let length = details.sections.filter { section in section.attributes.contains { $0.title == title && $0.value == "Tak" } }.reduce(0) { $0 + $1.lengthMeters }
                            if length > 0 { row(title, formatDistance(length)) }
                        }
                    }.padding(.top, 6)
                }
                elevation(details)
                DisclosureGroup("Odcinki drogi") {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(details.sections) { section in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 4) {
                                    row("Długość", formatDistance(section.lengthMeters))
                                    ForEach(roadInformationItems(section.attributes)) { item in row(item.title, item.value) }
                                }.padding(.top, 4)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.names.isEmpty ? "Droga bez nazwy" : section.names.joined(separator: " · "))
                                    Text("Od \(formatDistance(section.startMeters)) · \(formatDistance(section.lengthMeters))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder private func elevation(_ details: DetailedRouteInformation) -> some View {
        let known = details.elevations.filter { $0.heightMeters != nil }
        DisclosureGroup("Profil wysokości") {
            if known.count > 1 {
                Chart(chartPoints(details.elevations)) { point in
                    LineMark(x: .value("Dystans (km)", point.distance / 1000),
                             y: .value("Wysokość (m)", point.height), series: .value("Część", point.series))
                }
                .chartYAxisLabel("m n.p.m.")
                .chartXAxisLabel("km")
                .frame(height: 150)
                if let low = known.compactMap(\.heightMeters).min(), let high = known.compactMap(\.heightMeters).max() {
                    row("Najniższy / najwyższy punkt", "\(Int(low.rounded())) / \(Int(high.rounded())) m n.p.m.")
                }
                row("Podejścia / podjazdy", details.ascent.map { "około \(Int($0.rounded())) m" } ?? "Brak pełnych danych")
                row("Zejścia / zjazdy", details.descent.map { "około \(Int($0.rounded())) m" } ?? "Brak pełnych danych")
                Text("Wysokości i przewyższenia są szacunkowe.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Profil wysokości niedostępny.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private struct ElevationPoint: Identifiable {
        var id: Int
        var distance: Double
        var height: Double
        var series: Int
    }

    private func chartPoints(_ samples: [RouteElevationSample]) -> [ElevationPoint] {
        var series = 0
        return samples.enumerated().compactMap { index, sample in
            guard let height = sample.heightMeters else { series += 1; return nil }
            return ElevationPoint(id: index, distance: sample.distanceMeters, height: height, series: series)
        }
    }

    private func distribution(_ title: String, sections: [RouteRoadSection]) -> some View {
        let groups = Dictionary(grouping: sections) { section in
            section.attributes.first { $0.title == title }?.value ?? "Brak danych"
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(groups.keys.sorted(), id: \.self) { value in
                let length = (groups[value] ?? []).reduce(0) { $0 + $1.lengthMeters }
                row(value, formatDistance(length))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }.font(.caption)
    }

    private func roadInformationItems(_ attributes: [RouteInformationItem]) -> [RouteInformationItem] {
        // Provider identifiers, model measurements and graph details stay in the data model.
        let visibleTitles: Set<String> = [
            "Nawierzchnia", "Klasa drogi", "Rodzaj odcinka", "Limit prędkości", "Liczba pasów",
            "Chodnik", "Pas rowerowy", "Sieć rowerowa", "Trudność szlaku", "Opłaty",
            "Nawierzchnia nieutwardzona lub nierówna", "Tunel", "Most", "Rondo", "Pobocze",
            "Przekroczenie granicy", "Sygnalizacja świetlna", "Trasa dla ciężarówek", "Strona ruchu",
            "Średnia wysokość", "Maksymalny podjazd", "Maksymalny zjazd", "Pas HOV",
            "Numery zjazdów", "Drogi na zjeździe", "Kierunki na drogowskazie", "Nazwa węzła"
        ]
        return attributes.compactMap { item in
            if item.title == "Zamknięcie zgłoszone przez serwer" {
                return RouteInformationItem(title: "Zamknięty odcinek", value: item.value)
            }
            return visibleTitles.contains(item.title) ? item : nil
        }
    }

    private func flag(_ value: Bool?) -> String {
        value.map { $0 ? "Występują" : "Nie wykryto w danych" } ?? "Brak danych"
    }

    private func formatDistance(_ value: Double) -> String {
        value >= 1000
            ? (value / 1000).formatted(.number.locale(PolishRegionalFormat.locale).precision(.fractionLength(1))) + " km"
            : "\(Int(value.rounded())) m"
    }

    @MainActor private func load(_ source: RouteInformationSource?) async {
        for warning in route.information?.warnings ?? [] {
            Self.logger.debug("Ostrzeżenie dostawcy trasy: \(warning, privacy: .private)")
        }
        guard let source else { failure = "Szczegóły odcinków niedostępne dla tej trasy."; return }
        let token = UUID()
        loadID = token
        loading = true
        failure = nil
        defer { if loadID == token { loading = false } }
        do {
            let loaded = try await ValhallaRouteInformationProvider.shared.load(source)
            try Task.checkCancellation()
            guard loadID == token else { return }
            for notice in loaded.notices {
                Self.logger.debug("Szczegóły dostawcy trasy: \(notice, privacy: .private)")
            }
            details = loaded
        } catch is CancellationError {
            // Closing details or changing route cancels the request; it isn't a data error.
        } catch {
            Self.logger.error("Pobieranie szczegółów trasy: \(error.localizedDescription, privacy: .private)")
            if loadID == token { failure = "Nie udało się pobrać szczegółów trasy." }
        }
    }
}

struct ManeuverInformationView: View {
    let maneuver: Maneuver

    var body: some View {
        if let information = maneuver.information {
            VStack(alignment: .leading, spacing: 4) {
                if information.distanceMeters != nil || information.duration != nil {
                    Text(stage(information)).font(.caption2).foregroundStyle(.secondary)
                }
                if !information.notices.isEmpty {
                    Text(information.notices.joined(separator: " · ")).font(.caption2).foregroundStyle(.orange)
                }

            }
        }
    }
    private func stage(_ info: ManeuverInformation) -> String {
        var parts: [String] = []
        if let length = info.distanceMeters {
            parts.append(length >= 1000 ? String(format: "%.1f km", length / 1000) : "\(Int(length.rounded())) m")
        }
        if let duration = info.duration { parts.append(duration < 60 ? "\(Int(duration.rounded())) s" : "około \(Int((duration / 60).rounded())) min") }
        return "Odcinek: " + parts.joined(separator: " · ")
    }
}
