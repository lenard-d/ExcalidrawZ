#if DEBUG && os(iOS) && targetEnvironment(simulator)
import SwiftUI

/// Exercises the welcome view without changing the store's presentation entitlement.
struct PresentationWelcomeUITestFixture: View {
    @State private var upgradeRequestCount = 0
    @State private var isShowingUpgradeResult = false

    var body: some View {
        NavigationStack {
            PresentationWelcomeView {
                upgradeRequestCount += 1
                isShowingUpgradeResult = true
            }
            .navigationTitle("Presentation")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Upgrade action received", isPresented: $isShowingUpgradeResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Request \(upgradeRequestCount)")
            }
        }
        .frame(width: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}
#endif
