import Foundation
import Security

/// The chat model providers. Both speak the OpenAI-compatible chat API.
enum Provider: String, CaseIterable, Identifiable, Codable {
    case deepseek, kimi

    var id: String { rawValue }
    var title: String { self == .deepseek ? "DeepSeek" : "Kimi" }
    var defaultBaseURL: String { self == .deepseek ? "https://api.deepseek.com/v1" : "https://api.moonshot.ai/v1" }
    /// Shown until the model list is fetched with the key.
    var knownModels: [String] {
        self == .deepseek ? ["deepseek-chat", "deepseek-reasoner"] : ["kimi-latest", "moonshot-v1-8k", "moonshot-v1-32k"]
    }
    /// Where the account's usage and billing are shown.
    var usageURL: URL {
        switch self {
        case .deepseek: return URL(string: "https://platform.deepseek.com/usage")!
        case .kimi: return URL(string: baseURL.contains(".cn") ? "https://platform.moonshot.cn/console/info" : "https://platform.moonshot.ai/console/info")!
        }
    }
    var keyHint: String {
        self == .deepseek ? "Get a key at platform.deepseek.com." : "Get a key at platform.moonshot.ai (or platform.moonshot.cn with the .cn address)."
    }

    var apiKey: String? {
        get { Keychain.get("api-key-\(rawValue)") }
        nonmutating set { Keychain.set(newValue, for: "api-key-\(rawValue)") }
    }
    var baseURL: String {
        let s = (UserDefaults.standard.string(forKey: "baseURL-\(rawValue)") ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? defaultBaseURL : s
    }
    var model: String {
        UserDefaults.standard.string(forKey: "model-\(rawValue)") ?? knownModels[0]
    }
}

struct ChatClient {
    struct Message: Codable, Equatable {
        let role: String
        let content: String
    }

    let provider: Provider

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let key = provider.apiKey, !key.isEmpty else {
            throw AppError("Add your \(provider.title) API key in Settings first.")
        }
        var base = provider.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw AppError("The \(provider.title) address isn't a valid URL.") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 120
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    func models() async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(for: try request("/models"))
        try check(response, data)
        struct List: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }

    /// One chat completion. With `json`, the model is asked for a JSON object (where the model supports it).
    func complete(_ messages: [Message], model: String, json: Bool, temperature: Double = 0.8) async throws -> String {
        struct Format: Encodable { let type: String }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double?
            let response_format: Format?
            let max_tokens: Int
        }
        let reasoning = model.contains("reasoner") || model.contains("thinking")
        var r = try request("/chat/completions", method: "POST")
        r.httpBody = try JSONEncoder().encode(Body(
            model: model, messages: messages,
            temperature: sentTemperature(temperature, reasoning: reasoning),
            response_format: json && !reasoning ? Format(type: "json_object") : nil,
            max_tokens: reasoning ? 8_000 : 800))
        let (data, response) = try await URLSession.shared.data(for: r)
        try check(response, data)
        struct Reply: Decodable {
            struct Choice: Decodable { struct M: Decodable { let content: String? }; let message: M }
            let choices: [Choice]
            let usage: Usage?
        }
        let decoded = try JSONDecoder().decode(Reply.self, from: data)
        if let usage = decoded.usage { UsageStore.record(usage, for: provider) }
        let text = decoded.choices.first?.message.content ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError("\(provider.title) returned an empty answer. Try again.")
        }
        return text
    }

    /// Streams a chat completion; `onText` gets the answer so far. Returns the whole answer.
    func stream(_ messages: [Message], model: String, temperature: Double = 0.8,
                onText: @escaping @Sendable (String) -> Void) async throws -> String {
        struct StreamOptions: Encodable { let include_usage: Bool }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double?
            let max_tokens: Int
            let stream: Bool
            let stream_options: StreamOptions?
        }
        let reasoning = model.contains("reasoner") || model.contains("thinking")
        var r = try request("/chat/completions", method: "POST")
        r.httpBody = try JSONEncoder().encode(Body(model: model, messages: messages,
                                                   temperature: sentTemperature(temperature, reasoning: reasoning),
                                                   max_tokens: reasoning ? 8_000 : 800, stream: true,
                                                   // DeepSeek reports token usage at the end of a stream when asked; Kimi always does
                                                   stream_options: provider == .deepseek ? StreamOptions(include_usage: true) : nil))
        let (bytes, response) = try await URLSession.shared.bytes(for: r)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 20_000 { break } }
            try check(response, data)
        }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
                let usage: Usage?        // Kimi puts it here
            }
            let choices: [Choice]
            let usage: Usage?            // DeepSeek (OpenAI style) puts it here
        }
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
            if let usage = chunk.usage ?? chunk.choices.first?.usage { UsageStore.record(usage, for: provider) }
            guard let piece = chunk.choices.first?.delta?.content, !piece.isEmpty else { continue }
            text += piece
            onText(text)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError("\(provider.title) returned an empty answer. Try again.")
        }
        return text
    }

    /// What is left on the account, as label/value lines.
    func balance() async throws -> [(String, String)] {
        switch provider {
        case .deepseek:
            // the balance endpoint lives at the root, not under /v1
            var r = try request("/user/balance")
            if let url = r.url, url.path.hasPrefix("/v1/") {
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                c?.path = String(url.path.dropFirst(3))
                r.url = c?.url
            }
            let (data, response) = try await URLSession.shared.data(for: r)
            try check(response, data)
            struct B: Decodable {
                struct Info: Decodable {
                    let currency: String
                    let total_balance: String
                    let granted_balance: String?
                    let topped_up_balance: String?
                }
                let is_available: Bool?
                let balance_infos: [Info]
            }
            let b = try JSONDecoder().decode(B.self, from: data)
            var lines: [(String, String)] = []
            for info in b.balance_infos {
                let symbol = info.currency == "CNY" ? "¥" : info.currency == "USD" ? "$" : info.currency + " "
                lines.append(("Balance (\(info.currency))", symbol + info.total_balance))
                if let t = info.topped_up_balance { lines.append(("  Topped up", symbol + t)) }
                if let g = info.granted_balance, g != "0.00" { lines.append(("  Granted", symbol + g)) }
            }
            if b.is_available == false { lines.append(("Status", "Not enough balance to make requests")) }
            return lines.isEmpty ? [("Balance", "—")] : lines
        case .kimi:
            let (data, response) = try await URLSession.shared.data(for: try request("/users/me/balance"))
            try check(response, data)
            struct B: Decodable {
                struct D: Decodable {
                    let available_balance: Double
                    let voucher_balance: Double?
                    let cash_balance: Double?
                }
                let data: D
            }
            let d = try JSONDecoder().decode(B.self, from: data).data
            let symbol = provider.baseURL.contains(".cn") ? "¥" : "$"
            let money = { (v: Double) in symbol + String(format: "%.2f", v) }
            var lines = [("Available", money(d.available_balance))]
            if let c = d.cash_balance { lines.append(("  Cash", money(c))) }
            if let v = d.voucher_balance, v != 0 { lines.append(("  Vouchers", money(v))) }
            if d.available_balance <= 0 { lines.append(("Status", "No balance left to make requests")) }
            return lines
        }
    }

    /// Kimi's models only accept a temperature of exactly 1; DeepSeek's reasoning model ignores it.
    private func sentTemperature(_ temperature: Double, reasoning: Bool) -> Double? {
        if provider == .kimi { return 1 }
        return reasoning ? nil : temperature
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        struct Wrapper: Decodable { struct E: Decodable { let message: String? }; let error: E? }
        let detail = (try? JSONDecoder().decode(Wrapper.self, from: data))?.error?.message
            ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
        switch http.statusCode {
        case 401: throw AppError("\(provider.title) rejected the API key (401). Check it in Settings.")
        case 402: throw AppError("Your \(provider.title) balance is empty (402).")
        case 429: throw AppError("\(provider.title) is rate limiting (429). Wait a moment and try again.")
        default: throw AppError("\(provider.title) error \(http.statusCode): \(detail)")
        }
    }
}

/// Token counts a provider reports for each request.
struct Usage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
}

/// Tokens Shuō has used per provider, this month and in total (kept on the phone).
enum UsageStore {
    struct Totals: Codable {
        var requests = 0
        var input = 0
        var output = 0
    }

    private static func key(_ provider: Provider, _ period: String) -> String { "usage-\(provider.rawValue)-\(period)" }
    static var thisMonth: String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func totals(_ provider: Provider, period: String) -> Totals {
        guard let data = UserDefaults.standard.data(forKey: key(provider, period)),
              let t = try? JSONDecoder().decode(Totals.self, from: data) else { return Totals() }
        return t
    }

    private static let lock = NSLock()

    static func record(_ usage: Usage, for provider: Provider) {
        lock.lock(); defer { lock.unlock() }
        for period in [thisMonth, "all"] {
            var t = totals(provider, period: period)
            t.requests += 1
            t.input += usage.prompt_tokens ?? 0
            t.output += usage.completion_tokens ?? 0
            UserDefaults.standard.set(try? JSONEncoder().encode(t), forKey: key(provider, period))
        }
    }

    static func reset(_ provider: Provider) {
        for period in [thisMonth, "all"] { UserDefaults.standard.removeObject(forKey: key(provider, period)) }
    }
}

enum Keychain {
    private static let service = "com.cadewardc.shuo"

    static func get(_ account: String) -> String? {
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

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
