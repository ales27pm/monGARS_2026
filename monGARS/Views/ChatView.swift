import SwiftData
import SwiftUI

struct ChatView: View {
    @Bindable var container: AppContainer
    let navigateToSection: ((AppSection) -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \AgentTraceRecord.createdAt, order: .forward) private var traces: [AgentTraceRecord]
    @Query(sort: \AgentRunRecord.updatedAt, order: .reverse) private var agentRuns: [AgentRunRecord]
    @FocusState private var isComposerFocused: Bool
    @State private var selectedConversation: Conversation?
    @State private var draft = ""
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var currentRunID: UUID?
    @State private var pendingApprovals: [UUID: PendingApproval] = [:]
    @State private var isDictating = false
    @State private var webViewRequest: IntegratedWebViewRequest?

    init(container: AppContainer, navigateToSection: ((AppSection) -> Void)? = nil) {
        self.container = container
        self.navigateToSection = navigateToSection
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if activeMessages.isEmpty {
                        ContentUnavailableView(
                            "monGARS",
                            systemImage: "sparkles",
                            description: Text("Ask me for a calculation, a saved memory, a document summary, or anything you want to work through.")
                        )
                        .padding(.top, 80)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(activeMessages) { message in
                                MessageBubble(
                                    message: message,
                                    traces: tracesForMessage(message),
                                    pendingApproval: pendingApprovals[message.id],
                                    onApprove: { approval in resolveInlineApproval(approval, approved: true) },
                                    onReject: { approval in resolveInlineApproval(approval, approved: false) },
                                    onHandoff: handleToolHandoff
                                )
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    isComposerFocused = false
                }
                .onChange(of: activeMessages.count) {
                    if let id = activeMessages.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await toggleDictation() }
                } label: {
                    Image(systemName: isDictating ? "stop.circle.fill" : "mic")
                }
                .buttonStyle(.bordered)
                .tint(isDictating ? .red : nil)
                .disabled(isRunning && !isDictating)

                TextField("Message monGARS", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($isComposerFocused)
                    .submitLabel(.send)
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
        .navigationTitle(activeConversation?.title ?? "monGARS")
        .toolbar {
            if let navigateToSection {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(AppSection.allCases) { section in
                            Button {
                                isComposerFocused = false
                                navigateToSection(section)
                            } label: {
                                Label(section.title, systemImage: section.icon)
                            }
                        }
                    } label: {
                        Label("Sections", systemImage: "line.3.horizontal")
                    }
                    .accessibilityLabel("Sections")
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isComposerFocused = false
                        createConversation()
                    } label: {
                        Label("New Chat", systemImage: "plus")
                    }

                    if !conversations.isEmpty {
                        Divider()
                        ForEach(conversations) { conversation in
                            Button {
                                isComposerFocused = false
                                selectedConversation = conversation
                            } label: {
                                Label(conversation.title, systemImage: selectedConversation?.id == conversation.id ? "checkmark" : "bubble.left")
                            }
                        }
                    }
                } label: {
                    Label("Conversations", systemImage: "sidebar.left")
                }

                Button {
                    saveDraftAsMemory()
                } label: {
                    Label("Save Memory", systemImage: "plus.circle")
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isRunning {
                    Button {
                        stopCurrentRun()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isComposerFocused = false
                }
            }
        }
        .onAppear {
            ensureConversationSelected()
        }
        .onChange(of: conversations.count) {
            ensureConversationSelected()
        }
        .onDisappear {
            stopDictation()
        }
        .sheet(item: $webViewRequest) { request in
            IntegratedWebViewSheet(url: request.url)
        }
    }

    private var activeConversation: Conversation? {
        selectedConversation ?? conversations.first
    }

    private var activeMessages: [ChatMessage] {
        (activeConversation?.messages ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    private func ensureConversationSelected() {
        if selectedConversation == nil {
            selectedConversation = conversations.first
        }
    }

    private func tracesForMessage(_ message: ChatMessage) -> [AgentTraceRecord] {
        guard let runID = message.agentRunID else { return [] }
        return traces.filter { $0.runID == runID }
    }

    private func createConversation() {
        let conversation = Conversation()
        modelContext.insert(conversation)
        try? modelContext.save()
        selectedConversation = conversation
        statusMessage = nil
        errorMessage = nil
    }

    private func send() {
        if isDictating {
            stopDictation()
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let conversation: Conversation
        if let current = activeConversation {
            conversation = current
        } else {
            let created = Conversation()
            modelContext.insert(created)
            selectedConversation = created
            conversation = created
        }

        draft = ""
        isComposerFocused = false
        errorMessage = nil
        statusMessage = nil
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
                let options = AgentRuntimeOptions(
                    autonomyLevel: container.settingsStore.autonomyLevel,
                    maxSteps: 12,
                    timeoutSeconds: 45,
                    networkToolsEnabled: container.settingsStore.remoteProviderEnabled
                )

                for try await event in container.agentRuntime.run(goal: text, conversationID: conversation.id, messages: history, provider: container.llmProvider(), options: options, context: modelContext) {
                    await MainActor.run {
                        switch event {
                        case .status(let runID, let phase, let message):
                            currentRunID = runID
                            assistant.agentRunID = runID
                            assistant.statusText = phase.statusText
                            statusMessage = message
                            container.diagnostics.graphSteps.append(phase.rawValue)
                        case .trace(_, let phase, let message):
                            container.diagnostics.graphSteps.append("\(phase.rawValue): \(message)")
                        case .partialResponse(let runID, let partial):
                            currentRunID = runID
                            assistant.agentRunID = runID
                            assistant.content = partial
                        case .approvalRequired(let runID, let approvalID, let toolName, let reason):
                            currentRunID = runID
                            assistant.agentRunID = runID
                            assistant.statusText = "Approval required"
                            assistant.content = "I need approval before running \(toolName): \(reason)"
                            pendingApprovals[assistant.id] = PendingApproval(id: approvalID, runID: runID, toolName: toolName, reason: reason)
                            statusMessage = "Approval required for \(toolName)."
                        case .completed(let runID, let response):
                            currentRunID = runID
                            assistant.agentRunID = runID
                            assistant.statusText = "Done"
                            assistant.content = response
                            if let action = ToolHandoffAction.actions(from: response).first(where: { $0.destination == .integratedWebView }) {
                                webViewRequest = IntegratedWebViewRequest(url: action.url)
                            }
                            pendingApprovals.removeValue(forKey: assistant.id)
                            statusMessage = nil
                        }
                    }
                }

                await MainActor.run {
                    conversation.updatedAt = .now
                    try? modelContext.save()
                    isRunning = false
                    currentRunID = nil
                    pendingApprovals.removeValue(forKey: assistant.id)
                }
            } catch {
                await MainActor.run {
                    assistant.content = "I hit an error: \(error.localizedDescription)"
                    container.diagnostics.lastError = error.localizedDescription
                    errorMessage = error.localizedDescription
                    isRunning = false
                    currentRunID = nil
                    pendingApprovals.removeValue(forKey: assistant.id)
                }
            }
        }
    }

    private func resolveInlineApproval(_ approval: PendingApproval, approved: Bool) {
        do {
            if approved {
                try container.agentRuntime.approve(approvalID: approval.id, context: modelContext)
                statusMessage = "Approved \(approval.toolName)."
            } else {
                try container.agentRuntime.reject(approvalID: approval.id, context: modelContext)
                statusMessage = "Rejected \(approval.toolName)."
            }
            if let messageID = pendingApprovals.first(where: { $0.value.id == approval.id })?.key {
                pendingApprovals.removeValue(forKey: messageID)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleToolHandoff(_ action: ToolHandoffAction) {
        switch action.destination {
        case .integratedWebView:
            webViewRequest = IntegratedWebViewRequest(url: action.url)
        case .openURL:
            openURL(action.url)
        }
    }

    private func stopCurrentRun() {
        guard let currentRunID,
              let run = agentRuns.first(where: { $0.id == currentRunID }) else {
            isRunning = false
            return
        }
        do {
            try container.agentRuntime.cancel(run: run, context: modelContext)
            statusMessage = "Agent run stopped."
            isRunning = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveDraftAsMemory() {
        do {
            try container.memoryService.save(content: draft, context: modelContext)
            draft = ""
            isComposerFocused = false
            statusMessage = "Saved to memory."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    private func toggleDictation() async {
        if isDictating {
            await MainActor.run {
                stopDictation()
                statusMessage = draft.isEmpty ? nil : "Dictation stopped."
            }
            return
        }

        do {
            await MainActor.run {
                isDictating = true
                statusMessage = "Listening..."
                errorMessage = nil
                isComposerFocused = true
            }
            try await container.speechService.startTranscription { transcript in
                Task { @MainActor in
                    draft = transcript
                    statusMessage = "Listening..."
                }
            }
        } catch {
            await MainActor.run {
                isDictating = false
                statusMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopDictation() {
        container.speechService.stopTranscription()
        isDictating = false
    }
}

struct PendingApproval: Identifiable, Equatable {
    let id: UUID
    let runID: UUID
    let toolName: String
    let reason: String
}

struct MessageBubble: View {
    let message: ChatMessage
    let traces: [AgentTraceRecord]
    let pendingApproval: PendingApproval?
    let onApprove: (PendingApproval) -> Void
    let onReject: (PendingApproval) -> Void
    let onHandoff: (ToolHandoffAction) -> Void
    @State private var isTraceExpanded = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .assistant { bubbleStack }
            Spacer(minLength: message.role == .assistant ? 40 : 80)
            if message.role == .user { bubbleStack }
        }
    }

    private var bubbleStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            bubble
            if let pendingApproval {
                approvalControls(pendingApproval)
            }
            if message.role == .assistant {
                handoffControls
            }
            if message.role == .assistant, !traces.isEmpty {
                DisclosureGroup(isExpanded: $isTraceExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(traces) { trace in
                            Text("\(trace.stepIndex). \(trace.phase): \(trace.message)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Label("Agent Trace", systemImage: "list.bullet.rectangle")
                        .font(.caption)
                }
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let status = message.statusText, message.role == .assistant {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.content.isEmpty ? "Thinking..." : message.content)
        }
            .padding(12)
            .background(message.role == .user ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundStyle(message.role == .user ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func approvalControls(_ approval: PendingApproval) -> some View {
        HStack(spacing: 8) {
            Button {
                onApprove(approval)
            } label: {
                Label("Approve", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                onReject(approval)
            } label: {
                Label("Reject", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
        }
    }

    private var handoffControls: some View {
        let actions = ToolHandoffAction.actions(from: message.content)
        return HStack(spacing: 8) {
            ForEach(actions) { action in
                Button {
                    onHandoff(action)
                } label: {
                    Label(action.label, systemImage: action.systemImage)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
