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

    /// What a status says about a file being there. HEAD's 404 is absence,
    /// and its 405 means ask GET instead, since some servers allow GET but
    /// not HEAD. A success is presence. Anything else is an error, never
    /// absence. (`Verification/SyncMerge.lean`: `webDAVPresence`.)
    enum Presence: Equatable { case present, absent, askGET, failed }

    static func presence(afterHEAD status: Int) -> Presence {
        if status == 405 { return .askGET }
        return presence(afterGET: status)
    }

    static func presence(afterGET status: Int) -> Presence {
        if status == 404 { return .absent }
        return (200..<300).contains(status) ? .present : .failed
    }

    /// Whether MKCOL left a directory there: created, already there (405),
    /// or a 409 Conflict over a collection a PROPFIND confirms is there.
    /// (`Verification/SyncMerge.lean`: `webDAVDirectoryReady`.)
    static func directoryReady(mkcolStatus: Int, existingCollection: Bool) -> Bool {
        [200, 201, 204, 405].contains(mkcolStatus) || (mkcolStatus == 409 && existingCollection)
    }

    /// What a PROPFIND says about a collection: 404 is none, a success is
    /// whatever its listing shows, and anything else is an error.
    /// (`Verification/SyncMerge.lean`: `collectionConfirmed`.)
    static func collectionConfirmed(
        propfindStatus: Int, listsCollection: () throws -> Bool
    ) rethrows -> Bool? {
        if propfindStatus == 404 { return false }
        guard (200..<300).contains(propfindStatus) else { return nil }
        return try listsCollection()
    }

    /// Whether a listing names `requested` as a collection.
    static func listsCollection(_ items: [LampWebDAVItem], at requested: String) -> Bool {
        items.contains { item in
            guard item.isDirectory else { return false }
            let found = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return found == requested || requested.hasSuffix("/\(found)")
        }
    }

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
        switch Self.presence(afterGET: response.statusCode) {
        case .absent: return nil
        case .failed, .askGET: throw StorageError.httpStatus(response.statusCode)
        case .present: break
        }
        return LampSyncRemoteFile(
            data: data,
            revision: response.value(forHTTPHeaderField: "ETag")
        )
    }

    /// Asks for only the first `count` bytes. A server that honours Range
    /// answers 206 with them; one that ignores it answers 200 with the whole
    /// body, which is streamed to disk and cut, so it costs a download but
    /// never the memory. The revision is the whole file's either way.
    public func readPrefix(path: String, count: Int) async throws -> LampSyncRemoteFile? {
        var request = try makeRequest(method: "GET", path: path)
        request.setValue("bytes=0-\(max(count, 1) - 1)", forHTTPHeaderField: "Range")
        let body: URL
        let response: HTTPURLResponse
        do {
            (body, response) = try await http.download(request)
        } catch LampWebDAVHTTP.TransportError.invalidResponse {
            throw StorageError.invalidResponse
        }
        defer { try? FileManager.default.removeItem(at: body) }
        switch Self.presence(afterGET: response.statusCode) {
        case .absent: return nil
        case .failed, .askGET: throw StorageError.httpStatus(response.statusCode)
        case .present: break
        }
        let handle = try FileHandle(forReadingFrom: body)
        defer { try? handle.close() }
        return LampSyncRemoteFile(
            data: try handle.read(upToCount: max(count, 0)) ?? Data(),
            revision: response.value(forHTTPHeaderField: "ETag")
        )
    }

    public func read(path: String, into url: URL) async throws -> LampSyncDownloadedFile? {
        let body: URL
        let response: HTTPURLResponse
        do {
            (body, response) = try await http.download(makeRequest(method: "GET", path: path))
        } catch LampWebDAVHTTP.TransportError.invalidResponse {
            throw StorageError.invalidResponse
        }
        defer { try? FileManager.default.removeItem(at: body) }
        switch Self.presence(afterGET: response.statusCode) {
        case .absent: return nil
        case .failed, .askGET: throw StorageError.httpStatus(response.statusCode)
        case .present: break
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: body, to: url)
        return LampSyncDownloadedFile(url: url, revision: response.value(forHTTPHeaderField: "ETag"))
    }

    public func upload(_ data: Data, to path: String) async throws {
        _ = try await write(data, to: path, condition: .unconditional)
    }

    public func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        let headers = try Self.putHeaders(for: condition)
        return try await putCreatingParents(path) {
            try await send(method: "PUT", path: path, headers: headers, body: data).1
        }
    }

    public func write(
        fileAt url: URL,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        let request = try http.makeRequest(
            method: "PUT", path: path, headers: try Self.putHeaders(for: condition)
        )
        return try await putCreatingParents(path) {
            do {
                return try await http.upload(request, fromFile: url).1
            } catch LampWebDAVHTTP.TransportError.invalidResponse {
                throw StorageError.invalidResponse
            }
        }
    }

    /// A PUT into a folder that isn't there fails with 409 and writes nothing
    /// (RFC 4918, 9.7.1). Per-file sync puts files into folders no one has
    /// made yet: a new writing's attachments, a book's pictures, a
    /// workspace. So on 409 the folders are made, and the same PUT, under
    /// the same condition, is asked once more.
    private func putCreatingParents(
        _ path: String,
        _ put: () async throws -> HTTPURLResponse
    ) async throws -> String? {
        var response = try await put()
        if response.statusCode == 409, path.contains("/") {
            try await LampSyncRemoteDirectories.prepareParents(for: path) { try await createDirectory($0) }
            response = try await put()
        }
        return try Self.revision(afterPUT: response)
    }

    private static func putHeaders(for condition: LampSyncWriteCondition) throws -> [String: String] {
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
        return headers
    }

    private static func revision(afterPUT response: HTTPURLResponse) throws -> String? {
        if response.statusCode == 412 || response.statusCode == 428 {
            throw StorageError.preconditionFailed
        }
        guard [200, 201, 204].contains(response.statusCode) else {
            throw StorageError.httpStatus(response.statusCode)
        }
        return response.value(forHTTPHeaderField: "ETag")
    }

    public func delete(_ path: String) async throws {
        let (_, response, _) = try await send(method: "DELETE", path: path)
        try requireSuccess(response, allowed: [200, 204, 404])
    }

    /// DELETE under the same preconditions PUT uses. 404 is a file already
    /// gone; 412 is one at another revision, which stays.
    public func delete(path: String, condition: LampSyncWriteCondition) async throws {
        var headers = try Self.putHeaders(for: condition)
        headers.removeValue(forKey: "Content-Type")
        let (_, response, _) = try await send(method: "DELETE", path: path, headers: headers)
        if response.statusCode == 412 || response.statusCode == 428 {
            throw StorageError.preconditionFailed
        }
        try requireSuccess(response, allowed: [200, 202, 204, 404])
    }

    public func createDirectory(_ path: String) async throws {
        let (_, response, _) = try await send(
            method: "MKCOL", path: path, headers: ["Content-Length": "0"]
        )
        // Some servers use Conflict for a collection that already exists.
        let existing = response.statusCode == 409 ? try await isExistingDirectory(path) : false
        guard Self.directoryReady(mkcolStatus: response.statusCode, existingCollection: existing) else {
            throw StorageError.httpStatus(response.statusCode)
        }
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
        let requested = request.url?.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        guard let confirmed = try Self.collectionConfirmed(
            propfindStatus: response.statusCode,
            listsCollection: {
                let items: [LampWebDAVItem]
                do {
                    items = try LampWebDAVDirectoryParser.parse(data)
                } catch LampWebDAVDirectoryParser.ParseError.invalidResponse(let message) {
                    throw StorageError.invalidXML(message)
                }
                return Self.listsCollection(items, at: requested)
            }
        ) else {
            throw StorageError.httpStatus(response.statusCode)
        }
        return confirmed
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
        switch Self.presence(afterHEAD: response.statusCode) {
        case .absent: return false
        case .present: return true
        case .askGET:
            // Some servers allow GET but reject HEAD for the same resource.
            return try await read(path: path) != nil
        case .failed: throw StorageError.httpStatus(response.statusCode)
        }
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
