import SwiftData
import SwiftUI

struct MemoryManagerView: View {
    @Bindable var container: AppContainer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MemoryRecord.createdAt, order: .reverse) private var memories: [MemoryRecord]
    @State private var newMemory = ""
    @State private var query = ""
    @State private var errorMessage: String?

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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(memory.content)
                        if !memory.tags.isEmpty {
                            Text(memory.tags.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: delete)
            }
        }
        .padding()
        .navigationTitle("Memories")
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
}

