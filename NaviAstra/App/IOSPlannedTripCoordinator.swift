#if os(iOS)
import Foundation
import Observation

/// Scene-local presentation state. The saved plans remain owned by TripPlanningService.
@MainActor
@Observable
final class IOSPlannedTripCoordinator {
    var workspace: IOSPlannedTripPresentation?
    var libraryFocusID: UUID?
    private var pendingWorkspace: IOSPlannedTripPresentation?
    private var returnsToLibrary = false

    func begin(_ presentation: IOSPlannedTripPresentation, returnToLibrary: Bool, router: AppRouter) {
        returnsToLibrary = returnToLibrary
        libraryFocusID = presentation.seed?.id
        if router.sheet != nil {
            pendingWorkspace = presentation
            router.dismiss()
        } else {
            workspace = presentation
        }
    }

    /// Wait for the previous sheet's dismissal before starting the editor.
    func presentPendingWorkspace() -> Bool {
        guard let pendingWorkspace else { return false }
        self.pendingWorkspace = nil
        workspace = pendingWorkspace
        return true
    }

    func didSave(_ trip: PlannedTrip) {
        libraryFocusID = trip.id
        returnsToLibrary = true
    }

    func finish(router: AppRouter) {
        guard returnsToLibrary else { return }
        returnsToLibrary = false
        router.present(.plannedTrips)
    }
}
#endif
