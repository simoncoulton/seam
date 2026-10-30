import SwiftUI

@main
struct SeamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Seam", id: "main") {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 780)
        .commands { SeamCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { Workspace.shared.installMonitor() }
    }

    private let launchedAt = Date()

    /// Folders handed over by another app (`NSWorkspace.open(_:withApplicationAt:)`), Finder, or the Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            let ws = Workspace.shared
            for (i, url) in urls.enumerated() {
                // A cold launch starts with one untouched tab: use it for the first URL rather than leaving it behind.
                if i == 0, Date().timeIntervalSince(launchedAt) < 3, ws.tabs.count == 1 { ws.tab.go(url) }
                else { ws.newTab(at: url) }
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Menu entries mirror the keyboard shortcuts for discoverability. Key handling itself lives in
/// `Workspace.handle`, which sees events before the menu does.
struct SeamCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { Workspace.shared.newTab() }.keyboardShortcut("t")
            Button("New File") { Workspace.shared.newFile() }.keyboardShortcut("n")
            Button("New Folder") { Workspace.shared.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Close Tab") { Workspace.shared.closeTab(Workspace.shared.activeTab) }.keyboardShortcut("w")
        }
        CommandMenu("Go") {
            Button("Back") { Workspace.shared.tab.back() }
            Button("Forward") { Workspace.shared.tab.forward() }
            Button("Enclosing Folder") { Workspace.shared.tab.goUp() }
            Divider()
            Button("Search…") { Workspace.shared.openSearch() }.keyboardShortcut("k", modifiers: .control)
            Button("Go to Location…") { Workspace.shared.openLocation() }.keyboardShortcut("l", modifiers: .control)
            Button("Keyboard Shortcuts") { Workspace.shared.overlay = .shortcuts }
        }
        CommandMenu("Theme") {
            ForEach(Workspace.shared.themes) { t in
                Button(t.name) { Workspace.shared.setTheme(t) }
            }
            Divider()
            Button("Save Current Theme as TOML…") { Workspace.shared.saveThemeCopy() }
        }
    }
}
