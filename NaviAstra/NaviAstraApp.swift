import SwiftUI

private struct AppScene: View {
    let appPhase: ScenePhase
    let dependencies: AppDependencies

    var body: some View {
        ContentView(dependencies: dependencies)
            .task {
                dependencies.navigationStore.setAppIsForeground(appPhase == .active)
                dependencies.navigationStore.startLocation()
            }
            .onChange(of: appPhase) { _, phase in
                dependencies.navigationStore.setAppIsForeground(phase == .active)
                if phase == .background { BackgroundMaintenance.schedule() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                dependencies.navigationStore.refreshEnergyPolicy()
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                dependencies.navigationStore.refreshEnergyPolicy()
            }
    }
}

@main
struct NaviAstraApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var dependencies = AppDependencies.live()

    init() { BackgroundMaintenance.register() }

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
