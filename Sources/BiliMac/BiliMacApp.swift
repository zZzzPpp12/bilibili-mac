import SwiftUI

@main struct BiliMacApp: App {
    @State private var store = AppStore()
    init() {
        // Exercise the real .app bundle and AppStore initialization in CI without
        // creating a window, accessing credentials or contacting the network.
        if ProcessInfo.processInfo.arguments.contains("--check-startup") {
            guard Bundle.main.bundleIdentifier == AppSettings.domain,
                  AppSettings.defaults.object(forKey: "appearance") != nil else {
                fputs("Packaged application startup check failed\n", stderr)
                exit(EXIT_FAILURE)
            }
            print("Packaged application startup OK (\(AppSettings.domain))")
            exit(EXIT_SUCCESS)
        }
    }
    var body: some Scene {
        Window("BiliMac", id: "main") {
            RootView(store: store)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }.defaultSize(width: 1320, height: 880).windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .toolbar) {
                    Button("搜索") { store.searchFocus += 1 }.keyboardShortcut("f")
                    Button("刷新") { store.reload() }.keyboardShortcut("r")
                }
            }
        Settings { SettingsView() }
    }
}
