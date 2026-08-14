import Foundation

enum FetchOutcome {
    case notModified
    /// data 已是原始字节；charset 来自 Content-Type（可能为 nil）。
    case success(data: Data, etag: String?, lastModified: String?, charset: String?, finalURL: URL)
}

enum FetchError: LocalizedError {
    case badURL(String)
    case status(code: Int, retryAfter: Date?)
    case tooLarge
    case notHTTP

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "URL 无效: \(s)"
        case .status(let code, _): return "HTTP \(code)"
        case .tooLarge: return "响应超过 10 MB 上限"
        case .notHTTP: return "非 HTTP 响应"
        }
    }
}

/// 网络抓取。条件 GET + 字节上限（设计文档 §4 机制 5）。
final class FeedFetcher: Sendable {
    static let maxBytes = 10 * 1024 * 1024

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil // 缓存语义由 ETag/Last-Modified 承担，不再叠一层 URLCache
        config.httpAdditionalHeaders = ["User-Agent": "2W/0.1 (macOS RSS reader)"]
        session = URLSession(configuration: config)
    }

    /// userAgent / basicUser 为 nil 时沿用 session 默认头，既有调用点行为不变。
    func fetch(url: URL, etag: String? = nil, lastModified: String? = nil,
               userAgent: String? = nil, basicUser: String? = nil,
               basicPassword: String? = nil) async throws -> FetchOutcome {
        var request = URLRequest(url: url)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        if let userAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let auth = Self.basicAuthHeader(user: basicUser, password: basicPassword) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP }
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.status(
                code: http.statusCode,
                retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        }

        let expected = http.expectedContentLength
        if expected > Int64(Self.maxBytes) { throw FetchError.tooLarge }

        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 1 << 16)
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxBytes { throw FetchError.tooLarge }
        }

        return .success(
            data: data,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            charset: http.textEncodingName,
            finalURL: http.url ?? url)
    }

    /// RFC 7617 的 `Basic base64(用户名:密码)`。用户名为空 = 不认证（密码可以为空，有站点这么用）。
    static func basicAuthHeader(user: String?, password: String?) -> String? {
        guard let user, !user.isEmpty else { return nil }
        return "Basic " + Data("\(user):\(password ?? "")".utf8).base64EncodedString()
    }

    /// Retry-After 支持秒数与 RFC 7231 HTTP-date。无效值交给调度器使用默认退避。
    static func retryAfter(_ value: String?, now: Date = Date()) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z",
                       "EEE MMM d HH':'mm':'ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(date, now) }
        }
        return nil
    }
}
