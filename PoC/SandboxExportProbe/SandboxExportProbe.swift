import AppKit
import Foundation

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments
    case wrongFolder
    case script(String)
    case unexpectedLibrary(Int)

    var description: String {
        switch self {
        case .invalidArguments: "Pass the exact dedicated test-folder path as the only argument."
        case .wrongFolder: "The selected folder was not the dedicated test folder. No export was attempted."
        case .script(let detail): "Photos Automation: \(detail)"
        case .unexpectedLibrary(let count): "Photos has \(count) items instead of 4,096. No export was attempted."
        }
    }
}

private struct ExportObservation {
    let scriptSeconds: TimeInterval
    let readySeconds: TimeInterval?
    let acceptedItems: Int
    let readyItems: Int
    let fileCount: Int
    let scriptError: String?
}

private let batchSize = 20
private let batchCount = 2
private let firstItemIndex = 2876

private func appleScriptStringLiteral(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func nonemptyFiles(in directory: URL) -> [URL] {
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return urls.filter { url in
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}

private func execute(_ source: String) throws -> NSAppleEventDescriptor {
    guard let script = NSAppleScript(source: source) else {
        throw ProbeError.script("Could not compile AppleScript")
    }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo { throw ProbeError.script(errorInfo.description) }
    return result
}

private func candidateIDs() throws -> [String] {
    let source = """
    with timeout of 60 seconds
        tell application id "com.apple.Photos"
            set libraryCount to count of media items
            if libraryCount is not 4096 then return libraryCount
            set itemIDs to {}
            repeat with itemIndex from \(firstItemIndex) to \(firstItemIndex + batchSize * batchCount - 1)
                set end of itemIDs to id of media item itemIndex as text
            end repeat
            return itemIDs
        end tell
    end timeout
    """
    let response = try execute(source)
    if response.numberOfItems == 0 {
        throw ProbeError.unexpectedLibrary(Int(response.int32Value))
    }
    let ids = (1...response.numberOfItems).compactMap { response.atIndex($0)?.stringValue }
    guard ids.count == batchSize * batchCount, Set(ids).count == ids.count else {
        throw ProbeError.script("The candidate ID list is incomplete or contains duplicates")
    }
    return ids
}

private func testRenderedBatch(_ identifiers: [String], to directory: URL) throws -> ExportObservation {
    let identifierList = identifiers.map(appleScriptStringLiteral).joined(separator: ", ")
    let source = """
    set requestedIDs to {\(identifierList)}
    set selectedItems to {}
    with timeout of 90 seconds
        tell application id "com.apple.Photos"
            repeat with requestedID in requestedIDs
                set requestedText to requestedID as text
                set targetItem to missing value
                try
                    set targetItem to media item id requestedText
                    if (id of targetItem as text) is not requestedText then set targetItem to missing value
                end try
                if targetItem is missing value then
                    set matchingItems to every media item whose id is requestedText
                    if (count of matchingItems) is greater than 0 then set targetItem to item 1 of matchingItems
                end if
                if targetItem is not missing value then set end of selectedItems to targetItem
            end repeat
            if (count of selectedItems) is greater than 0 then
                export selectedItems to POSIX file \(appleScriptStringLiteral(directory.path)) using originals false
            end if
        end tell
    end timeout
    return count of selectedItems
    """
    let started = Date()
    var errorDescription: String?
    var acceptedItems = 0
    do {
        let response = try execute(source)
        acceptedItems = Int(response.int32Value)
    } catch {
        errorDescription = String(describing: error)
    }
    let scriptSeconds = Date().timeIntervalSince(started)

    let waitStarted = Date()
    let deadline = waitStarted.addingTimeInterval(8)
    var readyItems = 0
    var fileCount = 0
    repeat {
        fileCount = nonemptyFiles(in: directory).count
        readyItems = min(fileCount, identifiers.count)
        if readyItems == identifiers.count {
            return ExportObservation(
                scriptSeconds: scriptSeconds,
                readySeconds: Date().timeIntervalSince(waitStarted),
                acceptedItems: acceptedItems,
                readyItems: readyItems,
                fileCount: fileCount,
                scriptError: errorDescription
            )
        }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    return ExportObservation(
        scriptSeconds: scriptSeconds,
        readySeconds: nil,
        acceptedItems: acceptedItems,
        readyItems: readyItems,
        fileCount: fileCount,
        scriptError: errorDescription
    )
}

private func report(_ label: String, _ observation: ExportObservation) {
    print("RESULT \(label) script-seconds=\(observation.scriptSeconds) ready-seconds=\(observation.readySeconds.map(String.init(describing:)) ?? "none") accepted=\(observation.acceptedItems)/20 ready=\(observation.readyItems)/20 files=\(observation.fileCount) script-error=\(observation.scriptError ?? "none")")
    fflush(stdout)
}

private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.run() }
    }

    private func run() {
        defer { NSApp.terminate(nil) }
        do {
            guard CommandLine.arguments.count == 2 else { throw ProbeError.invalidArguments }
            let expectedFolder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                .standardizedFileURL
            let panel = NSOpenPanel()
            panel.directoryURL = expectedFolder
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.prompt = "Use Test Folder"
            panel.message = "Select only the dedicated Photo Libraries sandbox test folder."
            print("PROBE waiting-for-test-folder-selection")
            fflush(stdout)
            guard panel.runModal() == .OK, let selectedFolder = panel.url else {
                print("RESULT cancelled; no export attempted")
                return
            }
            guard selectedFolder.standardizedFileURL == expectedFolder else {
                throw ProbeError.wrongFolder
            }
            let didStartAccess = selectedFolder.startAccessingSecurityScopedResource()
            defer { if didStartAccess { selectedFolder.stopAccessingSecurityScopedResource() } }

            let fileManager = FileManager.default
            let controlParent = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SandboxExportProbe", isDirectory: true)
            let control = controlParent.appendingPathComponent("control-\(UUID().uuidString)", isDirectory: true)
            let selected = selectedFolder.appendingPathComponent("selected-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: control, withIntermediateDirectories: true)
            defer {
                try? fileManager.removeItem(at: control)
                try? fileManager.removeItem(at: selected)
            }
            try fileManager.createDirectory(at: selected, withIntermediateDirectories: false)

            let identifiers = try candidateIDs()
            print("PROBE start=\(Date()) photos-items=4096 candidate-range=\(firstItemIndex)...\(firstItemIndex + identifiers.count - 1)")
            fflush(stdout)
            for batchIndex in 0..<batchCount {
                let batchIDs = Array(identifiers[(batchIndex * batchSize)..<((batchIndex + 1) * batchSize)])
                for (label, root) in [("app-container", control), ("selected-folder", selected)] {
                    let destination = root.appendingPathComponent("batch-\(batchIndex + 1)", isDirectory: true)
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
                    print("PROBE testing \(label) batch=\(batchIndex + 1) start=\(Date())")
                    fflush(stdout)
                    report("\(label)-batch-\(batchIndex + 1)", try testRenderedBatch(batchIDs, to: destination))
                    try fileManager.removeItem(at: destination)
                }
            }
            print("RESULT output-subdirectories-removed-on-exit=true")
            fflush(stdout)
        } catch {
            print("RESULT probe-error=\(error)")
            fflush(stdout)
        }
    }
}

let app = NSApplication.shared
private let delegate = ProbeDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
