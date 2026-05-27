import Foundation

public enum ICloudError: Error, Equatable {
    case notSignedIn
    case notAvailable
    case timeout
    case invalidPath
}

public actor ICloudContainer {
    private let identifier: String
    private let overrideRoot: URL?
    private let fileManager: FileManager

    public init(identifier: String, overrideRoot: URL? = nil, fileManager: FileManager = .default) {
        self.identifier = identifier
        self.overrideRoot = overrideRoot
        self.fileManager = fileManager
    }

    public func rootURL() throws -> URL {
        if let overrideRoot {
            let documents = overrideRoot.appendingPathComponent("Documents", isDirectory: true)
            try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
            return documents
        }
        guard let url = fileManager.url(forUbiquityContainerIdentifier: identifier) else {
            throw ICloudError.notAvailable
        }
        let documents = url.appendingPathComponent("Documents", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    public func ensureAvailable(timeoutSeconds: Int = 30) async throws {
        if overrideRoot != nil { return }
        for _ in 0..<timeoutSeconds {
            if fileManager.url(forUbiquityContainerIdentifier: identifier) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ICloudError.timeout
    }

    public func relativeURL(for relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { throw ICloudError.invalidPath }
        return try rootURL().appendingPathComponent(trimmed)
    }
}
