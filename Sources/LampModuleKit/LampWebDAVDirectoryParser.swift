import Foundation

public struct LampWebDAVItem: Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let etag: String?
    public let lastModified: Date?
    public let size: Int64?
}

public enum LampWebDAVDirectoryParser {
    public enum ParseError: Error {
        case invalidResponse(String)
    }

    public static func parse(_ data: Data) throws -> [LampWebDAVItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawMultiStatus else {
            throw ParseError.invalidResponse(parser.parserError?.localizedDescription ?? "Invalid WebDAV XML")
        }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private(set) var items: [LampWebDAVItem] = []
        private(set) var sawMultiStatus = false
        private var elementDepth = 0
        private var href: String?
        private var isDirectory = false
        private var etag: String?
        private var lastModified: Date?
        private var size: Int64?
        private var text = ""
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter
        }()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            text = ""
            if elementDepth == 0 {
                sawMultiStatus = Self.localName(elementName) == "multistatus"
            }
            elementDepth += 1
            switch Self.localName(elementName) {
            case "response":
                href = nil
                isDirectory = false
                etag = nil
                lastModified = nil
                size = nil
            case "collection":
                isDirectory = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            elementDepth -= 1
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch Self.localName(elementName) {
            case "href":
                href = value
            case "getetag":
                etag = value
            case "getlastmodified":
                lastModified = dateFormatter.date(from: value)
            case "getcontentlength":
                size = Int64(value)
            case "response":
                if let href {
                    let encodedPath = URLComponents(string: href)?.percentEncodedPath ?? href
                    let path = encodedPath.removingPercentEncoding ?? encodedPath
                    let name = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        .split(separator: "/").last.map(String.init) ?? ""
                    if !name.isEmpty {
                        items.append(LampWebDAVItem(
                            path: path,
                            name: name,
                            isDirectory: isDirectory,
                            etag: etag,
                            lastModified: lastModified,
                            size: size
                        ))
                    }
                }
            default:
                break
            }
            text = ""
        }

        private static func localName(_ name: String) -> Substring {
            name.split(separator: ":").last ?? Substring(name)
        }
    }
}
