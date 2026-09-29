import AppKit
import Combine
import Foundation
import Network

@MainActor
final class WebGalleryServer: ObservableObject {
    static let shared = WebGalleryServer()
    static let port: UInt16 = 8766

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Web gallery is off."
    @Published private(set) var allowedLogins: [String]
    @Published private(set) var sharedLibraryIDs: Set<LibraryID>
    @Published var expectedHost: String {
        didSet { UserDefaults.standard.set(expectedHost, forKey: Self.hostKey) }
    }
    @Published var mapsToken: String {
        didSet { UserDefaults.standard.set(mapsToken, forKey: Self.mapsTokenKey) }
    }

    private static let loginsKey = "WebGallery.allowedTailscaleLogins.v1"
    private static let librariesKey = "WebGallery.sharedLibraryIDs.v1"
    private static let hostKey = "WebGallery.expectedHost.v1"
    private static let mapsTokenKey = "WebGallery.mapsToken.v1"
    private var listener: NWListener?
    private var listenerGeneration = UUID()
    private var connections: [UUID: WebGalleryHTTPConnection] = [:]
    private var context: Context?
    private let systemProvider = SystemPhotoLibraryProvider()
    private weak var searchModel: UnifiedSearchViewModel?
    private var placeNameResolver: PlaceNameResolver?
    private var webDirectProviders: [LibraryID: (bookmark: Data, provider: RegisteredPhotoLibraryProvider)] = [:]
    private struct SystemVideoKey: Hashable {
        let itemID: String
        let live: Bool
    }
    private struct SystemVideoPreparation {
        let directory: URL
        let task: Task<URL?, Never>
    }
    private var systemVideoCache: [SystemVideoKey: URL] = [:]
    private var systemVideoCacheOrder: [SystemVideoKey] = []
    private var systemVideoPreparations: [SystemVideoKey: SystemVideoPreparation] = [:]
    private var retiredSystemVideoDirectories: Set<URL> = []
    private var systemVideoCacheGeneration = UUID()
    private static let maximumSystemVideoCacheEntries = 4
    private var appIconPNGBySize: [Int: Data] = [:]

    private struct Context {
        let registry: LibraryRegistry
        let systemModel: SystemPhotoLibraryViewModel
        let store: LibraryPreviewStore
    }

    private init() {
        let defaults = UserDefaults.standard
        allowedLogins = defaults.stringArray(forKey: Self.loginsKey) ?? []
        sharedLibraryIDs = Set((defaults.stringArray(forKey: Self.librariesKey) ?? [])
            .compactMap(UUID.init(uuidString:)).map(LibraryID.init(rawValue:)))
        expectedHost = defaults.string(forKey: Self.hostKey) ?? ""
        mapsToken = defaults.string(forKey: Self.mapsTokenKey) ?? ""
    }

    func useSearchModel(_ model: UnifiedSearchViewModel) {
        searchModel = model
    }

    private static func validServeHost(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let hostname = String(parts[0])
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard hostname.hasSuffix(".ts.net"),
              hostname.count < 254,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { byte in
                      (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
                  }
              }) else { return nil }
        if parts.count == 2 {
            let rawPort = String(parts[1])
            guard let port = UInt16(rawPort), port > 0, port != 443,
                  rawPort == String(port) else { return nil }
        }
        return value
    }

    func addLogin(_ input: String) {
        let login = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !login.isEmpty,
              login.count <= 254,
              !login.contains(where: { $0.isWhitespace || $0.isNewline }),
              !allowedLogins.contains(login) else { return }
        allowedLogins.append(login)
        allowedLogins.sort()
        UserDefaults.standard.set(allowedLogins, forKey: Self.loginsKey)
    }

    func removeLogin(_ login: String) {
        allowedLogins.removeAll { $0 == login }
        UserDefaults.standard.set(allowedLogins, forKey: Self.loginsKey)
    }

    func setShared(_ shared: Bool, libraryID: LibraryID) {
        if shared { sharedLibraryIDs.insert(libraryID) }
        else {
            sharedLibraryIDs.remove(libraryID)
            clearSystemVideoCache()
        }
        UserDefaults.standard.set(
            sharedLibraryIDs.map { $0.rawValue.uuidString },
            forKey: Self.librariesKey
        )
    }

    func start(
        registry: LibraryRegistry,
        systemModel: SystemPhotoLibraryViewModel,
        store: LibraryPreviewStore
    ) {
        guard !isRunning, listener == nil else { return }
        guard Self.validServeHost(expectedHost) != nil,
              !allowedLogins.isEmpty,
              registry.libraries.contains(where: { sharedLibraryIDs.contains($0.id) }) else {
            statusMessage = "Enter your Tailscale Serve host and optional port, allowed logins, and at least one library."
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            guard let port = NWEndpoint.Port(rawValue: Self.port) else {
                statusMessage = "Invalid web gallery port."
                return
            }
            let listener = try NWListener(using: parameters, on: port)
            context = Context(registry: registry, systemModel: systemModel, store: store)
            if registry.libraries.contains(where: {
                sharedLibraryIDs.contains($0.id) && $0.descriptor.kind.isSystemPhotoLibrary
            }), systemModel.authorization.permitsReading, systemModel.assets.isEmpty {
                systemModel.loadLibrary()
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            let generation = UUID()
            listenerGeneration = generation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.listenerGeneration == generation else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.statusMessage = "Local gallery is listening on 127.0.0.1:\(Self.port)."
                    case .failed(let error):
                        self.stop()
                        self.statusMessage = "Web gallery could not start: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            self.listener = listener
            statusMessage = "Starting web gallery…"
            listener.start(queue: .global(qos: .utility))
        } catch {
            context = nil
            statusMessage = "Web gallery could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        listenerGeneration = UUID()
        clearSystemVideoCache()
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        context = nil
        webDirectProviders.removeAll()
        isRunning = false
        statusMessage = "Web gallery is off."
    }

    private func accept(_ connection: NWConnection) {
        guard isRunning, connections.count < 32 else {
            connection.cancel()
            return
        }
        let id = UUID()
        let client = WebGalleryHTTPConnection(connection: connection) { [weak self] request, reply in
            Task { @MainActor [weak self] in
                guard let self else {
                    reply(.text(403, "Gallery unavailable"))
                    return
                }
                reply(await self.route(request))
            }
        } onFinish: { [weak self] in
            Task { @MainActor [weak self] in self?.connections[id] = nil }
        }
        connections[id] = client
        client.start()
    }

    private func authorize(_ request: WebGalleryHTTPRequest) -> String? {
        guard isRunning, context != nil else { return nil }
        guard let host = Self.validServeHost(expectedHost) else { return nil }
        guard request.headers["host"]?.lowercased() == host,
              let login = request.headers["tailscale-user-login"]?.lowercased(),
              allowedLogins.contains(login),
              request.headers["origin"].map({ $0.lowercased() == "https://\(host)" }) ?? true,
              request.headers["sec-fetch-site"].map({ $0 == "same-origin" || $0 == "none" }) ?? true else {
            return nil
        }
        return login
    }

    private func sharedLibrary(_ rawID: String, context: Context) -> RegisteredLibrary? {
        guard let uuid = UUID(uuidString: rawID) else { return nil }
        let id = LibraryID(rawValue: uuid)
        guard sharedLibraryIDs.contains(id) else { return nil }
        return context.registry.libraries.first(where: { $0.id == id })
    }

    private func directProvider(for library: RegisteredLibrary) -> RegisteredPhotoLibraryProvider? {
        guard !library.descriptor.kind.isSystemPhotoLibrary,
              library.availability == .online else { return nil }
        let bookmark = library.descriptor.bookmarkData
        if let cached = webDirectProviders[library.id], cached.bookmark == bookmark {
            return cached.provider
        }
        let provider = RegisteredPhotoLibraryProvider(bookmarkData: bookmark)
        webDirectProviders[library.id] = (bookmark, provider)
        return provider
    }

    private func route(_ request: WebGalleryHTTPRequest) async -> WebGalleryHTTPResponse {
        guard let login = authorize(request), let context else {
            return .text(403, "Access requires an allowed Tailscale Serve user")
        }
        guard let host = Self.validServeHost(expectedHost) else { return .text(403, "Invalid Serve host") }
        guard let components = URLComponents(string: "https://\(host)\(request.target)"),
              components.fragment == nil else { return .text(400, "Invalid URL") }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else {
                return .text(400, "Invalid query")
            }
            query[item.name] = value
        }

        switch components.path {
        case "/":
            return WebGalleryHTTPResponse(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(WebGalleryPage.html.utf8)
            )
        case "/favicon.ico", "/photo-libraries-icon.ico":
            guard query.isEmpty else { return .text(400, "Invalid icon request") }
            guard let png = appIconPNG(size: 32) else {
                return .text(500, "App icon unavailable")
            }
            var icon = Data([0, 0, 1, 0, 1, 0, 32, 32, 0, 0, 1, 0, 32, 0])
            withUnsafeBytes(of: UInt32(png.count).littleEndian) { icon.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(22).littleEndian) { icon.append(contentsOf: $0) }
            icon.append(png)
            return WebGalleryHTTPResponse(
                status: 200, contentType: "image/x-icon", body: icon, cacheable: true
            )
        case "/favicon.png", "/apple-touch-icon.png":
            guard query.isEmpty else { return .text(400, "Invalid icon request") }
            let size = components.path == "/favicon.png" ? 32 : 180
            guard let icon = appIconPNG(size: size) else {
                return .text(500, "App icon unavailable")
            }
            return WebGalleryHTTPResponse(
                status: 200, contentType: "image/png", body: icon, cacheable: true
            )
        case "/api/libraries":
            guard query.isEmpty else { return .text(400, "Invalid query") }
            do {
                let snapshots = try await gallerySnapshots(for: "all", context: context)
                return json(["libraries": snapshots.map { snapshot -> [String: Any] in
                    ["id": snapshot.library.id.rawValue.uuidString,
                     "name": snapshot.library.descriptor.metadata.displayName,
                     "count": snapshot.items.count,
                     "complete": snapshot.complete,
                     "kind": snapshot.library.descriptor.kind.isSystemPhotoLibrary ? "system" : "registered"]
                }])
            } catch { return galleryError(error) }
        case "/api/map-token":
            guard query.isEmpty else { return .text(400, "Invalid map token request") }
            let token = mapsToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token.utf8.count <= 8_192 else {
                return .text(404, "Apple Maps token not configured")
            }
            return json(["token": token])
        case "/api/memories":
            guard query.isEmpty else { return .text(400, "Invalid memories request") }
            do {
                let snapshots = try await gallerySnapshots(for: "all", context: context)
                let visibleItems = Dictionary(snapshots.flatMap { snapshot in
                    snapshot.items.map { item in
                        (UnifiedSearchDocument.identifier(
                            libraryID: snapshot.library.id, assetID: item.id
                        ), item)
                    }
                }, uniquingKeysWith: { first, _ in first })
                let photos = snapshots.flatMap { snapshot in
                    snapshot.items.compactMap { item -> MemoryPhoto? in
                        guard let date = item.date else { return nil }
                        let place = searchModel?.place(
                            libraryID: snapshot.library.id, assetID: item.id
                        )
                        return MemoryPhoto(
                            libraryID: snapshot.library.id, assetID: item.id,
                            libraryName: item.libraryName, date: date,
                            coordinate: item.location,
                            placeName: place?.city, regionName: place?.country,
                            isFavorite: item.isFavorite, pixelWidth: item.width,
                            pixelHeight: item.height, isVideo: item.mediaType == "video"
                        )
                    }
                }
                let memories = await Task.detached(priority: .utility) {
                    MemoryGenerator.generate(from: photos, now: Date())
                }.value
                guard authorize(request) == login,
                      snapshots.allSatisfy({ sharedLibraryIDs.contains($0.library.id) }),
                      snapshots.allSatisfy({ !$0.library.descriptor.kind.isSystemPhotoLibrary
                          || systemProvider.authorizationStatus().permitsReading }) else {
                    return .text(403, "Gallery unavailable")
                }
                let englishDate = DateFormatter()
                englishDate.locale = Locale(identifier: "en_US")
                englishDate.calendar = Calendar(identifier: .gregorian)
                englishDate.dateStyle = .medium
                englishDate.timeStyle = .none
                return json(["memories": memories.map { memory -> [String: Any] in
                    let included = memory.photos.compactMap { visibleItems[$0.id] }
                    let cover = included.max { lhs, rhs in
                        let left = (lhs.isFavorite ? 1_000_000_000.0 : 0)
                            + min(Double(lhs.width) * Double(lhs.height), 100_000_000)
                        let right = (rhs.isFavorite ? 1_000_000_000.0 : 0)
                            + min(Double(rhs.width) * Double(rhs.height), 100_000_000)
                        return left < right
                    }
                    let dateRange = Calendar.current.isDate(memory.startDate, inSameDayAs: memory.endDate)
                        ? englishDate.string(from: memory.startDate)
                        : "\(englishDate.string(from: memory.startDate)) – \(englishDate.string(from: memory.endDate))"
                    let title: String
                    if memory.kind == .onThisDay {
                        title = memory.suggestedTitle
                    } else {
                        let separator = memory.suggestedTitle.range(of: " · ", options: .backwards)
                        let prefix = separator.map { String(memory.suggestedTitle[..<$0.lowerBound]) }
                            ?? memory.suggestedTitle
                        title = "\(prefix) · \(englishDate.string(from: memory.startDate))"
                    }
                    return [
                        "id": memory.id, "kind": memory.kind.rawValue,
                        "title": title, "dateRange": dateRange,
                        "cover": cover.map { $0.json as Any } ?? NSNull(),
                        "items": included.map(\.json)
                    ]
                }])
            } catch { return galleryError(error) }
        case "/api/memory-music":
            guard Set(query.keys) == ["track"],
                  let track = query["track"],
                  ["memory-warmth", "memory-dream", "memory-journey", "memory-stillness"].contains(track),
                  let url = Bundle.main.url(forResource: track, withExtension: "wav")
                    ?? Bundle.main.url(forResource: track, withExtension: "wav", subdirectory: "MemoryMusic")
                    ?? Bundle.main.url(forResource: track, withExtension: "wav", subdirectory: "Resources/MemoryMusic"),
                  let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize > 0 else {
                return .text(404, "Music unavailable")
            }
            return WebGalleryHTTPResponse(
                status: 200, contentType: "audio/wav", body: Data(),
                file: WebGalleryHTTPFile(
                    url: url, offset: 0, length: Int64(fileSize),
                    totalLength: Int64(fileSize), cleanupDirectory: nil
                )
            )
        case "/api/map":
            guard query.isEmpty else { return .text(400, "Invalid map request") }
            do {
                // Build one fresh, sharing-scoped snapshot instead of rebuilding it
                // for every page of map points. Cached durations are sufficient here.
                let snapshots = try await gallerySnapshots(for: "all", context: context)
                let items = snapshots.flatMap(\.items).compactMap { item -> [String: Any]? in
                    guard item.location != nil else { return nil }
                    return item.mapJSON
                }
                return json(["items": items])
            } catch { return galleryError(error) }
        case "/api/items":
            guard let filter = GalleryFilter(query: query, maximumLimit: 100) else {
                return .text(400, "Invalid item request")
            }
            do {
                let snapshots = try await gallerySnapshots(
                    for: filter.library, context: context,
                    includeAlbums: filter.album != nil
                )
                var items = try filteredItems(in: snapshots, filter: filter)
                if filter.newestFirst { items.reverse() }
                return json([
                    "items": items.dropFirst(min(filter.offset, items.count)).prefix(filter.limit).map(\.json),
                    "total": items.count
                ])
            } catch { return galleryError(error) }
        case "/api/collections":
            guard Set(query.keys) == ["library"], let library = query["library"] else {
                return .text(400, "Invalid collection request")
            }
            do {
                let snapshots = try await gallerySnapshots(
                    for: library, context: context, includeAlbums: true, includeDurations: true
                )
                return json(collections(in: snapshots))
            } catch { return galleryError(error) }
        case "/api/item":
            guard Set(query.keys) == ["library", "id"],
                  let library = query["library"], library != "all",
                  let id = query["id"], !id.isEmpty else {
                return .text(400, "Invalid photo request")
            }
            do {
                let snapshots = try await gallerySnapshots(
                    for: library, context: context, includeDurations: true
                )
                guard let item = snapshots.first?.items.first(where: { $0.id == id }) else {
                    return .text(404, "Image unavailable")
                }
                var detail = item.json
                detail["title"] = item.infoTitle
                let englishDateTime = DateFormatter()
                englishDateTime.locale = Locale(identifier: "en_US")
                englishDateTime.calendar = Calendar(identifier: .gregorian)
                englishDateTime.dateStyle = .long
                englishDateTime.timeStyle = .medium
                detail["dateText"] = item.date.map { englishDateTime.string(from: $0) }
                    ?? item.dateDescription
                detail["details"] = snapshots[0].library.descriptor.kind.isSystemPhotoLibrary
                    ? Self.systemInfoDetails(for: item) : Self.registeredInfoDetails(for: item)
                let metadata: PhotoTechnicalMetadata?
                if snapshots[0].library.descriptor.kind.isSystemPhotoLibrary {
                    let extracted = try? await systemProvider.technicalMetadata(
                        for: id, networkAccessAllowed: false
                    )
                    metadata = item.mediaType == "video"
                        ? (extracted ?? .empty).applyingCatalogValues(
                            pixelWidth: item.width, pixelHeight: item.height,
                            fileSize: item.fileSize, filename: item.filename
                        ) : extracted
                    guard authorize(request) == login,
                          sharedLibrary(library, context: context) != nil,
                          systemProvider.isWebVisibleWebMedia(id) else {
                        return .text(404, "Image unavailable")
                    }
                } else {
                    let storedMetadata = await context.store.webTechnicalMetadata(
                        for: id, libraryID: snapshots[0].library.id,
                        directProvider: directProvider(for: snapshots[0].library)
                    )
                    let catalogMetadata: PhotoTechnicalMetadata? =
                        item.mediaType == "image" || item.mediaType == "video" ? .empty : nil
                    metadata = (storedMetadata ?? catalogMetadata)?.applyingCatalogValues(
                        pixelWidth: item.width, pixelHeight: item.height,
                        fileSize: item.fileSize, filename: item.filename
                    )
                    guard authorize(request) == login,
                          sharedLibrary(library, context: context) != nil,
                          context.store.manifest(for: snapshots[0].library.id)?
                            .items.contains(where: { $0.id == id }) == true else {
                        return .text(404, "Image unavailable")
                    }
                }
                if let metadata,
                   let encoded = try? JSONEncoder().encode(metadata),
                   let object = try? JSONSerialization.jsonObject(with: encoded) {
                    detail["technicalMetadata"] = object
                } else {
                    detail["technicalMetadata"] = NSNull()
                }
                return json(["item": detail])
            } catch { return galleryError(error) }
        case "/api/place":
            guard Set(query.keys) == ["library", "id"],
                  let library = query["library"], library != "all",
                  let id = query["id"], !id.isEmpty else {
                return .text(400, "Invalid place request")
            }
            do {
                let snapshots = try await gallerySnapshots(for: library, context: context)
                guard let coordinate = snapshots.first?.items.first(where: { $0.id == id })?.location else {
                    return .text(404, "Location unavailable")
                }
                if placeNameResolver == nil {
                    placeNameResolver = try? PlaceNameResolver()
                }
                guard let placeNameResolver else {
                    return json(["address": ""])
                }
                let place = await placeNameResolver.resolve(coordinate)
                guard authorize(request) == login,
                      sharedLibrary(library, context: context) != nil else {
                    return .text(404, "Location unavailable")
                }
                let address = place.map {
                    $0.formattedAddress.isEmpty ? $0.searchableText : $0.formattedAddress
                } ?? ""
                return json(["address": address])
            } catch { return galleryError(error) }
        case "/api/image":
            guard let rawLibrary = query["library"],
                  let library = sharedLibrary(rawLibrary, context: context),
                  let itemID = query["id"], !itemID.isEmpty,
                  let size = query["size"], ["thumb", "viewer"].contains(size),
                  Set(query.keys) == ["library", "id", "size"] else {
                return .text(400, "Invalid image request")
            }
            if library.descriptor.kind.isSystemPhotoLibrary {
                guard systemProvider.authorizationStatus().permitsReading,
                      systemProvider.isWebVisibleWebMedia(itemID) else {
                    return .text(404, "Image unavailable")
                }
                let data = try? await systemProvider.webPreviewJPEG(
                    for: itemID,
                    maximumPixelLength: size == "thumb" ? 480 : 4096
                )
                guard authorize(request) == login,
                      sharedLibrary(rawLibrary, context: context) != nil,
                      systemProvider.isWebVisibleWebMedia(itemID),
                      let data else { return .text(404, "Image unavailable") }
                return WebGalleryHTTPResponse(status: 200, contentType: "image/jpeg", body: data)
            }
            let payload = await context.store.webPreviewData(
                for: itemID,
                libraryID: library.id,
                prefersViewer: size == "viewer",
                directProvider: directProvider(for: library)
            )
            guard authorize(request) == login,
                  sharedLibrary(rawLibrary, context: context) != nil,
                  context.store.manifest(for: library.id)?
                    .items.contains(where: { $0.id == itemID }) == true,
                  let payload else { return .text(404, "Image unavailable") }
            return WebGalleryHTTPResponse(status: 200, contentType: payload.contentType, body: payload.data)
        case "/api/video":
            let live = query["live"] == "1"
            let expectedKeys: Set<String> = live
                ? ["library", "id", "live"] : ["library", "id"]
            guard Set(query.keys) == expectedKeys,
                  let rawLibrary = query["library"],
                  let library = sharedLibrary(rawLibrary, context: context),
                  let itemID = query["id"], !itemID.isEmpty else {
                return .text(400, "Invalid video request")
            }
            guard let item = (try? await gallerySnapshots(for: rawLibrary, context: context))?
                .first?.items.first(where: { $0.id == itemID }),
                  live ? (item.isLivePhoto && item.mediaType == "image")
                    : item.mediaType == "video" else {
                if library.descriptor.kind.isSystemPhotoLibrary {
                    if !systemProvider.authorizationStatus().permitsReading {
                        clearSystemVideoCache()
                    } else if !systemProvider.isWebVisibleWebMedia(itemID) {
                        removeSystemVideoCache(
                            for: SystemVideoKey(itemID: itemID, live: live), deferRemoval: false
                        )
                    }
                }
                return .text(404, "Video unavailable")
            }
            if !library.descriptor.kind.isSystemPhotoLibrary {
                // The manifest item and sharing selection authorize app-owned
                // proxies; a registered provider resolves uncached local media.
                let cachedURL = live
                    ? context.store.livePhotoVideoURL(for: itemID, libraryID: library.id)
                    : context.store.playbackVideoURL(for: itemID, libraryID: library.id)
                if let cachedURL {
                    guard authorize(request) == login,
                          sharedLibrary(rawLibrary, context: context) != nil,
                          context.store.manifest(for: library.id)?
                            .items.contains(where: { $0.id == itemID }) == true else {
                        return .text(404, "Video unavailable")
                    }
                    return videoResponse(for: request, fileURL: cachedURL, cleanupDirectory: nil)
                }
                guard library.availability == .online,
                      let provider = directProvider(for: library) else {
                    return .text(404, "Video unavailable")
                }
                let directory = webVideoDirectory()
                do {
                    try createWebVideoDirectory(directory)
                    let sourceURL: URL
                    do {
                        sourceURL = try await provider.videoURL(for: itemID, live: live)
                    } catch {
                        try? FileManager.default.removeItem(at: directory)
                        return .text(404, "Local video source unavailable")
                    }
                    let fileURL = directory.appendingPathComponent("video.mp4", isDirectory: false)
                    do {
                        defer { try? FileManager.default.removeItem(at: sourceURL) }
                        try await VideoPlaybackProxyLoader.createWebMP4(
                            from: sourceURL, to: fileURL
                        )
                    } catch {
                        try? FileManager.default.removeItem(at: directory)
                        return .text(500, "Video conversion failed")
                    }
                    guard authorize(request) == login,
                          sharedLibrary(rawLibrary, context: context) != nil,
                          (try? await gallerySnapshots(for: rawLibrary, context: context))?
                            .first?.items.contains(where: {
                                $0.id == itemID && (live ? $0.isLivePhoto : $0.mediaType == "video")
                            }) == true else {
                        try? FileManager.default.removeItem(at: directory)
                        return .text(404, "Video unavailable")
                    }
                    // Browsers request separate byte ranges while loading and seeking.
                    // Keep one app-owned proxy for those requests instead of exporting
                    // the original again after every HTTP response.
                    if live {
                        try context.store.storeLivePhotoVideo(
                            fileURL, for: itemID, libraryID: library.id
                        )
                    } else {
                        try await context.store.storePlaybackVideo(
                            fileURL, for: itemID, libraryID: library.id
                        )
                    }
                    try? FileManager.default.removeItem(at: directory)
                    guard authorize(request) == login,
                          sharedLibrary(rawLibrary, context: context) != nil,
                          let cachedURL = live
                            ? context.store.livePhotoVideoURL(for: itemID, libraryID: library.id)
                            : context.store.playbackVideoURL(for: itemID, libraryID: library.id) else {
                        return .text(404, "Video unavailable")
                    }
                    return videoResponse(for: request, fileURL: cachedURL, cleanupDirectory: nil)
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    return .text(500, "Video preparation failed")
                }
            }
            guard systemProvider.authorizationStatus().permitsReading,
                  systemProvider.isWebVisibleWebMedia(itemID) else {
                removeSystemVideoCache(
                    for: SystemVideoKey(itemID: itemID, live: live), deferRemoval: false
                )
                return .text(404, "Video unavailable")
            }
            let key = SystemVideoKey(itemID: itemID, live: live)
            guard let fileURL = await systemVideoURL(for: key),
                  authorize(request) == login,
                  sharedLibrary(rawLibrary, context: context) != nil,
                  (try? await gallerySnapshots(for: rawLibrary, context: context))?
                    .first?.items.contains(where: {
                        $0.id == itemID && (live ? $0.isLivePhoto : $0.mediaType == "video")
                    }) == true,
                  systemProvider.authorizationStatus().permitsReading,
                  systemProvider.isWebVisibleWebMedia(itemID) else {
                if !systemProvider.authorizationStatus().permitsReading
                    || !systemProvider.isWebVisibleWebMedia(itemID) {
                    removeSystemVideoCache(for: key, deferRemoval: false)
                }
                return .text(404, "Video unavailable")
            }
            return videoResponse(for: request, fileURL: fileURL, cleanupDirectory: nil)
        default:
            return .text(404, "Not found")
        }
    }

    private func appIconPNG(size: Int) -> Data? {
        if let cached = appIconPNGBySize[size] { return cached }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSApplication.shared.applicationIconImage.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero, operation: .copy, fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        appIconPNGBySize[size] = data
        return data
    }

    /// Safari makes several range requests for one movie. Share the finished
    /// proxy and any in-flight conversion across those requests.
    private func systemVideoURL(for key: SystemVideoKey) async -> URL? {
        if let cached = systemVideoCache[key] {
            if FileManager.default.fileExists(atPath: cached.path) {
                systemVideoCacheOrder.removeAll { $0 == key }
                systemVideoCacheOrder.append(key)
                return cached
            }
            removeSystemVideoCache(for: key, deferRemoval: false)
        }
        let generation = listenerGeneration
        let cacheGeneration = systemVideoCacheGeneration
        let preparation: SystemVideoPreparation
        if let pending = systemVideoPreparations[key] {
            preparation = pending
        } else {
            let directory = webVideoDirectory()
            do { try createWebVideoDirectory(directory) }
            catch { return nil }
            let fileURL = directory.appendingPathComponent("video.mp4", isDirectory: false)
            let task = Task { [systemProvider] () -> URL? in
                do {
                    guard try await systemProvider.webPlayableMP4File(
                        for: key.itemID, live: key.live, to: fileURL
                    ) else {
                        try? FileManager.default.removeItem(at: directory)
                        return nil
                    }
                    return fileURL
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    return nil
                }
            }
            preparation = SystemVideoPreparation(directory: directory, task: task)
            systemVideoPreparations[key] = preparation
        }
        let result = await preparation.task.value
        if systemVideoPreparations[key]?.directory == preparation.directory {
            systemVideoPreparations[key] = nil
        }
        guard generation == listenerGeneration,
              cacheGeneration == systemVideoCacheGeneration,
              isRunning, let result else {
            try? FileManager.default.removeItem(at: preparation.directory)
            return nil
        }
        if systemVideoCache[key] == nil {
            systemVideoCache[key] = result
            systemVideoCacheOrder.append(key)
            while systemVideoCacheOrder.count > Self.maximumSystemVideoCacheEntries {
                removeSystemVideoCache(for: systemVideoCacheOrder[0])
            }
        }
        return result
    }

    private func removeSystemVideoCache(
        for key: SystemVideoKey, deferRemoval: Bool = true
    ) {
        if let pending = systemVideoPreparations.removeValue(forKey: key) {
            pending.task.cancel()
            try? FileManager.default.removeItem(at: pending.directory)
        }
        if let cached = systemVideoCache.removeValue(forKey: key) {
            let directory = cached.deletingLastPathComponent()
            if deferRemoval {
                // A queued response may not have opened its file yet. Give an
                // evicted proxy time to start before removing its directory.
                retiredSystemVideoDirectories.insert(directory)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    try? FileManager.default.removeItem(at: directory)
                    self?.retiredSystemVideoDirectories.remove(directory)
                }
            } else {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        systemVideoCacheOrder.removeAll { $0 == key }
    }

    private func clearSystemVideoCache() {
        systemVideoCacheGeneration = UUID()
        for pending in systemVideoPreparations.values {
            pending.task.cancel()
            try? FileManager.default.removeItem(at: pending.directory)
        }
        systemVideoPreparations.removeAll()
        for cached in systemVideoCache.values {
            try? FileManager.default.removeItem(at: cached.deletingLastPathComponent())
        }
        systemVideoCache.removeAll()
        systemVideoCacheOrder.removeAll()
        for directory in retiredSystemVideoDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        retiredSystemVideoDirectories.removeAll()
    }

    private func webVideoDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoLibraries-WebGallery-\(UUID().uuidString)", isDirectory: true)
    }

    private func createWebVideoDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func videoResponse(
        for request: WebGalleryHTTPRequest,
        fileURL: URL,
        cleanupDirectory: URL?
    ) -> WebGalleryHTTPResponse {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let totalLength = (attributes[.size] as? NSNumber)?.int64Value,
              totalLength > 0 else {
            if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) }
            return .text(404, "Video unavailable")
        }
        guard let range = Self.videoRange(request.headers["range"], length: totalLength) else {
            if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) }
            return .rangeNotSatisfiable(totalLength: totalLength)
        }
        return WebGalleryHTTPResponse(
            status: request.headers["range"] == nil ? 200 : 206,
            contentType: "video/mp4", body: Data(),
            file: WebGalleryHTTPFile(
                url: fileURL, offset: range.lowerBound,
                length: range.upperBound - range.lowerBound + 1,
                totalLength: totalLength, cleanupDirectory: cleanupDirectory
            )
        )
    }

    private static func systemInfoDetails(for item: GalleryItem) -> [[String: String]] {
        var details = [
            ["label": "Library", "value": item.libraryName],
            ["label": "Kind", "value": item.mediaType == "video" ? "Video" : "Image"],
            ["label": "Dimensions", "value": "\(item.width) × \(item.height)"]
        ]
        if item.duration > 0 {
            details.append([
                "label": "Duration",
                "value": Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))
            ])
        }
        if item.representsBurst {
            details.append(["label": "Burst", "value": "Yes"])
        }
        return details
    }

    private static func registeredInfoDetails(for item: GalleryItem) -> [[String: String]] {
        var details = [
            ["label": "Library", "value": item.libraryName],
            ["label": "Kind", "value": item.mediaType == "video" ? "Video" : "Image"],
            ["label": "Dimensions", "value": "\(item.width) × \(item.height)"]
        ]
        if item.mediaType == "video", item.duration > 0 {
            details.append([
                "label": "Duration",
                "value": Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))
            ])
        }
        if let fileSize = item.fileSize {
            details.append([
                "label": "File Size",
                "value": ByteCountFormatter.string(
                    fromByteCount: Int64(fileSize), countStyle: .file
                )
            ])
        }
        return details
    }

    private struct GalleryItem {
        let id: String
        let library: String
        let libraryName: String
        let title: String
        let filename: String
        let date: Date?
        let width: Int
        let height: Int
        let mediaType: String
        let mediaCategories: Set<MediaCategory>
        let canPlay: Bool
        let hasPreview: Bool
        let isFavorite: Bool
        let isLivePhoto: Bool
        let caption: String
        let keywords: [String]
        let fileSize: Int?
        let location: SearchCoordinate?
        let infoTitle: String
        let dateDescription: String
        let duration: TimeInterval
        let representsBurst: Bool
        let modificationDate: Date?

        var json: [String: Any] {
            var result: [String: Any] = [
                "id": id, "library": library, "libraryName": libraryName,
                "title": title, "filename": filename,
                "date": date.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "width": width, "height": height, "mediaType": mediaType,
                "canPlay": canPlay,
                "hasPreview": hasPreview, "duration": duration.isFinite && duration > 0 ? duration : 0,
                "isFavorite": isFavorite, "isLivePhoto": isLivePhoto,
                "caption": caption, "keywords": keywords,
                "fileSize": NSNull(), "location": NSNull()
            ]
            if let fileSize { result["fileSize"] = fileSize }
            if let location {
                result["location"] = ["latitude": location.latitude, "longitude": location.longitude]
            }
            return result
        }

        var mapJSON: [String: Any] {
            guard let location else { return [:] }
            return [
                "id": id, "library": library, "title": title, "filename": filename,
                "date": date.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "mediaType": mediaType, "canPlay": canPlay,
                "hasPreview": hasPreview, "isLivePhoto": isLivePhoto,
                "duration": duration.isFinite && duration > 0 ? duration : 0,
                "location": ["latitude": location.latitude, "longitude": location.longitude]
            ]
        }

        func matches(_ words: [String]) -> Bool {
            let dates = date.map {
                [ISO8601DateFormatter().string(from: $0),
                 $0.formatted(date: .numeric, time: .omitted)]
            } ?? []
            let text = ([title, filename, caption, libraryName,
                         "\(width) × \(height)"] + keywords + dates).joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    private struct GalleryAlbum {
        let id: String
        let title: String
        let parent: String
        let memberIDs: Set<String>?
    }

    private struct GallerySnapshot {
        let library: RegisteredLibrary
        let items: [GalleryItem]
        let albums: [GalleryAlbum]
        let complete: Bool
    }

    private struct GalleryFilter {
        let library: String
        let album: String?
        let mediaCategory: MediaCategory?
        let words: [String]
        let year: Int?
        let month: Int?
        let offset: Int
        let limit: Int
        let newestFirst: Bool

        init?(query: [String: String], maximumLimit: Int) {
            let requestedCategory = query["type"].flatMap {
                $0 == "video" ? MediaCategory.videos : MediaCategory(rawValue: $0)
            }
            guard Set(query.keys).isSubset(of: ["library", "album", "q", "year", "month", "offset", "limit", "order", "type"]),
                  let library = query["library"], !library.isEmpty,
                  let offset = Int(query["offset"] ?? "0"), offset >= 0,
                  let limit = Int(query["limit"] ?? "80"), (1...maximumLimit).contains(limit),
                  (query["order"] == nil || query["order"] == "newest"),
                  (query["type"] == nil || requestedCategory != nil),
                  (query["q"]?.count ?? 0) <= 256 else { return nil }
            if let album = query["album"], album.isEmpty || library == "all" { return nil }
            var year: Int?
            var month: Int?
            if let rawYear = query["year"] {
                guard let value = Int(rawYear), (1...9999).contains(value) else { return nil }
                year = value
            }
            if let rawMonth = query["month"] {
                guard year != nil, let value = Int(rawMonth), (1...12).contains(value) else { return nil }
                month = value
            }
            self.library = library
            self.album = query["album"]
            self.mediaCategory = requestedCategory
            self.words = (query["q"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
            self.year = year
            self.month = month
            self.offset = offset
            self.limit = limit
            self.newestFirst = query["order"] == "newest"
        }
    }

    private enum GalleryReadError: Error {
        case invalidLibrary
        case invalidAlbum
        case incompleteAlbum
        case photosAccessDenied
    }

    /// Accept one HTTP byte range. An invalid or unsupported range is a 416;
    /// serving the whole file in response to it would defeat bounded seeking.
    private static func videoRange(_ header: String?, length: Int64) -> ClosedRange<Int64>? {
        guard length > 0 else { return nil }
        guard let header else { return 0...(length - 1) }
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let raw = header.dropFirst(6)
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)...(length - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < length else { return nil }
        if parts[1].isEmpty { return start...(length - 1) }
        guard let end = Int64(parts[1]), end >= start else { return nil }
        return start...min(end, length - 1)
    }

    private func galleryError(_ error: Error) -> WebGalleryHTTPResponse {
        switch error {
        case GalleryReadError.invalidLibrary:
            return .text(400, "Invalid library request")
        case GalleryReadError.invalidAlbum:
            return .text(404, "Album unavailable")
        case GalleryReadError.photosAccessDenied:
            return .text(403, "Photos access denied")
        case GalleryReadError.incompleteAlbum:
            return .text(409, "Album membership has not been indexed on this Mac")
        default:
            // Do not include file paths, resource identifiers, or underlying
            // framework errors in responses sent to visitors.
            return .text(500, "Library data is temporarily unavailable")
        }
    }

    private func gallerySnapshots(
        for rawLibrary: String,
        context: Context,
        includeAlbums: Bool = false,
        includeDurations: Bool = false
    ) async throws -> [GallerySnapshot] {
        let libraries: [RegisteredLibrary]
        if rawLibrary == "all" {
            libraries = context.registry.libraries.filter { sharedLibraryIDs.contains($0.id) }
        } else if let library = sharedLibrary(rawLibrary, context: context) {
            libraries = [library]
        } else {
            throw GalleryReadError.invalidLibrary
        }
        var snapshots: [GallerySnapshot] = []
        for library in libraries {
            let libraryID = library.id.rawValue.uuidString
            let libraryName = library.descriptor.metadata.displayName
            if library.descriptor.kind.isSystemPhotoLibrary {
                // Revoked Photos access also removes System Library data from
                // aggregate views, even if the native model still holds assets.
                guard systemProvider.authorizationStatus().permitsReading else {
                    if rawLibrary != "all" { throw GalleryReadError.photosAccessDenied }
                    continue
                }
                let knownFilenames = Dictionary(
                    context.systemModel.assets.map { ($0.id, $0.originalFilename) },
                    uniquingKeysWith: { first, _ in first }
                )
                let items = try systemProvider.fetchAssets()
                    .filter {
                        !$0.isHidden && ($0.mediaType == "image" ||
                            $0.mediaType == "video" && systemProvider.isWebVisibleWebMedia($0.id))
                    }
                    .map { asset in
                        let filename = knownFilenames[asset.id] ?? asset.originalFilename
                        return GalleryItem(
                            id: asset.id, library: libraryID, libraryName: libraryName,
                            title: filename.isEmpty ? "Photo" : filename, filename: filename,
                            date: asset.creationDate, width: asset.pixelWidth, height: asset.pixelHeight,
                            mediaType: asset.mediaType, mediaCategories: asset.mediaCategories,
                            canPlay: asset.mediaType == "video",
                            hasPreview: true, isFavorite: asset.isFavorite,
                            isLivePhoto: asset.isLivePhoto, caption: "", keywords: [],
                            fileSize: nil, location: validGalleryCoordinate(asset.coordinate),
                            infoTitle: "", dateDescription: "", duration: asset.duration,
                            representsBurst: asset.representsBurst,
                            modificationDate: asset.modificationDate
                        )
                    }
                var albums: [GalleryAlbum] = []
                if includeAlbums {
                    func append(_ nodes: [PhotoCollectionNode], parent: String) throws {
                        for node in nodes {
                            if node.kind == .folder {
                                try append(node.children, parent: parent.isEmpty ? node.title : "\(parent) / \(node.title)")
                            } else {
                                albums.append(GalleryAlbum(
                                    id: node.id, title: node.title, parent: parent,
                                    memberIDs: try systemProvider.fetchAssetIdentifiers(inAlbum: node.id)
                                ))
                            }
                        }
                    }
                    try append(systemProvider.fetchUserCollectionHierarchy(), parent: "")
                }
                snapshots.append(GallerySnapshot(library: library, items: items, albums: albums, complete: true))
            } else {
                if includeDurations {
                    await context.store.ensurePlaybackDurations(for: library.id)
                }
                guard sharedLibraryIDs.contains(library.id) else {
                    if rawLibrary != "all" { throw GalleryReadError.invalidLibrary }
                    continue
                }
                let manifest = context.store.manifest(for: library.id)
                // Use only the existing root catalog. Album IDs alone are not
                // authority to reveal an item outside this catalog.
                let items = (manifest?.items ?? []).map { item in
                    let mediaType = UnifiedSearchViewModel.mediaType(for: item.filename)
                    let isLivePhoto = context.store.isDirectLivePhoto(item.id, libraryID: library.id)
                        || context.store.livePhotoVideoURL(for: item.id, libraryID: library.id) != nil
                    var categories = Set<MediaCategory>()
                    if mediaType == "video" { categories.insert(.videos) }
                    if isLivePhoto { categories.insert(.livePhotos) }
                    return GalleryItem(
                        id: item.id, library: libraryID, libraryName: libraryName,
                        title: item.name.isEmpty ? item.filename : item.name, filename: item.filename,
                        date: item.captureDate, width: item.pixelWidth, height: item.pixelHeight,
                        mediaType: mediaType, mediaCategories: categories,
                        canPlay: mediaType == "video" && (
                            context.store.hasPlaybackVideo(for: item.id, libraryID: library.id)
                            || library.availability == .online
                        ),
                        hasPreview: manifest?.thumbnailFilenames[item.id] != nil
                            || library.availability == .online,
                        isFavorite: item.isFavorite,
                        isLivePhoto: isLivePhoto,
                        caption: item.itemDescription, keywords: item.keywords,
                        fileSize: item.fileSize,
                        location: validGalleryCoordinate(UnifiedSearchViewModel.coordinate(from: item.locationDescription)),
                        infoTitle: item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            == item.filename.trimmingCharacters(in: .whitespacesAndNewlines)
                            ? "" : item.name.trimmingCharacters(in: .whitespacesAndNewlines),
                        dateDescription: item.dateDescription,
                        duration: manifest?.playbackVideoDurations?[item.id] ?? 0,
                        representsBurst: false, modificationDate: nil
                    )
                }
                let albums = includeAlbums ? (manifest?.albums ?? []).map { album in
                    GalleryAlbum(
                        id: album.id, title: album.name, parent: album.parentName ?? "",
                        memberIDs: album.mediaItemIDs.map { Set($0) }
                    )
                } : []
                snapshots.append(GallerySnapshot(
                    library: library, items: items, albums: albums,
                    complete: manifest?.isComplete ?? false
                ))
            }
        }
        return snapshots
    }

    private func validGalleryCoordinate(_ coordinate: SearchCoordinate?) -> SearchCoordinate? {
        guard let coordinate,
              coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) else { return nil }
        return coordinate
    }

    private func sortedGalleryItems(_ items: [GalleryItem]) -> [GalleryItem] {
        items.sorted { lhs, rhs in
            let leftDate = lhs.date ?? .distantPast
            let rightDate = rhs.date ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            if lhs.library != rhs.library { return lhs.library < rhs.library }
            return lhs.id < rhs.id
        }
    }

    private func filteredItems(in snapshots: [GallerySnapshot], filter: GalleryFilter) throws -> [GalleryItem] {
        var members: Set<String>?
        if let albumID = filter.album {
            guard let album = snapshots.first?.albums.first(where: { $0.id == albumID }) else {
                throw GalleryReadError.invalidAlbum
            }
            guard let ids = album.memberIDs else { throw GalleryReadError.incompleteAlbum }
            members = ids
        }
        let calendar = Calendar(identifier: .gregorian)
        return sortedGalleryItems(snapshots.flatMap(\.items).filter { item in
            guard members.map({ $0.contains(item.id) }) ?? true,
                  filter.mediaCategory.map({ item.mediaCategories.contains($0) }) ?? true,
                  filter.words.isEmpty || item.matches(filter.words) else { return false }
            if let year = filter.year {
                guard let date = item.date, calendar.component(.year, from: date) == year else { return false }
                if let month = filter.month, calendar.component(.month, from: date) != month { return false }
            }
            return true
        })
    }

    private func collections(in snapshots: [GallerySnapshot]) -> [String: Any] {
        let items = sortedGalleryItems(snapshots.flatMap(\.items))
        let calendar = Calendar(identifier: .gregorian)
        var years: [Int: [GalleryItem]] = [:]
        var months: [Int: [GalleryItem]] = [:]
        var undatedCount = 0
        for item in items {
            guard let date = item.date else { undatedCount += 1; continue }
            let year = calendar.component(.year, from: date)
            let month = calendar.component(.month, from: date)
            years[year, default: []].append(item)
            months[year * 100 + month, default: []].append(item)
        }
        let albums: [[String: Any]] = snapshots.flatMap { snapshot in
            snapshot.albums.map { album in
                let members = sortedGalleryItems(snapshot.items.filter { album.memberIDs?.contains($0.id) ?? false })
                return [
                    "id": album.id, "library": snapshot.library.id.rawValue.uuidString,
                    "title": album.title, "parent": album.parent, "count": members.count,
                    "complete": album.memberIDs != nil,
                    "cover": members.last.map { $0.json as Any } ?? NSNull()
                ]
            }
        }
        return [
            "albums": albums,
            "years": years.keys.sorted().map { year -> [String: Any] in
                let group = years[year] ?? []
                return ["year": year, "count": group.count, "cover": group.last.map { $0.json as Any } ?? NSNull()]
            },
            "months": months.keys.sorted().map { key -> [String: Any] in
                let group = months[key] ?? []
                return ["year": key / 100, "month": key % 100, "count": group.count,
                        "cover": group.last.map { $0.json as Any } ?? NSNull()]
            },
            "undatedCount": undatedCount, "total": items.count,
            "complete": snapshots.allSatisfy { $0.complete }
        ]
    }

    private func json(_ object: [String: Any]) -> WebGalleryHTTPResponse {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return .text(500, "Could not encode gallery response")
        }
        return WebGalleryHTTPResponse(status: 200, contentType: "application/json; charset=utf-8", body: data)
    }
}
