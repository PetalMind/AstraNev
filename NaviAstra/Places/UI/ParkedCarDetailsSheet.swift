import SwiftUI
#if os(iOS)
import UIKit
#else
import PhotosUI
import ImageIO
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    @State private var displayedCar: ParkedCar
    @State private var errorMessage: String?
#if !os(iOS)
    @State private var photoSelection: PhotosPickerItem?
    @State private var photoImage: Image?
    @State private var isLoadingPhoto = false
    var onSavePhoto: (Data) -> String? = { _ in nil }
    var onLoadPhoto: () async -> Data? = { nil }
#endif

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
    let onRemove: () -> Bool

    init(car: ParkedCar, onEstimateRoute: @escaping () async throws -> SearchRouteEstimate?,
         startsEditing: Bool = false, canGuide: Bool, guideUnavailableReason: String,
         onShowMap: @escaping () -> Void, onGuide: @escaping () -> Void,
         onUpdate: @escaping (ParkedCar) -> Bool,
         onRemove: @escaping () -> Bool) {
        self.car = car
        self.onEstimateRoute = onEstimateRoute
        self.canGuide = canGuide
        self.guideUnavailableReason = guideUnavailableReason
        self.onShowMap = onShowMap
        self.onGuide = onGuide
        self.onUpdate = onUpdate
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
#if os(iOS)
            .navigationTitle(isEditing ? "Szczegóły postoju" : "Moje auto")
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: isEditing) { _, editing in
                selectedDetent = editing || dynamicTypeSize.isAccessibilitySize ? .large : .medium
            }
#else
            .navigationTitle(isEditing ? "Szczegóły parkowania" : "Zaparkowany samochód")
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
            .alert("Nie udało się wykonać czynności", isPresented: Binding(
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
                guard canGuide else {
                    isEstimatingRoute = false
                    return
                }
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
#if !os(iOS)
            .task(id: displayedCar.photoPath) {
                guard displayedCar.photoPath != nil else {
                    photoImage = nil
                    return
                }
                guard let data = await onLoadPhoto(), !Task.isCancelled else { return }
                let thumbnail = await Self.photoThumbnail(from: data)
                guard !Task.isCancelled else { return }
                photoImage = thumbnail.map(Self.image(from:))
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
                    let thumbnail = await Self.photoThumbnail(from: data)
                    guard !Task.isCancelled, photoSelection == selection else { return }
                    guard let thumbnail else {
                        errorMessage = "Wybrany plik nie jest obsługiwanym zdjęciem."
                        return
                    }
                    guard let photoPath = onSavePhoto(data) else {
                        errorMessage = "Nie udało się zapisać zdjęcia. Spróbuj ponownie."
                        return
                    }
                    photoImage = Self.image(from: thumbnail)
                    displayedCar.photoPath = photoPath
                } catch {
                    if !Task.isCancelled { errorMessage = "Nie udało się wczytać zdjęcia. Spróbuj ponownie." }
                }
            }
#endif
        }
#if os(iOS)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large],
                             selection: dynamicTypeSize.isAccessibilitySize ? .constant(.large) : $selectedDetent)
#endif
        .environment(\.locale, PolishRegionalFormat.locale)
    }

#if os(iOS)
    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                walkingRouteSummary
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)

                VStack(spacing: 4) {
                    Button(action: onGuide) {
                        Label("Prowadź pieszo do auta", systemImage: "figure.walk")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canGuide)

                    removalButton
                }

                Divider()
                Button(action: onShowMap) {
                    Label(displayedCar.address ?? "Pokaż auto na mapie", systemImage: "mappin.and.ellipse")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("Pokazuje zapisane miejsce parkowania na mapie")

                if let parkingDetails = displayedCar.parkingDetails {
                    Label(parkingDetails, systemImage: "parkingsign.circle")
                }
                if let note = displayedCar.note, !note.isEmpty {
                    Label(note, systemImage: "note.text")
                }
                if let expiry = displayedCar.parkingExpiresAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let title = expiry <= context.date ? "Czas parkowania minął" : "Koniec parkowania"
                        Label("\(title) · \(PolishRegionalFormat.dateTime(expiry))", systemImage: "clock")
                    }
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
#else
    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                walkingRouteSummary

                VStack(alignment: .leading, spacing: 14) {
                    Label(displayedCar.address ?? "Zapisana lokalizacja na mapie", systemImage: "mappin.and.ellipse")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Zapisano \(PolishRegionalFormat.dateTime(displayedCar.parkedAt))",
                          systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(Color.naviTextSecondary)
                    let coordinateFormat = FloatingPointFormatStyle<Double>.number
                        .precision(.fractionLength(5)).locale(PolishRegionalFormat.locale)
                    Text("\(displayedCar.coordinate.latitude.formatted(coordinateFormat)) · \(displayedCar.coordinate.longitude.formatted(coordinateFormat))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.naviTextSecondary)
                        .textSelection(.enabled)
                    if let accuracy = displayedCar.gpsAccuracy, accuracy.isFinite, accuracy >= 0 {
                        Label("Dokładność zapisu GPS ±\(accuracy.formatted(.number.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale))) m",
                              systemImage: "location.circle")
                            .font(.caption)
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                    Button(action: onShowMap) {
                        Label("Pokaż auto na mapie", systemImage: "map")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
#if os(iOS)
                .iosCardSurface()
#else
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
#endif

                if let expiration = displayedCar.parkingExpiresAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let expired = expiration <= context.date
                        VStack(alignment: .leading, spacing: 5) {
                            Label(expired ? "Czas parkowania minął" : "Koniec parkowania",
                                  systemImage: expired ? "exclamationmark.circle.fill" : "clock")
                                .font(.subheadline.weight(.semibold))
                            Text(PolishRegionalFormat.dateTime(expiration))
                                .font(.subheadline.monospacedDigit())
                        }
                        .foregroundStyle(expired ? Color(naviHex: NaviAstraColorPalette.warning) : Color.naviTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
#if os(iOS)
                        .iosCardSurface()
#else
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
#endif
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
                    Label(isLoadingPhoto ? "Wczytywanie zdjęcia…" : displayedCar.photoPath == nil ? "Dodaj zdjęcie miejsca" : "Zmień zdjęcie",
                          systemImage: "photo")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingPhoto)
                removalButton
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Button(action: onGuide) {
                    Label("Prowadź pieszo do auta", systemImage: "figure.walk")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }

#endif

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
#if !os(iOS)
            Section {
                removalButton
            }
#endif
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
                let arrival = PolishRegionalFormat.time(context.date.addingTimeInterval(estimate.travelTime))
                PlaceDetailsHeroSummary(
                    title: estimate.travelTime < 60 ? "Mniej niż minuta pieszo" : "\(TravelDurationFormatter.string(minutes: minutes)) pieszo",
                    symbol: "figure.walk", showsPOIIcon: true,
                    categoryTitle: nil,
                    travelSummary: "\(routeDistanceLabel(estimate.distanceMeters)) · na miejscu o \(arrival)")
            } else {
                PlaceDetailsHeroSummary(
                    title: "Powrót do samochodu", symbol: "figure.walk", showsPOIIcon: true,
                    categoryTitle: !canGuide ? guideUnavailableReason
                        : isEstimatingRoute ? "Wyznaczam trasę pieszą…" : "Czas i odległość dojścia są niedostępne.",
                    travelSummary: nil)
            }
        }
    }

    private func routeDistanceLabel(_ meters: Double) -> String {
        if meters < 1_000 {
            return meters.formatted(.number.precision(.fractionLength(0)).locale(PolishRegionalFormat.locale)) + " m"
        }
        return (meters / 1_000).formatted(.number.precision(.fractionLength(1)).locale(PolishRegionalFormat.locale)) + " km"
    }

    private var removalButton: some View {
        Button(role: .destructive) {
            showingRemovalConfirmation = true
        } label: {
            Label("Usuń miejsce parkowania", systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .confirmationDialog("Usunąć zapisane miejsce samochodu?", isPresented: $showingRemovalConfirmation,
                            titleVisibility: .visible) {
            Button("Usuń miejsce parkowania", role: .destructive) {
                guard onRemove() else {
                    errorMessage = "Nie udało się usunąć miejsca. Spróbuj ponownie."
                    return
                }
                dismiss()
            }
            Button("Anuluj", role: .cancel) { }
        } message: {
            Text("Usuniesz lokalizację samochodu i zapisane szczegóły postoju.")
        }
    }

#if !os(iOS)
    nonisolated private static func photoThumbnail(from data: Data) async -> CGImage? {
        await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_200,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }.value
    }

    private static func image(from thumbnail: CGImage) -> Image {
#if os(iOS)
        Image(uiImage: UIImage(cgImage: thumbnail))
#else
        Image(nsImage: NSImage(cgImage: thumbnail, size: .zero))
#endif
    }
#endif
}

private extension String {
    var parkedCarNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if DEBUG && os(iOS)
/// A device preview with an in-memory parking record and no navigation or storage callbacks.
struct ParkedCarSheetPreview: View {
    @State private var isPresented = true
    private let car = ParkedCar(coordinate: Coordinate(latitude: 0, longitude: 0),
                                floor: "1", sector: "B", spot: "12")

    var body: some View {
        Color(uiColor: .secondarySystemGroupedBackground)
            .sheet(isPresented: $isPresented) {
                ParkedCarDetailsSheet(
                    car: car, onEstimateRoute: { SearchRouteEstimate(travelTime: 35, distanceMeters: 28) },
                    canGuide: true, guideUnavailableReason: "", onShowMap: {}, onGuide: {},
                    onUpdate: { _ in false }, onRemove: { false })
                    .presentationDragIndicator(.visible)
                    .dynamicTypeSize(CommandLine.arguments.contains("--duzy-tekst-podgladu") ? .accessibility2 : .large)
            }
    }
}
#endif
