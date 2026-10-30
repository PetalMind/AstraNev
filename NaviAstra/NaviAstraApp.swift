import SwiftUI
#if os(iOS)
import UIKit
#endif

private struct AppScene: View {
    let appPhase: ScenePhase
    let dependencies: AppDependencies

    var body: some View {
        ContentView(dependencies: dependencies)
            .environment(\.locale, PolishRegionalFormat.locale)
            .task {
                #if DEBUG && os(iOS)
                guard !IOSDebugDrivingScenario.isEnabled else { return }
                #endif
                dependencies.navigationStore.setAppIsForeground(appPhase == .active)
                dependencies.navigationStore.startLocation()
                updateScreenIdleTimer()
                #if os(iOS)
                VoiceIntentBridge.shared.resumePendingRequest()
                // Let SwiftUI present the scene before preparing historical GPS data.
                await Task.yield()
                guard !Task.isCancelled else { return }
                await dependencies.recoverDrivingHistoryAfterLaunch()
                #endif
            }
            .onChange(of: appPhase) { _, phase in
                #if DEBUG && os(iOS)
                guard !IOSDebugDrivingScenario.isEnabled else { return }
                #endif
                dependencies.navigationStore.setAppIsForeground(phase == .active)
                updateScreenIdleTimer()
                #if os(iOS)
                if phase == .active { VoiceIntentBridge.shared.resumePendingRequest() }
                #endif
                if phase == .background { BackgroundMaintenance.schedule() }
            }
            .onChange(of: dependencies.navigationStore.state.status) { _, _ in
                updateScreenIdleTimer()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                dependencies.navigationStore.refreshEnergyPolicy()
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                dependencies.navigationStore.refreshEnergyPolicy()
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                VoiceIntentBridge.shared.resumePendingRequest()
            }
            #endif
    }

    private func updateScreenIdleTimer() {
        #if os(iOS)
        let status = dependencies.navigationStore.state.status
        UIApplication.shared.isIdleTimerDisabled = appPhase == .active &&
            (status == .navigating || status == .rerouting)
        #endif
    }
}

@main
struct NaviAstraApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var dependencies = AppDependencies.live()

    init() {
        TripNotificationDelegate.shared.install()
        BackgroundMaintenance.register()
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            AppScene(appPhase: scenePhase, dependencies: dependencies)
        }
        .defaultSize(width: 1100, height: 760)
        #else
        WindowGroup {
            AppScene(appPhase: scenePhase, dependencies: dependencies)
        }
        #endif
    }
}
