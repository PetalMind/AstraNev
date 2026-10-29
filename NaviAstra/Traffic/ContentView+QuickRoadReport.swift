#if os(iOS)
import SwiftUI
import UIKit

struct QuickRoadReportFeedback: Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

extension ContentView {
    var quickRoadReportButton: some View {
        Menu {
            ForEach(RoadReportKind.allCases) { kind in
                Button(kind.title, systemImage: kind.symbol) {
                    saveQuickRoadReport(kind)
                }
            }
        } label: {
            Label {
                Text("Zgłoś")
                    .font(.system(size: 15, weight: .semibold))
            } icon: {
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(Color.naviTextPrimary)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .modifier(NavigationGlassSurface(radius: 24, interactive: true))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zgłoś zdarzenie drogowe")
        .accessibilityHint("Wybierz rodzaj, aby od razu zapisać zgłoszenie lokalnie przy bieżącej pozycji GPS")
    }

    @ViewBuilder
    var quickRoadReportFeedbackView: some View {
        if let feedback = quickRoadReportFeedback {
            Label(feedback.message, systemImage: feedback.isError ? "location.slash" : "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(feedback.isError ? Color.red : Color.naviTextPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityElement(children: .combine)
                .task(id: feedback.id) {
                    do { try await Task.sleep(for: .seconds(6)) } catch { return }
                    guard quickRoadReportFeedback?.id == feedback.id else { return }
                    quickRoadReportFeedback = nil
                }
        }
    }

    private func saveQuickRoadReport(_ kind: RoadReportKind) {
        // Read again when the kind is selected: the menu may have been open while driving.
        let now = Date()
        guard let location = navigationStore.state.location,
              location.accuracy >= 0, location.accuracy <= 50,
              (-5...60).contains(now.timeIntervalSince(location.timestamp)) else {
            showQuickRoadReportFeedback(RoadReportError.invalidLocation.errorDescription ?? "Czekam na dokładną pozycję GPS.", isError: true)
            return
        }
        do {
            try LocalRoadReportStore.shared.add(kind: kind, coordinate: location.coordinate, at: now)
            // Publishes the local point immediately, including against the active navigation route.
            navigationStore.refreshTraffic(force: true, forceRouteRefresh: false)
            showQuickRoadReportFeedback("Zapisano lokalnie: \(kind.title). Zgłoszenie wygaśnie za 30 minut.", isError: false)
        } catch let failure as RoadReportError {
            showQuickRoadReportFeedback(failure.errorDescription ?? "Nie udało się zapisać zgłoszenia.", isError: true)
        } catch {
            showQuickRoadReportFeedback(RoadReportError.storage.errorDescription ?? "Nie udało się zapisać zgłoszenia.", isError: true)
        }
    }

    private func showQuickRoadReportFeedback(_ message: String, isError: Bool) {
        quickRoadReportFeedback = QuickRoadReportFeedback(message: message, isError: isError)
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
#endif
