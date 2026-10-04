import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: RemoteSessionController

    var body: some View {
        Group {
            if session.isAuthenticated {
                ControlView()
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.22), value: session.isAuthenticated)
        .overlay {
            // Privacy cover shown the instant the app is interrupted while a
            // remote session is live. Non-interactive: it is a disguise, not a
            // login. Applied without animation so the app-switcher snapshot
            // captures it fully.
            if session.isObscured && session.isAuthenticated {
                CalculatorView { _ in }
                    .allowsHitTesting(false)
            }
        }
    }
}

