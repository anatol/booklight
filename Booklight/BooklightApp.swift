import SwiftUI

@main
struct BooklightApp: App {
    /// One library for the whole app. Each window (iPad multitasking, Mac
    /// Catalyst File > New Window) shares it, so there is a single poller and a
    /// single progress write queue per tracking directory.
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
        }
    }
}
