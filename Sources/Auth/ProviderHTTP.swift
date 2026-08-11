import Foundation

/// Common HTTP plumbing for providers.
public struct ProviderHTTP {
    public let session: URLSession
    public var defaultHeaders: [String: String]

    /// Read from the framework's own bundle rather than `Bundle.main`, which
    /// under `make test` is the xctest runner and not the app.
    private static let version = Bundle(for: BundleToken.self)
        .infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"

    private static let userAgent = "aibars/\(version) (https://github.com/AndrxwWxng/aibars)"

    /// Cookies stay off: providers hand-build their own `Cookie` header, and a
    /// stored `Set-Cookie` from a previous poll would silently override it.
    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json"
        ]
        return URLSession(configuration: config)
    }

    // One session per timeout, shared for the life of the process: a poll cycle
    // fires ~18 requests, and a fresh session per request means a fresh TCP and
    // TLS handshake per request. Keyed by timeout rather than overridden per
    // request because request-vs-config precedence is not dependable, and
    // Mistral's deliberate 4s best-effort calls must stay 4s.
    private static let defaultSession = makeSession(timeout: 15)
    private static let shortSession = makeSession(timeout: 4)

    public init(headers: [String: String] = [:], timeout: TimeInterval = 15) {
        switch timeout {
        case 15: self.session = Self.defaultSession
        case 4: self.session = Self.shortSession
        default: self.session = Self.makeSession(timeout: timeout)
        }
        self.defaultHeaders = headers
    }

    public func get(_ url: URL, headers extra: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        for (k, v) in defaultHeaders { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extra { request.setValue(v, forHTTPHeaderField: k) }
        request.httpMethod = "GET"
        return try await perform(request)
    }

    public func post(_ url: URL, body: Data, headers extra: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        for (k, v) in defaultHeaders { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extra { request.setValue(v, forHTTPHeaderField: k) }
        request.httpMethod = "POST"
        request.httpBody = body
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.network("Non-HTTP response")
            }
            switch http.statusCode {
            case 200..<300: return (data, http)
            case 401, 403: throw ProviderError.sessionExpired
            case 429: throw ProviderError.rateLimited
            default:
                let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                throw ProviderError.network("HTTP \(http.statusCode): \(body)")
            }
        } catch let e as ProviderError {
            throw e
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
    }

    /// Decoding needs no session, so callers holding bytes already can reach
    /// this without building a `ProviderHTTP` at all.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            throw ProviderError.parse("\(error.localizedDescription) — \(preview)")
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try Self.decode(type, from: data)
    }
}

/// Anchor for `Bundle(for:)` — resolves to the framework this file compiles into.
private final class BundleToken {}

/// Convenience for date helpers.
public enum ProviderDate {
    public static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static let iso8601NoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ string: String) -> Date? {
        if let d = iso8601.date(from: string) { return d }
        if let d = iso8601NoFrac.date(from: string) { return d }
        if let seconds = TimeInterval(string) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

/// Coerce a JSON value (Int, Double, NSNumber, or numeric String) to Double.
public enum ProviderNumber {
    public static func coerce(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let n as Int64: return Double(n)
        case let n as UInt64: return Double(n)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
