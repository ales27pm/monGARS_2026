import SwiftData
import SwiftUI

@main
struct MonGARSApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .modelContainer(container.modelContainer)
        }
    }
}

