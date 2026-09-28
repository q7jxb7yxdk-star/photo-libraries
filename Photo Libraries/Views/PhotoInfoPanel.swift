import MapKit
import SwiftUI

nonisolated struct PhotoInfoDetail: Identifiable, Hashable, Sendable {
    let label: String
    let value: String

    var id: String { "\(label):\(value)" }
}

struct PhotoInfoContent {
    let title: String
    let filename: String
    let dateText: String
    let isFavorite: Bool
    let isLivePhoto: Bool
    let isVideo: Bool
    let caption: String
    let keywords: [String]
    let textMetadataError: String?
    let details: [PhotoInfoDetail]
    let technicalMetadata: PhotoTechnicalMetadata?
    let isLoadingTechnicalMetadata: Bool
    let place: SearchPlace?
    let coordinate: SearchCoordinate?
    let isLocationUnavailable: Bool

    static func system(
        _ asset: PhotoAssetSummary,
        libraryName: String,
        textMetadata: PhotoCatalogTextMetadata?,
        textMetadataError: String?,
        technicalMetadata: PhotoTechnicalMetadata?,
        isLoadingTechnicalMetadata: Bool,
        place: SearchPlace?,
        isLocationUnavailable: Bool
    ) -> Self {
        let isVideo = asset.mediaType == "video"
        let displayedMetadata = isVideo
            ? (technicalMetadata ?? PhotoTechnicalMetadata.empty)
                .applyingCatalogValues(
                    pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                    fileSize: nil, filename: asset.originalFilename
                )
            : technicalMetadata
        var details = [
            PhotoInfoDetail(label: "Library", value: libraryName),
            PhotoInfoDetail(label: "Kind", value: asset.mediaType.capitalized),
            PhotoInfoDetail(label: "Dimensions", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
        ]
        if asset.duration > 0 {
            details.append(PhotoInfoDetail(
                label: "Duration",
                value: Duration.seconds(asset.duration).formatted(.time(pattern: .minuteSecond))
            ))
        }
        if asset.isHidden {
            details.append(PhotoInfoDetail(label: "Hidden", value: "Yes"))
        }
        if asset.representsBurst {
            details.append(PhotoInfoDetail(label: "Burst", value: "Yes"))
        }
        return Self(
            title: textMetadata?.title ?? "",
            filename: asset.originalFilename,
            dateText: asset.creationDate?.formatted(date: .long, time: .standard) ?? "",
            isFavorite: asset.isFavorite,
            isLivePhoto: asset.isLivePhoto,
            isVideo: isVideo,
            caption: textMetadata?.caption ?? "",
            keywords: textMetadata?.keywords ?? [],
            textMetadataError: textMetadataError,
            details: details,
            technicalMetadata: displayedMetadata,
            isLoadingTechnicalMetadata: isLoadingTechnicalMetadata,
            place: place,
            coordinate: asset.coordinate,
            isLocationUnavailable: isLocationUnavailable
        )
    }

    static func registered(
        _ item: PhotosAutomationMediaItem,
        libraryName: String,
        isLivePhoto: Bool,
        technicalMetadata: PhotoTechnicalMetadata?,
        videoDuration: TimeInterval? = nil,
        place: SearchPlace?,
        isLocationUnavailable: Bool
    ) -> Self {
        let mediaType = isLivePhoto ? "image" : UnifiedSearchViewModel.mediaType(for: item.filename)
        let itemTitle = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = item.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalogMetadata = mediaType == "image" || mediaType == "video"
            ? PhotoTechnicalMetadata.empty : nil
        var displayedMetadata = (technicalMetadata ?? catalogMetadata)?.applyingCatalogValues(
            pixelWidth: item.pixelWidth,
            pixelHeight: item.pixelHeight,
            fileSize: item.fileSize,
            filename: item.filename
        )
        if mediaType == "video", displayedMetadata?.videoDuration == nil {
            displayedMetadata?.videoDuration = videoDuration
        }
        var details = [
            PhotoInfoDetail(label: "Library", value: libraryName),
            PhotoInfoDetail(label: "Kind", value: mediaType.capitalized),
            PhotoInfoDetail(label: "Dimensions", value: "\(item.pixelWidth) × \(item.pixelHeight)")
        ]
        if let fileSize = item.fileSize {
            details.append(PhotoInfoDetail(
                label: "File Size",
                value: ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
            ))
        }
        return Self(
            title: itemTitle == filename ? "" : itemTitle,
            filename: item.filename,
            dateText: item.captureDate?.formatted(date: .long, time: .standard)
                ?? item.dateDescription,
            isFavorite: item.isFavorite,
            isLivePhoto: isLivePhoto,
            isVideo: mediaType == "video",
            caption: item.itemDescription,
            keywords: item.keywords,
            textMetadataError: nil,
            details: details,
            technicalMetadata: displayedMetadata,
            isLoadingTechnicalMetadata: false,
            place: place,
            coordinate: UnifiedSearchViewModel.coordinate(from: item.locationDescription),
            isLocationUnavailable: isLocationUnavailable
        )
    }
}

struct PhotoInfoPanel: View {
    let title: String
    let filename: String
    let dateText: String
    let isFavorite: Bool
    let isLivePhoto: Bool
    let isVideo: Bool
    let caption: String
    let keywords: [String]
    let textMetadataError: String?
    let details: [PhotoInfoDetail]
    let technicalMetadata: PhotoTechnicalMetadata?
    let isLoadingTechnicalMetadata: Bool
    let place: SearchPlace?
    let coordinate: SearchCoordinate?
    let isLocationUnavailable: Bool

    init(content: PhotoInfoContent) {
        title = content.title
        filename = content.filename
        dateText = content.dateText
        isFavorite = content.isFavorite
        isLivePhoto = content.isLivePhoto
        isVideo = content.isVideo
        caption = content.caption
        keywords = content.keywords
        textMetadataError = content.textMetadataError
        details = content.details
        technicalMetadata = content.technicalMetadata
        isLoadingTechnicalMetadata = content.isLoadingTechnicalMetadata
        place = content.place
        coordinate = content.coordinate
        isLocationUnavailable = content.isLocationUnavailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Info")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 18)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if title.isEmpty {
                    Text("Title")
                        .font(.title3)
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    Text(title)
                        .font(.title3)
                }
                Spacer(minLength: 8)
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(isFavorite ? Color.red : Color.secondary)
                    .accessibilityLabel(isFavorite ? "Favorite" : "Not Favorite")
            }

            Text(filename.isEmpty ? "—" : filename)
                .font(.body)
                .lineLimit(2)
                .padding(.top, 8)

            Text(dateText.isEmpty ? "—" : dateText)
                .font(.body)
                .foregroundStyle(dateText.isEmpty ? .secondary : .primary)
                .padding(.top, 4)

            technicalCard
                .padding(.top, 18)

            infoTextSection(
                value: caption,
                placeholder: "Caption"
            )
            infoTextSection(
                value: keywords.joined(separator: ", "),
                placeholder: "Keyword"
            )
            if let textMetadataError {
                Text(textMetadataError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            locationSection
        }
        .textSelection(.enabled)
    }

    private var technicalCard: some View {
        Group {
            if let technicalMetadata {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(cameraName(technicalMetadata)
                            ?? (isVideo ? "Video" : "Camera information unavailable"))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if !isVideo, let whiteBalance = technicalMetadata.whiteBalance {
                            Image(systemName: "camera.filters")
                                .help("White Balance: \(whiteBalance)")
                        }
                        if !isVideo {
                            Image(systemName: "viewfinder")
                                .help("Camera metadata")
                        }
                    }

                    if isVideo {
                        if let description = videoCameraDescription(technicalMetadata) {
                            Text(description)
                                .lineLimit(2)
                        }
                    } else {
                        Text(focalLengthText(technicalMetadata) ?? "Focal length unavailable")
                            .lineLimit(2)
                    }

                    if isVideo {
                        HStack(spacing: 10) {
                            if let quality = videoQuality(technicalMetadata) { Text(quality) }
                            if let dimensions = dimensionText(technicalMetadata) { Text(dimensions) }
                            if let fileSize = technicalMetadata.fileSize {
                                Text(ByteCountFormatter.string(
                                    fromByteCount: fileSize, countStyle: .file
                                ))
                            }
                            if let codec = technicalMetadata.videoCodec { Text(codec) }
                            Spacer(minLength: 2)
                            Image(systemName: "video.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Video")
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    } else {
                        HStack(spacing: 10) {
                            if let megapixels = megapixelText(technicalMetadata) { Text(megapixels) }
                            if let dimensions = dimensionText(technicalMetadata) { Text(dimensions) }
                            Spacer(minLength: 4)
                            if let fileSize = technicalMetadata.fileSize {
                                Text(ByteCountFormatter.string(
                                    fromByteCount: fileSize,
                                    countStyle: .file
                                ))
                            }
                            if let format = technicalMetadata.fileFormat {
                                Text(format == "HEIC" ? "HEIF" : format)
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.secondary, in: RoundedRectangle(cornerRadius: 3))
                            }
                            if isLivePhoto { livePhotoBadge }
                        }
                    }

                    Divider()

                    if isVideo {
                        HStack(spacing: 12) {
                            Text(technicalMetadata.videoFrameRate.map {
                                "\($0.formatted(.number.precision(.fractionLength(0...2)))) FPS"
                            } ?? "— FPS")
                                .frame(maxWidth: .infinity)
                            Text(technicalMetadata.videoDuration.map(videoDurationText) ?? "—:—")
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ForEach(exposureMetrics(technicalMetadata)) { metric in
                                Text(metric.value)
                                    .frame(maxWidth: .infinity)
                                    .help(metric.label)
                            }
                        }
                    }

                    let remainingDetails = details.filter {
                        ($0.label != "Dimensions"
                            || technicalMetadata.pixelWidth == nil
                            || technicalMetadata.pixelHeight == nil)
                            && ($0.label != "File Size" || technicalMetadata.fileSize == nil)
                            && ($0.label != "Duration" || technicalMetadata.videoDuration == nil)
                    }
                    if !isVideo && !remainingDetails.isEmpty {
                        Divider()
                        detailRows(remainingDetails)
                    }
                    if isVideo && isLoadingTechnicalMetadata {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading video metadata…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    if isLivePhoto {
                        livePhotoBadge
                    }
                    detailRows(details)
                    if isLoadingTechnicalMetadata {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading camera metadata…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var livePhotoBadge: some View {
        Image(systemName: "livephoto")
            .foregroundStyle(.secondary)
            .help("Live Photo")
            .accessibilityLabel("Live Photo")
    }

    private func detailRows(_ rows: [PhotoInfoDetail]) -> some View {
        ForEach(rows) { detail in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(detail.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(detail.value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    private func cameraName(_ metadata: PhotoTechnicalMetadata) -> String? {
        switch (metadata.cameraMake, metadata.cameraModel) {
        case let (make?, model?) where model.localizedCaseInsensitiveContains(make):
            return model
        case let (make?, model?):
            return "\(make) \(model)"
        case let (make?, nil):
            return make
        case let (nil, model?):
            return model
        default:
            return nil
        }
    }

    private func megapixelText(_ metadata: PhotoTechnicalMetadata) -> String? {
        guard let width = metadata.pixelWidth,
              let height = metadata.pixelHeight,
              width > 0,
              height > 0 else { return nil }
        let megapixels = Double(width) * Double(height) / 1_000_000
        return "\(megapixels.formatted(.number.precision(.fractionLength(0...1)))) MP"
    }

    private func focalLengthText(_ metadata: PhotoTechnicalMetadata) -> String? {
        guard let focalLength = metadata.focalLengthIn35mm ?? metadata.focalLength else {
            return nil
        }
        return "\(wholeNumber(focalLength)) mm"
    }

    private func dimensionText(_ metadata: PhotoTechnicalMetadata) -> String? {
        guard let width = metadata.pixelWidth, let height = metadata.pixelHeight else { return nil }
        return "\(width) × \(height)"
    }

    private func exposureMetrics(_ metadata: PhotoTechnicalMetadata) -> [PhotoInfoMetric] {
        [
            PhotoInfoMetric(
                label: "ISO",
                value: metadata.iso.map { "ISO \(wholeNumber($0))" } ?? "ISO —"
            ),
            PhotoInfoMetric(
                label: "35mm-equivalent focal length",
                value: (metadata.focalLengthIn35mm ?? metadata.focalLength)
                    .map { "\(wholeNumber($0)) mm" } ?? "— mm"
            ),
            PhotoInfoMetric(
                label: "Exposure compensation",
                value: metadata.exposureBias.map { "\(decimal($0)) ev" } ?? "— ev"
            ),
            PhotoInfoMetric(
                label: "Aperture",
                value: metadata.aperture.map { "ƒ\(decimal($0))" } ?? "ƒ—"
            ),
            PhotoInfoMetric(
                label: "Shutter speed",
                value: metadata.exposureTime.map(shutterSpeed) ?? "— s"
            )
        ]
    }

    private func videoCameraDescription(_ metadata: PhotoTechnicalMetadata) -> String? {
        let focalLength = metadata.focalLengthIn35mm.map { "\(wholeNumber($0)) mm" }
        let aperture = metadata.aperture.map { "ƒ\(decimal($0))" }
        let optics = [focalLength, aperture].compactMap { $0 }.joined(separator: " ")
        let camera = metadata.videoCameraName
        if let camera, !optics.isEmpty { return "\(camera) — \(optics)" }
        if let camera { return camera }
        if !optics.isEmpty { return optics }
        return metadata.lensModel
    }

    private func videoQuality(_ metadata: PhotoTechnicalMetadata) -> String? {
        guard let width = metadata.pixelWidth, let height = metadata.pixelHeight else {
            return nil
        }
        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        if longEdge >= 7_680 && shortEdge >= 4_320 { return "8K" }
        if longEdge >= 3_840 && shortEdge >= 2_160 { return "4K" }
        if shortEdge >= 1_080 { return "1080p" }
        if shortEdge >= 720 { return "720p" }
        return nil
    }

    private func videoDurationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—:—" }
        let wholeSeconds = max(Int(seconds.rounded()), 0)
        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let remainder = wholeSeconds % 60
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func shutterSpeed(_ seconds: Double) -> String {
        guard seconds > 0 else { return "— s" }
        if seconds < 1 {
            return "1/\(max(Int((1 / seconds).rounded()), 1)) s"
        }
        return "\(decimal(seconds)) s"
    }

    private func infoTextSection(value: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            if value.isEmpty {
                Text(placeholder)
                    .font(.title3)
                    .italic()
                    .foregroundStyle(.secondary)
            } else {
                Text(value)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 18)
    }

    @ViewBuilder
    private var locationSection: some View {
        if let coordinate {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                Text(locationText)
                    .font(.title3)
                    .textSelection(.enabled)

                PhotoLocationMap(
                    coordinate: coordinate,
                    markerTitle: place?.name.isEmpty == false
                        ? place?.name ?? "Photo Location"
                        : "Photo Location"
                )
                .id(coordinate)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Coordinates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(coordinate.latitude), \(coordinate.longitude)")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 18)
        }
    }

    private var locationText: String {
        guard let place else {
            return isLocationUnavailable ? "Address unavailable" : "Resolving location…"
        }
        if !place.formattedAddress.isEmpty { return place.formattedAddress }
        let text = place.searchableText
        return text.isEmpty ? "Location unavailable" : text
    }
}

private struct PhotoInfoMetric: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

private struct PhotoLocationMap: View {
    let coordinate: SearchCoordinate
    let markerTitle: String

    private var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    var body: some View {
        Map(
            initialPosition: .region(
                MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
                )
            ),
            interactionModes: [.pan, .zoom]
        ) {
            Marker(markerTitle, coordinate: center)
        }
        .mapControls {
            MapZoomStepper()
        }
    }
}
