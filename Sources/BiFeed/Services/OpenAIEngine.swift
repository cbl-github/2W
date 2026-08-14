import Foundation

enum APITranslateError: LocalizedError {
    case notConfigured
    case badStatus(Int)
    case badPayload

    var errorDescription: String? {
        switch self {
        case .notConfigured: return L("error.api.notConfigured")
        case .badStatus(let code): return L("error.api.badStatus", code)
        case .badPayload: return L("error.api.badPayload")
        }
    }
}

/// OpenAI 兼容中转翻译引擎。凭据每次调用现读（UserDefaults + Keychain），
/// 设置改动无需重建实例即生效。
@MainActor
final class OpenAICompatibleEngine: TranslationEngine {
    /// 每组请求的源文本字符上限；单段超限独立成组。
    private static let maxGroupChars = 3000

    /// 原文照用（冻结契约）。多行字面量只为断行，`\` 续行不产生换行，字符串值与折行前逐字相同。
    private static let systemPrompt = """
        你是专业译者。把用户消息里 JSON 数组中的每个段落翻译成简体中文：技术术语保留英文原词或用业界通行译法，\
        语气自然像中文技术博客，不逐字直译。只输出 JSON 数组，元素 {"i": 原编号, "t": "译文"}，\
        编号一一对应，不增不减，无任何多余文字。
        """

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    // MARK: - TranslationEngine

    func availability(source: String, target: String) async -> EngineAvailability {
        currentConfig() != nil ? .installed : .unsupported
    }

    func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        guard let config = currentConfig() else { throw APITranslateError.notConfigured }

        // 分组：按源文本累计 ≤3000 字符。超限段落进组时组已被清空，天然独立成组。
        var groups: [[Item]] = []
        var current: [Item] = []
        var chars = 0
        for (i, text) in texts.enumerated() {
            if !current.isEmpty, chars + text.count > Self.maxGroupChars {
                groups.append(current)
                current = []
                chars = 0
            }
            current.append(Item(i: i, text: text))
            chars += text.count
        }
        if !current.isEmpty { groups.append(current) }

        // 组间串行（保序、限速友好），按全局下标装回。
        var out = [String?](repeating: nil, count: texts.count)
        for group in groups {
            for answer in try await translateGroup(group, config: config) {
                out[answer.i] = answer.t
            }
        }
        return out.map { $0! } // requestOnce 已校验编号集合与请求一致，必非 nil
    }

    func requestDownload(source: String, target: String) async {}

    // MARK: - 请求

    private struct Config {
        let endpoint: URL
        let model: String
        let key: String
    }

    private struct Item: Encodable {
        var i: Int
        var text: String
    }

    private struct Answer: Decodable {
        var i: Int
        var t: String
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }

        var model: String
        var temperature: Double
        var messages: [Message]
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String
            }

            var message: Message
        }

        var choices: [Choice]
    }

    private func currentConfig() -> Config? {
        let d = UserDefaults.standard
        let base = (d.string(forKey: SettingsKey.apiBaseURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (d.string(forKey: SettingsKey.apiModel) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = KeychainStore.get(account: "api-key") ?? ""
        guard !base.isEmpty, !model.isEmpty, !key.isEmpty,
              let endpoint = URL(string: Self.normalize(base) + "/chat/completions")
        else { return nil }
        return Config(endpoint: endpoint, model: model, key: key)
    }

    /// 去尾部 /；以 /v1 结尾不重复加，否则补 /v1。
    private static func normalize(_ base: String) -> String {
        var s = base
        while s.hasSuffix("/") { s.removeLast() }
        return s.hasSuffix("/v1") ? s : s + "/v1"
    }

    private func translateGroup(_ items: [Item], config: Config) async throws -> [Answer] {
        do {
            return try await requestOnce(items, config: config)
        } catch APITranslateError.badPayload {
            // LLM 输出波动（段数/编号不符、JSON 坏）是规格内现实：同组重试一次，再失败照抛。
            return try await requestOnce(items, config: config)
        }
    }

    private func requestOnce(_ items: [Item], config: Config) async throws -> [Answer] {
        let userJSON = String(data: try! JSONEncoder().encode(items), encoding: .utf8)!
        let body = ChatRequest(
            model: config.model,
            temperature: 0.2,
            messages: [
                .init(role: "system", content: Self.systemPrompt),
                .init(role: "user", content: userJSON),
            ])

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try! JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APITranslateError.badStatus(http.statusCode)
        }

        guard let content = (try? JSONDecoder().decode(ChatResponse.self, from: data))?
            .choices.first?.message.content
        else { throw APITranslateError.badPayload }

        // 掐头去尾：模型可能包 ``` 围栏或加说明文字，取第一个 '[' 到最后一个 ']'。
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"), start < end,
              let answers = try? JSONDecoder().decode([Answer].self, from: Data(content[start...end].utf8))
        else { throw APITranslateError.badPayload }

        guard answers.count == items.count, Set(answers.map(\.i)) == Set(items.map(\.i)) else {
            throw APITranslateError.badPayload
        }
        return answers
    }
}
