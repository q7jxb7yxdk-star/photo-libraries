import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PhotoTechnicalMetadata: Codable, Hashable, Sendable {
    let cameraMake: String?
    let cameraModel: String?
    let lensModel: String?
    let iso: Double?
    let meteringMode: Int?
    let focalLength: Double?
    let focalLengthIn35mm: Double?
    let exposureBias: Double?
    let aperture: Double?
    let exposureTime: Double?
    let whiteBalance: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let fileSize: Int64?
    let fileFormat: String?
    var videoDuration: TimeInterval? = nil
    var videoFrameRate: Double? = nil
    var videoCodec: String? = nil
    var videoCameraName: String? = nil

    static let empty = PhotoTechnicalMetadata(
        cameraMake: nil, cameraModel: nil, lensModel: nil, iso: nil,
        meteringMode: nil, focalLength: nil, focalLengthIn35mm: nil,
        exposureBias: nil, aperture: nil, exposureTime: nil, whiteBalance: nil,
        pixelWidth: nil, pixelHeight: nil, fileSize: nil, fileFormat: nil
    )

    func fillingMissingCameraValues(from original: PhotoTechnicalMetadata) -> PhotoTechnicalMetadata {
        var combined = PhotoTechnicalMetadata(
            cameraMake: cameraMake ?? original.cameraMake,
            cameraModel: cameraModel ?? original.cameraModel,
            lensModel: lensModel ?? original.lensModel,
            iso: iso ?? original.iso,
            meteringMode: meteringMode ?? original.meteringMode,
            focalLength: focalLength ?? original.focalLength,
            focalLengthIn35mm: focalLengthIn35mm ?? original.focalLengthIn35mm,
            exposureBias: exposureBias ?? original.exposureBias,
            aperture: aperture ?? original.aperture,
            exposureTime: exposureTime ?? original.exposureTime,
            whiteBalance: whiteBalance ?? original.whiteBalance,
            pixelWidth: pixelWidth ?? original.pixelWidth,
            pixelHeight: pixelHeight ?? original.pixelHeight,
            fileSize: fileSize ?? original.fileSize,
            fileFormat: fileFormat ?? original.fileFormat
        )
        combined.videoDuration = videoDuration ?? original.videoDuration
        combined.videoFrameRate = videoFrameRate ?? original.videoFrameRate
        combined.videoCodec = videoCodec ?? original.videoCodec
        combined.videoCameraName = videoCameraName ?? original.videoCameraName
        return combined
    }

    func applyingCatalogValues(
        pixelWidth: Int,
        pixelHeight: Int,
        fileSize: Int?,
        filename: String
    ) -> PhotoTechnicalMetadata {
        let filenameFormat = URL(fileURLWithPath: filename)
            .pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        var combined = PhotoTechnicalMetadata(
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            lensModel: lensModel,
            iso: iso,
            meteringMode: meteringMode,
            focalLength: focalLength,
            focalLengthIn35mm: focalLengthIn35mm,
            exposureBias: exposureBias,
            aperture: aperture,
            exposureTime: exposureTime,
            whiteBalance: whiteBalance,
            pixelWidth: pixelWidth > 0 ? pixelWidth : self.pixelWidth,
            pixelHeight: pixelHeight > 0 ? pixelHeight : self.pixelHeight,
            fileSize: fileSize.map(Int64.init) ?? self.fileSize,
            fileFormat: filenameFormat.isEmpty ? self.fileFormat : filenameFormat
        )
        combined.videoDuration = videoDuration
        combined.videoFrameRate = videoFrameRate
        combined.videoCodec = videoCodec
        combined.videoCameraName = videoCameraName
        return combined
    }

    func containsCameraValues(from source: PhotoTechnicalMetadata) -> Bool {
        func matches(_ expected: Double?, _ actual: Double?) -> Bool {
            guard let expected else { return true }
            guard let actual else { return false }
            return abs(expected - actual) < 0.01
        }
        return (source.cameraMake == nil || cameraMake == source.cameraMake)
            && (source.cameraModel == nil || cameraModel == source.cameraModel)
            && (source.lensModel == nil || lensModel == source.lensModel)
            && matches(source.iso, iso)
            && (source.meteringMode == nil || meteringMode == source.meteringMode)
            && matches(source.focalLength, focalLength)
            && matches(source.focalLengthIn35mm, focalLengthIn35mm)
            && matches(source.exposureBias, exposureBias)
            && matches(source.aperture, aperture)
            && matches(source.exposureTime, exposureTime)
            && (source.whiteBalance == nil || whiteBalance == source.whiteBalance)
    }
}

nonisolated enum PhotoTechnicalMetadataExtractor {
    static func videoMetadata(from fileURL: URL) async -> PhotoTechnicalMetadata? {
        guard UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .movie) == true else {
            return nil
        }
        let asset = AVURLAsset(url: fileURL)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let track = tracks.first
        let naturalSize = try? await track?.load(.naturalSize)
        let transform = try? await track?.load(.preferredTransform)
        let transformedSize = naturalSize.map { size in
            size.applying(transform ?? .identity)
        }
        let frameRate = try? await track?.load(.nominalFrameRate)
        let formatDescriptions = (try? await track?.load(.formatDescriptions)) ?? []
        let codec = formatDescriptions.first.map { description in
            let code = CMFormatDescriptionGetMediaSubType(description)
            if code == kCMVideoCodecType_HEVC { return "HEVC" }
            if code == kCMVideoCodecType_H264 { return "H.264" }
            let characters = (0..<4).map { shift in
                UnicodeScalar((code >> (24 - shift * 8)) & 0xff).map(String.init) ?? ""
            }
            return characters.joined().trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        let assetItems = (try? await asset.load(.metadata)) ?? []
        let trackItems = (try? await track?.load(.metadata)) ?? []
        let cameraMake = await metadataText(
            in: assetItems, identifier: .quickTimeMetadataMake
        )
        let cameraModel = await metadataText(
            in: assetItems, identifier: .quickTimeMetadataModel
        )
        let lensModel = await metadataText(
            in: trackItems + assetItems, identifier: .quickTimeMetadataCameraLensModel
        )
        let cameraIdentifier = await metadataText(
            in: trackItems + assetItems, identifier: .quickTimeMetadataCameraIdentifier
        )
        let equivalentFocalLength = await metadataText(
            in: trackItems + assetItems,
            identifier: .quickTimeMetadataCameraFocalLength35mmEquivalent
        )
        let irisFNumber = await metadataText(
            in: trackItems + assetItems, identifier: .quickTimeMetadataCameraLensIrisFNumber
        )
        let duration = try? await asset.load(.duration)
        let seconds = duration.map(CMTimeGetSeconds)
        let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        var metadata = PhotoTechnicalMetadata(
            cameraMake: cameraMake, cameraModel: cameraModel, lensModel: lensModel, iso: nil,
            meteringMode: nil, focalLength: nil,
            focalLengthIn35mm: numericMetadata(equivalentFocalLength),
            exposureBias: nil, aperture: numericMetadata(irisFNumber),
            exposureTime: nil, whiteBalance: nil,
            pixelWidth: transformedSize.map { Int(abs($0.width).rounded()) },
            pixelHeight: transformedSize.map { Int(abs($0.height).rounded()) },
            fileSize: fileSize.map(Int64.init),
            fileFormat: fileURL.pathExtension.uppercased()
        )
        metadata.videoDuration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        metadata.videoFrameRate = frameRate.flatMap { $0 > 0 ? Double($0) : nil }
        metadata.videoCodec = codec.flatMap { $0.isEmpty ? nil : $0 }
        metadata.videoCameraName = cameraName(
            identifier: cameraIdentifier,
            lensModel: lensModel,
            equivalentFocalLength: metadata.focalLengthIn35mm
        )
        return metadata
    }

    private static func metadataText(
        in items: [AVMetadataItem],
        identifier: AVMetadataIdentifier
    ) async -> String? {
        for item in items where item.identifier == identifier {
            if let value = try? await item.load(.stringValue) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func numericMetadata(_ text: String?) -> Double? {
        guard let text,
              let range = text.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let value = Double(text[range]), value > 0 else { return nil }
        return value
    }

    private static func cameraName(
        identifier: String?,
        lensModel: String?,
        equivalentFocalLength: Double?
    ) -> String? {
        let description = [identifier, lensModel].compactMap { $0 }
            .joined(separator: " ").lowercased()
        if description.contains("ultra wide") || description.contains("ultrawide") {
            return "Ultra Wide Camera"
        }
        if description.contains("telephoto") { return "Telephoto Camera" }
        if description.contains("main camera") || description.contains("wide camera") {
            return "Main Camera"
        }
        if description.contains("front") { return "Front Camera" }
        if description.contains("back") || description.contains("rear") {
            if let equivalentFocalLength, (23...27).contains(equivalentFocalLength) {
                return "Main Camera"
            }
            return "Back Camera"
        }
        return nil
    }

    static func metadata(from files: [URL]) -> PhotoTechnicalMetadata? {
        for fileURL in files {
            if let metadata = metadata(from: fileURL) {
                return metadata
            }
        }
        return nil
    }

    static func metadata(from fileURL: URL) -> PhotoTechnicalMetadata? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return nil
        }
        return makeMetadata(
            properties: properties,
            typeIdentifier: CGImageSourceGetType(source) as String?,
            fileSize: try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
    }

    static func metadata(from data: Data, fileSize: Int64? = nil) -> PhotoTechnicalMetadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return nil
        }
        return makeMetadata(
            properties: properties,
            typeIdentifier: CGImageSourceGetType(source) as String?,
            fileSize: fileSize ?? Int64(data.count)
        )
    }

    private static func makeMetadata(
        properties: [CFString: Any],
        typeIdentifier: String?,
        fileSize: Int?
    ) -> PhotoTechnicalMetadata {
        makeMetadata(
            properties: properties,
            typeIdentifier: typeIdentifier,
            fileSize: fileSize.map(Int64.init)
        )
    }

    private static func makeMetadata(
        properties: [CFString: Any],
        typeIdentifier: String?,
        fileSize: Int64?
    ) -> PhotoTechnicalMetadata {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber]
        let whiteBalanceValue = number(exif[kCGImagePropertyExifWhiteBalance])?.intValue

        let format = typeIdentifier.flatMap { identifier in
            UTType(identifier)?.preferredFilenameExtension?.uppercased()
        }

        return PhotoTechnicalMetadata(
            cameraMake: text(tiff[kCGImagePropertyTIFFMake]),
            cameraModel: text(tiff[kCGImagePropertyTIFFModel]),
            lensModel: text(exif[kCGImagePropertyExifLensModel]),
            iso: isoValues?.first?.doubleValue,
            meteringMode: number(exif[kCGImagePropertyExifMeteringMode])?.intValue,
            focalLength: number(exif[kCGImagePropertyExifFocalLength])?.doubleValue,
            focalLengthIn35mm: number(exif[kCGImagePropertyExifFocalLenIn35mmFilm])?.doubleValue,
            exposureBias: number(exif[kCGImagePropertyExifExposureBiasValue])?.doubleValue,
            aperture: number(exif[kCGImagePropertyExifFNumber])?.doubleValue,
            exposureTime: number(exif[kCGImagePropertyExifExposureTime])?.doubleValue,
            whiteBalance: whiteBalanceValue.map { $0 == 0 ? "Auto" : "Manual" },
            pixelWidth: number(properties[kCGImagePropertyPixelWidth])?.intValue,
            pixelHeight: number(properties[kCGImagePropertyPixelHeight])?.intValue,
            fileSize: fileSize,
            fileFormat: format
        )
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }
}

nonisolated enum PhotoTechnicalMetadataEmbedder {
    enum Error: LocalizedError {
        case unsupportedImage
        case cannotWrite
        case metadataMismatch(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedImage:
                return "The edited image format cannot be inspected safely before import."
            case .cannotWrite:
                return "Camera metadata could not be written into the edited image before import."
            case .metadataMismatch(let reason):
                return "The edited image could not be verified before import: \(reason)"
            }
        }
    }

    static func embeddingCaptureMetadata(
        _ metadata: PhotoTechnicalMetadata,
        originalEXIFPropertyList: Data?,
        location: PhotoTransferLocation?,
        in fileURL: URL
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let rendered = PhotoTechnicalMetadataExtractor.metadata(from: fileURL) else {
            throw Error.unsupportedImage
        }

        var properties = original
        var tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let originalEXIFPropertyList {
            guard let sourceEXIF = try PropertyListSerialization.propertyList(
                from: originalEXIFPropertyList, format: nil
            ) as? [String: Any] else {
                throw Error.unsupportedImage
            }
            for (key, value) in sourceEXIF {
                exif[key as CFString] = value
            }
            // These EXIF dimensions describe the flattened edited image.
            exif[kCGImagePropertyExifPixelXDimension] = rendered.pixelWidth
            exif[kCGImagePropertyExifPixelYDimension] = rendered.pixelHeight
        }
        if let value = metadata.cameraMake { tiff[kCGImagePropertyTIFFMake] = value }
        if let value = metadata.cameraModel { tiff[kCGImagePropertyTIFFModel] = value }
        if exif[kCGImagePropertyExifLensModel] == nil,
           let value = metadata.lensModel {
            exif[kCGImagePropertyExifLensModel] = value
        }
        if exif[kCGImagePropertyExifISOSpeedRatings] == nil,
           let value = metadata.iso {
            exif[kCGImagePropertyExifISOSpeedRatings] = [NSNumber(value: Int(value.rounded()))]
        }
        if exif[kCGImagePropertyExifMeteringMode] == nil,
           let value = metadata.meteringMode {
            exif[kCGImagePropertyExifMeteringMode] = value
        }
        if exif[kCGImagePropertyExifFocalLength] == nil,
           let value = metadata.focalLength {
            exif[kCGImagePropertyExifFocalLength] = value
        }
        if exif[kCGImagePropertyExifFocalLenIn35mmFilm] == nil,
           let value = metadata.focalLengthIn35mm {
            exif[kCGImagePropertyExifFocalLenIn35mmFilm] = Int(value.rounded())
        }
        if exif[kCGImagePropertyExifExposureBiasValue] == nil,
           let value = metadata.exposureBias {
            exif[kCGImagePropertyExifExposureBiasValue] = value
        }
        if exif[kCGImagePropertyExifFNumber] == nil,
           let value = metadata.aperture {
            exif[kCGImagePropertyExifFNumber] = value
        }
        if exif[kCGImagePropertyExifExposureTime] == nil,
           let value = metadata.exposureTime {
            exif[kCGImagePropertyExifExposureTime] = value
        }
        if exif[kCGImagePropertyExifWhiteBalance] == nil,
           let value = metadata.whiteBalance {
            exif[kCGImagePropertyExifWhiteBalance] = value == "Auto" ? 0 : 1
        }
        properties[kCGImagePropertyTIFFDictionary] = tiff
        properties[kCGImagePropertyExifDictionary] = exif
        if let location {
            var gps = original[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
            gps[kCGImagePropertyGPSLatitude] = abs(location.latitude)
            gps[kCGImagePropertyGPSLatitudeRef] = location.latitude < 0 ? "S" : "N"
            gps[kCGImagePropertyGPSLongitude] = abs(location.longitude)
            gps[kCGImagePropertyGPSLongitudeRef] = location.longitude < 0 ? "W" : "E"
            if let altitude = location.altitude {
                gps[kCGImagePropertyGPSAltitude] = abs(altitude)
                gps[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
            }
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        properties[kCGImageDestinationPreserveGainMap] = true

        let outputDirectory = fileURL.deletingLastPathComponent().appendingPathComponent(
            "capture-metadata-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
        let output = outputDirectory.appendingPathComponent(fileURL.lastPathComponent)
        var copiedWithoutRecompression = false
        if let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
            var copyOptions = properties
            copyOptions[kCGImageDestinationMergeMetadata] = true
            copiedWithoutRecompression = CGImageDestinationCopyImageSource(
                destination, source, copyOptions as CFDictionary, nil
            ) && exifValuesMatch(exif, in: output)
                && (location.map { gpsLocation(from: output)?.matches($0) == true } ?? true)
        }
        if !copiedWithoutRecompression {
            try? FileManager.default.removeItem(at: output)
            guard let destination = CGImageDestinationCreateWithURL(
                output as CFURL, type, 1, nil
            ) else {
                try? FileManager.default.removeItem(at: outputDirectory)
                throw Error.cannotWrite
            }
            CGImageDestinationAddImageFromSource(
                destination, source, 0, properties as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: outputDirectory)
                throw Error.cannotWrite
            }
        }
        let locationMatches = location.map { expected in
            gpsLocation(from: output)?.matches(expected) == true
        } ?? true
        let outputSize = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let originalSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let outputSource = CGImageSourceCreateWithURL(output as CFURL, nil)
        let outputProperties = outputSource.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        // Image I/O may write the default upright orientation explicitly.
        let originalOrientation = (original[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let outputOrientation = (outputProperties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let orientationMatches = originalOrientation == outputOrientation
        let sourceGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeHDRGainMap
        ) != nil
        let outputGainMap = outputSource.map {
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                $0, 0, kCGImageAuxiliaryDataTypeHDRGainMap
            ) != nil
        } ?? false
        // Reject a severe size drop, which can indicate that a HEIF rewrite
        // discarded image data or encoded the current appearance too heavily.
        let sizeIsPlausible = originalSize == 0 || outputSize >= originalSize / 2
        let cameraValuesMatch = originalEXIFPropertyList == nil
            ? PhotoTechnicalMetadataExtractor.metadata(from: output)?
                .containsCameraValues(from: metadata) == true
            : true
        let result = PhotoTechnicalMetadataExtractor.metadata(from: output)
        var mismatches: [String] = []
        if result == nil { mismatches.append("the rewritten image cannot be read") }
        if !cameraValuesMatch || (metadata.cameraMake != nil && result?.cameraMake != metadata.cameraMake)
            || (metadata.cameraModel != nil && result?.cameraModel != metadata.cameraModel) {
            mismatches.append("camera make or model changed")
        }
        if result?.pixelWidth != rendered.pixelWidth || result?.pixelHeight != rendered.pixelHeight {
            mismatches.append("pixel dimensions changed")
        }
        let changedEXIFKeys = exifMismatchedKeys(exif, in: output)
        if !changedEXIFKeys.isEmpty {
            let names = changedEXIFKeys.prefix(5).joined(separator: ", ")
            let remaining = changedEXIFKeys.count > 5 ? " and \(changedEXIFKeys.count - 5) more" : ""
            mismatches.append("EXIF fields changed (\(names)\(remaining))")
        }
        if !locationMatches { mismatches.append("GPS coordinates changed or disappeared") }
        if !orientationMatches { mismatches.append("image orientation changed") }
        if sourceGainMap && !outputGainMap { mismatches.append("HDR gain map disappeared") }
        if !sizeIsPlausible {
            mismatches.append("rewritten image is \(outputSize) bytes; rendered image was \(originalSize) bytes")
        }
        guard mismatches.isEmpty else {
            try? FileManager.default.removeItem(at: outputDirectory)
            throw Error.metadataMismatch(mismatches.joined(separator: "; "))
        }
        return output
    }

    static func exifValuesMatch(_ expected: [CFString: Any], in fileURL: URL) -> Bool {
        exifMismatchedKeys(expected, in: fileURL).isEmpty
    }

    private static func exifMismatchedKeys(_ expected: [CFString: Any], in fileURL: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let actual = properties[kCGImagePropertyExifDictionary]
                as? [CFString: Any] else {
            return expected.isEmpty ? [] : expected.keys.map { $0 as String }.sorted()
        }
        var changed: [String] = []
        for (key, value) in expected {
            guard let outputValue = actual[key],
                  exifValueMatches(value, outputValue, for: key) else {
                if key == kCGImagePropertyExifFocalLength,
                   let expectedNumber = value as? NSNumber,
                   let actualNumber = actual[key] as? NSNumber {
                    changed.append("FocalLength: \(expectedNumber.doubleValue) → \(actualNumber.doubleValue) mm")
                } else {
                    changed.append(key as String)
                }
                continue
            }
        }
        return changed.sorted()
    }

    private static func exifValueMatches(_ expected: Any, _ actual: Any, for key: CFString) -> Bool {
        if key == kCGImagePropertyExifFocalLength,
           let expectedNumber = expected as? NSNumber,
           let actualNumber = actual as? NSNumber {
            // HEIF writes focal length as an EXIF rational. Rewriting it can
            // round the last decimal place without changing the camera value.
            return abs(expectedNumber.doubleValue - actualNumber.doubleValue) <= 0.005
        }
        return (expected as AnyObject).isEqual(actual)
    }

    static func gpsLocation(from fileURL: URL) -> PhotoTransferLocation? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else {
            return nil
        }
        let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
        let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
        let altitude = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue
        let altitudeRef = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue
        return PhotoTransferLocation(
            latitude: latitudeRef == "S" ? -latitude : latitude,
            longitude: longitudeRef == "W" ? -longitude : longitude,
            altitude: altitude.map { altitudeRef == 1 ? -$0 : $0 }
        )
    }
}
