import Foundation

/// Only explicitly shared library identities and display metadata cross processes.
/// File grants stay in the executable that obtained them; caches are independent.
@MainActor
enum WebGallerySharedConfiguration {
    static let groupID = "WX793X49GJ.com.sunny.photo-libraries.web-gallery"

    struct Snapshot: Codable, Equatable {
        var enabled: Bool
        var expectedHost: String
        var allowedLogins: [String]
        var sharedLibraryIDs: [String]
        var mapsToken: String
        var descriptors: [LibraryDescriptor]
    }

    struct Status: Codable {
        let isRunning: Bool
        let message: String
        let isAuthorizing: Bool
        let updatedAt: Date
    }

    private static func file(_ name: String) throws -> URL {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            throw NSError(domain: "WebGallery", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The Web Gallery shared container is unavailable. Check App Group signing for both targets."
            ])
        }
        return root.appendingPathComponent(name)
    }

    static func publish(server: WebGalleryServer, registry: LibraryRegistry, enabled: Bool) throws {
        let descriptors = registry.descriptors.filter { server.sharedLibraryIDs.contains($0.id) }
            .map { descriptor in
                LibraryDescriptor(
                    id: descriptor.id, kind: descriptor.kind, bookmarkData: Data(),
                    addedAt: descriptor.addedAt, metadata: descriptor.metadata
                )
            }
        let snapshot = Snapshot(
            enabled: enabled, expectedHost: server.expectedHost,
            allowedLogins: server.allowedLogins,
            sharedLibraryIDs: server.sharedLibraryIDs.map { $0.rawValue.uuidString }.sorted(),
            mapsToken: server.mapsToken, descriptors: descriptors
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let url = try file("configuration.json")
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
    }

    static func load() throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file("configuration.json")))
    }

    static func writeStatus(isRunning: Bool, message: String, isAuthorizing: Bool = false) throws {
        let status = Status(isRunning: isRunning, message: message, isAuthorizing: isAuthorizing, updatedAt: .now)
        try JSONEncoder().encode(status).write(to: file("status.json"), options: .atomic)
    }

    static func loadStatus() throws -> Status {
        try JSONDecoder().decode(Status.self, from: Data(contentsOf: file("status.json")))
    }
}
