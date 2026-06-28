import SwiftData
import SwiftUI

@main
struct MonGARSApp: App {
    @State private var container: AppContainer?

    var body: some Scene {
        WindowGroup {
            if let container {
                RootView(container: container)
                    .modelContainer(container.modelContainer)
            } else {
                LaunchLoadingView()
                    .task {
                        guard container == nil else { return }
                        container = AppContainer()
                    }
            }
        }
    }
}

private struct LaunchLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.blue)

            ProgressView()
                .controlSize(.regular)

            Text("Starting monGARS")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
