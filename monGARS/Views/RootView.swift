import SwiftData
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case chat
    case memories
    case documents
    case diagnostics
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: "Chat"
        case .memories: "Memories"
        case .documents: "Documents"
        case .diagnostics: "Diagnostics"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .memories: "brain"
        case .documents: "doc.text"
        case .diagnostics: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Bindable var container: AppContainer
    @Environment(\.modelContext) private var modelContext
    @State private var selection: AppSection? = .chat

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("monGARS")
        } detail: {
            switch selection ?? .chat {
            case .chat:
                ChatView(container: container)
            case .memories:
                MemoryManagerView(container: container)
            case .documents:
                DocumentsView(container: container)
            case .diagnostics:
                DiagnosticsView(container: container)
            case .settings:
                SettingsView(container: container)
            }
        }
        .task {
            container.seedIfNeeded(context: modelContext)
            container.diagnostics.providerStatus = await container.llmProvider().status
        }
    }
}

