import CryptoKit
import Foundation
import Photos

final class PhotoResourceExporter {
    private let resourceManager: PHAssetResourceManager

    init(resourceManager: PHAssetResourceManager) {
        self.resourceManager = resourceManager
    }

    func export(
        resources: [PHAssetResource],
        assetIdentifier: String,
        stagingRoot: URL,
        networkAccessAllowed: Bool,
        selectedResourceIndices: Set<Int>? = nil,
        progress: @escaping (PhotoResourceExportProgress) -> Void
    ) async throws -> PhotoResourceExportManifest {
        let jobID = UUID()
        let jobDirectory = stagingRoot.appendingPathComponent(jobID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: jobDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw SystemPhotoLibraryError.cannotCreateStagingDirectory(jobDirectory, error)
        }

        let cancellation = ResourceRequestCancellation(resourceManager: resourceManager)
        let selectedResources = resources.enumerated().filter { index, _ in
            selectedResourceIndices == nil || selectedResourceIndices?.contains(index) == true
        }
        var entries: [PhotoResourceExportManifest.Entry] = []
        entries.reserveCapacity(selectedResources.count)
        var usedStagedFilenames = Set<String>()

        do {
            return try await withTaskCancellationHandler {
                for (completedCount, indexedResource) in selectedResources.enumerated() {
                let (index, resource) = indexedResource
                try Task.checkCancellation()
                progress(
                    PhotoResourceExportProgress(
                        completedResourceCount: completedCount,
                        totalResourceCount: selectedResources.count,
                        currentFilename: resource.pocFilename
                    )
                )

                let stagedFilename = uniqueStagedFilename(
                    for: resource,
                    index: index,
                    usedFilenames: &usedStagedFilenames
                )
                let destination = jobDirectory.appendingPathComponent(stagedFilename, isDirectory: false)
                let partialDestination = destination.appendingPathExtension("partial")
                let written = try await write(
                    resource,
                    to: partialDestination,
                    networkAccessAllowed: networkAccessAllowed,
                    cancellation: cancellation
                )
                do {
                    try FileManager.default.moveItem(at: partialDestination, to: destination)
                } catch {
                    throw SystemPhotoLibraryError.resourceWriteFailed(destination, error)
                }
                entries.append(
                    .init(
                        resourceIndex: index,
                        resourceType: resource.type.pocName,
                        originalFilename: resource.pocFilename,
                        uniformTypeIdentifier: resource.uniformTypeIdentifier,
                        stagedFilename: stagedFilename,
                        byteCount: written.byteCount,
                        sha256: written.sha256
                    )
                )
            }

                let manifest = PhotoResourceExportManifest(
                schemaVersion: 1,
                jobID: jobID,
                sourceAssetLocalIdentifier: assetIdentifier,
                createdAt: Date(),
                entries: entries
            )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let manifestURL = jobDirectory.appendingPathComponent("manifest.json", isDirectory: false)
                do {
                    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
                } catch {
                    throw SystemPhotoLibraryError.resourceWriteFailed(manifestURL, error)
                }

                progress(
                    PhotoResourceExportProgress(
                        completedResourceCount: selectedResources.count,
                        totalResourceCount: selectedResources.count,
                        currentFilename: nil
                    )
                )
                return manifest
            } onCancel: {
                cancellation.cancelAll()
            }
        } catch {
            try? FileManager.default.removeItem(at: jobDirectory)
            throw error
        }
    }

    private func write(
        _ resource: PHAssetResource,
        to destination: URL,
        networkAccessAllowed: Bool,
        cancellation: ResourceRequestCancellation
    ) async throws -> (byteCount: Int64, sha256: String) {
        do {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let writer = try ResourceStreamWriter(url: destination)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = networkAccessAllowed

            return try await withCheckedThrowingContinuation { continuation in
                var requestID: PHAssetResourceDataRequestID = 0
                requestID = resourceManager.requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { data in
                        writer.append(data)
                    },
                    completionHandler: { error in
                        cancellation.unregister(requestID)
                        if let writeError = writer.failure {
                            writer.close()
                            continuation.resume(
                                throwing: SystemPhotoLibraryError.resourceWriteFailed(destination, writeError)
                            )
                        } else if cancellation.cancelled {
                            writer.close()
                            continuation.resume(throwing: CancellationError())
                        } else if let error {
                            writer.close()
                            continuation.resume(
                                throwing: SystemPhotoLibraryError.resourceRequestFailed(
                                    resource.pocFilename,
                                    error
                                )
                            )
                        } else {
                            do {
                                continuation.resume(returning: try writer.finish())
                            } catch {
                                continuation.resume(
                                    throwing: SystemPhotoLibraryError.resourceWriteFailed(destination, error)
                                )
                            }
                        }
                    }
                )
                cancellation.register(requestID)
            }
        } catch let error as SystemPhotoLibraryError {
            throw error
        } catch {
            throw SystemPhotoLibraryError.cannotCreateStagingFile(destination, error)
        }
    }

    /// Preserve original names whenever possible. Matching stems are important
    /// evidence for Photos when it recognizes Live Photo and RAW/JPEG pairs.
    private func uniqueStagedFilename(
        for resource: PHAssetResource,
        index: Int,
        usedFilenames: inout Set<String>
    ) -> String {
        let unsafe = resource.pocFilename
        let sanitized = unsafe
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if !sanitized.isEmpty, usedFilenames.insert(sanitized.lowercased()).inserted {
            return sanitized
        }

        let sourceURL = URL(fileURLWithPath: sanitized)
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension
        let suffix = String(format: "-%03d-%@", index, resource.type.pocName)
        let candidate = fileExtension.isEmpty
            ? stem + suffix
            : stem + suffix + "." + fileExtension
        usedFilenames.insert(candidate.lowercased())
        return candidate
    }
}

/// Thread-safe helper used by PhotoKit callbacks and Task cancellation. It must
/// not inherit the app target's default MainActor isolation.
private nonisolated final class ResourceRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let resourceManager: PHAssetResourceManager
    private var requestIDs: Set<PHAssetResourceDataRequestID> = []
    private var isCancelled = false

    init(resourceManager: PHAssetResourceManager) {
        self.resourceManager = resourceManager
    }

    func register(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            resourceManager.cancelDataRequest(requestID)
        } else {
            requestIDs.insert(requestID)
            lock.unlock()
        }
    }

    func unregister(_ requestID: PHAssetResourceDataRequestID) {
        _ = lock.withLock {
            requestIDs.remove(requestID)
        }
    }

    var cancelled: Bool {
        lock.withLock { isCancelled }
    }

    func cancelAll() {
        let ids: [PHAssetResourceDataRequestID] = lock.withLock {
            isCancelled = true
            let ids = Array(requestIDs)
            requestIDs.removeAll()
            return ids
        }
        ids.forEach(resourceManager.cancelDataRequest)
    }
}

/// Thread-safe stream state shared by PhotoKit's data and completion callbacks.
private nonisolated final class ResourceStreamWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let fileHandle: FileHandle
    private var hasher = SHA256()
    private var writtenBytes: Int64 = 0
    private var storedFailure: Error?
    private var isClosed = false

    init(url: URL) throws {
        fileHandle = try FileHandle(forWritingTo: url)
    }

    var failure: Error? {
        lock.withLock { storedFailure }
    }

    func append(_ data: Data) {
        lock.withLock {
            guard storedFailure == nil, !isClosed else { return }
            do {
                try fileHandle.write(contentsOf: data)
                hasher.update(data: data)
                writtenBytes += Int64(data.count)
            } catch {
                storedFailure = error
            }
        }
    }

    func finish() throws -> (byteCount: Int64, sha256: String) {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            if !isClosed {
                try fileHandle.synchronize()
                try fileHandle.close()
                isClosed = true
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (writtenBytes, digest)
        }
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            try? fileHandle.close()
            isClosed = true
        }
    }
}

private extension NSLock {
    nonisolated func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
