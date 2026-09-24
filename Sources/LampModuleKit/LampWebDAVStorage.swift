import Foundation

/// Shared WebDAV operations. App adapters translate these results into their
/// own storage errors and map files into their respective local formats.
public struct LampWebDAVStorage: Sendable, LampSyncRemoteStore {
    public enum StorageError: Error {
        case invalidPath
        case invalidResponse
        case invalidXML(String)
        case httpStatus(Int)
        case preconditionFailed
    }

    private let http: LampWebDAVHTTP

    public static func isStrongETag(_ revision: String) -> Bool {
        // RFC 9110 entity-tag grammar permits one opaque quoted tag here.
        // An embedded quote could turn If-Match into a list of validators.
        let bytes = Array(revision.utf8)
        guard bytes.count >= 2, bytes.first == 0x22, bytes.last == 0x22 else {
            return false
        }
        return bytes.dropFirst().dropLast().allSatisfy { byte in
            byte == 0x21 || (byte >= 0x23 && byte <= 0x7e) || byte >= 0x80
        }
    }

    public init(
        baseURL: URL,
        credentials: LampWebDAVHTTP.Credentials? = nil,
        session: URLSession? = nil
    ) {
        http = LampWebDAVHTTP(baseURL: baseURL, credentials: credentials, session: session)
    }

    public func makeRequest(method: String, path: String) throws -> URLRequest {
        do {
            return try http.makeRequest(method: method, path: path)
        } catch LampWebDAVHTTP.TransportError.invalidPath {
            throw StorageError.invalidPath
        }
    }

    public func testConnection() async throws -> Bool {
        let body = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>
        """.utf8)
        let (_, response, _) = try await send(
            method: "PROPFIND", path: "",
            headers: ["Depth": "0", "Content-Type": "application/xml"], body: body
        )
        return (200..<300).contains(response.statusCode)
    }

    public func listDirectory(_ path: String) async throws -> [LampWebDAVItem]? {
        let body = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop>
        <d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/>
        </d:prop></d:propfind>
        """.utf8)
        let (data, response, request) = try await send(
            method: "PROPFIND", path: path,
            headers: ["Depth": "1", "Content-Type": "application/xml"], body: body
        )
        if response.statusCode == 404 { return nil }
        try requireSuccess(response)
        let items: [LampWebDAVItem]
        do {
            items = try LampWebDAVDirectoryParser.parse(data)
        } catch LampWebDAVDirectoryParser.ParseError.invalidResponse(let message) {
            throw StorageError.invalidXML(message)
        }
        let requestedPath = request.url?.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return items.filter { item in
            let itemPath = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return itemPath != requestedPath && itemPath != relativePath
        }
    }

    public func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        try await listDirectory(directory)?.map { item in
            LampSyncRemoteEntry(
                path: item.path,
                name: item.name,
                isDirectory: item.isDirectory,
                revision: item.etag,
                modifiedAt: item.lastModified,
                size: item.size
            )
        }
    }

    public func download(_ path: String) async throws -> Data? {
        try await read(path: path)?.data
    }

    public func read(path: String) async throws -> LampSyncRemoteFile? {
        let (data, response, _) = try await send(method: "GET", path: path)
        if response.statusCode == 404 { return nil }
        try requireSuccess(response)
        return LampSyncRemoteFile(
            data: data,
            revision: response.value(forHTTPHeaderField: "ETag")
        )
    }

    public func upload(_ data: Data, to path: String) async throws {
        _ = try await write(data, to: path, condition: .unconditional)
    }

    public func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        var headers = ["Content-Type": "application/octet-stream"]
        switch condition {
        case .unconditional:
            break
        case .ifAbsent:
            headers["If-None-Match"] = "*"
        case .ifRevision(let revision):
            // HTTP If-Match uses strong comparison. A weak or malformed ETag
            // cannot protect this write from replacing a different version.
            guard Self.isStrongETag(revision) else {
                throw StorageError.preconditionFailed
            }
            headers["If-Match"] = revision
        }
        let (_, response, _) = try await send(
            method: "PUT", path: path,
            headers: headers, body: data
        )
        if response.statusCode == 412 || response.statusCode == 428 {
            throw StorageError.preconditionFailed
        }
        try requireSuccess(response, allowed: [200, 201, 204])
        return response.value(forHTTPHeaderField: "ETag")
    }

    public func delete(_ path: String) async throws {
        let (_, response, _) = try await send(method: "DELETE", path: path)
        try requireSuccess(response, allowed: [200, 204, 404])
    }

    public func createDirectory(_ path: String) async throws {
        let (_, response, _) = try await send(
            method: "MKCOL", path: path, headers: ["Content-Length": "0"]
        )
        if response.statusCode == 409, try await isExistingDirectory(path) {
            // Some servers use Conflict for a collection that already exists.
            return
        }
        try requireSuccess(response, allowed: [200, 201, 204, 405])
    }

    private func isExistingDirectory(_ path: String) async throws -> Bool {
        let body = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>
        """.utf8)
        let (data, response, request) = try await send(
            method: "PROPFIND", path: path,
            headers: ["Depth": "0", "Content-Type": "application/xml"], body: body
        )
        if response.statusCode == 404 { return false }
        try requireSuccess(response)
        let items: [LampWebDAVItem]
        do {
            items = try LampWebDAVDirectoryParser.parse(data)
        } catch LampWebDAVDirectoryParser.ParseError.invalidResponse(let message) {
            throw StorageError.invalidXML(message)
        }
        let requested = request.url?.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return items.contains { item in
            guard item.isDirectory else { return false }
            let found = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return found == requested || requested.hasSuffix("/\(found)")
        }
    }

    public func getETag(_ path: String) async throws -> String? {
        let (_, response, _) = try await send(method: "HEAD", path: path)
        if response.statusCode == 404 { return nil }
        try requireSuccess(response)
        return response.value(forHTTPHeaderField: "ETag")
    }

    public func revision(path: String) async throws -> String? {
        do {
            return try await getETag(path)
        } catch StorageError.httpStatus(405) {
            // Some WebDAV servers reject HEAD even though GET is available.
            return try await read(path: path)?.revision
        }
    }

    public func exists(_ path: String) async throws -> Bool {
        let (_, response, _) = try await send(method: "HEAD", path: path)
        if response.statusCode == 404 { return false }
        if response.statusCode == 405 {
            // Some servers allow GET but reject HEAD for the same resource.
            return try await read(path: path) != nil
        }
        try requireSuccess(response)
        return true
    }

    private func send(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse, URLRequest) {
        let request: URLRequest
        do {
            request = try http.makeRequest(method: method, path: path, headers: headers, body: body)
        } catch LampWebDAVHTTP.TransportError.invalidPath {
            throw StorageError.invalidPath
        }
        do {
            let (data, response) = try await http.send(request)
            return (data, response, request)
        } catch LampWebDAVHTTP.TransportError.invalidResponse {
            throw StorageError.invalidResponse
        }
    }

    private func requireSuccess(
        _ response: HTTPURLResponse,
        allowed: Set<Int>? = nil
    ) throws {
        let code = response.statusCode
        guard allowed?.contains(code) ?? (200..<300).contains(code) else {
            throw StorageError.httpStatus(code)
        }
    }
}
