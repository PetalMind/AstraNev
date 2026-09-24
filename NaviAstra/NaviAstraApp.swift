import SwiftUI

@main
struct NaviAstraApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 760)
        #else
        WindowGroup {
            ContentView()
        }
        #endif
    }
}
