import Foundation
import Security

/// DeepSeek's OpenAI-compatible chat API.
struct DeepSeekClient {
    static let defaultBaseURL = "https://api.deepseek.com"
    /// Shown until the model list has been fetched with the key.
    static let knownModels = ["deepseek-chat", "deepseek-reasoner"]

    var apiKey: String
    var baseURL: String

    init(apiKey: String = Keychain.deepSeekKey ?? "", baseURL: String? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = baseURL ?? UserDefaults.standard.string(forKey: "deepseekBaseURL") ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = trimmed.isEmpty ? Self.defaultBaseURL : trimmed
    }

    private func endpoint(_ path: String) throws -> URL {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw AppError("The DeepSeek address isn't a valid URL.") }
        return url
    }

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard !apiKey.isEmpty else { throw AppError("Add your DeepSeek API key in Settings first.") }
        var r = URLRequest(url: try endpoint(path))
        r.httpMethod = method
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    /// The models this key can use.
    func models() async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(for: try request("/models"))
        try Self.check(response, data)
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    /// Streams a chat completion and returns the full answer; `onText` gets the answer so far.
    func complete(model: String, messages: [Message], maxTokens: Int? = nil, temperature: Double = 0.7,
                  onText: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let stream: Bool
            let max_tokens: Int?
            let temperature: Double?
        }
        var r = try request("/chat/completions", method: "POST")
        r.timeoutInterval = 900
        // the reasoning model ignores temperature
        let body = Body(model: model, messages: messages, stream: true, max_tokens: maxTokens,
                        temperature: model.contains("reasoner") ? nil : temperature)
        r.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: r)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 20_000 { break } }
            try Self.check(response, data)
        }

        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
            if let piece = chunk.choices.first?.delta?.content, !piece.isEmpty {
                text += piece
                onText(text)
            }
        }
        guard !text.isEmpty else { throw AppError("DeepSeek returned an empty answer. Try again or pick another model.") }
        return text
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        struct Wrapper: Decodable { struct E: Decodable { let message: String? }; let error: E? }
        let detail = (try? JSONDecoder().decode(Wrapper.self, from: data))?.error?.message
            ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
        switch http.statusCode {
        case 401: throw AppError("DeepSeek rejected the API key (401). Check it in Settings.")
        case 402: throw AppError("Your DeepSeek balance is empty (402). Top up at platform.deepseek.com.")
        case 429: throw AppError("DeepSeek is rate limiting requests (429). Wait a moment and try again.")
        default: throw AppError("DeepSeek error \(http.statusCode): \(detail)")
        }
    }
}

/// The DeepSeek API key, kept in the Keychain.
enum Keychain {
    private static let service = "com.cadewardc.edge"
    private static let account = "deepseek-api-key"

    static var deepSeekKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            var add = query
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
