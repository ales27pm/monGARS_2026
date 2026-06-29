import SwiftData
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case chat
    case memories
    case documents
    case goals
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .memories: "Memories"
        case .documents: "Documents"
        case .goals: "Goals"
        case .diagnostics: "Diagnostics"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .memories: "brain"
        case .documents: "doc.text"
        case .goals: "checklist"
        case .diagnostics: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Bindable var container: AppContainer
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppSection? = .chat

    var body: some View {
        Group {
            if !container.storageState.allowsUserWorkflows {
                StorageUnavailableView(message: container.storageState.message ?? "Persistent storage is unavailable.")
            } else if horizontalSizeClass == .compact {
                compactRoot
            } else {
                regularRoot
            }
        }
        .task {
            container.seedIfNeeded(context: modelContext)
            container.diagnostics.providerStatus = await container.llmProvider().status
        }
    }

    private var compactRoot: some View {
        TabView(selection: compactSelection) {
            ForEach(AppSection.allCases) { section in
                NavigationStack {
                    content(for: section)
                }
                .tabItem {
                    Label(section.title, systemImage: section.icon)
                }
                .tag(section)
            }
        }
    }

    private var regularRoot: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("monGARS")
        } detail: {
            content(for: selection ?? .chat)
        }
    }

    private var compactSelection: Binding<AppSection> {
        Binding(
            get: { selection ?? .chat },
            set: { selection = $0 }
        )
    }

    @ViewBuilder
    private func content(for section: AppSection) -> some View {
        switch section {
        case .chat:
            ChatView(container: container) { section in
                selection = section
            }
        case .memories:
            MemoryManagerView(container: container)
                .navigationTitle(AppSection.memories.title)
        case .documents:
            DocumentsView(container: container)
                .navigationTitle(AppSection.documents.title)
        case .goals:
            GoalsView(container: container)
                .navigationTitle(AppSection.goals.title)
        case .diagnostics:
            DiagnosticsView(container: container)
                .navigationTitle(AppSection.diagnostics.title)
        case .settings:
            SettingsView(container: container)
                .navigationTitle(AppSection.settings.title)
        }
    }
}

private struct StorageUnavailableView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.red)

            Text("Storage Unavailable")
                .font(.title.bold())

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)

            Text("Chat, memories, documents, goals, and tools are disabled because new data cannot be stored durably.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
