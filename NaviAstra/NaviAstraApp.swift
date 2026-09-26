import SwiftUI

private struct AppScene: View {
    @State private var dependencies = AppDependencies.live()

    var body: some View {
        ContentView(dependencies: dependencies)
    }
}

@main
struct NaviAstraApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            AppScene()
        }
        .defaultSize(width: 1100, height: 760)
        #else
        WindowGroup {
            AppScene()
        }
        #endif
    }
}
