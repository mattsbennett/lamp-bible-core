import Foundation

/// Shared HTTP transport for the iOS module and macOS archive WebDAV clients.
/// Callers decide which status codes are valid for each WebDAV operation.
public struct LampWebDAVHTTP: Sendable {
    public struct Credentials: Sendable {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public enum TransportError: Error {
        case invalidPath
        case invalidResponse
    }

    public let baseURL: URL
    private let credentials: Credentials?
    private let session: URLSession

    public init(
        baseURL: URL,
        credentials: Credentials? = nil,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session ?? Self.makeSession()
    }

    public func makeRequest(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws -> URLRequest {
        let url: URL
        if path.isEmpty {
            url = baseURL
        } else {
            let segments = path.split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            let hasTrailingSlash = segments.last?.isEmpty == true
            let components = hasTrailingSlash ? Array(segments.dropLast()) : segments
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw TransportError.invalidPath
            }
            var built = baseURL
            for component in components {
                built.appendPathComponent(component)
            }
            if hasTrailingSlash && !built.path.hasSuffix("/"),
               var parts = URLComponents(url: built, resolvingAgainstBaseURL: false) {
                parts.path += "/"
                built = parts.url ?? built
            }
            url = built
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let credentials {
            let token = Data("\(credentials.username):\(credentials.password)".utf8)
                .base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TransportError.invalidResponse
        }
        return (data, response)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }
}
