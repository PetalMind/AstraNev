import SwiftUI
import PhotosUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct ParkedCarToast: Identifiable {
    let id = UUID()
    let gpsAccuracy: Double?
    let previousCar: ParkedCar?
}

private struct ParkedCarRouteRequest: Equatable {
    let destination: Coordinate
    let canGuide: Bool
}

struct ParkedCarDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
#if os(iOS)
    @State private var selectedDetent: PresentationDetent
#endif
    @State private var isEditing: Bool
    @State private var floor: String
    @State private var sector: String
    @State private var spot: String
    @State private var note: String
    @State private var hasParkingExpiry: Bool
    @State private var parkingExpiry: Date
    @State private var showingRemovalConfirmation = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var displayedCar: ParkedCar
    @State private var errorMessage: String?
    @State private var isLoadingPhoto = false

    let car: ParkedCar
    @State private var walkingEstimate: SearchRouteEstimate?
    @State private var estimateUpdatedAt: Date?
    @State private var isEstimatingRoute = true
    let onEstimateRoute: () async throws -> SearchRouteEstimate?
    let canGuide: Bool
    let guideUnavailableReason: String
    let onShowMap: () -> Void
    let onGuide: () -> Void
    let onUpdate: (ParkedCar) -> Bool
    let onSavePhoto: (Data) -> String?
    let onRemove: () -> Bool

    init(car: ParkedCar, onEstimateRoute: @escaping () async throws -> SearchRouteEstimate?, initialPhotoData: Data? = nil,
         startsEditing: Bool = false, canGuide: Bool, guideUnavailableReason: String,
         onShowMap: @escaping () -> Void, onGuide: @escaping () -> Void,
         onUpdate: @escaping (ParkedCar) -> Bool, onSavePhoto: @escaping (Data) -> String?,
         onRemove: @escaping () -> Bool) {
        self.car = car
        self.onEstimateRoute = onEstimateRoute
        self.canGuide = canGuide
        self.guideUnavailableReason = guideUnavailableReason
        self.onShowMap = onShowMap
        self.onGuide = onGuide
        self.onUpdate = onUpdate
        self.onSavePhoto = onSavePhoto
        self.onRemove = onRemove
#if os(iOS)
        _selectedDetent = State(initialValue: startsEditing ? .large : .medium)
#endif
        _isEditing = State(initialValue: startsEditing)
        _floor = State(initialValue: car.floor ?? "")
        _sector = State(initialValue: car.sector ?? "")
        _spot = State(initialValue: car.spot ?? "")
        _note = State(initialValue: car.note ?? "")
        _hasParkingExpiry = State(initialValue: car.parkingExpiresAt != nil)
        _parkingExpiry = State(initialValue: car.parkingExpiresAt ?? Date().addingTimeInterval(7_200))
        _photoData = State(initialValue: initialPhotoData)
        _displayedCar = State(initialValue: car)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEditing {
                    editForm
                } else {
                    details
                }
            }
            .navigationTitle(isEditing ? "Szczegóły parkowania" : "Zaparkowany samochód")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: isEditing) { _, editing in
                if editing { selectedDetent = .large }
            }
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditing ? "Anuluj" : "Gotowe") {
                        if isEditing { resetFields() }
                        if isEditing { isEditing = false } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button("Zapisz", action: saveDetails)
                            .fontWeight(.semibold)
                    } else {
                        Button("Edytuj") { resetFields(); isEditing = true }
                    }
                }
            }
            .confirmationDialog("Usunąć zapisane miejsce samochodu?", isPresented: $showingRemovalConfirmation,
                                titleVisibility: .visible) {
                Button("Usuń miejsce parkowania", role: .destructive) {
                    if !onRemove() { errorMessage = "Nie udało się usunąć miejsca. Spróbuj ponownie." }
                }
                Button("Anuluj", role: .cancel) { }
            } message: {
                Text("Tej czynności nie można cofnąć.")
            }
            .alert("Nie udało się zapisać zmian", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: car) { _, updated in
                guard updated.id == displayedCar.id else { return }
                displayedCar = updated
                if !isEditing { resetFields() }
            }
            .task(id: ParkedCarRouteRequest(destination: car.coordinate, canGuide: canGuide)) {
                walkingEstimate = nil
                estimateUpdatedAt = nil
                while !Task.isCancelled {
                    isEstimatingRoute = true
                    do {
                        let estimate = try await onEstimateRoute()
                        try Task.checkCancellation()
                        walkingEstimate = estimate
                        estimateUpdatedAt = estimate == nil ? nil : Date()
                    } catch {
                        guard !Task.isCancelled else { return }
                        walkingEstimate = nil
                        estimateUpdatedAt = nil
                    }
                    isEstimatingRoute = false
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                }
            }
            .task(id: photoSelection) {
                guard let selection = photoSelection else { return }
                isLoadingPhoto = true
                defer { isLoadingPhoto = false }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else {
                        errorMessage = "Nie udało się wczytać zdjęcia. Wybierz je ponownie."
                        return
                    }
                    guard !Task.isCancelled, photoSelection == selection else { return }
#if os(iOS)
                    let isImage = UIImage(data: data) != nil
#else
                    let isImage = NSImage(data: data) != nil
#endif
                    guard isImage else {
                        errorMessage = "Wybrany plik nie jest obsługiwanym zdjęciem."
                        return
                    }
                    guard let photoPath = onSavePhoto(data) else {
                        errorMessage = "Nie udało się zapisać zdjęcia. Spróbuj ponownie."
                        return
                    }
                    photoData = data
                    displayedCar.photoPath = photoPath
                } catch {
                    if !Task.isCancelled { errorMessage = "Nie udało się wczytać zdjęcia. Spróbuj ponownie." }
                }
            }
        }
#if os(iOS)
        .presentationDetents([.medium, .large], selection: $selectedDetent)
#endif
        .environment(\.locale, Locale(identifier: "pl_PL"))
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "car.side.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        walkingRouteSummary
                        Text(displayedCar.parkedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "pl_PL"))))
                            .font(.subheadline)
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 14) {
                    Label(displayedCar.address ?? "Zapisana lokalizacja na mapie", systemImage: "mappin.and.ellipse")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: "%.5f, %.5f", displayedCar.coordinate.latitude, displayedCar.coordinate.longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.naviTextSecondary)
                        .textSelection(.enabled)
                    if let accuracy = displayedCar.gpsAccuracy, accuracy.isFinite, accuracy >= 0 {
                        Label("Dokładność zapisu GPS ±\(Int(accuracy.rounded())) m", systemImage: "location.circle")
                            .font(.caption)
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                    Button(action: onShowMap) {
                        Label("Pokaż auto na mapie", systemImage: "map")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

                if let expiration = displayedCar.parkingExpiresAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let expired = expiration <= context.date
                        VStack(alignment: .leading, spacing: 5) {
                            Label(expired ? "Czas parkowania minął" : "Koniec parkowania",
                                  systemImage: expired ? "exclamationmark.circle.fill" : "clock")
                                .font(.subheadline.weight(.semibold))
                            Text(expiration.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "pl_PL"))))
                                .font(.subheadline.monospacedDigit())
                        }
                        .foregroundStyle(expired ? Color(naviHex: NaviAstraColorPalette.warning) : Color.naviTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
                    }
                }

                if displayedCar.parkingDetails != nil || displayedCar.note != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Jak odnaleźć auto").font(.headline)
                        if let parkingDetails = displayedCar.parkingDetails {
                            Label(parkingDetails, systemImage: "parkingsign.circle")
                        }
                        if let note = displayedCar.note, !note.isEmpty {
                            Label(note, systemImage: "note.text")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.subheadline)
                }

                if let photoImage {
                    photoImage
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel("Zdjęcie miejsca parkowania")
                }
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Label(isLoadingPhoto ? "Wczytywanie zdjęcia…" : photoData == nil ? "Dodaj zdjęcie miejsca" : "Zmień zdjęcie",
                          systemImage: "photo")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingPhoto)

                Button("Usuń miejsce parkowania", systemImage: "trash", role: .destructive) {
                    showingRemovalConfirmation = true
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Button(action: onGuide) {
                    Label("Prowadź pieszo do auta", systemImage: "figure.walk")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canGuide)
                if !canGuide {
                    Text(guideUnavailableReason)
                        .font(.caption)
                        .foregroundStyle(Color.naviTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }

    private var editForm: some View {
        Form {
            Section("Miejsce parkingowe") {
                TextField("Poziom", text: $floor)
                TextField("Sektor", text: $sector)
                TextField("Numer miejsca", text: $spot)
            }
            Section("Notatka") {
                TextField("Np. przy czerwonej windzie", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }
            Section {
                Toggle("Ustaw koniec parkowania", isOn: $hasParkingExpiry)
                if hasParkingExpiry {
                    DatePicker("Do", selection: $parkingExpiry)
                }
            } header: {
                Text("Koniec parkowania")
            } footer: {
                Text("Zapisana godzina jest widoczna w karcie auta. Nie wysyła powiadomienia.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func saveDetails() {
        var updated = displayedCar
        updated.floor = floor.parkedCarNilIfBlank
        updated.sector = sector.parkedCarNilIfBlank
        updated.spot = spot.parkedCarNilIfBlank
        updated.note = note.parkedCarNilIfBlank
        updated.parkingExpiresAt = hasParkingExpiry ? parkingExpiry : nil
        guard onUpdate(updated) else {
            errorMessage = "Nie udało się zapisać szczegółów parkowania. Twoje zmiany pozostają w formularzu."
            return
        }
        displayedCar = updated
        isEditing = false
    }

    private func resetFields() {
        floor = displayedCar.floor ?? ""
        sector = displayedCar.sector ?? ""
        spot = displayedCar.spot ?? ""
        note = displayedCar.note ?? ""
        hasParkingExpiry = displayedCar.parkingExpiresAt != nil
        parkingExpiry = displayedCar.parkingExpiresAt ?? Date().addingTimeInterval(7_200)
    }

    private var walkingRouteSummary: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if canGuide, let estimate = walkingEstimate, let updatedAt = estimateUpdatedAt,
               context.date.timeIntervalSince(updatedAt) <= 60 {
                let minutes = max(1, Int(ceil(estimate.travelTime / 60)))
                Text(estimate.travelTime < 60 ? "Mniej niż minuta pieszo" : "\(minutes) min pieszo")
                    .font(.title3.bold())
                Text("\(routeDistanceLabel(estimate.distanceMeters)) · dojście o \(context.date.addingTimeInterval(estimate.travelTime).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "pl_PL"))))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.naviTextSecondary)
            } else {
                Text("Zaparkowany samochód").font(.title3.bold())
                Text(!canGuide ? guideUnavailableReason : isEstimatingRoute ? "Wyznaczam trasę pieszą…" : "Trasa piesza i ETA niedostępne")
                    .font(.caption)
                    .foregroundStyle(Color.naviTextSecondary)
            }
        }
    }

    private func routeDistanceLabel(_ meters: Double) -> String {
        if meters < 1_000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", meters / 1_000)
    }

    private var photoImage: Image? {
        guard let photoData else { return nil }
#if os(iOS)
        guard let image = UIImage(data: photoData) else { return nil }
        return Image(uiImage: image)
#else
        guard let image = NSImage(data: photoData) else { return nil }
        return Image(nsImage: image)
#endif
    }
}

private extension String {
    var parkedCarNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
