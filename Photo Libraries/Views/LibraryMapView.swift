import AppKit
import Combine
import CoreLocation
import MapKit
import SwiftUI

/// A cross-library map built only from already-indexed coordinate metadata.
/// It deliberately does not request place names: selecting a marker is the
/// first point at which that location's photo previews are loaded.
@MainActor
struct LibraryMapView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    let registry: LibraryRegistry
    let store: LibraryPreviewStore
    let systemModel: SystemPhotoLibraryViewModel
    let probe: RegisteredLibraryProbeModel

    @State private var snapshot = MapDataSnapshot.empty
    @State private var selectedMarkerIDs: Set<String> = []
    @State private var showsPhotoGrid = false
    @State private var expandedPhotoID: String?

    private var selectedMarkers: [MapMarkerGroup] {
        snapshot.markers.filter { selectedMarkerIDs.contains($0.id) }
    }

    private var selectedPhotos: [MapPhoto] {
        selectedMarkers
            .flatMap(\.photos)
            .sorted(by: MapPhoto.isNewer)
    }

    private var expandedPhoto: MapPhoto? {
        guard let expandedPhotoID else { return nil }
        return selectedPhotos.first { $0.id == expandedPhotoID }
    }

    var body: some View {
        ZStack {
            mapPane
                .opacity(showsPhotoGrid || expandedPhoto != nil ? 0 : 1)
                .allowsHitTesting(!showsPhotoGrid && expandedPhoto == nil)

            if showsPhotoGrid, expandedPhoto == nil {
                photoGrid
            }

            if let expandedPhoto {
                expandedPhotoView(expandedPhoto)
            }
        }
        .background {
            MapPhotoKeyboardMonitor(
                isEnabled: expandedPhoto != nil,
                onPrevious: { moveExpandedPhoto(by: -1) },
                onNext: { moveExpandedPhoto(by: 1) }
            )
        }
        .navigationTitle(showsPhotoGrid ? "Map Photos" : "Map")
        .navigationSubtitle(
            showsPhotoGrid && expandedPhoto == nil
                ? "\(selectedPhotos.count.formatted()) photos from this area"
                : ""
        )
        .toolbar {
            if showsPhotoGrid && expandedPhoto == nil {
                ToolbarItem(placement: .navigation) {
                    Button("Back to Map", systemImage: "arrow.left") {
                        expandedPhotoID = nil
                        showsPhotoGrid = false
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onAppear(perform: rebuildSnapshot)
        .onReceive(
            systemModel.$assets
                .dropFirst()
                .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        ) { _ in rebuildSnapshot() }
        .onReceive(
            store.$manifests
                .dropFirst()
                .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        ) { _ in rebuildSnapshot() }
        .onReceive(registry.$descriptors.dropFirst()) { _ in rebuildSnapshot() }
    }

    @ViewBuilder
    private var mapPane: some View {
        if snapshot.markers.isEmpty {
            ContentUnavailableView(
                "No Photo Locations",
                systemImage: "map",
                description: Text(snapshot.emptyMapMessage)
            )
        } else {
            NativeLibraryMapView(
                markers: snapshot.markers,
                store: store,
                systemModel: systemModel,
                selectedMarkerIDs: selectedMarkerIDs,
                onSelect: showPhotos
            )
        }
    }

    private var photoGrid: some View {
        VStack(spacing: 0) {
            Divider()

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 1)],
                    spacing: 1
                ) {
                    ForEach(selectedPhotos) { photo in
                        Button {
                            expandedPhotoID = photo.id
                        } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    GeometryReader { geometry in
                                        photoThumbnail(
                                            photo,
                                            pixelSize: max(1, Int(ceil(geometry.size.width * displayScale)))
                                        )
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                                .clipped()
                        }
                        .buttonStyle(.plain)
                        .help("Open \(photo.title)")
                        .accessibilityLabel(photo.title)
                        .accessibilityValue(photo.libraryName)
                    }
                }
                .padding(1)
            }
            .background(colorScheme == .dark ? Color.black : Color.white)
        }
    }

    private func showPhotos(_ markerIDs: Set<String>) {
        guard !markerIDs.isEmpty else { return }
        selectedMarkerIDs = markerIDs
        expandedPhotoID = nil
        showsPhotoGrid = true
    }

    private func moveExpandedPhoto(by offset: Int) {
        guard let expandedPhotoID,
              let adjacent = PhotoSequence.adjacent(
                in: selectedPhotos, selectedID: expandedPhotoID, offset: offset
              ) else { return }
        self.expandedPhotoID = adjacent.id
    }

    @ViewBuilder
    private func photoThumbnail(_ photo: MapPhoto, pixelSize: Int) -> some View {
        if let asset = photo.systemAsset {
            SystemMapPhotoThumbnail(
                systemModel: systemModel,
                asset: asset,
                targetSize: CGSize(width: CGFloat(pixelSize), height: CGFloat(pixelSize))
            )
        } else if let libraryID = photo.libraryID, let item = photo.registeredItem {
            RegisteredMapPhotoThumbnail(
                store: store,
                libraryID: libraryID,
                item: item,
                pixelSize: pixelSize
            )
        } else {
            MapThumbnailPlaceholder(systemImage: "photo")
        }
    }

    private func rebuildSnapshot() {
        let updatedSnapshot = Self.makeSnapshot(
            descriptors: registry.descriptors,
            manifests: store.manifests,
            systemAssets: systemModel.assets
        )
        let validMarkerIDs = Set(updatedSnapshot.markers.map(\.id))
        selectedMarkerIDs.formIntersection(validMarkerIDs)
        if selectedMarkerIDs.isEmpty {
            showsPhotoGrid = false
        }
        if let expandedPhotoID,
           !updatedSnapshot.markers
            .flatMap(\.photos)
            .contains(where: { $0.id == expandedPhotoID }) {
            self.expandedPhotoID = nil
        }
        guard updatedSnapshot != snapshot else { return }
        snapshot = updatedSnapshot
    }

    @ViewBuilder
    private func expandedPhotoView(_ photo: MapPhoto) -> some View {
        ExpandedPhotoContainer(
            title: photo.title,
            previous: PhotoSequence.adjacent(in: selectedPhotos, selectedID: photo.id, offset: -1).map { previous in
                { expandedPhotoID = previous.id }
            },
            next: PhotoSequence.adjacent(in: selectedPhotos, selectedID: photo.id, offset: 1).map { next in
                { expandedPhotoID = next.id }
            },
            close: { expandedPhotoID = nil }
        ) {
            if let asset = photo.systemAsset {
                SystemMapExpandedPhoto(systemModel: systemModel, asset: asset)
            } else if let libraryID = photo.libraryID,
                      let item = photo.registeredItem {
                RegisteredMapExpandedPhoto(
                    store: store,
                    libraryID: libraryID,
                    item: item,
                    probe: probe
                )
            } else {
                MapThumbnailPlaceholder(systemImage: "photo")
            }
        }
    }

    private static func makeSnapshot(
        descriptors: [LibraryDescriptor],
        manifests: [LibraryID: LibraryPreviewManifest],
        systemAssets: [PhotoAssetSummary]
    ) -> MapDataSnapshot {
        let systemLibraryName = descriptors.first(where: { $0.kind.isSystemPhotoLibrary })?
            .metadata.displayName ?? "System Photo Library"
        let systemPhotos = systemAssets.compactMap { asset -> MapPhoto? in
            guard let coordinate = validCoordinate(asset.coordinate) else { return nil }
            return MapPhoto(
                id: "system:\(asset.id)",
                coordinate: coordinate,
                libraryID: nil,
                libraryName: systemLibraryName,
                title: asset.originalFilename.isEmpty ? asset.mediaType.capitalized : asset.originalFilename,
                captureDate: asset.creationDate,
                dateText: asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "",
                dimensionsText: "\(asset.pixelWidth) × \(asset.pixelHeight)",
                systemAsset: asset,
                registeredItem: nil
            )
        }

        let registeredPhotos = manifests.values.flatMap { manifest in
            manifest.items.compactMap { item -> MapPhoto? in
                guard let coordinate = validCoordinate(
                    UnifiedSearchViewModel.coordinate(from: item.locationDescription)
                ) else { return nil }
                return MapPhoto(
                    id: "\(manifest.libraryID.rawValue.uuidString):\(item.id)",
                    coordinate: coordinate,
                    libraryID: manifest.libraryID,
                    libraryName: manifest.libraryDisplayName,
                    title: item.name.isEmpty ? item.filename : item.name,
                    captureDate: item.captureDate,
                    dateText: item.captureDate?.formatted(date: .abbreviated, time: .shortened)
                        ?? item.dateDescription,
                    dimensionsText: "\(item.pixelWidth) × \(item.pixelHeight)",
                    systemAsset: nil,
                    registeredItem: item
                )
            }
        }
        let photos = systemPhotos + registeredPhotos
        let markers = Dictionary(grouping: photos, by: MapRegionKey.init)
            .map { region, photos in
                return MapMarkerGroup(
                    id: region.id,
                    coordinate: representativeCoordinate(for: photos),
                    photos: photos.sorted(by: MapPhoto.isNewer)
                )
            }
            .sorted { $0.id < $1.id }

        let nonSystemDescriptors = descriptors.filter { !$0.kind.isSystemPhotoLibrary }
        let incompleteNames = nonSystemDescriptors.compactMap { descriptor -> String? in
            guard let manifest = manifests[descriptor.id],
                  manifest.isComplete,
                  manifest.items.count >= manifest.totalMediaItemCount,
                  (manifest.pendingMetadataItemIDs?.isEmpty ?? true) else {
                return descriptor.metadata.displayName
            }
            return nil
        }.sorted()
        let indexingNotice = incompleteNames.isEmpty ? nil
            : "Map includes available indexed locations. Complete Index is still needed for: \(incompleteNames.joined(separator: ", "))."

        let emptyMapMessage: String
        if let indexingNotice {
            emptyMapMessage = indexingNotice
        } else if systemAssets.isEmpty && manifests.isEmpty {
            emptyMapMessage = "Load the System Photo Library or complete indexing for a non-system library to show photos with location metadata."
        } else {
            emptyMapMessage = "None of the available photos has valid location metadata."
        }

        return MapDataSnapshot(
            markers: markers,
            nonSystemIndexingNotice: indexingNotice,
            emptyMapMessage: emptyMapMessage
        )
    }

    /// Keeps regional grouping while placing each marker on a real photo
    /// coordinate. Repeated coordinates win; otherwise use the real point
    /// nearest the regional photo centroid.
    private nonisolated static func representativeCoordinate(
        for photos: [MapPhoto]
    ) -> SearchCoordinate {
        guard let firstPhoto = photos.first else {
            return SearchCoordinate(latitude: 0, longitude: 0)
        }

        let count = Double(photos.count)
        let centroid = SearchCoordinate(
            latitude: photos.reduce(0) { $0 + $1.coordinate.latitude } / count,
            longitude: photos.reduce(0) { $0 + $1.coordinate.longitude } / count
        )
        let photosByCoordinate = Dictionary(grouping: photos, by: \.coordinate)

        return photosByCoordinate.keys.min { lhs, rhs in
            let leftCount = photosByCoordinate[lhs]?.count ?? 0
            let rightCount = photosByCoordinate[rhs]?.count ?? 0
            if leftCount != rightCount {
                return leftCount > rightCount
            }

            let leftDistance = squaredMapDistance(from: lhs, to: centroid)
            let rightDistance = squaredMapDistance(from: rhs, to: centroid)
            if leftDistance != rightDistance {
                return leftDistance < rightDistance
            }
            if lhs.latitude != rhs.latitude {
                return lhs.latitude < rhs.latitude
            }
            return lhs.longitude < rhs.longitude
        } ?? firstPhoto.coordinate
    }

    private nonisolated static func squaredMapDistance(
        from coordinate: SearchCoordinate,
        to reference: SearchCoordinate
    ) -> Double {
        let latitudeDelta = coordinate.latitude - reference.latitude
        let longitudeScale = cos(reference.latitude * .pi / 180)
        let longitudeDelta = (coordinate.longitude - reference.longitude) * longitudeScale
        return latitudeDelta * latitudeDelta + longitudeDelta * longitudeDelta
    }

    private nonisolated static func validCoordinate(
        _ coordinate: SearchCoordinate?
    ) -> SearchCoordinate? {
        guard let coordinate,
              coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude),
              (-180...180).contains(coordinate.longitude) else {
            return nil
        }
        return coordinate
    }
}

private struct MapPhotoKeyboardMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    func makeNSView(context: Context) -> MapPhotoKeyboardMonitorView {
        MapPhotoKeyboardMonitorView()
    }

    func updateNSView(_ view: MapPhotoKeyboardMonitorView, context: Context) {
        view.isEnabled = isEnabled
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ view: MapPhotoKeyboardMonitorView, coordinator: ()) {
        view.removeMonitor()
    }
}

private final class MapPhotoKeyboardMonitorView: NSView {
    var isEnabled = false
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    private var eventMonitor: Any?

    func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.isEnabled,
                  let window = self.window,
                  event.window === window,
                  window.isKeyWindow,
                  window.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !(window.firstResponder is NSTextView) else {
                return event
            }
            switch event.keyCode {
            case 123, 126:
                self.onPrevious?()
            case 124, 125:
                self.onNext?()
            default:
                return event
            }
            return nil
        }
    }

    func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct SystemMapPhotoThumbnail: View {
    let systemModel: SystemPhotoLibraryViewModel
    let asset: PhotoAssetSummary
    let targetSize: CGSize

    var body: some View {
        SystemPhotoLibraryThumbnailView(
            model: systemModel,
            asset: asset,
            targetSize: targetSize,
            requestGeneration: systemModel.thumbnailRequestGeneration,
            placeholderSystemImage: asset.mediaType == "video" ? "video" : "photo",
            showsMediaBadge: false
        )
    }
}

private struct RegisteredMapPhotoThumbnail: View {
    @ObservedObject var store: LibraryPreviewStore
    let libraryID: LibraryID
    let item: PhotosAutomationMediaItem
    let pixelSize: Int

    var body: some View {
        CachedLibraryThumbnailView(
            store: store,
            libraryID: libraryID,
            itemID: item.id,
            revision: store.thumbnailRevision(for: item.id, libraryID: libraryID),
            placeholderSystemImage: UnifiedSearchViewModel.mediaType(for: item.filename) == "video"
                ? "video" : "photo",
            hasError: store.manifest(for: libraryID)?.itemErrors[item.id] != nil,
            thumbnailPixelSize: pixelSize,
            thumbnailAspectRatio: item.pixelWidth > 0 && item.pixelHeight > 0
                ? Double(max(item.pixelWidth, item.pixelHeight))
                    / Double(min(item.pixelWidth, item.pixelHeight))
                : nil,
            showsMediaBadge: false
        )
        .equatable()
    }
}

private struct SystemMapExpandedPhoto: View {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var systemModel: SystemPhotoLibraryViewModel
    let asset: PhotoAssetSummary

    var body: some View {
        if asset.mediaType == "video" {
            SystemLibraryVideoPlayer(assetID: asset.id)
        } else {
            GeometryReader { proxy in
                let targetSize = SystemPhotoLibraryViewModel.viewerTargetSize(
                    for: proxy.size,
                    displayScale: displayScale
                )
                Group {
                    if let image = systemModel.viewerImages[asset.id]
                        ?? systemModel.thumbnails[asset.id] {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: "\(asset.id):\(Int(targetSize.width))x\(Int(targetSize.height))") {
                    systemModel.requestViewerImage(for: asset, size: targetSize)
                }
            }
            .onDisappear {
                systemModel.cancelViewerImageRequest(for: asset.id)
            }
        }
    }
}

private struct RegisteredMapExpandedPhoto: View {
    @ObservedObject var store: LibraryPreviewStore
    let libraryID: LibraryID
    let item: PhotosAutomationMediaItem
    let probe: RegisteredLibraryProbeModel

    var body: some View {
        if UnifiedSearchViewModel.mediaType(for: item.filename) == "video" {
            RegisteredLibraryVideoPlayer(
                item: item,
                libraryID: libraryID,
                store: store
            )
        } else {
            CachedLibraryThumbnailView(
                store: store,
                libraryID: libraryID,
                itemID: item.id,
                revision: store.viewerPreviewRevision(
                    for: item.id,
                    libraryID: libraryID
                ),
                placeholderSystemImage: "photo",
                hasError: store.manifest(for: libraryID)?.itemErrors[item.id] != nil,
                contentMode: .fit,
                prefersViewerPreview: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MapThumbnailPlaceholder: View {
    let systemImage: String

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NativeLibraryMapView: NSViewRepresentable {
    let markers: [MapMarkerGroup]
    let store: LibraryPreviewStore
    let systemModel: SystemPhotoLibraryViewModel
    let selectedMarkerIDs: Set<String>
    let onSelect: (Set<String>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsZoomControls = true
        mapView.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: 10_000
        )
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronizeAnnotations(markers, in: mapView)
        context.coordinator.refreshSelection(in: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NativeLibraryMapView

        private var annotationsByID: [String: LibraryLocationAnnotation] = [:]
        private var signaturesByID: [String: MapAnnotationSignature] = [:]
        private var hasSetInitialRegion = false

        init(parent: NativeLibraryMapView) {
            self.parent = parent
        }

        func synchronizeAnnotations(_ markers: [MapMarkerGroup], in mapView: MKMapView) {
            let desiredIDs = Set(markers.map(\.id))
            let removedIDs = Set(annotationsByID.keys).subtracting(desiredIDs)
            if !removedIDs.isEmpty {
                let removedAnnotations = removedIDs.compactMap { annotationsByID.removeValue(forKey: $0) }
                removedIDs.forEach { signaturesByID[$0] = nil }
                mapView.removeAnnotations(removedAnnotations)
            }

            var addedAnnotations: [LibraryLocationAnnotation] = []
            var didUpdateExistingAnnotation = false
            for marker in markers {
                let signature = MapAnnotationSignature(marker: marker)
                if let annotation = annotationsByID[marker.id] {
                    guard signaturesByID[marker.id] != signature else { continue }
                    if signaturesByID[marker.id]?.coordinate != signature.coordinate {
                        mapView.removeAnnotation(annotation)
                        let replacement = LibraryLocationAnnotation(marker: marker)
                        annotationsByID[marker.id] = replacement
                        signaturesByID[marker.id] = signature
                        addedAnnotations.append(replacement)
                        continue
                    }
                    annotation.photoCount = marker.photos.count
                    annotation.latestPhoto = marker.latestPhoto
                    signaturesByID[marker.id] = signature
                    didUpdateExistingAnnotation = true
                } else {
                    let annotation = LibraryLocationAnnotation(marker: marker)
                    annotationsByID[marker.id] = annotation
                    signaturesByID[marker.id] = signature
                    addedAnnotations.append(annotation)
                }
            }
            if !addedAnnotations.isEmpty {
                mapView.addAnnotations(addedAnnotations)
            }

            if !hasSetInitialRegion, !annotationsByID.isEmpty {
                hasSetInitialRegion = true
                if let densestLocation = annotationsByID.values.max(by: { lhs, rhs in
                    if lhs.photoCount != rhs.photoCount {
                        return lhs.photoCount < rhs.photoCount
                    }
                    return lhs.markerID < rhs.markerID
                }) {
                    let region = MKCoordinateRegion(
                        center: densestLocation.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
                    )
                    mapView.setRegion(mapView.regionThatFits(region), animated: false)
                }
            } else if didUpdateExistingAnnotation {
                refreshVisibleAnnotationViews(in: mapView)
            }
        }

        func refreshSelection(in mapView: MKMapView) {
            refreshVisibleAnnotationViews(in: mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let identifier = "library-photo-cluster"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    as? LibraryPhotoAnnotationView)
                    ?? LibraryPhotoAnnotationView(
                        annotation: cluster,
                        reuseIdentifier: identifier
                    )
                view.annotation = cluster
                configureClusterView(view, cluster: cluster)
                return view
            }

            guard let location = annotation as? LibraryLocationAnnotation else { return nil }
            let identifier = "library-photo-location"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? LibraryPhotoAnnotationView)
                ?? LibraryPhotoAnnotationView(
                    annotation: location,
                    reuseIdentifier: identifier
                )
            view.annotation = location
            view.clusteringIdentifier = "library-photo-location-cluster"
            view.displayPriority = .defaultHigh
            configureLocationView(view, annotation: location)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let location = view.annotation as? LibraryLocationAnnotation {
                parent.onSelect([location.markerID])
            } else if let cluster = view.annotation as? MKClusterAnnotation {
                parent.onSelect(Set(
                    cluster.memberAnnotations.compactMap {
                        ($0 as? LibraryLocationAnnotation)?.markerID
                    }
                ))
            }
            if let annotation = view.annotation {
                mapView.deselectAnnotation(annotation, animated: false)
            }
            refreshVisibleAnnotationViews(in: mapView)
        }

        private func refreshVisibleAnnotationViews(in mapView: MKMapView) {
            for annotation in mapView.annotations {
                guard let view = mapView.view(for: annotation)
                    as? LibraryPhotoAnnotationView else {
                    continue
                }
                if let location = annotation as? LibraryLocationAnnotation {
                    configureLocationView(view, annotation: location)
                } else if let cluster = annotation as? MKClusterAnnotation {
                    configureClusterView(view, cluster: cluster)
                }
            }
        }

        private func configureLocationView(
            _ view: LibraryPhotoAnnotationView,
            annotation: LibraryLocationAnnotation
        ) {
            view.configure(
                photo: annotation.latestPhoto,
                photoCount: annotation.photoCount,
                store: parent.store,
                systemModel: parent.systemModel,
                isSelected: parent.selectedMarkerIDs.contains(annotation.markerID),
                accessibilityLabel:
                "\(annotation.photoCount.formatted()) photos at this location"
            )
        }

        private func configureClusterView(
            _ view: LibraryPhotoAnnotationView,
            cluster: MKClusterAnnotation
        ) {
            let members = cluster.memberAnnotations.compactMap {
                $0 as? LibraryLocationAnnotation
            }
            let photoCount = members.reduce(0) { $0 + $1.photoCount }
            let containsSelection = members.contains {
                parent.selectedMarkerIDs.contains($0.markerID)
            }
            let latestPhoto = members
                .map(\.latestPhoto)
                .sorted(by: MapPhoto.isNewer)
                .first
            guard let latestPhoto else { return }
            view.configure(
                photo: latestPhoto,
                photoCount: photoCount,
                store: parent.store,
                systemModel: parent.systemModel,
                isSelected: containsSelection,
                accessibilityLabel:
                    "\(photoCount.formatted()) photos across \(members.count.formatted()) locations"
            )
            view.displayPriority = .defaultHigh
        }
    }
}

private final class LibraryPhotoAnnotationView: MKAnnotationView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = NSRect(x: 0, y: 0, width: 68, height: 78)
        centerOffset = CGPoint(x: 0, y: -34)
        canShowCallout = false
        collisionMode = .rectangle

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        photo: MapPhoto,
        photoCount: Int,
        store: LibraryPreviewStore,
        systemModel: SystemPhotoLibraryViewModel,
        isSelected: Bool,
        accessibilityLabel: String
    ) {
        hostingView.rootView = AnyView(
            MapPhotoAnnotationContent(
                photo: photo,
                photoCount: photoCount,
                store: store,
                systemModel: systemModel,
                isSelected: isSelected
            )
        )
        setAccessibilityLabel(accessibilityLabel)
    }
}

private struct MapPhotoAnnotationContent: View {
    @Environment(\.displayScale) private var displayScale
    let photo: MapPhoto
    let photoCount: Int
    @ObservedObject var store: LibraryPreviewStore
    @ObservedObject var systemModel: SystemPhotoLibraryViewModel
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(photoCount.formatted())
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    isSelected ? Color.accentColor : Color.black.opacity(0.78),
                    in: Capsule()
                )

            thumbnail
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isSelected ? Color.accentColor : Color.white, lineWidth: 3)
                }
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        }
        .frame(width: 68, height: 78, alignment: .top)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let pixelSize = max(1, Int(ceil(54 * displayScale)))
        if let asset = photo.systemAsset {
            SystemMapPhotoThumbnail(
                systemModel: systemModel,
                asset: asset,
                targetSize: CGSize(width: CGFloat(pixelSize), height: CGFloat(pixelSize))
            )
        } else if let libraryID = photo.libraryID,
                  let item = photo.registeredItem {
            RegisteredMapPhotoThumbnail(
                store: store,
                libraryID: libraryID,
                item: item,
                pixelSize: pixelSize
            )
        } else {
            MapThumbnailPlaceholder(systemImage: "photo")
        }
    }
}

private final class LibraryLocationAnnotation: NSObject, MKAnnotation {
    let markerID: String
    let coordinate: CLLocationCoordinate2D
    var photoCount: Int
    var latestPhoto: MapPhoto

    init(marker: MapMarkerGroup) {
        markerID = marker.id
        coordinate = marker.clLocation
        photoCount = marker.photos.count
        latestPhoto = marker.latestPhoto
        super.init()
    }
}

private struct MapAnnotationSignature: Equatable {
    let coordinate: SearchCoordinate
    let photoCount: Int
    let latestPhotoID: String

    init(marker: MapMarkerGroup) {
        coordinate = marker.coordinate
        photoCount = marker.photos.count
        latestPhotoID = marker.latestPhoto.id
    }
}

private struct MapDataSnapshot: Equatable {
    let markers: [MapMarkerGroup]
    let nonSystemIndexingNotice: String?
    let emptyMapMessage: String

    static let empty = MapDataSnapshot(
        markers: [],
        nonSystemIndexingNotice: nil,
        emptyMapMessage: "Loading photo locations…"
    )
}

private struct MapPhoto: Identifiable, Equatable {
    let id: String
    let coordinate: SearchCoordinate
    let libraryID: LibraryID?
    let libraryName: String
    let title: String
    let captureDate: Date?
    let dateText: String
    let dimensionsText: String
    let systemAsset: PhotoAssetSummary?
    let registeredItem: PhotosAutomationMediaItem?

    nonisolated static func isNewer(_ lhs: MapPhoto, _ rhs: MapPhoto) -> Bool {
        switch (lhs.captureDate, rhs.captureDate) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id < rhs.id
        }
    }
}

/// Coarsens GPS coordinates into roughly five-kilometre areas so the map is
/// useful for browsing trips and neighbourhoods rather than individual roads.
private struct MapRegionKey: Hashable {
    private static let cellSize = 0.05

    let latitudeIndex: Int
    let longitudeIndex: Int

    init(_ photo: MapPhoto) {
        latitudeIndex = Int(floor(
            (photo.coordinate.latitude + 90) / Self.cellSize
        ))
        longitudeIndex = Int(floor(
            (photo.coordinate.longitude + 180) / Self.cellSize
        ))
    }

    var id: String { "region:\(latitudeIndex):\(longitudeIndex)" }

}

private struct MapMarkerGroup: Identifiable, Equatable {
    let id: String
    let coordinate: SearchCoordinate
    let photos: [MapPhoto]

    var latestPhoto: MapPhoto { photos[0] }

    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
