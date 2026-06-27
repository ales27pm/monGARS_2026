import SwiftData
import SwiftUI

struct MemoryManagerView: View {
    @Bindable var container: AppContainer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MemoryRecord.createdAt, order: .reverse) private var memories: [MemoryRecord]
    @State private var newMemory = ""
    @State private var query = ""
    @State private var errorMessage: String?
    @State private var editingMemory: MemoryRecord?
    @State private var exportText = ""
    @State private var showingExport = false
    @State private var confirmingForgetAll = false

    var filteredMemories: [MemoryRecord] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return memories }
        return (try? container.memoryService.search(query: query, context: modelContext)) ?? []
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Save an important fact", text: $newMemory)
                    .textFieldStyle(.roundedBorder)
                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField("Search memories", text: $query)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            List {
                ForEach(filteredMemories) { memory in
                    Button {
                        editingMemory = memory
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(memory.content)
                                .foregroundStyle(.primary)
                            HStack(spacing: 8) {
                                Label(memory.scope, systemImage: "archivebox")
                                Label(memory.source, systemImage: "tag")
                                Label(memory.importance.formatted(.number.precision(.fractionLength(2))), systemImage: "star")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if !memory.tags.isEmpty {
                                Text(memory.tags.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: delete)
            }
        }
        .padding()
        .navigationTitle("Memories")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    exportMemories()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(memories.isEmpty)

                Button(role: .destructive) {
                    confirmingForgetAll = true
                } label: {
                    Label("Forget All", systemImage: "trash")
                }
                .disabled(memories.isEmpty)
            }
        }
        .sheet(item: $editingMemory) { memory in
            MemoryEditorView(container: container, memory: memory)
        }
        .sheet(isPresented: $showingExport) {
            NavigationStack {
                TextEditor(text: $exportText)
                    .font(.body.monospaced())
                    .padding()
                    .navigationTitle("Memory Export")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showingExport = false
                            }
                        }
                    }
            }
        }
        .confirmationDialog("Forget all memories?", isPresented: $confirmingForgetAll, titleVisibility: .visible) {
            Button("Forget All", role: .destructive) {
                forgetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every local long-term memory stored by monGARS.")
        }
    }

    private func save() {
        do {
            try container.memoryService.save(content: newMemory, context: modelContext)
            newMemory = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            let memory = filteredMemories[index]
            try? container.memoryService.delete(memory, context: modelContext)
        }
    }

    private func exportMemories() {
        do {
            exportText = try container.memoryService.exportText(context: modelContext)
            showingExport = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func forgetAll() {
        do {
            _ = try container.memoryService.forgetAll(context: modelContext)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MemoryEditorView: View {
    @Bindable var container: AppContainer
    @Bindable var memory: MemoryRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var content: String = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Memory") {
                    TextEditor(text: $content)
                        .frame(minHeight: 140)
                }

                Section("Details") {
                    LabeledContent("Scope", value: memory.scope)
                    LabeledContent("Source", value: memory.source)
                    LabeledContent("Importance", value: memory.importance.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("Updated", value: memory.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                content = memory.content
            }
        }
    }

    private func save() {
        do {
            try container.memoryService.edit(memory, content: content, context: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
