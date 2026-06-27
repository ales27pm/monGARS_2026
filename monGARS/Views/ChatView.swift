import SwiftData
import SwiftUI

struct ChatView: View {
    @Bindable var container: AppContainer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var selectedConversation: Conversation?
    @State private var draft = ""
    @State private var isRunning = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedConversation) {
                ForEach(conversations) { conversation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(conversation.updatedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(conversation)
                }
                .onDelete(perform: deleteConversation)
            }
            .navigationTitle("Conversations")
            .toolbar {
                Button {
                    createConversation()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
            }
        } detail: {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(activeConversation?.messages.sorted(by: { $0.createdAt < $1.createdAt }) ?? []) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: activeConversation?.messages.count ?? 0) {
                        if let id = activeConversation?.messages.sorted(by: { $0.createdAt < $1.createdAt }).last?.id {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await requestSpeech() }
                    } label: {
                        Image(systemName: "mic")
                    }
                    .buttonStyle(.bordered)

                    TextField("Message monGARS", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .onSubmit { send() }

                    Button {
                        send()
                    } label: {
                        Image(systemName: isRunning ? "hourglass" : "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
                }
                .padding()
            }
            .navigationTitle(activeConversation?.title ?? "Chat")
            .toolbar {
                Button {
                    saveDraftAsMemory()
                } label: {
                    Label("Save Memory", systemImage: "plus.circle")
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if selectedConversation == nil {
                selectedConversation = conversations.first
            }
        }
    }

    private var activeConversation: Conversation? {
        selectedConversation ?? conversations.first
    }

    private func createConversation() {
        let conversation = Conversation()
        modelContext.insert(conversation)
        try? modelContext.save()
        selectedConversation = conversation
    }

    private func deleteConversation(_ offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(conversations[index])
        }
        try? modelContext.save()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let conversation = activeConversation ?? Conversation()
        if activeConversation == nil {
            modelContext.insert(conversation)
            selectedConversation = conversation
        }
        draft = ""
        errorMessage = nil
        isRunning = true

        let userMessage = ChatMessage(role: .user, content: text)
        conversation.messages.append(userMessage)
        conversation.title = conversation.title == "New Chat" ? String(text.prefix(36)) : conversation.title
        conversation.updatedAt = .now
        try? modelContext.save()

        let assistant = ChatMessage(role: .assistant, content: "")
        conversation.messages.append(assistant)
        try? modelContext.save()

        Task {
            do {
                let history = conversation.messages.map { "\($0.role.rawValue): \($0.content)" }
                let execution = AgentExecutionContext(
                    llmProvider: container.llmProvider(),
                    toolRouter: container.toolRouter,
                    context: modelContext,
                    event: { event in
                        await MainActor.run { container.diagnostics.record(event: event) }
                    }
                )
                for try await event in container.agentGraph.run(input: text, messages: history, context: execution) {
                    await MainActor.run {
                        container.diagnostics.record(event: event)
                        if case .partialResponse(let partial) = event {
                            assistant.content = partial
                        }
                        if case .checkpoint(let checkpoint) = event, checkpoint.nodeID == "respond" {
                            assistant.content = checkpoint.state.finalResponse
                        }
                    }
                }
                await MainActor.run {
                    conversation.updatedAt = .now
                    try? modelContext.save()
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    assistant.content = "I hit an error: \(error.localizedDescription)"
                    container.diagnostics.lastError = error.localizedDescription
                    errorMessage = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }

    private func saveDraftAsMemory() {
        do {
            try container.memoryService.save(content: draft, context: modelContext)
            draft = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestSpeech() async {
        let allowed = await container.speechService.requestAuthorization()
        await MainActor.run {
            errorMessage = allowed ? "Speech is authorized. Live dictation UI can be connected from this service." : "Speech permission was not granted or is unavailable."
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant { bubble }
            Spacer(minLength: message.role == .assistant ? 40 : 80)
            if message.role == .user { bubble }
        }
    }

    private var bubble: some View {
        Text(message.content.isEmpty ? "Thinking..." : message.content)
            .padding(12)
            .background(message.role == .user ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundStyle(message.role == .user ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

