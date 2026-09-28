// Standalone, non-destructive benchmark. It exports ten rendered previews to
// private temporary staging and removes only that newly created staging tree.
// It never exports originals or accesses a .photoslibrary package directly.

import Foundation

enum ProbeError: Error, CustomStringConvertible {
    case script(String)
    case unexpectedLibraryCount(Int)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .script(let detail): "AppleScript failed: \(detail)"
        case .unexpectedLibraryCount(let count): "Photos has \(count) items, not the expected 4,096; no export was attempted."
        case .malformedResponse(let detail): "Malformed Photos response: \(detail)"
        }
    }
}

func runScript(_ source: String) throws -> NSAppleEventDescriptor {
    guard let script = NSAppleScript(source: source) else {
        throw ProbeError.script("Could not compile the script")
    }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        throw ProbeError.script(errorInfo.description)
    }
    return result
}

func listStrings(_ descriptor: NSAppleEventDescriptor?) throws -> [String] {
    guard let descriptor else { throw ProbeError.malformedResponse("Missing list") }
    guard descriptor.numberOfItems > 0 else { return [] }
    return try (1...descriptor.numberOfItems).map { index in
        guard let value = descriptor.atIndex(index)?.stringValue else {
            throw ProbeError.malformedResponse("Missing string at index \(index)")
        }
        return value
    }
}

func files(in directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ))?.filter { url in
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
    } ?? []
}

func waitForFiles(in directories: [URL], minimum: Int, seconds: TimeInterval) -> (Int, TimeInterval) {
    let started = Date()
    let deadline = started.addingTimeInterval(seconds)
    var count = 0
    repeat {
        count = directories.reduce(0) { $0 + files(in: $1).count }
        if count >= minimum { break }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    return (count, Date().timeIntervalSince(started))
}

let selectionStart = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 1) : 1
let selectionCount = 10
guard selectionStart >= 1, selectionStart + selectionCount - 1 <= 4096 else {
    throw ProbeError.malformedResponse("Selection range must fit within 1...4096")
}
let countResponse = try runScript("""
with timeout of 30 seconds
    tell application id "com.apple.Photos" to return count of media items
end timeout
""")
let libraryCount = Int(countResponse.int32Value)
guard libraryCount == 4096 else { throw ProbeError.unexpectedLibraryCount(libraryCount) }
print("RESULT verified-photos-item-count=\(libraryCount)")
print("RESULT selection-range=\(selectionStart)...\(selectionStart + selectionCount - 1)")

let metadataResponse = try runScript("""
with timeout of 30 seconds
    tell application id "com.apple.Photos"
        set itemIDs to {}
        set itemFilenames to {}
        repeat with itemIndex from \(selectionStart) to \(selectionStart + selectionCount - 1)
            set targetItem to media item itemIndex
            set end of itemIDs to id of targetItem as text
            set end of itemFilenames to filename of targetItem as text
        end repeat
        return {itemIDs, itemFilenames}
    end tell
end timeout
""")
let identifiers = try listStrings(metadataResponse.atIndex(1))
let filenames = try listStrings(metadataResponse.atIndex(2))
guard identifiers.count == selectionCount, filenames.count == selectionCount else {
    throw ProbeError.malformedResponse("Expected ten IDs and filenames")
}

let staging = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent("PhotoLibrariesBulkProbe-\(UUID().uuidString)", isDirectory: true)
let bulkDirectory = staging.appendingPathComponent("bulk", isDirectory: true)
let isolatedDirectory = staging.appendingPathComponent("isolated", isDirectory: true)
try FileManager.default.createDirectory(at: bulkDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: isolatedDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: staging) }

let bulkScript = """
with timeout of 120 seconds
    tell application id "com.apple.Photos"
        set selectedItems to {}
        repeat with itemIndex from \(selectionStart) to \(selectionStart + selectionCount - 1)
            set end of selectedItems to media item itemIndex
        end repeat
        export selectedItems to POSIX file "\(bulkDirectory.path)" using originals false
    end tell
end timeout
return "done"
"""
let bulkStarted = Date()
_ = try runScript(bulkScript)
let bulkCommandSeconds = Date().timeIntervalSince(bulkStarted)
let (bulkFileCount, bulkWaitSeconds) = waitForFiles(
    in: [bulkDirectory], minimum: selectionCount, seconds: 30
)
let exportedNames = files(in: bulkDirectory).map { $0.deletingPathExtension().lastPathComponent.lowercased() }
let expectedNames = filenames.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() }
let uniqueExpectedNames = Set(expectedNames)
let unambiguousMatches = expectedNames.filter { name in
    uniqueExpectedNames.count == expectedNames.count && exportedNames.filter { $0 == name }.count == 1
}.count
print("RESULT bulk command-seconds=\(bulkCommandSeconds) ready-wait-seconds=\(bulkWaitSeconds) file-count=\(bulkFileCount) unambiguous-filename-matches=\(unambiguousMatches)/\(selectionCount)")

var isolatedCommands: [String] = []
var itemDirectories: [URL] = []
for index in selectionStart..<(selectionStart + selectionCount) {
    let directory = isolatedDirectory.appendingPathComponent(String(format: "%04d", index), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    itemDirectories.append(directory)
    isolatedCommands.append("export {media item \(index)} to POSIX file \"\(directory.path)\" using originals false")
}
let isolatedScript = """
with timeout of 120 seconds
    tell application id "com.apple.Photos"
        \(isolatedCommands.joined(separator: "\n        "))
    end tell
end timeout
return "done"
"""
let isolatedStarted = Date()
_ = try runScript(isolatedScript)
let isolatedCommandSeconds = Date().timeIntervalSince(isolatedStarted)
let (isolatedFileCount, isolatedWaitSeconds) = waitForFiles(
    in: itemDirectories, minimum: selectionCount, seconds: 30
)
let mappedDirectories = itemDirectories.filter { !files(in: $0).isEmpty }.count
print("RESULT isolated command-seconds=\(isolatedCommandSeconds) ready-wait-seconds=\(isolatedWaitSeconds) file-count=\(isolatedFileCount) mapped-directories=\(mappedDirectories)/\(selectionCount)")
print("RESULT staging-removed-on-exit=true")
