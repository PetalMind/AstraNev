import SwiftUI

extension ContentView {
    var currentParkedCarLocation: NavigationLocation? {
        if navigationStore.state.status == .arrived,
           navigationStore.state.transportMode == .car,
           let arrival = navigationStore.state.arrivalLocation { return arrival }
        guard let location = navigationStore.state.location,
              Date().timeIntervalSince(location.timestamp) >= 0,
              Date().timeIntervalSince(location.timestamp) <= 15,
              location.accuracy >= 0,
              location.accuracy.isFinite else { return nil }
        return location
    }

    var arrivalParkedCarPrompt: some View {
        Group {
            if navigationStore.state.status == .arrived,
               navigationStore.state.transportMode == .car,
               !arrivalCarPromptDismissed {
                HStack(spacing: 11) {
                    Image(systemName: "car.side.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
                        .frame(width: 38, height: 38)
                        .background(Color(naviHex: NaviAstraColorPalette.warning).opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Zaparkowałeś tutaj?")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.naviTextPrimary)
                        Text(currentParkedCarLocation == nil
                             ? "Czekam na aktualną pozycję GPS."
                             : "Zapisz pozycję auta, żeby łatwo do niego wrócić.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.naviTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 2)
                    VStack(spacing: 4) {
                        Button(action: saveCurrentParkedCar) {
                            Text("Zapisz")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 13)
                                .frame(minHeight: 34)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(currentParkedCarLocation == nil)
                        .opacity(currentParkedCarLocation == nil ? 0.55 : 1)
                        .accessibilityLabel("Zapisz miejsce samochodu")

                        Button("Nie teraz") { arrivalCarPromptDismissed = true }
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.naviTextSecondary)
                            .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                }
                .modifier(NavigationGlassSurface(radius: 19))
            }
        }
    }

    var parkedCarFloatingAction: some View {
        Group {
            if let expiresAt = parkedCarPromptExpiresAt {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    if context.date < expiresAt &&
                        (navigationStore.state.status != .arrived || arrivalCarPromptDismissed) {
                        Button(action: saveCurrentParkedCar) {
                            Label("Tu zaparkowałem", systemImage: "car.side.fill")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 46)
                                .background(Color.accentColor, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                                .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
                        }
                        .buttonStyle(.plain)
                        .disabled(currentParkedCarLocation == nil)
                        .opacity(currentParkedCarLocation == nil ? 0.58 : 1)
                    }
                }
            }
        }
    }

    var parkedCarToastView: some View {
        Group {
            if let parkedCarToast {
                HStack(spacing: 11) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(Color(naviHex: NaviAstraColorPalette.success))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Samochód zapisany")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.naviTextPrimary)
                        Text(parkedCarToast.gpsAccuracy.map { "Dokładność GPS ±\(Int($0.rounded())) m" }
                             ?? "Punkt wybrany na mapie")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                    Spacer(minLength: 4)
                    Button("Dodaj szczegóły") {
                        openParkedCarDetails(startEditing: true)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .buttonStyle(.plain)
                    Button("Cofnij") { undoParkedCarSave() }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.naviTextSecondary)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 18, y: 7)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    func saveCurrentParkedCar() {
        guard let location = currentParkedCarLocation else {
            placeStore.errorMessage = "Czekam na aktualną pozycję GPS, aby zapisać miejsce samochodu."
            return
        }
        requestParkedCarSave(at: location.coordinate, accuracy: location.accuracy)
    }

    func requestParkedCarSave(at coordinate: Coordinate, accuracy: Double?) {
        let parkedAt = Date()
        guard placeStore.parkedCar != nil else {
            persistParkedCar(at: coordinate, accuracy: accuracy, parkedAt: parkedAt)
            return
        }
        pendingParkedCarCoordinate = coordinate
        pendingParkedCarAccuracy = accuracy
        pendingParkedCarDate = parkedAt
        showParkedCarReplacementConfirmation = true
    }

    func persistParkedCar(at coordinate: Coordinate, accuracy: Double?, parkedAt: Date = Date()) {
        let previousCar = placeStore.parkedCar
        guard placeStore.saveParkedCar(at: coordinate, parkedAt: parkedAt) else { return }
        arrivalCarPromptDismissed = true
        parkedCarPromptExpiresAt = nil
        let savedCar = placeStore.parkedCar
        let toast = ParkedCarToast(gpsAccuracy: accuracy, previousCar: previousCar)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { parkedCarToast = toast }
        parkedCarToastDismissTask?.cancel()
        parkedCarToastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, parkedCarToast?.id == toast.id else { return }
            withAnimation(.easeOut(duration: 0.25)) { parkedCarToast = nil }
        }

        guard let savedCar else { return }
        Task { @MainActor in
            guard let address = await GUGiKAddressProvider().reverseGeocode(savedCar.coordinate),
                  var updated = placeStore.parkedCar,
                  updated.id == savedCar.id else { return }
            updated.address = address
            _ = placeStore.updateParkedCar(updated)
        }
    }

    func undoParkedCarSave() {
        parkedCarToastDismissTask?.cancel()
        guard let parkedCarToast else { return }
        if let previousCar = parkedCarToast.previousCar {
            _ = placeStore.updateParkedCar(previousCar)
        } else {
            _ = placeStore.removeParkedCar()
        }
        withAnimation(.easeOut(duration: 0.2)) { self.parkedCarToast = nil }
    }

    func openParkedCarDetails(startEditing: Bool = false) {
        guard let car = placeStore.parkedCar else { return }
        parkedCarStartsInEditMode = startEditing
        selectedParkedCar = car
        parkedCarToastDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { parkedCarToast = nil }
    }

    func guideToParkedCar(_ car: ParkedCar) {
        guard currentParkedCarLocation != nil else {
            navigationStore.state.errorMessage = "Czekam na aktualną pozycję GPS, aby wyznaczyć trasę do auta."
            return
        }
        selectedParkedCar = nil
        parkedCarStartsInEditMode = false
        let destination = car.destination
        navigationStore.state.routeOrigin = nil
        navigationStore.selectDestination(destination, applyConfiguredMode: false)
        Task {
            await navigationStore.selectTransportMode(.walking)
            await navigationStore.planRoute()
            guard navigationStore.state.status == .routePreview else { return }
            navigationStore.begin()
        }
    }
}
