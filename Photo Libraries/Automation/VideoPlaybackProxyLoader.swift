import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Converts an observed Photos export into an app-owned H.264/AAC MP4.
/// The caller verifies the active library and owns the export directory.
nonisolated enum VideoPlaybackProxyLoader {
    enum ProxyError: LocalizedError {
        case missingMovie
        case unsupportedExport

        var errorDescription: String? {
            switch self {
            case .missingMovie: "Photos did not export a movie file."
            case .unsupportedExport: "This movie cannot be converted to MP4."
            }
        }
    }

    static func create(
        from result: PhotosAutomationExportResult,
        expectedItem: PhotosAutomationMediaItem,
        stagingRoot: URL
    ) async throws -> URL {
        guard result.mediaItemID == expectedItem.id,
              result.reportedFilename == expectedItem.filename,
              let movie = result.observedFiles.first(where: {
                  UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true
              }) else {
            throw ProxyError.missingMovie
        }
        try Task.checkCancellation()
        let destination = stagingRoot.appendingPathComponent(UUID().uuidString + ".mp4")
        try await createWebMP4(from: movie, to: destination)
        return destination
    }

    /// Converts one locally available movie to a browser-compatible file.
    /// The caller owns and removes both the source and destination staging files.
    static func createWebMP4(from movie: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: movie)
        guard try await asset.load(.isPlayable) else {
            throw ProxyError.unsupportedExport
        }
        // A local H.264/AAC MP4 already has the browser format we need. Copy
        // it without waiting for a full video export before the HTTP response.
        if movie.pathExtension.lowercased() == "mp4",
           try await isBrowserCompatibleMP4(asset) {
            do {
                // Both paths are app-owned staging files. A hard link avoids a
                // second large copy; copy if the volume does not support it.
                do {
                    try FileManager.default.linkItem(at: movie, to: destination)
                } catch {
                    try FileManager.default.copyItem(at: movie, to: destination)
                }
                try Task.checkCancellation()
                return
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        guard let session = AVAssetExportSession(
                  asset: asset,
                  presetName: AVAssetExportPreset1920x1080
              ),
              session.supportedFileTypes.contains(.mp4) else {
            throw ProxyError.unsupportedExport
        }
        do {
            try await session.export(to: destination, as: .mp4)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func isBrowserCompatibleMP4(_ asset: AVAsset) async throws -> Bool {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { return false }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard try await hasOnlyCodec(videoTracks, codec: 0x61766331) else { return false }
        // Core Media reports AAC as 'aac ', although the MP4 sample entry is 'mp4a'.
        return try await hasOnlyCodec(audioTracks, codec: 0x61616320)
    }

    private static func hasOnlyCodec(_ tracks: [AVAssetTrack], codec: UInt32) async throws -> Bool {
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            guard !formats.isEmpty,
                  formats.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == codec }) else {
                return false
            }
        }
        return true
    }
}
