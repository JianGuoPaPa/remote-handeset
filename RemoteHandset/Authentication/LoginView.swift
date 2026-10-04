import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: RemoteSessionController

    var body: some View {
        CalculatorView { candidate in
            guard candidate.allSatisfy({ $0.isNumber })
            else {
                return
            }

            _ = await session.unlockFromCalculator(candidate)
        }
    }
}
