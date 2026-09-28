// Standalone, read-only probe. It does not link to or modify the app target.
// Run only while Photos is already showing the library under investigation.

import AppKit
import Foundation
import MediaLibrary

func waitForValue<Value>(seconds: TimeInterval, _ read: () -> Value?) -> Value? {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let value = read() { return value }
        RunLoop.current.run(until: min(Date().addingTimeInterval(0.1), deadline))
    } while Date() < deadline
    return nil
}

func walk(_ group: MLMediaGroup, seen: inout Set<String>) -> [MLMediaGroup] {
    guard seen.insert(group.identifier).inserted else { return [] }
    var result = [group]
    for child in group.childGroups ?? [] {
        result.append(contentsOf: walk(child, seen: &seen))
    }
    return result
}

let started = Date()
let library = MLMediaLibrary(options: [
    MLMediaLoadIncludeSourcesKey: [MLMediaSourcePhotosIdentifier]
])

_ = library.mediaSources // Starts MediaLibrary's asynchronous source load.
guard let sources = waitForValue(seconds: 45, { library.mediaSources }) else {
    print("RESULT source-timeout elapsed=\(Date().timeIntervalSince(started))")
    exit(2)
}

print("RESULT source-count=\(sources.count) source-ids=\(sources.keys.sorted())")
guard let source = sources[MLMediaSourcePhotosIdentifier] else {
    print("RESULT photos-source-unavailable")
    exit(3)
}

print("RESULT source-attribute-keys=\(source.attributes.keys.sorted())")
_ = source.rootMediaGroup // Starts MediaLibrary's asynchronous group load.
guard let root = waitForValue(seconds: 45, { source.rootMediaGroup }) else {
    print("RESULT root-group-timeout elapsed=\(Date().timeIntervalSince(started))")
    exit(4)
}

var seen = Set<String>()
let groups = walk(root, seen: &seen)
print("RESULT group-count=\(groups.count)")
let allPhotos = groups.filter { $0.typeIdentifier == MLPhotosAllPhotosAlbumTypeIdentifier }
print("RESULT all-photos-group-count=\(allPhotos.count)")
for (index, group) in allPhotos.enumerated() {
    _ = group.mediaObjects // Starts asynchronous media-object load.
    guard let objects = waitForValue(seconds: 90, { group.mediaObjects }) else {
        print("RESULT group=\(index) media-objects-timeout")
        continue
    }

    let uniqueObjects = Dictionary(objects.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    let thumbnailURLs = uniqueObjects.values.compactMap(\.thumbnailURL)
    let sample = Array(thumbnailURLs.prefix(20))
    let decodableSampleCount = sample.filter { NSImage(contentsOf: $0) != nil }.count
    let packagePaths = Set(uniqueObjects.values.compactMap { object -> String? in
        guard let path = object.url?.path,
              let range = path.range(of: ".photoslibrary", options: .caseInsensitive) else {
            return nil
        }
        return String(path[..<range.upperBound])
    })
    print("RESULT group=\(index) items=\(objects.count) unique-items=\(uniqueObjects.count) thumbnail-urls=\(thumbnailURLs.count) sample-decodable=\(decodableSampleCount)/\(sample.count) package-paths=\(packagePaths.sorted()) elapsed=\(Date().timeIntervalSince(started))")
}
