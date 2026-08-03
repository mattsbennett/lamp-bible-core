import Darwin
import Foundation
import LampCore
import LampModuleKit

@main
enum LampModuleCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            printUsage()
            exit(EXIT_FAILURE)
        }

        let succeeded: Bool
        switch arguments[0] {
        case "inspect" where arguments.count > 1:
            succeeded = inspect(paths: Array(arguments.dropFirst()))
        case "build" where arguments.count == 2 || arguments.count == 3:
            succeeded = build(sourcePath: arguments[1], outputPath: arguments.count == 3 ? arguments[2] : nil)
        case "verify" where arguments.count == 2:
            succeeded = await verify(path: arguments[1])
        default:
            printUsage()
            exit(EXIT_FAILURE)
        }
        exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func inspect(paths: [String]) -> Bool {
        var failed = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let inspection = try ModuleJSONInspector().inspect(data)
                printInspection(inspection, url: url)
                failed = failed || !inspection.canCompile
            } catch {
                failed = true
                print("\(url.lastPathComponent): invalid")
                print("  error / \(error.localizedDescription)")
            }
        }

        return !failed
    }

    private static func build(sourcePath: String, outputPath: String?) -> Bool {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let outputURL = outputPath.map { URL(fileURLWithPath: $0) }
        do {
            let result = try LampModuleCompiler().compile(
                sourceURL: sourceURL,
                destinationURL: outputURL
            )
            print("Built \(result.outputURL.path)")
            print("  type: \(result.kind.rawValue)")
            print("  module: \(result.moduleID)")
            print("  size: \(result.compressedByteCount) bytes (\(result.uncompressedByteCount) uncompressed)")
            print("  sha256: \(result.sha256)")
            let counts = result.tableCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            print("  contents: \(counts)")
            return true
        } catch {
            writeError("Build failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func verify(path: String) async -> Bool {
        let sourceURL = URL(fileURLWithPath: path)
        let temporaryLibraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryLibraryURL) }

        do {
            let library = LampLibrary(rootURL: temporaryLibraryURL)
            let module = try await library.install(from: sourceURL)
            print("Verified \(sourceURL.path)")
            print("  type: \(module.kind.rawValue)")
            print("  module: \(module.id)")
            print("  name: \(module.name)")
            print("  size: \(module.compressedByteCount) bytes")

            if module.kind == .translation {
                let books = try await library.translationBooks(moduleID: module.id)
                let chapterCount = books.reduce(0) { $0 + $1.chapterCount }
                print("  contents: books=\(books.count), chapters=\(chapterCount)")
                if let firstBook = books.first {
                    let chapter = try await library.chapter(
                        moduleID: module.id,
                        bookNumber: firstBook.id,
                        chapterNumber: 1
                    )
                    print("  first chapter: \(firstBook.name) 1, verses=\(chapter.verses.count)")
                    if let firstVerse = chapter.verses.first {
                        let probe = firstVerse.text
                            .split(whereSeparator: { $0.isWhitespace })
                            .prefix(3)
                            .joined(separator: " ")
                        let searchResults = try await library.searchTranslations(
                            query: probe,
                            moduleIDs: Set([module.id]),
                            limit: 1
                        )
                        guard !searchResults.isEmpty else {
                            throw LampLibraryError.integrityCheckFailed("Translation search index returned no results for known text.")
                        }
                        print("  search index: ready")
                        if let studyData = try await library.verseStudyData(
                            moduleID: module.id,
                            reference: firstVerse.id
                        ) {
                            print("  verse metadata: annotations=\(studyData.annotations.count), footnotes=\(studyData.footnotes.count)")
                        }
                    }
                }
            } else if module.kind == .plan {
                let plans = try await library.readingPlans()
                guard let plan = plans.first,
                      let firstDay = try await library.readingPlanDay(moduleID: module.id, day: 1) else {
                    throw LampLibraryError.integrityCheckFailed("Reading plan metadata or day 1 is missing.")
                }
                print("  contents: days=\(plan.duration), first-day readings=\(firstDay.readings.count)")
            }
            return true
        } catch {
            writeError("Verification failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func printInspection(_ inspection: ModuleInspection, url: URL) {
        let kind = inspection.kind?.rawValue ?? "unknown"
        let status = inspection.canCompile ? "valid" : "invalid"
        print("\(url.lastPathComponent): \(status) \(kind)")

        if let id = inspection.metadata.id {
            print("  id: \(id)")
        }
        if let name = inspection.metadata.name {
            print("  name: \(name)")
        }
        if !inspection.statistics.isEmpty {
            let summary = inspection.statistics
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            print("  contents: \(summary)")
        }
        for issue in inspection.issues {
            print("  \(issue.severity.rawValue) \(issue.path) \(issue.message)")
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func printUsage() {
        writeError("""
            Usage:
              lamp-module inspect <module.json> [module.json ...]
              lamp-module build <module.json> [output.lamp]
              lamp-module verify <module.lamp>
            """)
    }
}
