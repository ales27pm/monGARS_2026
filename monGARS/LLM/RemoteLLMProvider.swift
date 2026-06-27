import Foundation

struct RemoteLLMProvider: LLMProvider {
    let name = "Remote Endpoint"
    let capabilities = LLMProviderCapabilities.remote
    var endpoint: String
    var isEnabled: Bool

    var status: String {
        get async {
            isEnabled ? "Remote provider enabled for \(endpoint)" : "Remote provider disabled; no network calls allowed"
        }
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        guard isEnabled else { throw LLMProviderError.remoteDisabled }
        guard let url = URL(string: endpoint) else { throw LLMProviderError.invalidEndpoint }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": "llama3.2",
            "prompt": request.prompt,
            "stream": false
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let response = object["response"] as? String {
            return LLMResponse(text: response, providerName: name)
        }
        let text = String(data: data, encoding: .utf8) ?? "Remote provider returned an unreadable response."
        return LLMResponse(text: text, providerName: name)
    }
}
