import AppKit
import AVFoundation
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The same signed executable runs in a separate process for private PhotoKit.
/// Its protocol is one JSON request and one JSON response per line.
nonisolated private struct DirectWorkerRequest: Codable, Sendable {
    let operation: String
    var bookmarkData: Data? = nil
    var assetID: String? = nil
    var width: Int? = nil
    var height: Int? = nil
    var stagingPath: String? = nil
    var permitsWrites: Bool? = nil
    var importRequest: DirectLibraryImportRequest? = nil
    var deletionRequest: DirectLibraryDeletionRequest? = nil
}

nonisolated struct DirectLibraryImportRequest: Codable, Sendable {
    let resourcePaths: [String]
    let isLivePhoto: Bool
    let captureDate: Date
    let isFavorite: Bool
    let location: PhotoTransferLocation?
    let albums: [PhotoTransferAlbum]
    let textMetadata: PhotoCatalogTextMetadata
}

nonisolated struct DirectLibraryDeletionRequest: Codable, Sendable {
    let sourceUUIDs: [String]
    let albums: [PhotoTransferAlbum]
}

nonisolated struct DirectLibraryExport: Codable, Sendable {
    let sourceID: String
    let resourcePaths: [String]
    let isLivePhoto: Bool
    let captureDate: Date?
    let isFavorite: Bool
    let latitude: Double?
    let longitude: Double?
}

nonisolated private struct DirectWorkerResponse: Codable, Sendable {
    var error: String? = nil
    var catalog: DirectLibraryCatalog? = nil
    var imageData: Data? = nil
    var videoPath: String? = nil
    var originalExport: DirectLibraryExport? = nil
    var importedAssetID: String? = nil
    var deletedCount: Int? = nil
}

#if DIRECT_LIBRARY_HELPER
/// Read complete protocol lines without mixing Swift's buffered stdin reader
/// with the parent's FileHandle pipe I/O.
nonisolated private struct DirectWorkerLineReader {
    private var buffered = Data()

    mutating func next() throws -> Data? {
        while !buffered.contains(0x0A) {
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
            }
            if count > 0 {
                buffered.append(contentsOf: chunk.prefix(count))
            } else if count == 0 {
                guard buffered.isEmpty else {
                    throw DirectLibraryError.database("The worker request ended mid-line.")
                }
                return nil
            } else if errno != EINTR {
                throw DirectLibraryError.database("The worker could not read its request.")
            }
        }
        guard let newline = buffered.firstIndex(of: 0x0A) else { return nil }
        let line = Data(buffered[..<newline])
        buffered.removeSubrange(...newline)
        return line
    }
}

@MainActor
enum DirectLibraryWorkerMain {
    static func run() async {
        var provider: PrivateRegisteredPhotoLibrary?
        var exportedVideos: [String: URL] = [:]
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var reader = DirectWorkerLineReader()
        while true {
            let line: Data
            do {
                guard let next = try reader.next() else { break }
                line = next
            } catch {
                break
            }
            let response: DirectWorkerResponse
            var operation = "decode request"
            do {
                let request = try decoder.decode(DirectWorkerRequest.self, from: line)
                operation = request.operation
                switch request.operation {
                case "open":
                    guard let bookmark = request.bookmarkData else {
                        throw DirectLibraryError.database("Missing library bookmark")
                    }
                    provider = try PrivateRegisteredPhotoLibrary(
                        bookmarkData: bookmark, permitsWrites: request.permitsWrites == true
                    )
                    response = DirectWorkerResponse()
                case "catalog":
                    guard let provider else { throw DirectLibraryError.accessDenied }
                    response = DirectWorkerResponse(catalog: try provider.catalog())
                case "image":
                    guard let provider, let id = request.assetID else {
                        throw DirectLibraryError.accessDenied
                    }
                    response = DirectWorkerResponse(imageData: provider.imageData(
                        for: id,
                        size: CGSize(
                            width: max(1, request.width ?? 600),
                            height: max(1, request.height ?? 600)
                        )
                    ))
                case "liveVideo", "video":
                    guard let provider, let id = request.assetID else {
                        throw DirectLibraryError.accessDenied
                    }
                    let key = "\(request.operation):\(id)"
                    let url: URL?
                    if let cached = exportedVideos[key],
                       FileManager.default.fileExists(atPath: cached.path) {
                        url = cached
                    } else {
                        url = try await provider.videoURL(
                            for: id, live: request.operation == "liveVideo"
                        )
                        exportedVideos[key] = url
                    }
                    response = DirectWorkerResponse(videoPath: url?.path)
                case "exportOriginals":
                    guard let provider, let id = request.assetID,
                          let path = request.stagingPath else {
                        throw DirectLibraryError.accessDenied
                    }
                    response = DirectWorkerResponse(originalExport: try await provider.exportOriginalResources(
                        for: id, to: URL(fileURLWithPath: path, isDirectory: true)
                    ))
                case "import":
                    guard let provider, let details = request.importRequest else {
                        throw DirectLibraryError.accessDenied
                    }
                    response = DirectWorkerResponse(importedAssetID: try await provider.importAsset(details))
                case "delete":
                    guard let provider, let details = request.deletionRequest else {
                        throw DirectLibraryError.accessDenied
                    }
                    response = DirectWorkerResponse(deletedCount: try await provider.deleteAssets(details))
                default:
                    throw DirectLibraryError.database("Unknown worker request")
                }
            } catch {
                let detail: String
                if error is DirectLibraryError {
                    detail = error.localizedDescription
                } else {
                    let nsError = error as NSError
                    detail = "\(error.localizedDescription) [\(nsError.domain) code \(nsError.code)]"
                }
                response = DirectWorkerResponse(error: "Helper \(operation): \(detail)")
            }
            guard var data = try? encoder.encode(response) else { break }
            data.append(0x0A)
            do {
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                break
            }
        }
    }
}
#else

/// Run synchronous Image I/O decoding at Default QoS, matching the reported wait.
/// Callers suspend while waiting, and the queue bounds concurrent decodes.
nonisolated private enum DirectThumbnailDecoder {
    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Photo Libraries Direct Thumbnail Decode"
        queue.qualityOfService = .default
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func thumbnail(from url: URL, maxPixelSize: Int) async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                continuation.resume(returning: CGImageSourceCreateThumbnailAtIndex(
                    source, 0, options as CFDictionary
                ))
            }
        }
    }
}

/// Serializes requests so responses cannot be attributed to the wrong image.
private actor DirectLibraryWorkerClient {
    private let bookmarkData: Data
    private let permitsWrites: Bool
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffered = Data()

    init(bookmarkData: Data, permitsWrites: Bool = false) {
        self.bookmarkData = bookmarkData
        self.permitsWrites = permitsWrites
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
    }

    func catalog() throws -> DirectLibraryCatalog {
        guard let value = try send(DirectWorkerRequest(operation: "catalog")).catalog else {
            throw DirectLibraryError.database("The worker returned no catalog")
        }
        return value
    }

    func imageData(for id: String, size: CGSize) throws -> Data? {
        let response = try send(DirectWorkerRequest(
            operation: "image", assetID: id,
            width: Int(size.width), height: Int(size.height)
        ))
        return response.imageData
    }

    func videoURL(for id: String, live: Bool) throws -> URL {
        let response = try send(DirectWorkerRequest(
            operation: live ? "liveVideo" : "video", assetID: id
        ))
        guard let path = response.videoPath else {
            throw DirectLibraryError.media("The helper returned no video file.")
        }
        return URL(fileURLWithPath: path)
    }

    func exportOriginalResources(for id: String, to directory: URL) throws -> DirectLibraryExport {
        let response = try send(DirectWorkerRequest(
            operation: "exportOriginals", assetID: id, stagingPath: directory.path
        ))
        guard let export = response.originalExport else {
            throw DirectLibraryError.media("The helper returned no original resources.")
        }
        return export
    }

    func importAsset(_ request: DirectLibraryImportRequest) throws -> String {
        guard permitsWrites else { throw DirectLibraryError.accessDenied }
        let response = try send(DirectWorkerRequest(operation: "import", importRequest: request))
        guard let id = response.importedAssetID else {
            throw DirectLibraryError.media("The destination created no identifiable photo.")
        }
        return id
    }

    func deleteAssets(_ request: DirectLibraryDeletionRequest) throws -> Int {
        guard permitsWrites else { throw DirectLibraryError.accessDenied }
        let response = try send(DirectWorkerRequest(operation: "delete", deletionRequest: request))
        guard let count = response.deletedCount else {
            throw DirectLibraryError.media("Source deletion was not verified.")
        }
        return count
    }

    private func send(_ request: DirectWorkerRequest) throws -> DirectWorkerResponse {
        do {
            try Task.checkCancellation()
            try startIfNeeded()
            try Task.checkCancellation()
            let response = try exchange(request)
            // A completed deletion still needs to report its observed count.
            if request.operation != "delete" { try Task.checkCancellation() }
            return response
        } catch {
            stopWorker()
            throw error
        }
    }

    private func stopWorker() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
        buffered.removeAll(keepingCapacity: true)
    }

    private func startIfNeeded() throws {
        if let process, process.isRunning { return }
        var isStale = false
        let libraryURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale, libraryURL.pathExtension.lowercased() == "photoslibrary",
              libraryURL.startAccessingSecurityScopedResource() else {
            throw DirectLibraryError.accessDenied
        }
        defer { libraryURL.stopAccessingSecurityScopedResource() }
        // App-scoped bookmarks belong to this executable. Send the helper an
        // implicit security-scoped bookmark created while our grant is active.
        let helperBookmark = try libraryURL.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let executable = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/PhotoLibrariesDirectHelper", isDirectory: false
        )
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw DirectLibraryError.database("The direct-library helper is missing")
        }
        let child = Process()
        let toChild = Pipe()
        let fromChild = Pipe()
        child.executableURL = executable
        child.standardInput = toChild
        child.standardOutput = fromChild
        child.standardError = FileHandle.standardError
        try child.run()
        process = child
        input = toChild.fileHandleForWriting
        output = fromChild.fileHandleForReading
        buffered.removeAll(keepingCapacity: true)
        do {
            let response = try exchange(DirectWorkerRequest(
                operation: "open", bookmarkData: helperBookmark, permitsWrites: permitsWrites
            ))
            if let error = response.error {
                throw DirectLibraryError.database(error)
            }
        } catch {
            stopWorker()
            throw error
        }
    }

    private func exchange(_ request: DirectWorkerRequest) throws -> DirectWorkerResponse {
        guard let input, let output else {
            throw DirectLibraryError.database("The worker is not running")
        }
        var encoded = try JSONEncoder().encode(request)
        encoded.append(0x0A)
        try input.write(contentsOf: encoded)
        let isOpening = request.operation == "open"
        let openDeadline = ProcessInfo.processInfo.systemUptime + 30
        while !buffered.contains(0x0A) {
            if isOpening {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < openDeadline else {
                    throw DirectLibraryError.database(
                        "The direct-library helper did not answer its open request within 30 seconds."
                    )
                }
            }
            var descriptor = pollfd(
                fd: output.fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, 100)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw DirectLibraryError.database("The helper response pipe could not be polled.")
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count)
            }
            guard count > 0 else {
                if count < 0 && errno == EINTR { continue }
                throw DirectLibraryError.database("The worker closed its output")
            }
            buffered.append(contentsOf: chunk.prefix(count))
        }
        guard let newline = buffered.firstIndex(of: 0x0A) else {
            throw DirectLibraryError.database("The worker response is incomplete")
        }
        let line = Data(buffered[..<newline])
        buffered.removeSubrange(...newline)
        let response = try JSONDecoder().decode(DirectWorkerResponse.self, from: line)
        if let error = response.error { throw DirectLibraryError.media(error) }
        return response
    }
}

/// App-process facade. This type never calls a private PhotoKit selector.
@MainActor
final class RegisteredPhotoLibraryProvider {
    private let bookmarkData: Data
    private let worker: DirectLibraryWorkerClient
    private var copiedLiveVideos: [String: URL] = [:]
    private var copiedVideos: [String: URL] = [:]

    init(bookmarkData: Data, permitsWrites: Bool = false) {
        self.bookmarkData = bookmarkData
        worker = DirectLibraryWorkerClient(
            bookmarkData: bookmarkData, permitsWrites: permitsWrites
        )
    }

    func catalog() async throws -> DirectLibraryCatalog {
        try await worker.catalog()
    }

    func exportOriginalResources(for id: String, to directory: URL) async throws -> DirectLibraryExport {
        try await worker.exportOriginalResources(for: id, to: directory)
    }

    func importAsset(_ request: DirectLibraryImportRequest) async throws -> String {
        try await worker.importAsset(request)
    }

    func deleteAssets(_ request: DirectLibraryDeletionRequest) async throws -> Int {
        try await worker.deleteAssets(request)
    }

    func image(for id: String, size: CGSize) async -> NSImage? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        // PhotoKit applies the asset's edits, including rotation. Decoding the
        // original first would show its pre-edit orientation instead.
        if let data = try? await worker.imageData(for: id, size: size),
           let image = NSImage(data: data) {
            return image
        }
        guard !Task.isCancelled else { return nil }
        let bookmark = bookmarkData
        let maxPixelSize = max(1, Int(ceil(max(size.width, size.height))))
        let localImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            var stale = false
            guard let libraryURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale, libraryURL.startAccessingSecurityScopedResource() else {
                return nil
            }
            defer { libraryURL.stopAccessingSecurityScopedResource() }
            let stem = uuid.uuidString
            let originalsDirectory = libraryURL
                .appendingPathComponent("originals", isDirectory: true)
                .appendingPathComponent(String(stem.prefix(1)), isDirectory: true)
            guard let originals = try? FileManager.default.contentsOfDirectory(
                at: originalsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }
            let candidates = originals.filter { url in
                guard url.lastPathComponent.uppercased().hasPrefix(stem + "."),
                      let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for candidate in candidates {
                guard !Task.isCancelled else { return nil }
                guard let type = UTType(filenameExtension: candidate.pathExtension),
                      type.conforms(to: .image) else { continue }
                if let thumbnail = await DirectThumbnailDecoder.thumbnail(
                    from: candidate, maxPixelSize: maxPixelSize
                ) {
                    return thumbnail
                }
            }
            for candidate in candidates {
                guard !Task.isCancelled else { return nil }
                guard let type = UTType(filenameExtension: candidate.pathExtension),
                      type.conforms(to: .movie) else { continue }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: candidate))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(
                    width: CGFloat(maxPixelSize), height: CGFloat(maxPixelSize)
                )
                if let result = try? await generator.image(at: .zero) {
                    return result.image
                }
            }
            return nil
        }.value
        if let localImage {
            return NSImage(cgImage: localImage, size: .zero)
        }
        return nil
    }

    /// Read technical metadata only when an item is selected, from its local
    /// original without exporting the library or creating a preview.
    func technicalMetadata(for id: String, filename: String) async -> PhotoTechnicalMetadata? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let bookmark = bookmarkData
        return await Task.detached(priority: .userInitiated) { () -> PhotoTechnicalMetadata? in
            var stale = false
            guard let libraryURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale, libraryURL.startAccessingSecurityScopedResource() else {
                return nil
            }
            defer { libraryURL.stopAccessingSecurityScopedResource() }
            let stem = uuid.uuidString
            let originalsDirectory = libraryURL
                .appendingPathComponent("originals", isDirectory: true)
                .appendingPathComponent(String(stem.prefix(1)), isDirectory: true)
            guard let originals = try? FileManager.default.contentsOfDirectory(
                at: originalsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }
            let preferredExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
            let candidates = originals.filter { url in
                guard url.lastPathComponent.uppercased().hasPrefix(stem + "."),
                      let type = UTType(filenameExtension: url.pathExtension),
                      (type.conforms(to: .image) || type.conforms(to: .movie)),
                      let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted { lhs, rhs in
                let lhsPreferred = lhs.pathExtension.lowercased() == preferredExtension
                let rhsPreferred = rhs.pathExtension.lowercased() == preferredExtension
                if lhsPreferred != rhsPreferred { return lhsPreferred }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            for candidate in candidates {
                if let metadata = PhotoTechnicalMetadataExtractor.metadata(from: candidate) {
                    return metadata
                }
                if let metadata = await PhotoTechnicalMetadataExtractor.videoMetadata(
                    from: candidate
                ) {
                    return metadata
                }
            }
            return nil
        }.value
    }

    func videoURL(for id: String, live: Bool) async throws -> URL {
        if live, let local = try await localPairedVideoURL(for: id) {
            return local
        }
        if !live, let local = try await localOriginalVideoURL(for: id) {
            return local
        }
        return try await worker.videoURL(for: id, live: live)
    }

    func releaseLocalVideo(for id: String) {
        if let url = copiedVideos.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Stage an exact UUID-named local movie while the selected library's
    /// security scope is active. Never hand a package-internal URL to a player.
    private func localOriginalVideoURL(for id: String) async throws -> URL? {
        if let cached = copiedVideos[id],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let uuid = UUID(uuidString: id) else { return nil }
        let bookmark = bookmarkData
        let copied = try await Task.detached(priority: .userInitiated) { () -> URL? in
            var stale = false
            let libraryURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale, libraryURL.pathExtension.lowercased() == "photoslibrary",
                  libraryURL.startAccessingSecurityScopedResource() else {
                throw DirectLibraryError.accessDenied
            }
            defer { libraryURL.stopAccessingSecurityScopedResource() }
            let originals = libraryURL.appendingPathComponent("originals", isDirectory: true)
                .appendingPathComponent(String(uuid.uuidString.prefix(1)), isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: originals,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }
            let candidates = entries.filter { source in
                guard source.deletingPathExtension().lastPathComponent.uppercased() == uuid.uuidString,
                      UTType(filenameExtension: source.pathExtension)?.conforms(to: .movie) == true,
                      let values = try? source.resourceValues(forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
                      ]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
                    && (values.fileSize ?? 0) > 0
            }
            guard candidates.count == 1, let source = candidates.first else { return nil }
            try Task.checkCancellation()
            let destinationDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoLibrariesDirectMedia", isDirectory: true)
            try FileManager.default.createDirectory(
                at: destinationDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let destination = destinationDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(source.pathExtension.lowercased())
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                try Task.checkCancellation()
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }.value
        if Task.isCancelled {
            if let copied { try? FileManager.default.removeItem(at: copied) }
            throw CancellationError()
        }
        if let copied { copiedVideos[id] = copied }
        return copied
    }

    /// A local Live Photo's paired resource uses the asset UUID with the
    /// resource-type suffix. Copy it while the selected package's read scope
    /// is active so AVPlayer only reads an app-owned temporary file.
    private func localPairedVideoURL(for id: String) async throws -> URL? {
        if let cached = copiedLiveVideos[id],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let uuid = UUID(uuidString: id) else { return nil }
        let bookmark = bookmarkData
        let file = "\(uuid.uuidString)_3.mov"
        let directory = String(uuid.uuidString.prefix(1))
        let copied = try await Task.detached(priority: .userInitiated) { () -> URL? in
            var stale = false
            let libraryURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale, libraryURL.startAccessingSecurityScopedResource() else {
                throw DirectLibraryError.accessDenied
            }
            defer { libraryURL.stopAccessingSecurityScopedResource() }
            let source = libraryURL.appendingPathComponent("originals", isDirectory: true)
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(file, isDirectory: false)
            guard FileManager.default.fileExists(atPath: source.path) else { return nil }
            let destinationDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoLibrariesDirectMedia", isDirectory: true)
            try FileManager.default.createDirectory(
                at: destinationDirectory, withIntermediateDirectories: true
            )
            let destination = destinationDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }.value
        if let copied { copiedLiveVideos[id] = copied }
        return copied
    }
}
#endif
