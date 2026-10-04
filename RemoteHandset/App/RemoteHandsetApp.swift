import SwiftUI

@main
struct RemoteHandsetApp: App {
    @StateObject private var session = RemoteSessionController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, newPhase in
                    session.handleScenePhase(newPhase)
                }
        }
    }
}
