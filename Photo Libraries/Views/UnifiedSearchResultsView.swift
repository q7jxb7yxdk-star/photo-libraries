import SwiftUI

struct UnifiedSearchResultsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    let results: [UnifiedSearchDocument]
    @ObservedObject var store: LibraryPreviewStore
    @ObservedObject var systemModel: SystemPhotoLibraryViewModel
    let selectedDocumentID: String?
    let onSelect: (UnifiedSearchDocument) -> Void
    let onOpen: (UnifiedSearchDocument) -> Void

    private let columns = [GridItem(.adaptive(minimum: 155), spacing: 1)]

    var body: some View {
        let systemAssetsByID = Dictionary(
            uniqueKeysWithValues: systemModel.assets.map { ($0.id, $0) }
        )
        LazyVGrid(columns: columns, spacing: 1) {
            ForEach(results) { document in
                Button { onSelect(document) } label: {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            GeometryReader { geometry in
                                thumbnail(
                                    for: document,
                                    systemAssetsByID: systemAssetsByID,
                                    pixelSize: max(1, Int(ceil(geometry.size.width * displayScale)))
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .overlay {
                            if selectedDocumentID == document.id {
                                Rectangle()
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                        }
                        .clipped()
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        onOpen(document)
                    }
                )
                .accessibilityLabel(document.displayName.isEmpty ? document.filename : document.displayName)
                .accessibilityValue("\(document.libraryName), \(document.mediaType), \(document.pixelWidth) × \(document.pixelHeight)")
            }
        }
        .padding(1)
        .background(colorScheme == .dark ? Color.black : Color.white)
    }

    @ViewBuilder
    private func thumbnail(
        for document: UnifiedSearchDocument,
        systemAssetsByID: [String: PhotoAssetSummary],
        pixelSize: Int
    ) -> some View {
        if document.source == .systemPhotoLibrary,
           let asset = systemAssetsByID[document.assetID] {
            SystemPhotoLibraryThumbnailView(
                model: systemModel,
                asset: asset,
                targetSize: CGSize(width: CGFloat(pixelSize), height: CGFloat(pixelSize)),
                requestGeneration: systemModel.thumbnailRequestGeneration,
                placeholderSystemImage: document.mediaType == "video" ? "video" : "photo"
            )
        } else if document.source == .registeredLibrary {
            CachedLibraryThumbnailView(
                store: store,
                libraryID: document.libraryID,
                itemID: document.assetID,
                revision: store.thumbnailRevision(
                    for: document.assetID,
                    libraryID: document.libraryID
                ),
                placeholderSystemImage: document.mediaType == "video" ? "video" : "photo",
                hasError: false,
                isLivePhoto: store.isDirectLivePhoto(document.assetID, libraryID: document.libraryID)
                    || store.manifest(for: document.libraryID)?
                        .livePhotoVideoFilenames?[document.assetID] != nil,
                thumbnailPixelSize: pixelSize,
                thumbnailAspectRatio: document.pixelWidth > 0 && document.pixelHeight > 0
                    ? Double(max(document.pixelWidth, document.pixelHeight))
                        / Double(min(document.pixelWidth, document.pixelHeight))
                    : nil
            )
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: document.mediaType == "video" ? "video" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
