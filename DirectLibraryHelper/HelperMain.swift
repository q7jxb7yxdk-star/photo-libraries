import Foundation

@main enum DirectLibraryHelperEntry {
    @MainActor static func main() async {
        await DirectLibraryWorkerMain.run()
    }
}
