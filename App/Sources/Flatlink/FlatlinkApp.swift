import AppKit
import SwiftUI

@main
struct FlatlinkApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var library = Library()
    @State private var loginItem = LoginItem()
    @State private var selection: Pair.ID?

    var body: some Scene {
        Window("Flatlink", id: "main") {
            ContentView(library: library, selection: $selection)
                .frame(minWidth: 760, minHeight: 540)
                .tint(.marigold)
                .environment(loginItem)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    library.forgetPlans()
                    loginItem.refresh()
                }
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Photo Folder…") {
                    if let source = Panels.chooseSource() { selection = library.add(source: source).id }
                }
                .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView(loginItem: loginItem)
                .tint(.marigold)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Watching goes on with the window closed; the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opened at login, Flatlink is there to watch: its window would only be in the way, so the app starts
    /// hidden, as ⌘H leaves it. Hiding the window itself instead leaves SwiftUI a window it never lays out.
    func applicationDidFinishLaunching(_ notification: Notification) {
        if LoginItem.launchedAtLogin { NSApp.hide(nil) }
    }

    /// Clicking the app in the Dock shows it again, even where activating it doesn't unhide it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if NSApp.isHidden { NSApp.unhide(nil) }
        return true
    }
}

/// The open panels and the things done in other apps.
@MainActor
enum Panels {
    static func chooseSource(startingAt path: String? = nil) -> String? {
        choose(
            message: "Choose the folder that holds your photos, in as many subfolders as you like.",
            prompt: "Choose Photos", startingAt: path, canCreate: false
        )
    }

    static func chooseDest(startingAt path: String? = nil) -> String? {
        choose(
            message: "Choose the flat folder to fill with links. PhotoLab keeps your edits here, so keep it once you use it.",
            prompt: "Choose Link Folder", startingAt: path, canCreate: true
        )
    }

    private static func choose(message: String, prompt: String, startingAt path: String?, canCreate: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreate
        panel.message = message
        panel.prompt = prompt
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// PhotoLab, which opens a folder it is handed as its current folder.
    static var photoLab: URL? {
        let workspace = NSWorkspace.shared
        for version in (9...14).reversed() {
            if let url = workspace.urlForApplication(withBundleIdentifier: "com.dxo.PhotoLab\(version)") { return url }
        }
        return nil
    }

    static func openInPhotoLab(_ path: String) {
        guard let app = photoLab else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

