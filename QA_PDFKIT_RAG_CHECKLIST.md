# QA PDFKit RAG Checklist

- Import a selectable-text PDF. Expected: document is saved, chunks are created, and search finds page text.
- Import an image-only scanned PDF. Expected: honest unreadable/selectable-text error or empty-text failure; no invented content.
- Web fetch a PDF URL with selectable text. Expected: response includes page-numbered text preview.
- Web fetch a large PDF over the response-size limit. Expected: bounded failure from `NetworkClient`.
- Query Chat for content from the imported PDF. Expected: document retrieval cites the imported document text through SwiftData chunks.
