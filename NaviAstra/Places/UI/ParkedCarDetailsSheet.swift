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

struct ParkedCarDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
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

    let car: ParkedCar
    let distanceMeters: Double?
    let onGuide: () -> Void
    let onUpdate: (ParkedCar) -> Void
    let onSavePhoto: (Data) -> String?
    let onRemove: () -> Void

    init(car: ParkedCar, distanceMeters: Double?, initialPhotoData: Data? = nil,
         startsEditing: Bool = false, onGuide: @escaping () -> Void,
         onUpdate: @escaping (ParkedCar) -> Void, onSavePhoto: @escaping (Data) -> String?,
         onRemove: @escaping () -> Void) {
        self.car = car
        self.distanceMeters = distanceMeters
        self.onGuide = onGuide
        self.onUpdate = onUpdate
        self.onSavePhoto = onSavePhoto
        self.onRemove = onRemove
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
                        Button("Edytuj") { isEditing = true }
                    }
                }
            }
            .confirmationDialog("Usunąć zapisane miejsce samochodu?", isPresented: $showingRemovalConfirmation,
                                titleVisibility: .visible) {
                Button("Usuń samochód", role: .destructive, action: onRemove)
                Button("Anuluj", role: .cancel) { }
            } message: {
                Text("Tej czynności nie można cofnąć.")
            }
            .onChange(of: photoSelection) { _, selection in
                guard let selection else { return }
                Task {
                    guard let data = try? await selection.loadTransferable(type: Data.self),
                          let photoPath = onSavePhoto(data) else { return }
                    photoData = data
                    var updated = displayedCar
                    updated.photoPath = photoPath
                    displayedCar = updated
                    onUpdate(updated)
                }
            }
        }
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 13) {
                    Image(systemName: "car.side.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(distanceMeters.map(distanceLabel) ?? "Miejsce zapisane")
                            .font(.headline)
                        Text("Zaparkowano \(displayedCar.parkedAt.formatted(.relative(presentation: .named)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(15)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    if let address = displayedCar.address, !address.isEmpty {
                        Label(address, systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                    } else {
                        Label("Adres nie jest dostępny", systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let parkingDetails = displayedCar.parkingDetails {
                        Label(parkingDetails, systemImage: "parkingsign.circle")
                            .font(.subheadline)
                    }
                    if let note = displayedCar.note, !note.isEmpty {
                        Label(note, systemImage: "note.text")
                            .font(.subheadline)
                    }
                    if let expiration = displayedCar.parkingExpiresAt {
                        Label("Parking do \(expiration.formatted(date: .omitted, time: .shortened))",
                              systemImage: "clock")
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

                if let photoImage {
                    photoImage
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Label(photoData == nil ? "Dodaj zdjęcie" : "Zmień zdjęcie",
                          systemImage: photoData == nil ? "camera" : "photo")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.bordered)

                Button(action: onGuide) {
                    Label("Prowadź do auta", systemImage: "figure.walk")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)

                Button("Usuń samochód", systemImage: "trash", role: .destructive) {
                    showingRemovalConfirmation = true
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            }
            .padding(20)
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
            Section("Przypomnienie") {
                Toggle("Ustaw koniec parkowania", isOn: $hasParkingExpiry)
                if hasParkingExpiry {
                    DatePicker("Do", selection: $parkingExpiry, in: Date()...)
                }
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
        displayedCar = updated
        onUpdate(updated)
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

    private func distanceLabel(_ meters: Double) -> String {
        if meters < 1_000 { return "\(Int(meters.rounded())) m od Ciebie" }
        return String(format: "%.1f km od Ciebie", meters / 1_000)
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
