import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

struct ToolHandoffAction: Identifiable, Equatable {
    enum Destination: Equatable {
        case openURL
        case integratedWebView
        case mailCompose
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
            actions.append(ToolHandoffAction(label: "Compose Email", systemImage: "envelope", url: url, destination: .mailCompose))
        }
        if let url = firstURL(in: text, schemes: ["http", "https"], hostPrefix: "maps.apple.com") {
            actions.append(ToolHandoffAction(label: "Open Maps", systemImage: "map", url: url, destination: .openURL))
        }
        if text.localizedCaseInsensitiveContains("in-app webview"),
           let url = lastURL(in: text, schemes: ["http", "https"], excludingHostPrefix: "maps.apple.com") {
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

    private static func lastURL(in text: String, schemes: Set<String>, excludingHostPrefix: String? = nil) -> URL? {
        for token in urlTokens(in: text).reversed() {
            guard let url = URL(string: token),
                  let scheme = url.scheme?.lowercased(),
                  schemes.contains(scheme) else {
                continue
            }
            if let excludingHostPrefix,
               url.host?.lowercased().hasPrefix(excludingHostPrefix) == true {
                continue
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
    @State private var state: WebViewLoadState

    init(url: URL) {
        self.url = url
        _state = State(initialValue: WebViewLoadState(url: url))
    }

    var body: some View {
        #if canImport(WebKit)
        VStack(spacing: 0) {
            webViewStatusBar
            WebKitView(url: url, state: $state)
        }
        #else
        ContentUnavailableView("Web view unavailable", systemImage: "safari", description: Text(url.absoluteString))
        #endif
    }

    private var webViewStatusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: state.isLoading ? "arrow.triangle.2.circlepath" : "safari")
                    .foregroundStyle(state.statusColor)
                Text(state.displayHost)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text(state.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if state.errorMessage != nil {
                    Button {
                        state.reloadToken = UUID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Retry page load")
                }
            }

            if state.isLoading {
                ProgressView(value: state.estimatedProgress)
                    .progressViewStyle(.linear)
            }

            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}

#if canImport(WebKit)
private struct WebViewLoadState: Equatable {
    var currentURL: URL
    var isLoading = false
    var estimatedProgress = 0.0
    var errorMessage: String?
    var reloadToken = UUID()

    init(url: URL) {
        currentURL = url
    }

    var displayHost: String {
        currentURL.host ?? currentURL.absoluteString
    }

    var statusText: String {
        if errorMessage != nil { return "Failed" }
        if isLoading { return "Loading" }
        return "Loaded"
    }

    var statusColor: Color {
        if errorMessage != nil { return .red }
        if isLoading { return .blue }
        return .green
    }
}

private struct WebKitView: UIViewRepresentable {
    let url: URL
    @Binding var state: WebViewLoadState

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let shouldLoadRequestedURL = uiView.url != url
        let shouldRetry = context.coordinator.lastReloadToken != state.reloadToken
        guard shouldLoadRequestedURL || shouldRetry else { return }
        context.coordinator.lastReloadToken = state.reloadToken
        state.errorMessage = nil
        state.isLoading = true
        uiView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: $state)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var state: WebViewLoadState
        var lastReloadToken: UUID

        init(state: Binding<WebViewLoadState>) {
            _state = state
            lastReloadToken = state.wrappedValue.reloadToken
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.currentURL = webView.url ?? state.currentURL
            state.isLoading = true
            state.errorMessage = nil
            state.estimatedProgress = webView.estimatedProgress
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            state.currentURL = webView.url ?? state.currentURL
            state.estimatedProgress = webView.estimatedProgress
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.currentURL = webView.url ?? state.currentURL
            state.isLoading = false
            state.estimatedProgress = 1
            state.errorMessage = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            record(error: error, webView: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            record(error: error, webView: webView)
        }

        private func record(error: Error, webView: WKWebView) {
            state.currentURL = webView.url ?? state.currentURL
            state.isLoading = false
            state.errorMessage = error.localizedDescription
        }
    }
}
#endif
