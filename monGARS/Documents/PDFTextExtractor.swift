import Foundation

#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct PDFTextExtractionResult: Sendable, Equatable {
    var pageTexts: [String]

    var text: String {
        pageTexts.joined(separator: "\n\n")
    }
}

enum PDFTextExtractor {
    static func extract(data: Data, maxCharactersPerPage: Int = 4_000) throws -> PDFTextExtractionResult {
        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            throw PersistenceError.importFailed("PDFKit could not open the PDF data.")
        }
        guard document.pageCount > 0 else {
            throw PersistenceError.importFailed("PDF contains no readable pages.")
        }

        var pageTexts: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let raw = page.string ?? ""
            let cleaned = raw
                .replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            pageTexts.append("Page \(pageIndex + 1):\n\(String(cleaned.prefix(maxCharactersPerPage)))")
        }

        guard !pageTexts.isEmpty else {
            throw PersistenceError.importFailed("PDFKit opened the PDF, but no selectable text was found.")
        }
        return PDFTextExtractionResult(pageTexts: pageTexts)
        #else
        throw PersistenceError.importFailed("PDFKit is unavailable on this platform.")
        #endif
    }
}

enum DiagnosticPDFFactory {
    static func makeSelectablePDFData(text: String) -> Data? {
        #if canImport(UIKit)
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(x: 0, y: 0, width: 300, height: 180), nil)
        UIGraphicsBeginPDFPage()
        (text as NSString).draw(
            at: CGPoint(x: 24, y: 64),
            withAttributes: [.font: UIFont.systemFont(ofSize: 14)]
        )
        UIGraphicsEndPDFContext()
        return data as Data
        #else
        return nil
        #endif
    }
}
