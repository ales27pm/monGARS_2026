import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

struct ToolHandoffAction: Identifiable, Equatable {
    enum Destination: Equatable {
        case openURL
        case integratedWebView
    }

    var id: String { "\(destination)-\(url.absoluteString)" }
    var label: String
    var systemImage: String
    var url: URL
    var destination: Destination

    static func actions(from text: String) -> [ToolHandoffAction] {
        var actions: [ToolHandoffAction] = []

        if let url = firstURL(in: text, schemes: ["sms"]) {
            actions.append(ToolHandoffAction(label: "Open Messages", systemImage: "message", url: url, destination: .openURL))
        }
        if let url = firstURL(in: text, schemes: ["tel"]) {
            actions.append(ToolHandoffAction(label: "Call", systemImage: "phone", url: url, destination: .openURL))
        }
        if let url = firstURL(in: text, schemes: ["mailto"]) {
            actions.append(ToolHandoffAction(label: "Open Mail", systemImage: "envelope", url: url, destination: .openURL))
        }
        if let url = firstURL(in: text, schemes: ["http", "https"], hostPrefix: "maps.apple.com") {
            actions.append(ToolHandoffAction(label: "Open Maps", systemImage: "map", url: url, destination: .openURL))
        }
        if text.localizedCaseInsensitiveContains("in-app webview"),
           let url = firstURL(in: text, schemes: ["http", "https"]) {
            actions.append(ToolHandoffAction(label: "Open Web View", systemImage: "safari", url: url, destination: .integratedWebView))
        }

        return actions
    }

    private static func firstURL(in text: String, schemes: Set<String>, hostPrefix: String? = nil) -> URL? {
        for token in urlTokens(in: text) {
            guard let url = URL(string: token),
                  let scheme = url.scheme?.lowercased(),
                  schemes.contains(scheme) else {
                continue
            }
            if let hostPrefix {
                guard url.host?.lowercased().hasPrefix(hostPrefix) == true else { continue }
            }
            return url
        }
        return nil
    }

    private static func urlTokens(in text: String) -> [String] {
        let pattern = #"(sms:[^\s]+|tel://[^\s]+|mailto:[^\s]+|https?://[^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        }
    }
}

struct IntegratedWebViewRequest: Identifiable, Equatable {
    var id: String { url.absoluteString }
    var url: URL
}

struct IntegratedWebViewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            IntegratedWebView(url: url)
                .navigationTitle(url.host ?? "Web View")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Label("Done", systemImage: "xmark")
                        }
                    }
                }
        }
    }
}

struct IntegratedWebView: View {
    let url: URL

    var body: some View {
        #if canImport(WebKit)
        WebKitView(url: url)
        #else
        ContentUnavailableView("Web view unavailable", systemImage: "safari", description: Text(url.absoluteString))
        #endif
    }
}

#if canImport(WebKit)
private struct WebKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard uiView.url != url else { return }
        uiView.load(URLRequest(url: url))
    }
}
#endif
