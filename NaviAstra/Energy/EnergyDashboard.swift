import SwiftUI
import Charts

enum EnergyNumber {
    static func text(_ value: Double, digits: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).locale(Locale(identifier: "pl_PL")))
    }
    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "PLN").locale(Locale(identifier: "pl_PL")))
    }
    static func parse(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }
}

struct EnergyCostLabel: View {
    let estimate: EnergyEstimate
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EnergyUsageLabel(estimate: estimate)
            Label("Szacowany koszt: \(EnergyNumber.money(estimate.cost))", systemImage: "fuelpump")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.naviTextPrimary)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct EnergyUsageLabel: View {
    let estimate: EnergyEstimate
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(estimate.components, id: \.kind) { component in
                Label("Szacowane zużycie · \(component.kind.title): ~\(EnergyNumber.text(component.quantity)) \(component.kind.unit)",
                      systemImage: component.kind.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.naviTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    Text("Średnie \(component.kind == .electricity ? "zużycie" : "spalanie"): \(EnergyNumber.text(component.consumptionPer100Km)) \(component.kind.unit)/100 km")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    Text(component.measurementDescription)
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

struct EnergyConsumptionSummary: View {
    let store: EnergyStore
    let vehicle: EnergyVehicle
    let trips: [TripRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vehicle.name).font(.subheadline.weight(.semibold))
            ForEach(vehicle.kinds) { kind in
                let periods = store.periods(for: vehicle, kind: kind, trips: trips)
                let valid = periods.filter { $0.consumption != nil }
                if let average = EnergyCalculator.average(valid) {
                    Label("Średnie \(kind == .electricity ? "zużycie" : "spalanie") · \(kind.title): \(EnergyNumber.text(average)) \(kind.unit)/100 km",
                          systemImage: kind.symbol)
                        .font(.subheadline).monospacedDigit()
                    Text("\(EnergyNumber.text(valid.reduce(0) { $0 + ($1.kilometers ?? 0) })) km · \(EnergyNumber.text(valid.reduce(0) { $0 + $1.quantity })) \(kind.unit) · \(valid.count) zamkniętych okresów")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    Text(EnergyCalculator.measurementDescription(valid))
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                } else {
                    Text("\(kind.title): \(store.consumptionUnavailableReason(for: vehicle, kind: kind, trips: trips))")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct EnergyDashboard: View {
    @Bindable var store: EnergyStore
    @Bindable var places: PlaceStore
    let coordinate: Coordinate?
    @State private var addingVehicle = false
    @State private var editingVehicle: EnergyVehicle?
    @State private var addingEntry = false
    @State private var editingEntry: EnergyEntry?
    @State private var removingEntry: EnergyEntry?
    @State private var removingVehicle: EnergyVehicle?
    @State private var interval = 30

    private var vehicle: EnergyVehicle? { store.selectedVehicle }
    private var vehicleEntries: [EnergyEntry] {
        store.entries.filter { $0.vehicleID == vehicle?.id }.sorted { $0.date > $1.date }
    }
    private var vehicleTrips: [TripRecord] {
        places.trips.filter { $0.vehicleID == vehicle?.id && $0.transportMode == .car && $0.arrived }
    }

    var body: some View {
        EnergyCanvas {
            if let error = store.errorMessage { EnergySection { Text(error).foregroundStyle(Color(naviHex: NaviAstraColorPalette.danger)) } }
            if let error = places.errorMessage { EnergySection { Text(error).foregroundStyle(Color(naviHex: NaviAstraColorPalette.danger)) } }
            EnergySection("Moje pojazdy") {
                if store.vehicles.isEmpty {
                    ContentUnavailableView("Dodaj pojazd", systemImage: "car.side",
                        description: Text("Zapisuj tankowania lub ładowania i porównuj je z przebiegiem samochodu."))
                } else {
                    Picker("Pojazd do kolejnych przejazdów", selection: Binding(
                        get: { store.selectedVehicle?.id }, set: { _ = store.select($0) })) {
                        ForEach(store.vehicles) { item in Text(item.name).tag(Optional(item.id)) }
                    }
                    if let vehicle {
                        LabeledContent("Napęd", value: vehicle.powertrain.title)
                        if let odometer = vehicleEntries.first(where: { $0.odometer != nil })?.odometer {
                            LabeledContent("Ostatni wpis licznika", value: "\(EnergyNumber.text(odometer)) km")
                        }
                        Button("Edytuj pojazd", systemImage: "pencil") { editingVehicle = vehicle }
                            .buttonStyle(.bordered)
                    }
                }
                Button("Dodaj pojazd", systemImage: "plus") { addingVehicle = true }
                    .buttonStyle(.bordered)
            }
            if let vehicle {
                overview(vehicle)
                statistics(vehicle)
                history(vehicle)
                tripAssignments(vehicle)
                EnergySection {
                    Text("Przebieg licznika ma pierwszeństwo. Dystans NaviAstra obejmuje tylko ukończone, przypisane przejazdy samochodem. Przejazd przecinający datę wpisu jest dzielony według dostępnego śladu GPS; luki i odcinki bez śladu są pomijane. Kwoty w PLN.")
                        .font(.footnote).foregroundStyle(Color.naviTextSecondary)
                    Button("Usuń pojazd", role: .destructive) { removingVehicle = vehicle }
                }
            }
        }
        .navigationTitle("Paliwo i koszty jazdy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if vehicle != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Dodaj wpis", systemImage: "plus") { addingEntry = true }
                }
            }
        }
        .sheet(isPresented: $addingVehicle) { EnergyVehicleEditor(store: store, original: nil) }
        .sheet(item: $editingVehicle) { EnergyVehicleEditor(store: store, original: $0) }
        .sheet(isPresented: $addingEntry) {
            if let vehicle { EnergyEntryEditor(store: store, vehicle: vehicle, original: nil, coordinate: coordinate, trips: places.trips) }
        }
        .sheet(item: $editingEntry) { entry in
            if let vehicle { EnergyEntryEditor(store: store, vehicle: vehicle, original: entry, coordinate: coordinate, trips: places.trips) }
        }
        .confirmationDialog("Usunąć wpis? Spalanie zostanie przeliczone.", isPresented: Binding(
            get: { removingEntry != nil }, set: { if !$0 { removingEntry = nil } }), titleVisibility: .visible, presenting: removingEntry) { entry in
                Button("Usuń", role: .destructive) {
                    _ = store.removeEntry(entry.id)
                    removingEntry = nil
                }
        }
        .confirmationDialog("Usunąć profil pojazdu? Przejazdy pozostaną w historii.", isPresented: Binding(
            get: { removingVehicle != nil }, set: { if !$0 { removingVehicle = nil } }), titleVisibility: .visible, presenting: removingVehicle) { vehicle in
                Button("Usuń", role: .destructive) {
                    _ = store.removeVehicle(vehicle.id)
                    removingVehicle = nil
                }
        }
    }

    @ViewBuilder private func overview(_ vehicle: EnergyVehicle) -> some View {
        ForEach(vehicle.kinds) { kind in
            let periods = store.periods(for: vehicle, kind: kind, trips: places.trips)
            EnergySection(kind.title, symbol: kind.symbol) {
                if let average = EnergyCalculator.average(periods) {
                    EnergyMetricHero(title: kind == .electricity ? "Średnie zużycie" : "Średnie spalanie", value: EnergyNumber.text(average), unit: "\(kind.unit)/100 km", symbol: kind.symbol)
                    Text(kind == .electricity ? "Energia ładowania obejmuje straty"
                         : EnergyCalculator.measurementDescription(periods))
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                } else {
                    Text(store.consumptionUnavailableReason(for: vehicle, kind: kind, trips: places.trips))
                        .foregroundStyle(Color.naviTextSecondary)
                }
                if let last = vehicleEntries.first(where: { $0.kind == kind }) {
                    LabeledContent("Ostatni wpis", value: "\(EnergyNumber.text(last.quantity)) \(kind.unit) · \(EnergyNumber.money(last.totalPrice))")
                    let since = vehicleTrips.filter { EnergyCalculator.recordedKilometers($0, from: last.date, to: Date()) != nil }
                    LabeledContent("Zapisany dystans od wpisu", value: "\(EnergyNumber.text(since.reduce(0) { $0 + (EnergyCalculator.recordedKilometers($1, from: last.date, to: Date()) ?? 0) })) km")
                    LabeledContent("Przejazdy od wpisu", value: "\(since.count)")
                    let wholeTrips = since.filter { $0.startedAt >= last.date }
                    let moving = wholeTrips.reduce(0) { $0 + $1.movingSeconds }
                    LabeledContent("Czas całych przejazdów", value: "\(Int(moving / 3600)) h \(Int(moving / 60) % 60) min")
                    if moving > 0 {
                        LabeledContent("Średnia całych przejazdów", value: "\(EnergyNumber.text(wholeTrips.reduce(0) { $0 + $1.distanceMeters } / moving * 3.6, digits: 1)) km/h")
                    }
                }
                let valid = periods.filter { $0.consumption != nil }
                if !valid.isEmpty {
                    Chart(valid) { period in
                        LineMark(x: .value("Data", period.end.date), y: .value("Zużycie", period.consumption!))
                            .foregroundStyle(Color.accentColor)
                        PointMark(x: .value("Data", period.end.date), y: .value("Zużycie", period.consumption!))
                            .foregroundStyle(Color.accentColor)
                    }
                    .chartYAxisLabel("\(kind.unit)/100 km")
                    .chartPlotStyle { $0.background(Color.accentColor.opacity(0.035)) }
                    .tint(Color.accentColor)
                    .frame(height: 160)
                    .accessibilityLabel("Zużycie w zamkniętych okresach pomiarowych: \(kind.title)")
                }
            }
        }
        EnergySection("Koszt przejazdu") {
            if let estimate = store.estimate(vehicleID: vehicle.id, kilometers: 1, trips: places.trips) {
                EnergyMetricHero(title: "Szacowany koszt kilometra", value: EnergyNumber.money(estimate.cost), unit: "/ km", symbol: "creditcard")
                Text("Średnie zużycie i ostatnia cena każdego rodzaju energii. Dla PHEV wynik wymaga danych benzyny i prądu.")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
            } else {
                Text("Koszt pojawi się po zamknięciu pomiaru zużycia dla każdego rodzaju energii pojazdu.")
                    .foregroundStyle(Color.naviTextSecondary)
            }
        }
    }

    private func statistics(_ vehicle: EnergyVehicle) -> some View {
        let now = Date()
        let calendar = Calendar.current
        let start = interval == 365 ? calendar.dateInterval(of: .year, for: now)!.start
            : calendar.date(byAdding: .day, value: -30, to: now)!
        let entries = vehicleEntries.filter { $0.date >= start && $0.date <= now }
        let trips = vehicleTrips.filter { EnergyCalculator.recordedKilometers($0, from: start, to: now) != nil }
        return EnergySection("Statystyki") {
            Picker("Okres", selection: $interval) {
                Text("Ostatnie 30 dni").tag(30)
                Text("Bieżący rok").tag(365)
            }.pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 18) {
                EnergyMetric(title: "Zarejestrowano", value: "\(EnergyNumber.text(trips.reduce(0) { $0 + (EnergyCalculator.recordedKilometers($1, from: start, to: now) ?? 0) })) km", symbol: "road.lanes")
                EnergyMetric(title: "Wydatki", value: EnergyNumber.money(entries.reduce(0) { $0 + $1.totalPrice }), symbol: "creditcard")
                EnergyMetric(title: "Tankowania i ładowania", value: "\(entries.count)", symbol: "fuelpump")
            }
            Divider()
            let month = calendar.dateInterval(of: .month, for: now)!.start
            LabeledContent("Wydatki w tym miesiącu", value: EnergyNumber.money(vehicleEntries.filter { $0.date >= month && $0.date <= now }.reduce(0) { $0 + $1.totalPrice }))
            ForEach(vehicle.kinds) { kind in
                let matching = entries.filter { $0.kind == kind }
                let quantity = matching.reduce(0) { $0 + $1.quantity }
                LabeledContent("Kupiono · \(kind.title)", value: "\(EnergyNumber.text(quantity)) \(kind.unit)")
                if quantity > 0 {
                    LabeledContent("Średnia cena · \(kind.title)", value: "\(EnergyNumber.money(matching.reduce(0) { $0 + $1.totalPrice } / quantity))/\(kind.unit)")
                }
                let periods = store.periods(for: vehicle, kind: kind, trips: places.trips)
                    .filter { $0.start.date >= start && $0.end.date <= now }
                if let average = EnergyCalculator.average(periods) {
                    LabeledContent("Zużycie · \(kind.title)", value: "\(EnergyNumber.text(average)) \(kind.unit)/100 km")
                }
            }
            Text("Zakupy energii nie oznaczają zużycia w tym samym okresie. Średnie zużycie obejmuje tylko całe zamknięte okresy.")
                .font(.caption).foregroundStyle(Color.naviTextSecondary)
        }
    }

    private func history(_ vehicle: EnergyVehicle) -> some View {
        EnergySection("Historia tankowań i ładowań") {
            EnergyConsumptionSummary(store: store, vehicle: vehicle, trips: places.trips)
            Divider()
            if vehicleEntries.isEmpty { Text("Brak wpisów").foregroundStyle(Color.naviTextSecondary) }
            ForEach(vehicleEntries) { entry in
                let period = store.periods(for: vehicle, kind: entry.kind, trips: places.trips).first { $0.end.id == entry.id }
                DisclosureGroup {
                    LabeledContent("Cena", value: "\(EnergyNumber.money(entry.unitPrice))/\(entry.kind.unit)")
                    LabeledContent("Pełny zbiornik / bateria", value: entry.full ? "Tak" : "Nie")
                    if entry.kind != .electricity {
                        LabeledContent("Przed tankowaniem", value: (entry.fuelLevelBefore ?? .unspecified).title)
                    }
                    if let odometer = entry.odometer { LabeledContent("Licznik", value: "\(EnergyNumber.text(odometer)) km") }
                    if let period {
                        LabeledContent("Metoda", value: period.measurement.title)
                        LabeledContent("Początek okresu", value: TripHistoryFormat.date(period.start.date))
                        LabeledContent("Energia w okresie", value: "\(EnergyNumber.text(period.quantity)) \(entry.kind.unit)")
                        LabeledContent("Dystans", value: period.kilometers.map { "\(EnergyNumber.text($0)) km" } ?? "Brak danych")
                        LabeledContent("Dystans GPS", value: "\(EnergyNumber.text(period.recordedKilometers)) km")
                        LabeledContent("Przejazdy", value: "\(period.trips.count)")
                        if let consumption = period.consumption { LabeledContent("Zużycie", value: "\(EnergyNumber.text(consumption)) \(entry.kind.unit)/100 km") }
                        if let cost = period.costPerKm { LabeledContent("Koszt okresu/km", value: EnergyNumber.money(cost)) }
                        Text(period.quality).font(.caption).foregroundStyle(Color.naviTextSecondary)
                        if period.measurement == .reserveToReserve {
                            Text("Uwzględniono paliwo od tankowania rozpoczynającego okres. Paliwo z tego wpisu rozpoczyna kolejny pomiar.")
                                .font(.caption).foregroundStyle(Color.naviTextSecondary)
                        }
                    } else {
                        Text("Ten wpis nie zamyka osobnego pomiaru. Może rozpoczynać okres lub być uwzględniony w dłuższym pomiarze. Pełne zbiorniki mają pierwszeństwo przed nakładającymi się szacunkami z rezerwy.")
                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    }
                    HStack(spacing: 12) {
                        Button("Edytuj", systemImage: "pencil") { editingEntry = entry }
                            .buttonStyle(.bordered)
                        Button("Usuń wpis", systemImage: "trash", role: .destructive) { removingEntry = entry }
                            .buttonStyle(.bordered)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(entry.station.isEmpty ? entry.kind.title : entry.station, systemImage: entry.kind.symbol)
                            .font(.headline).foregroundStyle(Color.naviTextPrimary)
                        Text(TripHistoryFormat.date(entry.date)).font(.caption).foregroundStyle(Color.naviTextSecondary)
                        Text("\(entry.kind.title) · \(EnergyNumber.text(entry.quantity)) \(entry.kind.unit) · \(EnergyNumber.money(entry.totalPrice))")
                            .font(.subheadline)
                        if entry.startsAtReserve {
                            Label("Przed tankowaniem: rezerwa", systemImage: "fuelpump")
                                .font(.caption).foregroundStyle(Color.naviTextSecondary)
                        }
                        if let consumption = period?.consumption {
                            Text("\(entry.kind == .electricity ? "Zużycie" : "Spalanie") w okresie: \(EnergyNumber.text(consumption)) \(entry.kind.unit)/100 km")
                                .font(.caption).foregroundStyle(Color.naviTextSecondary)
                            if let period {
                                Text(period.measurement.title)
                                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tripAssignments(_ vehicle: EnergyVehicle) -> some View {
        EnergySection("Przejazdy i koszt paliwa") {
            let carTrips = places.trips.filter { $0.transportMode == .car && $0.arrived }.sorted { $0.startedAt > $1.startedAt }
            if carTrips.isEmpty { Text("Brak ukończonych przejazdów samochodem").foregroundStyle(Color.naviTextSecondary) }
            ForEach(carTrips) { trip in
                DisclosureGroup {
                    Picker("Pojazd tego przejazdu", selection: Binding(
                        get: { places.trips.first(where: { $0.id == trip.id })?.vehicleID },
                        set: { _ = places.assignVehicle($0, to: trip.id) })) {
                            Text("Nieprzypisany").tag(nil as UUID?)
                            ForEach(store.vehicles) { Text($0.name).tag(Optional($0.id)) }
                        }
                    if let estimate = store.estimate(for: trip, trips: places.trips) {
                        EnergyCostLabel(estimate: estimate)
                        Text("Szacunek według aktualnej średniej pojazdu i ostatnich zapisanych cen, także z późniejszych tankowań.")
                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    } else { Text("Przypisz pojazd i zapisz dystans oraz zamknięty pomiar: między rezerwami lub pełnymi zbiornikami; dla prądu między ładowaniami do 100%.").font(.caption).foregroundStyle(Color.naviTextSecondary) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(trip.destination.name, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.subheadline.weight(.semibold))
                        Text("\(TripHistoryFormat.date(trip.startedAt)) · \(EnergyNumber.text(trip.distanceMeters / 1000)) km")
                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                        Text(store.vehicles.first(where: { $0.id == trip.vehicleID })?.name ?? "Nieprzypisany pojazd")
                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                        if let estimate = store.estimate(for: trip, trips: places.trips) {
                            EnergyUsageLabel(estimate: estimate, compact: true)
                        }
                    }
                }
            }
        }
    }
}

struct EnergyVehicleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: EnergyStore
    let original: EnergyVehicle?
    @State private var name = ""
    @State private var powertrain = VehiclePowertrain.combustion
    @State private var fuel = EnergyKind.pb95
    @State private var tank = ""
    @State private var battery = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            EnergyCanvas {
                EnergySection("Pojazd", symbol: "car.side.fill") {
                    TextField("Nazwa pojazdu", text: $name)
                    Picker("Napęd", selection: $powertrain) { ForEach(VehiclePowertrain.allCases) { Text($0.title).tag($0) } }
                    if powertrain != .electric {
                        Picker("Paliwo", selection: $fuel) { ForEach(EnergyKind.allCases.filter { $0 != .electricity }) { Text($0.title).tag($0) } }
                        TextField("Pojemność zbiornika (L, opcjonalnie)", text: $tank)
                    }
                    if powertrain != .combustion { TextField("Pojemność baterii (kWh, opcjonalnie)", text: $battery) }
                }
                if let error { EnergySection("Nie udało się zapisać", symbol: "exclamationmark.triangle") { Text(error).foregroundStyle(Color(naviHex: NaviAstraColorPalette.danger)) } }
            }
            .navigationTitle(original == nil ? "Dodaj pojazd" : "Edytuj pojazd")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Zapisz") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .onAppear {
                if let original {
                    name = original.name; powertrain = original.powertrain; fuel = original.fuel
                    tank = original.tankCapacity.map { EnergyNumber.text($0) } ?? ""
                    battery = original.batteryCapacity.map { EnergyNumber.text($0) } ?? ""
                }
            }
        }
        .frame(minWidth: 320, minHeight: 400)
    }
    private func save() {
        guard tank.isEmpty || EnergyNumber.parse(tank).map({ $0 > 0 }) == true,
              battery.isEmpty || EnergyNumber.parse(battery).map({ $0 > 0 }) == true else {
            error = "Podaj prawidłową pojemność lub pozostaw pole puste."; return
        }
        var vehicle = original ?? EnergyVehicle(name: name)
        vehicle.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        vehicle.powertrain = powertrain; vehicle.fuel = fuel
        vehicle.tankCapacity = powertrain == .electric ? nil : EnergyNumber.parse(tank)
        vehicle.batteryCapacity = powertrain == .combustion ? nil : EnergyNumber.parse(battery)
        if store.saveVehicle(vehicle) { dismiss() } else { error = store.errorMessage }
    }
}

struct EnergyEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: EnergyStore
    let vehicle: EnergyVehicle
    let original: EnergyEntry?
    let coordinate: Coordinate?
    let trips: [TripRecord]
    var suggestedStation: FuelStopStation? = nil
    var onSaved: (() -> Void)? = nil
    @State private var quote: StationFuelPrices?
    @State private var priceLoading = false
    @State private var priceFailure = false
    @State private var priceRetry = 0
    @State private var appliedSuggestedPrice: String?
    @State private var date = Date()
    @State private var kind = EnergyKind.pb95
    @State private var quantity = ""
    @State private var price = ""
    @State private var total = ""
    @State private var quantityFromTotal = false
    @State private var odometer = ""
    @State private var full = false
    @State private var fuelLevelBefore = FuelLevelBefore.unspecified
    @State private var draftID = UUID()
    @State private var station = ""
    @State private var error: String?
    @State private var attachLocation = false
    private var parsedQuantity: Double? { EnergyNumber.parse(quantity) }
    private var parsedPrice: Double? { EnergyNumber.parse(price) }
    private var parsedTotal: Double? { EnergyNumber.parse(total) }
    private var draftEntry: EnergyEntry? {
        guard let quantity = parsedQuantity, quantity > 0, let price = parsedPrice, price >= 0,
              let total = parsedTotal, total >= 0,
              odometer.isEmpty || EnergyNumber.parse(odometer).map({ $0 >= 0 }) == true else { return nil }
        return EnergyEntry(id: original?.id ?? draftID, vehicleID: vehicle.id, date: date, kind: kind,
            quantity: quantity, unitPrice: price, totalPrice: total, odometer: EnergyNumber.parse(odometer),
            full: full, station: station.trimmingCharacters(in: .whitespacesAndNewlines),
            coordinate: original?.coordinate ?? suggestedStation?.identity.coordinate ?? (attachLocation ? coordinate : nil),
            fuelLevelBefore: kind == .electricity || fuelLevelBefore == .unspecified ? nil : fuelLevelBefore)
    }
    private var closingPeriod: EnergyPeriod? {
        guard let entry = draftEntry else { return nil }
        return EnergyCalculator.periods(vehicleID: vehicle.id, kind: kind,
            entries: store.entries.filter { $0.id != entry.id } + [entry], trips: trips)
            .first { $0.end.id == entry.id }
    }

    var body: some View {
        NavigationStack {
            EnergyCanvas {
                EnergySection(vehicle.name, symbol: kind.symbol) {
                    DatePicker("Data", selection: $date, in: ...Date())
                    Picker("Rodzaj energii", selection: $kind) { ForEach(vehicle.kinds) { Text($0.title).tag($0) } }
                    TextField("Ilość (\(kind.unit))", text: Binding(get: { quantity }, set: {
                        quantityFromTotal = false; quantity = $0; recalculate()
                    }))
                    TextField("Cena za \(kind.unit) (zł)", text: Binding(get: { price }, set: {
                        appliedSuggestedPrice = nil; price = $0; recalculate()
                    }))
                    TextField("Kwota (zł)", text: Binding(get: { total }, set: {
                        total = $0
                        if price.isEmpty, let quantity = parsedQuantity, quantity > 0, let total = parsedTotal, total > 0 {
                            appliedSuggestedPrice = nil
                            price = EnergyNumber.text(total / quantity, digits: 6)
                        }
                        quantityFromTotal = true
                        recalculate()
                    }))
                    Text("Kwota i cena wyliczają ilość. Ręcznie wpisana ilość i cena przeliczają kwotę.")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
                if suggestedStation != nil { stationPriceSuggestion }
                EnergySection(kind == .electricity ? "Pomiar zużycia" : "Pomiar spalania", symbol: "gauge.with.dots.needle.50percent") {
                    if kind != .electricity {
                        Picker("Paliwo przed tankowaniem", selection: $fuelLevelBefore) {
                            ForEach(FuelLevelBefore.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Text("Tankujesz za określoną kwotę? Wybierz „Na rezerwie”, jeśli tankujesz przy podobnym poziomie rezerwy. Nie musisz tankować do pełna.")
                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    }
                    Toggle(kind == .electricity ? "Naładowano do 100%" : "Zatankowano do pełna", isOn: $full)
                    TextField("Przebieg licznika (km, opcjonalnie)", text: $odometer)
                    Text("Licznik daje pełny dystans. Bez niego uwzględnimy tylko zapisane przejazdy przypisane do tego pojazdu.")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    measurementFeedback
                }
                EnergySection("Stacja") {
                    TextField("Nazwa stacji (opcjonalnie)", text: $station)
                    if let suggestedStation {
                        Label("Lokalizacja: \(suggestedStation.identity.name)", systemImage: "mappin.and.ellipse")
                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    } else if coordinate != nil && original == nil {
                        Toggle("Zapisz bieżącą lokalizację", isOn: $attachLocation)
                    }
                    if original?.coordinate != nil { Text("Wpis ma zapisaną lokalizację stacji").font(.caption).foregroundStyle(Color.naviTextSecondary) }
                }
                if let error { EnergySection { Text(error).foregroundStyle(Color(naviHex: NaviAstraColorPalette.danger)) } }
            }
            .navigationTitle(kind == .electricity
                             ? (original == nil ? "Dodaj ładowanie" : "Edytuj ładowanie")
                             : (original == nil ? "Dodaj tankowanie" : "Edytuj tankowanie"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Zapisz") { save() } }
            }
            .onAppear {
                kind = original?.kind ?? vehicle.kinds[0]
                if let suggestedStation, original == nil { station = suggestedStation.identity.name }
                if let original {
                    date = original.date; quantity = EnergyNumber.text(original.quantity, digits: 6)
                    price = EnergyNumber.text(original.unitPrice, digits: 6); total = EnergyNumber.text(original.totalPrice, digits: 2)
                    odometer = original.odometer.map { EnergyNumber.text($0, digits: 3) } ?? ""
                    full = original.full; station = original.station
                    fuelLevelBefore = original.fuelLevelBefore ?? .unspecified
                }
            }
            .task(id: "\(suggestedStation?.id ?? "manual")/\(kind.rawValue)/\(priceRetry)") {
                await loadStationPrice()
            }

        }
        .frame(minWidth: 320, minHeight: 480)
    }

    @ViewBuilder private var measurementFeedback: some View {
        if let period = closingPeriod {
            Divider()
            Label(period.start.kind == .electricity ? "Zamykasz pomiar zużycia" : period.measurement.title,
                  systemImage: "checkmark.circle")
                .font(.subheadline.weight(.semibold))
            Text("Od \(TripHistoryFormat.date(period.start.date))")
                .font(.caption).foregroundStyle(Color.naviTextSecondary)
            if let consumption = period.consumption, let kilometers = period.kilometers {
                Text("Po zapisaniu: \(EnergyNumber.text(consumption)) \(kind.unit)/100 km · \(EnergyNumber.text(kilometers)) km")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            } else if period.usesOdometer {
                Text("Przebieg na końcu okresu musi być większy niż na początku. Sprawdź licznik w obu wpisach.")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
            } else {
                Text("Do obliczenia wyniku brakuje dystansu. Uzupełnij licznik w obu wpisach lub przypisz zapisane przejazdy.")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
            }
            Text(period.quality).font(.caption).foregroundStyle(Color.naviTextSecondary)
        } else if kind == .electricity {
            Text("Dwa ładowania do 100% zamykają pomiar. Wpisuj energię z ładowarki; wynik obejmuje straty ładowania.")
                .font(.caption).foregroundStyle(Color.naviTextSecondary)
        } else if fuelLevelBefore == .reserve {
            Label("Pomiar od rezerwy do rezerwy", systemImage: "fuelpump")
                .font(.subheadline.weight(.semibold))
            Text("Paliwo dolane teraz uwzględnimy do kolejnego tankowania oznaczonego „Na rezerwie”. Zapisuj wszystkie tankowania po drodze. Różny poziom rezerwy wpływa na dokładność szacunku.")
                .font(.caption).foregroundStyle(Color.naviTextSecondary)
        } else if full {
            Text("Pełny zbiornik ustala początek pomiaru. Kolejne tankowanie do pełna zamknie okres; doliczymy wszystkie tankowania po drodze.")
                .font(.caption).foregroundStyle(Color.naviTextSecondary)
        } else {
            Text("Tankowanie częściowe doliczymy do pomiaru między rezerwami lub pełnymi zbiornikami. Początek i koniec pomiaru oznaczysz w odpowiednich wpisach, także przez edycję historii.")
                .font(.caption).foregroundStyle(Color.naviTextSecondary)
        }
    }
    @ViewBuilder private var stationPriceSuggestion: some View {
        EnergySection("Cena na stacji", symbol: "tag") {
            if priceLoading {
                ProgressView("Pobieranie ceny…")
            } else if priceFailure {
                Text("Nie udało się pobrać ceny. Wpisz ją ręcznie lub spróbuj ponownie.")
                    .foregroundStyle(Color.naviTextSecondary)
            } else if quote?.isClosed == true {
                Text("Źródło oznacza tę stację jako zamkniętą. Potwierdź stację i wpisz rzeczywistą cenę.")
                    .foregroundStyle(Color.naviTextSecondary)
            } else if let fuel = kind.stationFuel, let suggestion = quote?.prices.first(where: { $0.fuel == fuel }) {
                LabeledContent(suggestion.fuel.title, value: "\(suggestion.amount.formatted(.number.precision(.fractionLength(2)))) zł/L")
                Text(suggestion.reportedAt.map { "Zgłoszono: \(TripHistoryFormat.date($0))" } ?? "Cena bez daty zgłoszenia")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                if suggestion.isReportedToday(), appliedSuggestedPrice != nil {
                    Text("Wstawiono cenę zgłoszoną dzisiaj. Potwierdź cenę na dystrybutorze.")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                } else {
                    Button("Użyj tej ceny") { applyPrice(suggestion) }.buttonStyle(.bordered)
                    Text("To cena społecznościowa. Potwierdź aktualną cenę na stacji.")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
            } else {
                Text(kind == .electricity ? "Brak cen ładowania w tym źródle. Wpisz cenę ręcznie." : "Brak ceny wybranego paliwa. Wpisz ją ręcznie.")
                    .foregroundStyle(Color.naviTextSecondary)
            }
            HStack {
                Link("PaliwoMapa.pl", destination: quote?.sourceURL ?? URL(string: "https://paliwomapa.pl")!)
                Spacer()
                Button("Odśwież", systemImage: "arrow.clockwise") { priceRetry += 1 }.disabled(priceLoading)
            }.font(.caption)
        }
    }

    private func applyPrice(_ suggestion: StationFuelPrice) {
        price = suggestion.amount.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "pl_PL")))
        appliedSuggestedPrice = price
        recalculate()
    }

    private func loadStationPrice() async {
        guard let suggestedStation else { return }
        // Only remove a previously supplied price, never a manually edited value.
        if price == appliedSuggestedPrice {
            price = ""
            if quantityFromTotal { quantity = "" } else { total = "" }
        }
        appliedSuggestedPrice = nil
        quote = nil; priceFailure = false
        guard kind.stationFuel != nil else { priceLoading = false; return }
        priceLoading = true
        do {
            let fetched = try await PaliwoMapaFuelPriceProvider.shared.prices(for: suggestedStation.identity, forceRefresh: priceRetry > 0)
            guard !Task.isCancelled else { return }
            quote = fetched; priceLoading = false
            if fetched?.isClosed != true, let fuel = kind.stationFuel,
               let suggestion = fetched?.prices.first(where: { $0.fuel == fuel }),
               suggestion.isReportedToday(), price.isEmpty {
                applyPrice(suggestion)
            }
        } catch {
            guard !Task.isCancelled else { return }
            priceFailure = true; priceLoading = false
        }
    }

    private func recalculate() {
        if quantityFromTotal {
            guard let price = parsedPrice, price > 0, let total = parsedTotal, total >= 0 else {
                quantity = ""
                return
            }
            let calculated = total / price
            guard calculated.isFinite else { quantity = ""; return }
            quantity = EnergyNumber.text(calculated, digits: 6)
            return
        }
        guard let quantity = parsedQuantity, let price = parsedPrice else { return }
        let calculated = (quantity * price * 100).rounded() / 100
        guard calculated.isFinite else { return }
        total = EnergyNumber.text(calculated, digits: 2)
    }
    private func save() {
        guard let entry = draftEntry else {
            error = "Podaj prawidłową ilość, cenę, kwotę i przebieg."; return
        }
        if store.saveEntry(entry) { onSaved?(); dismiss() } else { error = store.errorMessage }
    }
}

/// The same palette and floating surfaces used by the trip archive and navigation panels.
private struct EnergyCanvas<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                content()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background {
            Color(naviHex: colorScheme == .dark
                ? NaviAstraColorPalette.navigationSurface : NaviAstraColorPalette.surfaceDay)
                .overlay {
                    LinearGradient(colors: [Color.accentColor.opacity(0.12), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        .foregroundStyle(Color.naviTextPrimary)
        .font(.subheadline)
        .tint(Color.accentColor)
        .textFieldStyle(.roundedBorder)
        .environment(\.locale, Locale(identifier: "pl_PL"))
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct EnergySection<Content: View>: View {
    let title: String?
    let symbol: String
    let content: () -> Content

    init(_ title: String? = nil, symbol: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol ?? Self.symbol(for: title)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Label {
                    Text(title).foregroundStyle(Color.naviTextPrimary)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(Color.accentColor)
                }
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 24))
    }

    private static func symbol(for title: String?) -> String {
        switch title {
        case "Moje pojazdy": "car.side.fill"
        case "Koszt przejazdu": "creditcard"
        case "Statystyki": "chart.bar.xaxis"
        case "Historia tankowań i ładowań": "clock.arrow.circlepath"
        case "Przejazdy i koszt paliwa": "point.topleft.down.to.point.bottomright.curvepath"
        case "Pomiar": "gauge.with.dots.needle.50percent"
        case "Stacja": "mappin.and.ellipse"
        default: "info.circle"
        }
    }
}

private struct EnergyMetricHero: View {
    let title: String
    let value: String
    let unit: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Color.naviTextSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    metricValue
                    Text(unit).font(.subheadline).foregroundStyle(Color.naviTextSecondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    metricValue
                    Text(unit).font(.subheadline).foregroundStyle(Color.naviTextSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var metricValue: some View {
        Text(value)
            .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
            .foregroundStyle(Color.naviTextPrimary)
    }
}

private struct EnergyMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.naviTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(title).font(.caption).foregroundStyle(Color.naviTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
