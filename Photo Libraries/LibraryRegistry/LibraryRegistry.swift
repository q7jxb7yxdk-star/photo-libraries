import Combine
import Foundation

/// Stores only user-authorized Photos library package locations. This type never
/// opens or writes a Photos library's internal database.
@MainActor
final class LibraryRegistry: ObservableObject {
    private enum Constants {
        static let defaultsKey = "LibraryRegistry.descriptors.v1"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Published private(set) var descriptors: [LibraryDescriptor] {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard, descriptors initialDescriptors: [LibraryDescriptor]? = nil) {
        self.defaults = defaults
        if let descriptors = initialDescriptors {
            self.descriptors = descriptors
            return
        }
        guard let data = defaults.data(forKey: Constants.defaultsKey),
              let decoded = try? decoder.decode([LibraryDescriptor].self, from: data) else {
            descriptors = []
            return
        }
        descriptors = decoded.map { descriptor in
            var normalized = descriptor
            let metadata = descriptor.metadata
            normalized.metadata = LibraryPackageMetadata(
                displayName: metadata.displayName,
                lastKnownPath: metadata.lastKnownPath,
                volumeName: metadata.volumeName,
                creationDate: metadata.creationDate,
                modificationDate: metadata.modificationDate
            )
            return normalized
        }
    }

    var libraries: [RegisteredLibrary] {
        descriptors
            .map { RegisteredLibrary(descriptor: $0, availability: availability(of: $0)) }
            .sorted {
                $0.descriptor.metadata.displayName.localizedStandardCompare(
                    $1.descriptor.metadata.displayName
                ) == .orderedAscending
            }
    }

    /// Registers a user-selected package. Browsing retains a read-only scope;
    /// non-system libraries also retain a transfer scope from this selection.
    @discardableResult
    func addSelectedLibrary(
        at url: URL,
        kind: LibraryKind = .userSelectedPhotosLibrary
    ) throws -> LibraryDescriptor {
        guard Self.isPhotosLibraryPackage(url) else {
            throw LibraryRegistryError.notAPhotosLibrary(url)
        }

        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let writeBookmarkData: Data?
        if kind.isSystemPhotoLibrary {
            writeBookmarkData = nil
        } else {
            writeBookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        let metadata = try packageMetadata(at: url)

        let standardizedURL = url.standardizedFileURL
        if let existing = descriptors.firstIndex(where: { descriptor in
            URL(fileURLWithPath: descriptor.metadata.lastKnownPath).standardizedFileURL == standardizedURL
                || (try? resolvedURL(for: descriptor).url.standardizedFileURL) == standardizedURL
        }) {
            if kind.isSystemPhotoLibrary {
                demoteOtherSystemLibraries(except: descriptors[existing].id)
            }
            let current = descriptors[existing]
            descriptors[existing] = LibraryDescriptor(
                id: current.id,
                kind: kind,
                bookmarkData: bookmarkData,
                writeBookmarkData: writeBookmarkData ?? current.writeBookmarkData,
                addedAt: current.addedAt,
                metadata: metadata
            )
            return descriptors[existing]
        }

        if kind.isSystemPhotoLibrary {
            demoteOtherSystemLibraries(except: nil)
        }
        let descriptor = LibraryDescriptor(
            kind: kind, bookmarkData: bookmarkData,
            writeBookmarkData: writeBookmarkData, metadata: metadata
        )
        descriptors.append(descriptor)
        return descriptor
    }

    func removeLibrary(id: LibraryID) {
        descriptors.removeAll { $0.id == id }
    }

    /// Uses the Pictures folder's sandbox grant for a previously registered
    /// package. The read bookmark must still identify the exact saved path.
    @discardableResult
    func ensureTransferWriteAccess(for id: LibraryID) throws -> LibraryDescriptor {
        guard let index = descriptors.firstIndex(where: { $0.id == id }) else {
            throw LibraryRegistryError.unknownLibrary(id)
        }
        let current = descriptors[index]
        guard !current.kind.isSystemPhotoLibrary else {
            throw LibraryRegistryError.transferAccessUnavailable(
                URL(fileURLWithPath: current.metadata.lastKnownPath)
            )
        }
        if !PhotoTransferCoordinator.needsTransferAuthorization(current) {
            return current
        }

        let resolution = try resolvedURL(for: current)
        guard !resolution.isStale else { throw LibraryRegistryError.staleBookmark(id) }
        let savedURL = URL(fileURLWithPath: current.metadata.lastKnownPath).standardizedFileURL
        guard Self.isPhotosLibraryPackage(savedURL),
              resolution.url.standardizedFileURL == savedURL else {
            throw LibraryRegistryError.transferAccessUnavailable(savedURL)
        }
        guard resolution.url.startAccessingSecurityScopedResource() else {
            throw LibraryRegistryError.accessDenied(savedURL)
        }
        defer { resolution.url.stopAccessingSecurityScopedResource() }
        guard FileManager.default.fileExists(atPath: savedURL.path) else {
            throw LibraryRegistryError.libraryOffline(savedURL)
        }

        let picturesURL = try FileManager.default.url(
            for: .picturesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ).resolvingSymlinksInPath().standardizedFileURL
        let actualURL = savedURL.resolvingSymlinksInPath().standardizedFileURL
        guard actualURL.pathComponents.starts(with: picturesURL.pathComponents),
              actualURL.pathComponents.count > picturesURL.pathComponents.count,
              resolution.url.resolvingSymlinksInPath().standardizedFileURL == actualURL else {
            throw LibraryRegistryError.transferAccessUnavailable(savedURL)
        }

        // Construct a fresh URL so the new bookmark does not inherit the old
        // read-only bookmark's scope.
        let writeBookmark = try savedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let updated = LibraryDescriptor(
            id: current.id,
            kind: current.kind,
            bookmarkData: current.bookmarkData,
            writeBookmarkData: writeBookmark,
            addedAt: current.addedAt,
            metadata: current.metadata
        )
        guard !PhotoTransferCoordinator.needsTransferAuthorization(updated) else {
            throw LibraryRegistryError.transferAccessUnavailable(savedURL)
        }
        descriptors[index] = updated
        return updated
    }

    /// Refreshes both scopes after the user selects this package again.
    @discardableResult
    func reauthorizeLibrary(id: LibraryID, with url: URL) throws -> LibraryDescriptor {
        guard let index = descriptors.firstIndex(where: { $0.id == id }) else {
            throw LibraryRegistryError.unknownLibrary(id)
        }
        guard Self.isPhotosLibraryPackage(url) else {
            throw LibraryRegistryError.notAPhotosLibrary(url)
        }

        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let writeBookmarkData: Data?
        if descriptors[index].kind.isSystemPhotoLibrary {
            writeBookmarkData = descriptors[index].writeBookmarkData
        } else {
            writeBookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        descriptors[index] = LibraryDescriptor(
            id: id,
            kind: descriptors[index].kind,
            bookmarkData: bookmarkData,
            writeBookmarkData: writeBookmarkData,
            addedAt: descriptors[index].addedAt,
            metadata: try packageMetadata(at: url)
        )
        return descriptors[index]
    }

    /// Starts a read-only security scope for the duration of `body`. Do not let a
    /// URL returned from this method escape the closure.
    func withReadAccess<Result>(
        to id: LibraryID,
        _ body: (URL) throws -> Result
    ) throws -> Result {
        guard let descriptor = descriptors.first(where: { $0.id == id }) else {
            throw LibraryRegistryError.unknownLibrary(id)
        }

        let resolution = try resolvedURL(for: descriptor)
        guard !resolution.isStale else {
            throw LibraryRegistryError.staleBookmark(id)
        }
        guard Self.isPhotosLibraryPackage(resolution.url) else {
            throw LibraryRegistryError.notAPhotosLibrary(resolution.url)
        }
        guard resolution.url.startAccessingSecurityScopedResource() else {
            throw LibraryRegistryError.accessDenied(resolution.url)
        }
        defer { resolution.url.stopAccessingSecurityScopedResource() }

        guard FileManager.default.fileExists(atPath: resolution.url.path) else {
            throw LibraryRegistryError.libraryOffline(resolution.url)
        }
        return try body(resolution.url)
    }

    /// Async counterpart used by supervised Automation operations. The security
    /// scope remains active only while the supplied operation is running.
    func withReadAccess<Result: Sendable>(
        to id: LibraryID,
        _ body: (URL) async throws -> Result
    ) async throws -> Result {
        guard let descriptor = descriptors.first(where: { $0.id == id }) else {
            throw LibraryRegistryError.unknownLibrary(id)
        }

        let resolution = try resolvedURL(for: descriptor)
        guard !resolution.isStale else {
            throw LibraryRegistryError.staleBookmark(id)
        }
        guard Self.isPhotosLibraryPackage(resolution.url) else {
            throw LibraryRegistryError.notAPhotosLibrary(resolution.url)
        }
        guard resolution.url.startAccessingSecurityScopedResource() else {
            throw LibraryRegistryError.accessDenied(resolution.url)
        }
        defer { resolution.url.stopAccessingSecurityScopedResource() }

        guard FileManager.default.fileExists(atPath: resolution.url.path) else {
            throw LibraryRegistryError.libraryOffline(resolution.url)
        }
        return try await body(resolution.url)
    }

    /// Resolves a registered library and keeps its read scope open without
    /// blocking the UI while Launch Services opens Photos.
    func withReadAccessOffMain<Result: Sendable>(
        to id: LibraryID,
        _ body: @escaping @Sendable (URL) async throws -> Result
    ) async throws -> Result {
        guard let descriptor = descriptors.first(where: { $0.id == id }) else {
            throw LibraryRegistryError.unknownLibrary(id)
        }
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: descriptor.bookmarkData,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else { throw LibraryRegistryError.staleBookmark(id) }
            guard url.pathExtension.caseInsensitiveCompare("photoslibrary") == .orderedSame else {
                throw LibraryRegistryError.notAPhotosLibrary(url)
            }
            guard url.startAccessingSecurityScopedResource() else {
                throw LibraryRegistryError.accessDenied(url)
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LibraryRegistryError.libraryOffline(url)
            }
            try Task.checkCancellation()
            return try await body(url)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func availability(of descriptor: LibraryDescriptor) -> LibraryAvailability {
        guard let resolution = try? resolvedURL(for: descriptor) else {
            return .needsReauthorization
        }
        guard !resolution.isStale else {
            return .needsReauthorization
        }
        guard Self.isPhotosLibraryPackage(resolution.url) else {
            return .invalidSelection
        }
        guard resolution.url.startAccessingSecurityScopedResource() else {
            return .needsReauthorization
        }
        defer { resolution.url.stopAccessingSecurityScopedResource() }
        return FileManager.default.fileExists(atPath: resolution.url.path) ? .online : .offline
    }

    private func resolvedURL(for descriptor: LibraryDescriptor) throws -> ResolvedBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: descriptor.bookmarkData,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedBookmark(url: url, isStale: isStale)
    }

    private func packageMetadata(at url: URL) throws -> LibraryPackageMetadata {
        let keys: Set<URLResourceKey> = [
            .nameKey,
            .volumeNameKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        return LibraryPackageMetadata(
            displayName: values.name ?? url.deletingPathExtension().lastPathComponent,
            lastKnownPath: url.path,
            volumeName: values.volumeName,
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate
        )
    }

    private func persist() {
        guard let data = try? encoder.encode(descriptors) else { return }
        defaults.set(data, forKey: Constants.defaultsKey)
    }

    private func demoteOtherSystemLibraries(except preservedID: LibraryID?) {
        for index in descriptors.indices
        where descriptors[index].kind.isSystemPhotoLibrary
            && descriptors[index].id != preservedID {
            let descriptor = descriptors[index]
            descriptors[index] = LibraryDescriptor(
                id: descriptor.id,
                kind: .userSelectedPhotosLibrary,
                bookmarkData: descriptor.bookmarkData,
                writeBookmarkData: descriptor.writeBookmarkData,
                addedAt: descriptor.addedAt,
                metadata: descriptor.metadata
            )
        }
    }

    private static func isPhotosLibraryPackage(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("photoslibrary") == .orderedSame
    }
}

private struct ResolvedBookmark {
    let url: URL
    let isStale: Bool
}

enum LibraryRegistryError: LocalizedError {
    case unknownLibrary(LibraryID)
    case notAPhotosLibrary(URL)
    case staleBookmark(LibraryID)
    case accessDenied(URL)
    case libraryOffline(URL)
    case transferAccessUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .unknownLibrary:
            "The selected library is no longer registered."
        case .notAPhotosLibrary(let url):
            "\(url.lastPathComponent) is not a .photoslibrary package."
        case .staleBookmark:
            "The library needs to be selected again before it can be accessed."
        case .accessDenied(let url):
            "The app was not granted access to \(url.lastPathComponent)."
        case .libraryOffline(let url):
            "\(url.lastPathComponent) is offline or unavailable."
        case .transferAccessUnavailable(let url):
            "Transfer access to \(url.lastPathComponent) is unavailable. No copy or source deletion was started."
        }
    }
}
