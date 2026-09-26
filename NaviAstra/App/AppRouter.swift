import Observation

enum AppSheetDestination: String, Identifiable {
    case search
    case originPicker
    case settings
    case routeSettings
    case favorites
    case history
    case trafficDetails

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppRouter {
    var sheet: AppSheetDestination? {
        willSet {
            if sheet != nil, newValue == nil {
                dismissedSheet = sheet
            }
        }
    }

    private var dismissedSheet: AppSheetDestination?

    func present(_ destination: AppSheetDestination) {
        sheet = destination
    }

    func dismiss(_ expectedDestination: AppSheetDestination? = nil) {
        guard expectedDestination == nil || sheet == expectedDestination else { return }
        sheet = nil
    }

    func consumeDismissedSheet() -> AppSheetDestination? {
        defer { dismissedSheet = nil }
        return dismissedSheet
    }
}
