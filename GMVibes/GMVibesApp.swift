import SwiftUI

@main
struct GMVibesApp: App {
    @State private var gmccEnvironment = GMCCEnvironment()
    @State private var kbiteStore = KBiteStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(gmccEnvironment)
                .environment(kbiteStore)
        }

        WindowGroup("KBite File", id: "kbite-md", for: URL.self) { $url in
            KBiteMarkdownWindowView(url: url)
        }
    }
}
