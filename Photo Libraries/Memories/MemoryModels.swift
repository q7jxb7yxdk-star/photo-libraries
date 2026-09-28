import Foundation

/// A reference to an indexed asset. A library ID is always part of the key:
/// Photos may issue the same asset identifier in different libraries.
nonisolated struct MemoryPhoto: Identifiable, Hashable, Sendable {
    let libraryID: LibraryID
    let assetID: String
    let libraryName: String
    let date: Date
    let coordinate: SearchCoordinate?
    let placeName: String?
    let regionName: String?
    let isFavorite: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let isVideo: Bool

    var id: String {
        UnifiedSearchDocument.identifier(libraryID: libraryID, assetID: assetID)
    }
}

nonisolated struct PhotoMemory: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case onThisDay
        case trip
        case event
    }

    let id: String
    let kind: Kind
    let suggestedTitle: String
    let startDate: Date
    let endDate: Date
    let photos: [MemoryPhoto]

    var dateRange: String {
        let dates = startDate.formatted(date: .abbreviated, time: .omitted)
        return Calendar.current.isDate(startDate, inSameDayAs: endDate)
            ? dates
            : "\(dates) – \(endDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// Deterministic, metadata-only grouping. It never opens an original or writes
/// to a Photos library. Incomplete dates are omitted by the caller.
nonisolated enum MemoryGenerator {
    private struct HomeArea {
        let regionKey: String?
        let center: SearchCoordinate
    }

    static func generate(from input: [MemoryPhoto], now: Date) -> [PhotoMemory] {
        let calendar = Calendar.current
        let photos = input.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
        let home = inferHome(from: photos, calendar: calendar)
        var memories: [PhotoMemory] = []

        let today = calendar.dateComponents([.month, .day, .year], from: now)
        let anniversaries = Dictionary(grouping: photos.filter { photo in
            let parts = calendar.dateComponents([.month, .day, .year], from: photo.date)
            return parts.month == today.month && parts.day == today.day
                && parts.year != today.year
        }) { calendar.component(.year, from: $0.date) }
        for (year, group) in anniversaries where group.count >= 3 {
            let ordered = group.sorted { $0.date < $1.date }
            guard let first = ordered.first, let last = ordered.last else { continue }
            memories.append(PhotoMemory(
                id: "on-this-day:\(year):\(today.month ?? 0):\(today.day ?? 0)",
                kind: .onThisDay,
                suggestedTitle: "On This Day · \(year)",
                startDate: first.date,
                endDate: last.date,
                photos: ordered
            ))
        }

        var eventCandidates: [PhotoMemory] = []
        var session: [MemoryPhoto] = []
        var previous: MemoryPhoto?
        func appendCandidate(_ group: [MemoryPhoto], isTrip: Bool) {
            guard group.count >= 5,
                  let first = group.first,
                  let last = group.last else { return }
            let place = group.compactMap(\.placeName).first { !$0.isEmpty }
            let destination = group.first { photo in
                if let region = normalizedRegion(photo.regionName),
                   let homeRegion = home?.regionKey, region != homeRegion {
                    return true
                }
                if let point = photo.coordinate, let home {
                    return distanceKilometres(point, home.center) > 40
                }
                return false
            }
            let tripPlace = [destination?.placeName, destination?.regionName, place]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            let title: String
            if isTrip {
                title = tripPlace.map {
                    "Trip in \($0) · \(first.date.formatted(date: .abbreviated, time: .omitted))"
                }
                    ?? "Trip · \(first.date.formatted(.dateTime.month(.wide).year()))"
            } else {
                title = place.map {
                    "Moments in \($0) · \(first.date.formatted(date: .abbreviated, time: .omitted))"
                }
                    ?? "Moments · \(first.date.formatted(date: .abbreviated, time: .omitted))"
            }
            eventCandidates.append(PhotoMemory(
                id: "event:\(group.map(\.id).min() ?? first.id)",
                kind: isTrip ? .trip : .event,
                suggestedTitle: title,
                startDate: first.date,
                endDate: last.date,
                photos: group
            ))
        }

        func finishSession() {
            defer { session.removeAll(keepingCapacity: true) }
            guard !session.isEmpty else { return }
            // Keep a continuous journey across days. Local activities need a
            // much tighter time and place window, including across midnight.
            if isAwayFromHome(session, home: home) {
                appendCandidate(session, isTrip: true)
                return
            }

            var moment: [MemoryPhoto] = []
            var previousMomentPhoto: MemoryPhoto?
            func finishMoment() {
                appendCandidate(moment, isTrip: isAwayFromHome(moment, home: home))
                moment.removeAll(keepingCapacity: true)
            }
            for photo in session {
                if let previousMomentPhoto {
                    let gap = photo.date.timeIntervalSince(previousMomentPhoto.date)
                    let nearby: Bool
                    if let previousLocation = previousMomentPhoto.coordinate,
                       let location = photo.coordinate {
                        nearby = distanceKilometres(previousLocation, location) <= 5
                    } else {
                        nearby = true
                    }
                    if gap > 2 * 3_600 || !nearby {
                        finishMoment()
                    }
                }
                moment.append(photo)
                previousMomentPhoto = photo
            }
            finishMoment()
        }

        for photo in photos {
            if let previous {
                let gap = photo.date.timeIntervalSince(previous.date)
                let closeEnough: Bool
                if let previousLocation = previous.coordinate,
                   let location = photo.coordinate {
                    closeEnough = distanceKilometres(previousLocation, location) <= 100
                } else {
                    closeEnough = gap <= 8 * 3_600
                }
                let span = photo.date.timeIntervalSince(session.first?.date ?? photo.date)
                if gap > 36 * 3_600 || span > 14 * 86_400 || !closeEnough {
                    finishSession()
                }
            }
            session.append(photo)
            previous = photo
        }
        finishSession()
        memories.append(contentsOf: curate(eventCandidates, calendar: calendar))

        return memories.sorted {
            if $0.kind == .onThisDay && $1.kind != .onThisDay { return true }
            if $1.kind == .onThisDay && $0.kind != .onThisDay { return false }
            if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
            return $0.id < $1.id
        }
    }

    /// Count distinct shooting days, not photos, so a burst-heavy holiday does
    /// not become the user's inferred home. A small sample needs a clear lead.
    private static func inferHome(from photos: [MemoryPhoto], calendar: Calendar) -> HomeArea? {
        let located = photos.filter { $0.coordinate != nil }
        let cells = Dictionary(grouping: located) { photo -> String in
            guard let point = photo.coordinate else { return "" }
            return "\(Int((point.latitude * 2).rounded())):\(Int((point.longitude * 2).rounded()))"
        }
        let eligibleCells = cells.filter { hasHomeEvidence($0.value, calendar: calendar) }
        let rankedCells = eligibleCells.sorted { lhs, rhs in
            let left = evidenceScore(lhs.value, calendar: calendar)
            let right = evidenceScore(rhs.value, calendar: calendar)
            return left == right ? lhs.key < rhs.key : left > right
        }
        guard let best = rankedCells.first else { return nil }
        let bestDays = evidenceScore(best.value, calendar: calendar)
        let runnerDays = rankedCells.count > 1
            ? evidenceScore(rankedCells[1].value, calendar: calendar) : 0
        guard bestDays != runnerDays,
              bestDays >= 10 || bestDays >= runnerDays * 2,
              let center = medianCoordinate(of: best.value) else { return nil }

        // Place-name resolution may still be in progress. Use it only to name
        // the coordinate-backed home area, never to choose the home area.
        let nearby = located.filter { photo in
            guard let point = photo.coordinate else { return false }
            return distanceKilometres(point, center) <= 40
        }
        let named = Dictionary(grouping: nearby.compactMap { photo -> (String, MemoryPhoto)? in
            guard let key = normalizedRegion(photo.regionName) else { return nil }
            return (key, photo)
        }) { $0.0 }
        let rankedNamed = named.sorted { lhs, rhs in
            let left = evidenceScore(lhs.value.map { $0.1 }, calendar: calendar)
            let right = evidenceScore(rhs.value.map { $0.1 }, calendar: calendar)
            return left == right ? lhs.key < rhs.key : left > right
        }
        let regionKey: String?
        if let first = rankedNamed.first {
            let firstDays = evidenceScore(first.value.map { $0.1 }, calendar: calendar)
            let secondDays = rankedNamed.count > 1
                ? evidenceScore(rankedNamed[1].value.map { $0.1 }, calendar: calendar) : 0
            regionKey = firstDays >= 2 && firstDays > secondDays ? first.key : nil
        } else {
            regionKey = nil
        }
        return HomeArea(regionKey: regionKey, center: center)
    }

    private static func evidenceScore(_ photos: [MemoryPhoto], calendar: Calendar) -> Int {
        Set(photos.map { calendar.startOfDay(for: $0.date) }).count
    }

    private static func hasHomeEvidence(_ photos: [MemoryPhoto], calendar: Calendar) -> Bool {
        evidenceScore(photos, calendar: calendar) >= 2
    }

    private static func medianCoordinate(of photos: [MemoryPhoto]) -> SearchCoordinate? {
        let points = photos.compactMap(\.coordinate)
        guard !points.isEmpty else { return nil }
        let latitudes = points.map(\.latitude).sorted()
        let longitudes = points.map(\.longitude).sorted()
        return SearchCoordinate(
            latitude: latitudes[latitudes.count / 2],
            longitude: longitudes[longitudes.count / 2]
        )
    }

    private static func isAwayFromHome(_ photos: [MemoryPhoto], home: HomeArea?) -> Bool {
        guard let home else { return false }
        let located = photos.filter { $0.coordinate != nil }
        guard !located.isEmpty else { return false }

        if let homeRegion = home.regionKey {
            let named = located.compactMap { normalizedRegion($0.regionName) }
            if !named.isEmpty {
                let away = named.filter { $0 != homeRegion }.count
                if away > 0 && away * 2 >= named.count { return true }
                if named.filter({ $0 == homeRegion }).count * 2 > named.count { return false }
            }
        }

        let distances = located.compactMap { photo -> Double? in
            guard let point = photo.coordinate else { return nil }
            return distanceKilometres(point, home.center)
        }
        let far = distances.filter { $0 > 200 }.count
        if far > 0 && far * 2 >= distances.count { return true }
        let away = distances.filter { $0 > 40 }.count
        return away >= 2 && away * 5 >= distances.count * 3
    }

    private static func normalizedRegion(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        let normalized = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        ).lowercased()
        if normalized.contains("hong kong") || normalized.contains("香港") {
            return "hong kong"
        }
        return normalized
    }

    /// Keep the strongest moment at a place each month, with a small overall cap
    /// for frequently photographed locations.
    private static func curate(
        _ candidates: [PhotoMemory], calendar: Calendar
    ) -> [PhotoMemory] {
        var chosen: [PhotoMemory] = []
        var usedMonths = Set<String>()
        var locationCounts: [String: Int] = [:]
        let ranked = candidates.sorted {
            let leftFavorites = $0.photos.filter(\.isFavorite).count
            let rightFavorites = $1.photos.filter(\.isFavorite).count
            if leftFavorites != rightFavorites { return leftFavorites > rightFavorites }
            if $0.photos.count != $1.photos.count { return $0.photos.count > $1.photos.count }
            if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
            return $0.id < $1.id
        }
        for memory in ranked {
            guard memory.kind == .event else {
                chosen.append(memory)
                continue
            }
            let location = locationKey(for: memory)
            let month = monthKey(for: memory, calendar: calendar)
            guard !usedMonths.contains(month), locationCounts[location, default: 0] < 6 else {
                continue
            }
            chosen.append(memory)
            usedMonths.insert(month)
            locationCounts[location, default: 0] += 1
        }
        return chosen
    }

    private static func monthKey(for memory: PhotoMemory, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: memory.startDate)
        return "\(locationKey(for: memory)):\(parts.year ?? 0):\(parts.month ?? 0)"
    }

    private static func locationKey(for memory: PhotoMemory) -> String {
        if let city = memory.photos.compactMap(\.placeName).first(where: { !$0.isEmpty }) {
            return "city:\(city.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased())"
        }
        if let coordinate = memory.photos.compactMap(\.coordinate).first {
            return "area:\(Int((coordinate.latitude * 4).rounded())):\(Int((coordinate.longitude * 4).rounded()))"
        }
        return "unknown"
    }

    private static func distanceKilometres(_ first: SearchCoordinate, _ second: SearchCoordinate) -> Double {
        let lat1 = first.latitude * .pi / 180
        let lat2 = second.latitude * .pi / 180
        let latitude = (second.latitude - first.latitude) * .pi / 180
        let longitude = (second.longitude - first.longitude) * .pi / 180
        let haversine = pow(sin(latitude / 2), 2)
            + cos(lat1) * cos(lat2) * pow(sin(longitude / 2), 2)
        return 6_371 * 2 * asin(min(1, sqrt(haversine)))
    }
}
