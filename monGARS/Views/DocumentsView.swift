import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DocumentsView: View {
    @Bindable var container: AppContainer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DocumentRecord.importedAt, order: .reverse) private var documents: [DocumentRecord]
    @State private var isImporting = false
    @State private var query = ""
    @State private var snippets: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Ask about imported documents", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button {
                    search()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                Button {
                    isImporting = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !snippets.isEmpty {
                List(snippets, id: \.self) { snippet in
                    Text(snippet)
                        .font(.callout)
                }
                .frame(maxHeight: 180)
            }

            List {
                ForEach(documents) { document in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(document.title)
                            .font(.headline)
                        Text(document.content)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .onDelete(perform: delete)
            }
        }
        .padding()
        .navigationTitle("Documents")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                try container.documentService.importDocument(url: url, context: modelContext)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func search() {
        do {
            snippets = try container.documentService.snippets(matching: query, context: modelContext)
            if snippets.isEmpty {
                errorMessage = "No document snippets matched that query."
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            try? container.documentService.delete(documents[index], context: modelContext)
        }
    }
}
