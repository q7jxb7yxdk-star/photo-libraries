import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Creates display-only thumbnail data from files exported by Photos into the
/// app's private preview cache. It never reads a `.photoslibrary` package.
nonisolated enum PreviewThumbnailLoader {
    struct Payload: Sendable {
        let thumbnailData: Data
        let viewerPreviewData: Data
        let technicalMetadata: PhotoTechnicalMetadata?
    }

    static func payload(
        from exportedFiles: [URL],
        thumbnailMaximumPixelSize: Int = 600,
        viewerMaximumPixelSize: Int = 4_096
    ) async throws -> Payload {
        for fileURL in exportedFiles {
            try Task.checkCancellation()

            if let thumbnailData = imagePreviewData(
                from: fileURL,
                maximumPixelSize: thumbnailMaximumPixelSize,
                compressionQuality: 0.84
            ), let viewerPreviewData = imagePreviewData(
                from: fileURL,
                maximumPixelSize: viewerMaximumPixelSize,
                compressionQuality: 0.92
            ) {
                return Payload(
                    thumbnailData: thumbnailData,
                    viewerPreviewData: viewerPreviewData,
                    technicalMetadata: PhotoTechnicalMetadataExtractor.metadata(from: fileURL)
                )
            }

            if isAudiovisualFile(fileURL),
               let previewData = try await videoPreviewData(
                   from: fileURL,
                   thumbnailMaximumPixelSize: thumbnailMaximumPixelSize,
                   viewerMaximumPixelSize: viewerMaximumPixelSize
               ) {
                return Payload(
                    thumbnailData: previewData.thumbnail,
                    viewerPreviewData: previewData.viewer,
                    technicalMetadata: await PhotoTechnicalMetadataExtractor.videoMetadata(
                        from: fileURL
                    )
                )
            }
        }

        throw PreviewThumbnailError.noSupportedResource
    }

    static func thumbnailData(
        from exportedFiles: [URL],
        maximumPixelSize: Int = 600
    ) async throws -> Data {
        try await payload(
            from: exportedFiles,
            thumbnailMaximumPixelSize: maximumPixelSize
        ).thumbnailData
    }

    private static func imagePreviewData(
        from fileURL: URL,
        maximumPixelSize: Int,
        compressionQuality: Double
    ) -> Data? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        guard CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return jpegData(from: image, compressionQuality: compressionQuality)
    }

    private static func isAudiovisualFile(_ fileURL: URL) -> Bool {
        guard let type = UTType(filenameExtension: fileURL.pathExtension) else {
            return false
        }
        return type.conforms(to: .audiovisualContent)
    }

    private static func videoPreviewData(
        from fileURL: URL,
        thumbnailMaximumPixelSize: Int,
        viewerMaximumPixelSize: Int
    ) async throws -> (thumbnail: Data, viewer: Data)? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: viewerMaximumPixelSize,
            height: viewerMaximumPixelSize
        )
        let result = try await generator.image(at: .zero)
        guard let viewerData = jpegData(from: result.image, compressionQuality: 0.92),
              let source = CGImageSourceCreateWithData(viewerData as CFData, nil),
              let thumbnailImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumPixelSize
                  ] as CFDictionary
              ),
              let thumbnailData = jpegData(
                  from: thumbnailImage,
                  compressionQuality: 0.84
              ) else {
            return nil
        }
        return (thumbnailData, viewerData)
    }

    private static func jpegData(
        from image: CGImage,
        compressionQuality: Double
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

nonisolated enum PreviewThumbnailError: LocalizedError {
    case noSupportedResource

    var errorDescription: String? {
        switch self {
        case .noSupportedResource:
            "Photos did not export a supported image or video preview resource."
        }
    }
}
