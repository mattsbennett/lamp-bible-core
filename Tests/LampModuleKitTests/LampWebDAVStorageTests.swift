import Foundation
import Testing
@testable import LampModuleKit

struct LampWebDAVStorageTests {
    @Test func acceptsOnlyOneStrongEntityTag() {
        for revision in ["\"\"", "\"one\"", "\"a,b\"", "\"back\\slash\""] {
            #expect(LampWebDAVStorage.isStrongETag(revision))
        }
        for revision in [
            "W/\"one\"", "\"a\",\"b\"", "\"a\" \"b\"",
            "\"a\\\"b\"", "\"a b\"", "\"a\n\"", "\"a\r\"", "\"a\t\"",
            "unquoted", "\"unfinished",
        ] {
            #expect(!LampWebDAVStorage.isStrongETag(revision))
        }
    }

    @Test func requestsPreserveDirectoryPathsAndRejectTraversal() throws {
        let baseURL = try #require(URL(string: "https://dav.example.com/sync/"))
        let storage = LampWebDAVStorage(
            baseURL: baseURL,
            credentials: .init(username: "reader", password: "secret")
        )
        let request = try storage.makeRequest(method: "PROPFIND", path: "Notes/My Study/")
        #expect(request.url?.absoluteString == "https://dav.example.com/sync/Notes/My%20Study/")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic cmVhZGVyOnNlY3JldA==")
        #expect(throws: LampWebDAVStorage.StorageError.self) {
            try storage.makeRequest(method: "GET", path: "../secrets")
        }
        #expect(throws: LampWebDAVStorage.StorageError.self) {
            try storage.makeRequest(method: "GET", path: "/outside")
        }
    }

    @Test func parserReadsMetadataAndEncodedNames() throws {
        let data = Data(#"""
            <?xml version="1.0" encoding="UTF-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response><d:href>/sync/Notes/</d:href>
                <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
              </d:response>
              <d:response><d:href>/sync/Notes/My%20Study.lamp</d:href>
                <d:propstat><d:prop><d:getetag>"abc"</d:getetag>
                  <d:getcontentlength>42</d:getcontentlength>
                  <d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified>
                </d:prop></d:propstat>
              </d:response>
              <d:response><d:href>https://dav.example.com/sync/Notes/Plan%23Draft.lamp</d:href></d:response>
            </d:multistatus>
            """#.utf8)
        let items = try LampWebDAVDirectoryParser.parse(data)
        #expect(items.count == 3)
        #expect(items[0].isDirectory)
        #expect(items[1].name == "My Study.lamp")
        #expect(items[1].etag == "\"abc\"")
        #expect(items[1].size == 42)
        #expect(items[1].lastModified != nil)
        #expect(items[2].name == "Plan#Draft.lamp")
        #expect(items[2].path == "/sync/Notes/Plan#Draft.lamp")
        #expect(throws: LampWebDAVDirectoryParser.ParseError.self) {
            try LampWebDAVDirectoryParser.parse(Data("<error/>".utf8))
        }
    }

    @Test func conditionalWritesSendExactETagsAndRejectStaleWrites() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let baseURL = try #require(URL(string: "https://dav.example.com/sync/"))
        let storage = LampWebDAVStorage(baseURL: baseURL, session: session)

        WebDAVTestURLProtocol.handler = { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                return (HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["ETag": "\"old\""]
                )!, Data("remote".utf8))
            }
            if request.httpMethod == "HEAD" {
                return (HTTPURLResponse(
                    url: url, statusCode: 405, httpVersion: nil, headerFields: nil
                )!, Data())
            }
            #expect(request.httpMethod == "PUT")
            if request.value(forHTTPHeaderField: "If-None-Match") == "*" {
                return (HTTPURLResponse(
                    url: url, statusCode: 201, httpVersion: nil,
                    headerFields: ["ETag": "\"new\""]
                )!, Data())
            }
            #expect(request.value(forHTTPHeaderField: "If-Match") == "\"old\"")
            return (HTTPURLResponse(
                url: url, statusCode: 412, httpVersion: nil, headerFields: nil
            )!, Data())
        }

        let remote = try #require(try await storage.read(path: "settings.db"))
        #expect(remote.data == Data("remote".utf8))
        #expect(remote.revision == "\"old\"")
        #expect(try await storage.revision(path: "settings.db") == "\"old\"")
        #expect(try await storage.exists("settings.db"))
        let newRevision = try await storage.write(
            Data("local".utf8), to: "settings.db", condition: .ifAbsent
        )
        #expect(newRevision == "\"new\"")
        do {
            _ = try await storage.write(
                Data("local".utf8), to: "settings.db",
                condition: .ifRevision("\"old\"")
            )
            Issue.record("Expected a stale write to fail")
        } catch LampWebDAVStorage.StorageError.preconditionFailed {
            // The server rejected the write atomically.
        }
        do {
            _ = try await storage.write(
                Data("local".utf8), to: "settings.db",
                condition: .ifRevision("W/\"old\"")
            )
            Issue.record("A weak ETag cannot guard a conditional write")
        } catch LampWebDAVStorage.StorageError.preconditionFailed {
            // Weak validators cannot be used with If-Match.
        }
        do {
            _ = try await storage.write(
                Data("local".utf8), to: "settings.db",
                condition: .ifRevision("\"a\",\"b\"")
            )
            Issue.record("A combined ETag cannot guard a conditional write")
        } catch LampWebDAVStorage.StorageError.preconditionFailed {
            // A validator list is not the one entity-tag that was observed.
        }

        WebDAVTestURLProtocol.handler = { request in
            let url = try #require(request.url)
            let status: Int
            switch (request.httpMethod, url.lastPathComponent) {
            case ("HEAD", "missing.db"), ("GET", "get-missing.db"):
                status = 404
            case ("HEAD", "forbidden.db"):
                status = 403
            case ("HEAD", "present.db"), ("GET", "get-present.db"):
                status = 204
            case ("HEAD", "get-present.db"), ("HEAD", "get-missing.db"):
                status = 405
            default:
                Issue.record("Unexpected WebDAV existence request: \(request)")
                status = 500
            }
            return (HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil
            )!, Data())
        }
        #expect(try await storage.exists("present.db"))
        #expect(try await storage.exists("get-present.db"))
        #expect(try await storage.exists("missing.db") == false)
        #expect(try await storage.exists("get-missing.db") == false)
        do {
            _ = try await storage.exists("forbidden.db")
            Issue.record("An authorization failure must not look like an absent file")
        } catch LampWebDAVStorage.StorageError.httpStatus(403) {
            // The caller can distinguish a server failure from a missing file.
        }

        WebDAVTestURLProtocol.handler = { request in
            let url = try #require(request.url)
            if request.httpMethod == "MKCOL" {
                return (HTTPURLResponse(
                    url: url, statusCode: 409, httpVersion: nil, headerFields: nil
                )!, Data())
            }
            #expect(request.httpMethod == "PROPFIND")
            #expect(request.value(forHTTPHeaderField: "Depth") == "0")
            let status = url.lastPathComponent == "missing" ? 404 : 207
            let resourceType = url.lastPathComponent == "file"
                ? "" : "<d:collection/>"
            let body = Data("""
                <d:multistatus xmlns:d="DAV:"><d:response>
                  <d:href>\(url.path)/</d:href>
                  <d:propstat><d:prop><d:resourcetype>\(resourceType)</d:resourcetype>
                  </d:prop></d:propstat>
                </d:response></d:multistatus>
                """.utf8)
            return (HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil
            )!, body)
        }
        try await storage.createDirectory("Notes/existing")
        for path in ["Notes/missing", "Notes/file"] {
            do {
                try await storage.createDirectory(path)
                Issue.record("A missing collection or file must keep the MKCOL conflict")
            } catch LampWebDAVStorage.StorageError.httpStatus(409) {
                // A verified collection is the only accepted conflict.
            }
        }
    }
}

private final class WebDAVTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request)
                ?? { throw URLError(.badServerResponse) }()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
