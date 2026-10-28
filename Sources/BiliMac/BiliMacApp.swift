import SwiftUI

@main struct BiliMacApp: App {
    @State private var store = AppStore()
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
