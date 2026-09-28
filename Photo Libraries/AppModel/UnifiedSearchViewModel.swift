import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class UnifiedSearchViewModel: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var results: [UnifiedSearchDocument] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var placesByDocumentID: [String: SearchPlace] = [:]
    @Published private(set) var unavailablePlaceDocumentIDs: Set<String> = []

    private var index: UnifiedSearchIndex?
    private var resolver: PlaceNameResolver?
    private var initializationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var upsertTask: Task<Void, Never>?
    private var geocodingTask: Task<Void, Never>?
    private var pendingUpserts: [String: UnifiedSearchDocument] = [:]
    private var pendingGeocoding: [String: [String: UnifiedSearchDocument]] = [:]
    private var priorityPlaceTasks: [String: Task<Void, Never>] = [:]
    private var systemAssetUpdatesCancellable: AnyCancellable?
    private var observedSystemModelID: ObjectIdentifier?
    private var observedSystemLibraryID: LibraryID?

    func bootstrap(
        registry: LibraryRegistry,
        store: LibraryPreviewStore,
        systemModel: SystemPhotoLibraryViewModel
    ) {
        initializeIfNeeded()
        for manifest in store.manifests.values {
            replace(manifest)
        }
        if let systemLibrary = registry.libraries.first(where: {
            $0.descriptor.kind.isSystemPhotoLibrary
        }) {
            observeSystemAssetUpdates(from: systemModel, library: systemLibrary)
            if !systemModel.assets.isEmpty {
                replaceSystemLibrary(systemLibrary, assets: systemModel.assets)
            }
        }
    }

    func apply(_ mutation: LibrarySearchMutation) {
        initializeIfNeeded()
        switch mutation {
        case .replaceLibrary(let manifest):
            replace(manifest)
        case .upsertItem(let libraryID, let libraryName, let item):
            let document = Self.document(
                item: item,
                libraryID: libraryID,
                libraryName: libraryName
            )
            enqueueUpsert(document)
        case .removeLibrary(let libraryID):
            performIndexOperation { index in
                try await index.removeLibrary(libraryID)
            }
        }
    }

    func replaceSystemLibrary(
        _ library: RegisteredLibrary,
        assets: [PhotoAssetSummary]
    ) {
        initializeIfNeeded()
        let documents = assets.map {
            Self.document(
                asset: $0,
                libraryID: library.id,
                libraryName: library.descriptor.metadata.displayName
            )
        }
        performIndexOperation { index in
            let indexed = try await index.replaceLibrary(documents, libraryID: library.id)
            await self.restoreIndexedPlaces(indexed, libraryID: library.id)
            await self.enqueueGeocoding(indexed)
        }
    }

    func place(libraryID: LibraryID, assetID: String) -> SearchPlace? {
        placesByDocumentID[
            UnifiedSearchDocument.identifier(libraryID: libraryID, assetID: assetID)
        ]
    }

    func isPlaceUnavailable(libraryID: LibraryID, assetID: String) -> Bool {
        unavailablePlaceDocumentIDs.contains(
            UnifiedSearchDocument.identifier(libraryID: libraryID, assetID: assetID)
        )
    }

    func requestPlace(
        libraryID: LibraryID,
        assetID: String,
        coordinate: SearchCoordinate?
    ) {
        guard let coordinate else { return }
        let documentID = UnifiedSearchDocument.identifier(
            libraryID: libraryID,
            assetID: assetID
        )
        guard placesByDocumentID[documentID] == nil,
              priorityPlaceTasks[documentID] == nil else {
            return
        }

        unavailablePlaceDocumentIDs.remove(documentID)

        priorityPlaceTasks[documentID] = Task { [weak self] in
            guard let self else { return }
            initializeIfNeeded()
            if let initializationTask { await initializationTask.value }
            guard !Task.isCancelled, let resolver, let index else {
                unavailablePlaceDocumentIDs.insert(documentID)
                priorityPlaceTasks[documentID] = nil
                return
            }
            if let place = await resolver.resolve(coordinate), !Task.isCancelled {
                try? await index.updatePlace(documentID: documentID, place: place)
                publish(place: place, documentIDs: [documentID])
                if !query.isEmpty { scheduleSearch() }
            } else if !Task.isCancelled {
                unavailablePlaceDocumentIDs.insert(documentID)
            }
            priorityPlaceTasks[documentID] = nil
        }
    }

    func requestPlace(
        libraryID: LibraryID,
        assetID: String,
        rawLocation: String
    ) {
        requestPlace(
            libraryID: libraryID,
            assetID: assetID,
            coordinate: Self.parseCoordinate(rawLocation)
        )
    }

    nonisolated static func coordinate(from rawLocation: String) -> SearchCoordinate? {
        parseCoordinate(rawLocation)
    }

    private func observeSystemAssetUpdates(
        from model: SystemPhotoLibraryViewModel,
        library: RegisteredLibrary
    ) {
        let modelID = ObjectIdentifier(model)
        guard observedSystemModelID != modelID || observedSystemLibraryID != library.id else {
            return
        }
        observedSystemModelID = modelID
        observedSystemLibraryID = library.id
        systemAssetUpdatesCancellable = model.searchAssetUpdates.sink { [weak self] assets in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for asset in assets {
                    enqueueUpsert(
                        Self.document(
                            asset: asset,
                            libraryID: library.id,
                            libraryName: library.descriptor.metadata.displayName
                        )
                    )
                }
            }
        }
    }

    private func replace(_ manifest: LibraryPreviewManifest) {
        let documents = manifest.items.map {
            Self.document(
                item: $0,
                libraryID: manifest.libraryID,
                libraryName: manifest.libraryDisplayName
            )
        }
        performIndexOperation { index in
            let indexed = try await index.replaceLibrary(
                documents, libraryID: manifest.libraryID
            )
            await self.restoreIndexedPlaces(indexed, libraryID: manifest.libraryID)
            await self.enqueueGeocoding(indexed)
        }
    }

    private func restoreIndexedPlaces(
        _ documents: [UnifiedSearchDocument], libraryID: LibraryID
    ) {
        let prefix = libraryID.rawValue.uuidString + ":"
        var places = placesByDocumentID.filter { !$0.key.hasPrefix(prefix) }
        for document in documents {
            if let place = document.place {
                places[document.id] = place
                unavailablePlaceDocumentIDs.remove(document.id)
            }
        }
        if places != placesByDocumentID { placesByDocumentID = places }
    }

    private func initializeIfNeeded() {
        guard index == nil, initializationTask == nil else { return }
        initializationTask = Task { [weak self] in
            guard let self else { return }
            do {
                index = try UnifiedSearchIndex()
                resolver = try PlaceNameResolver()
            } catch {
                errorMessage = error.localizedDescription
            }
            initializationTask = nil
        }
    }

    private func performIndexOperation(
        _ operation: @escaping @Sendable (UnifiedSearchIndex) async throws -> Void
    ) {
        Task { [weak self] in
            guard let self else { return }
            initializeIfNeeded()
            if let initializationTask { await initializationTask.value }
            guard let index else { return }
            do {
                try await operation(index)
                scheduleSearch(immediate: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Coalesces repeated changes for the same asset and drains them through
    /// one task. Large metadata enrichments therefore remain incremental
    /// without creating thousands of concurrent SQLite tasks.
    private func enqueueUpsert(_ document: UnifiedSearchDocument) {
        pendingUpserts[document.id] = document
        guard upsertTask == nil else { return }
        upsertTask = Task { [weak self] in
            guard let self else { return }
            initializeIfNeeded()
            if let initializationTask { await initializationTask.value }
            guard let index else {
                upsertTask = nil
                return
            }
            while !Task.isCancelled, let document = pendingUpserts.values.first {
                pendingUpserts[document.id] = nil
                do {
                    try await index.upsert(document)
                    enqueueGeocoding([document])
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            upsertTask = nil
            scheduleSearch(immediate: true)
        }
    }

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let rawQuery = query
        guard !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard !Task.isCancelled else { return }
            initializeIfNeeded()
            if let initializationTask { await initializationTask.value }
            guard let index else { return }
            isSearching = true
            do {
                let parsed = SearchQueryParser.parse(rawQuery)
                let matches = try await index.search(parsed)
                guard !Task.isCancelled, rawQuery == query else { return }
                results = matches
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func enqueueGeocoding(_ documents: [UnifiedSearchDocument]) {
        for document in documents where document.coordinate != nil && document.place == nil {
            guard let key = document.coordinate?.cacheKey else { continue }
            pendingGeocoding[key, default: [:]][document.id] = document
        }
        guard geocodingTask == nil, !pendingGeocoding.isEmpty else { return }
        geocodingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  let entry = pendingGeocoding.first,
                  let document = entry.value.values.first,
                  let coordinate = document.coordinate {
                pendingGeocoding[entry.key] = nil
                guard let resolver, let index else { continue }
                if let place = await resolver.resolve(coordinate) {
                    for documentID in entry.value.keys {
                        try? await index.updatePlace(documentID: documentID, place: place)
                    }
                    publish(place: place, documentIDs: Array(entry.value.keys))
                    if !query.isEmpty { scheduleSearch() }
                }
            }
            geocodingTask = nil
        }
    }

    private func publish(place: SearchPlace, documentIDs: [String]) {
        var updatedPlaces = placesByDocumentID
        for documentID in documentIDs {
            updatedPlaces[documentID] = place
            unavailablePlaceDocumentIDs.remove(documentID)
        }
        placesByDocumentID = updatedPlaces
    }
}

private extension UnifiedSearchViewModel {
    nonisolated static func document(
        item: PhotosAutomationMediaItem,
        libraryID: LibraryID,
        libraryName: String
    ) -> UnifiedSearchDocument {
        let coordinate = parseCoordinate(item.locationDescription)
        return UnifiedSearchDocument(
            id: UnifiedSearchDocument.identifier(libraryID: libraryID, assetID: item.id),
            libraryID: libraryID,
            assetID: item.id,
            libraryName: libraryName,
            source: .registeredLibrary,
            filename: item.filename,
            displayName: item.name,
            caption: item.itemDescription,
            keywords: item.keywords,
            rawLocation: item.locationDescription,
            place: nil,
            captureDate: item.captureDate,
            dateDescription: item.dateDescription,
            isFavorite: item.isFavorite,
            pixelWidth: item.pixelWidth,
            pixelHeight: item.pixelHeight,
            mediaType: mediaType(for: item.filename),
            coordinate: coordinate
        )
    }

    nonisolated static func document(
        asset: PhotoAssetSummary,
        libraryID: LibraryID,
        libraryName: String
    ) -> UnifiedSearchDocument {
        let rawLocation = asset.coordinate.map {
            "\($0.latitude),\($0.longitude)"
        } ?? ""
        return UnifiedSearchDocument(
            id: UnifiedSearchDocument.identifier(libraryID: libraryID, assetID: asset.id),
            libraryID: libraryID,
            assetID: asset.id,
            libraryName: libraryName,
            source: .systemPhotoLibrary,
            filename: asset.originalFilename,
            displayName: asset.originalFilename,
            caption: "",
            keywords: [],
            rawLocation: rawLocation,
            place: nil,
            captureDate: asset.creationDate,
            dateDescription: asset.creationDate?.formatted(date: .long, time: .shortened) ?? "",
            isFavorite: asset.isFavorite,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            mediaType: asset.mediaType,
            coordinate: asset.coordinate
        )
    }

    nonisolated static func parseCoordinate(_ value: String) -> SearchCoordinate? {
        let parts = value.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }
        return SearchCoordinate(latitude: latitude, longitude: longitude)
    }

}

extension UnifiedSearchViewModel {
    nonisolated static func mediaType(for filename: String) -> String {
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension) else {
            return "unknown"
        }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .movie) { return "video" }
        if type.conforms(to: .audio) { return "audio" }
        return "unknown"
    }
}
