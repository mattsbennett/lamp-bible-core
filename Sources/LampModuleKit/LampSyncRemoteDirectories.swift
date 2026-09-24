/// Prepares parent directories from the remote root toward a file. A batch
/// can pass its previously prepared paths to avoid repeating MKCOL requests.
public enum LampSyncRemoteDirectories {
    public enum DirectoryError: Error {
        case invalidPath
    }

    @discardableResult
    public static func prepareParents(
        for path: String,
        alreadyPrepared: Set<String> = [],
        createDirectory: (String) async throws -> Void
    ) async throws -> Set<String> {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DirectoryError.invalidPath
        }
        var prepared = alreadyPrepared
        var directory = ""
        for component in components.dropLast() {
            directory += directory.isEmpty ? String(component) : "/\(component)"
            if prepared.insert(directory).inserted {
                try await createDirectory(directory)
            }
        }
        return prepared
    }
}
