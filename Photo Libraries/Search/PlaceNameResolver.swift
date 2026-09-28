import CoreLocation
import Foundation
import MapKit

actor PlaceNameResolver {
    private static let minimumRequestInterval: TimeInterval = 1.5
    private static let maximumTransientRetryCount = 3

    private var cache: [String: SearchPlace]
    private var inFlight: [String: Task<SearchPlace?, Never>] = [:]
    private var nextRequestDate = Date.distantPast
    private let cacheURL: URL

    init() throws {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw UnifiedSearchIndexError.applicationSupportUnavailable
        }
        let directory = applicationSupport
            .appendingPathComponent("Photo Libraries", isDirectory: true)
            .appendingPathComponent("Search Index", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("places.json", isDirectory: false)
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: SearchPlace].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func resolve(_ coordinate: SearchCoordinate) async -> SearchPlace? {
        let key = coordinate.cacheKey
        if let cached = cache[key] { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task<SearchPlace?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.resolveUncached(coordinate)
        }
        inFlight[key] = task
        let place = await task.value
        inFlight[key] = nil
        if let place {
            cache[key] = place
            try? persistCache()
        }
        return place
    }

    private func resolveUncached(_ coordinate: SearchCoordinate) async -> SearchPlace? {
        var transientRetryCount = 0

        while !Task.isCancelled {
            do {
                try await waitForRequestSlot()
                let location = CLLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                guard let request = MKReverseGeocodingRequest(location: location),
                      let mapItem = try await request.mapItems.first else {
                    return nil
                }
                return SearchPlace(
                    name: mapItem.name ?? "",
                    city: mapItem.addressRepresentations?.cityName ?? "",
                    country: mapItem.addressRepresentations?.regionName ?? "",
                    formattedAddress: mapItem.address?.fullAddress ?? ""
                )
            } catch is CancellationError {
                return nil
            } catch {
                if let resetDelay = Self.throttleResetDelay(for: error) {
                    guard await sleep(seconds: resetDelay + 1) else { return nil }
                    continue
                }
                if Self.isPermanentNoResult(error) { return nil }

                transientRetryCount += 1
                guard transientRetryCount <= Self.maximumTransientRetryCount else {
                    return nil
                }
                let retryDelay = min(pow(2, Double(transientRetryCount)), 10)
                guard await sleep(seconds: retryDelay) else { return nil }
            }
        }
        return nil
    }

    /// Reserves request slots before sleeping so actor reentrancy cannot let
    /// multiple callers wake and send a burst together.
    private func waitForRequestSlot() async throws {
        let now = Date()
        let scheduledDate = nextRequestDate > now ? nextRequestDate : now
        nextRequestDate = scheduledDate.addingTimeInterval(Self.minimumRequestInterval)
        let delay = scheduledDate.timeIntervalSince(now)
        guard delay > 0 else { return }
        try await Task.sleep(for: .milliseconds(Int64(ceil(delay * 1_000))))
    }

    private func sleep(seconds: TimeInterval) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        do {
            try await Task.sleep(for: .milliseconds(Int64(ceil(seconds * 1_000))))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    nonisolated private static func throttleResetDelay(for error: Error) -> TimeInterval? {
        let nsError = error as NSError
        let isThrottled = (nsError.domain == MKErrorDomain && nsError.code == 3)
            || (nsError.domain == "GEOErrorDomain" && nsError.code == -3)
        guard isThrottled else { return nil }

        if let value = nsError.userInfo["timeUntilReset"] as? NSNumber {
            return max(value.doubleValue, 1)
        }
        if let details = nsError.userInfo["details"] as? [NSDictionary],
           let delay = details.compactMap({
               ($0["timeUntilReset"] as? NSNumber)?.doubleValue
           }).max() {
            return max(delay, 1)
        }
        return 10
    }

    nonisolated private static func isPermanentNoResult(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == MKErrorDomain && nsError.code == 4
    }

    private func persistCache() throws {
        let data = try JSONEncoder().encode(cache)
        try data.write(to: cacheURL, options: .atomic)
    }
}
